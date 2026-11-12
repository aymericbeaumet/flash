//! Shared JSON boundary rules, exercised against the wire-values corpus the
//! host's XCTest suites also consume.

use serde::{Deserialize, Deserializer};
use serde_json::Value;

pub(crate) fn pid(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .filter(|pid| (1..=i64::from(i32::MAX)).contains(pid))
}

pub(crate) fn deserialize_pid<'de, D: Deserializer<'de>>(input: D) -> Result<i64, D::Error> {
    pid(&Value::deserialize(input)?)
        .ok_or_else(|| serde::de::Error::custom("invalid process identifier"))
}

pub(crate) fn deserialize_optional_pid<'de, D: Deserializer<'de>>(
    input: D,
) -> Result<Option<i64>, D::Error> {
    let value = Value::deserialize(input)?;
    if value.is_null() {
        Ok(None)
    } else {
        pid(&value)
            .map(Some)
            .ok_or_else(|| serde::de::Error::custom("invalid process identifier"))
    }
}

fn present<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.get(key).filter(|value| !value.is_null())
}

fn only_keys(value: &Value, allowed: &[&str]) -> bool {
    value
        .as_object()
        .is_some_and(|object| object.keys().all(|key| allowed.contains(&key.as_str())))
}

/// A `core:status.observed` segment set: present, every name nonempty and
/// unique. An empty set is authoritative (nothing is observed).
pub(crate) fn valid_segment_set(segments: Option<&[String]>) -> bool {
    segments.is_some_and(|segments| {
        let mut seen = std::collections::BTreeSet::new();
        segments
            .iter()
            .all(|segment| !segment.is_empty() && seen.insert(segment.as_str()))
    })
}

pub(crate) fn absolute_url(value: &str) -> bool {
    let Some((scheme, _)) = value.split_once(':') else {
        return false;
    };
    scheme.starts_with(|character: char| character.is_ascii_alphabetic())
        && scheme
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"+-.".contains(&byte))
}

pub(crate) fn valid_result(method: &str, result: &Value) -> bool {
    let Some(object) = result.as_object() else {
        return false;
    };
    let Some(ok) = result.get("ok").and_then(Value::as_bool) else {
        return false;
    };
    if !ok {
        return if method == "perform" && result.get("unhandled") == Some(&Value::Bool(true)) {
            only_keys(result, &["ok", "unhandled"])
        } else {
            only_keys(result, &["ok", "error"])
                && result
                    .get("error")
                    .and_then(Value::as_str)
                    .is_some_and(|error| !error.trim().is_empty())
        };
    }
    if object.contains_key("error") || object.contains_key("unhandled") {
        return false;
    }
    if present(result, "target_pid").is_some_and(|value| pid(value).is_none()) {
        return false;
    }
    if ["navigation_url", "message"]
        .iter()
        .any(|key| present(result, key).is_some_and(|value| !value.is_string()))
    {
        return false;
    }
    if method == "hints" {
        if !only_keys(result, &["ok", "targets", "context_pid"])
            || present(result, "context_pid").is_some_and(|value| pid(value).is_none())
        {
            return false;
        }
        return result
            .get("targets")
            .and_then(Value::as_array)
            .is_some_and(|targets| targets.iter().all(valid_target));
    }
    if method == "text_grid" {
        return valid_text_grid(result);
    }
    if method == "perform" {
        return only_keys(result, &["ok", "target_pid", "navigation_url", "message"])
            && present(result, "navigation_url")
                .and_then(Value::as_str)
                .is_none_or(absolute_url);
    }
    true
}

/// Columns and rows of a `text_grid` reply are each at most this: tmux's own
/// window limit, so a grid the host lays out stays bounded.
pub(crate) const MAX_TEXT_GRID_DIMENSION: u64 = 10_000;

/// The host's catalog byte quota (`quotas.catalog_bytes`): the bytes of the
/// `rows` array as written in the publish frame, summed over the plugin's
/// sources after a per-source merge. The SDK enforces nothing here — the
/// host rejects an over-quota publish whole — but its publish frames are
/// pinned to add exactly the envelope around the compact rows, so a plugin
/// can size its catalog by the compact encoding alone.
#[cfg(test)]
pub(crate) const MAX_CATALOG_BYTES: usize = 4 * 1024 * 1024;

/// A `text_grid` success: `columns` × `rows` cells and lines inside them,
/// each captured text `{row, column, text}` or a status format laid out over
/// `{row, column, width, format}` cells.
fn valid_text_grid(result: &Value) -> bool {
    let dimension = |key: &str| {
        result
            .get(key)
            .and_then(Value::as_u64)
            .filter(|value| *value <= MAX_TEXT_GRID_DIMENSION)
    };
    let (Some(columns), Some(rows)) = (dimension("columns"), dimension("rows")) else {
        return false;
    };
    if !only_keys(result, &["ok", "columns", "rows", "lines"]) {
        return false;
    }
    let Some(lines) = result.get("lines").and_then(Value::as_array) else {
        return false;
    };
    lines.iter().all(|line| {
        let cell =
            |key: &str, bound: u64| line.get(key).and_then(Value::as_u64).filter(|v| *v < bound);
        let (Some(_), Some(column)) = (cell("row", rows), cell("column", columns)) else {
            return false;
        };
        let Some(object) = line.as_object() else {
            return false;
        };
        if object.contains_key("text") {
            return object.len() == 3 && line["text"].is_string();
        }
        object.len() == 4
            && line.get("format").is_some_and(Value::is_string)
            && line
                .get("width")
                .and_then(Value::as_u64)
                .is_some_and(|width| width >= 1 && width <= columns - column)
    })
}

/// Every key of one hint target (`protocol.json` `hint_target`): `id` and
/// `frame` are required, the rest optional.
const HINT_TARGET_KEYS: &[&str] = &[
    "id",
    "frame",
    "role",
    "label",
    "url",
    "pid",
    "priority",
    "context_id",
];

fn valid_target(target: &Value) -> bool {
    if !only_keys(target, HINT_TARGET_KEYS)
        || target
            .get("id")
            .and_then(Value::as_str)
            .is_none_or(str::is_empty)
    {
        return false;
    }
    let Some(frame) = target.get("frame").and_then(Value::as_object) else {
        return false;
    };
    if frame.len() != 4 {
        return false;
    }
    for key in ["x", "y", "width", "height"] {
        let Some(number) = frame.get(key).and_then(Value::as_f64) else {
            return false;
        };
        if !number.is_finite() || (matches!(key, "width" | "height") && number <= 0.0) {
            return false;
        }
    }
    if !["x", "y"]
        .iter()
        .zip(["width", "height"])
        .all(|(origin, size)| {
            (frame[*origin].as_f64().unwrap() + frame[size].as_f64().unwrap()).is_finite()
        })
    {
        return false;
    }
    if present(target, "pid").is_some_and(|value| pid(value).is_none()) {
        return false;
    }
    if present(target, "context_id").is_some_and(|value| value.as_str().is_none_or(str::is_empty)) {
        return false;
    }
    if ["id", "role", "label", "url"]
        .iter()
        .any(|key| present(target, key).is_some_and(|value| !value.is_string()))
    {
        return false;
    }
    if present(target, "priority").is_some_and(|value| {
        !matches!(
            value.as_str(),
            Some("low" | "normal" | "high" | "important" | "urgent")
        )
    }) {
        return false;
    }
    true
}

/// Whether `params` is a `poll` registration set the host accepts: exactly
/// `registrations`, at most `poll.max_registrations` names of
/// `[a-z0-9_-]{1,max_name_bytes}`, each exactly one of `every` (seconds,
/// floored at `min_every_ms`) or `after` (seconds, from zero) up to
/// `max_seconds`, and a plugin `priority`. Mirrors the host's decoder; the
/// shared corpus pins both.
pub(crate) fn valid_poll(params: &Value) -> bool {
    use crate::poll::{MAX_NAME_BYTES, MAX_REGISTRATIONS, MAX_SECONDS, MIN_EVERY, PollPriority};
    let Some(registrations) = params.get("registrations").and_then(Value::as_object) else {
        return false;
    };
    if !only_keys(params, &["registrations"]) || registrations.len() > MAX_REGISTRATIONS {
        return false;
    }
    registrations.iter().all(|(name, entry)| {
        let valid_name = !name.is_empty()
            && name.len() <= MAX_NAME_BYTES
            && name
                .bytes()
                .all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'_' | b'-'));
        let priority = entry.get("priority").and_then(Value::as_str);
        let valid_priority = PollPriority::ALL
            .iter()
            .any(|known| Some(known.wire()) == priority);
        let kinds: Vec<&str> = ["every", "after"]
            .into_iter()
            .filter(|kind| present(entry, kind).is_some())
            .collect();
        let [kind] = kinds.as_slice() else {
            return false;
        };
        let seconds = entry
            .get(*kind)
            .filter(|value| value.is_number())
            .and_then(Value::as_f64);
        let floor = if *kind == "every" {
            MIN_EVERY.as_secs_f64()
        } else {
            0.0
        };
        valid_name
            && valid_priority
            && only_keys(entry, &[kind, "priority"])
            && seconds.is_some_and(|seconds| seconds >= floor && seconds <= MAX_SECONDS as f64)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spatial_requests_preserve_optional_display_scale() {
        let value = serde_json::json!({"display_scale": 2.0});
        assert_eq!(
            serde_json::from_value::<crate::HintsRequest>(value.clone())
                .unwrap()
                .display_scale,
            Some(2.0)
        );
        assert_eq!(
            serde_json::from_value::<crate::TextGridRequest>(value)
                .unwrap()
                .display_scale,
            Some(2.0)
        );
        assert_eq!(
            serde_json::from_value::<crate::HintsRequest>(serde_json::json!({}))
                .unwrap()
                .display_scale,
            None
        );
        assert_eq!(
            serde_json::from_value::<crate::TextGridRequest>(serde_json::json!({}))
                .unwrap()
                .display_scale,
            None
        );
    }

    #[test]
    fn spatial_requests_reject_non_numeric_display_scale() {
        let value = serde_json::json!({"display_scale": "2"});
        assert!(serde_json::from_value::<crate::HintsRequest>(value.clone()).is_err());
        assert!(serde_json::from_value::<crate::TextGridRequest>(value).is_err());
    }

    #[test]
    fn shared_wire_corpus_matches_the_rust_boundary() {
        let fixture: Value =
            serde_json::from_str(include_str!("../fixtures/wire-values.fixture")).unwrap();
        for kind in [
            "protocol_version",
            "boolean",
            "pid",
            "perform",
            "hints",
            "text_grid",
        ] {
            for case in fixture[kind].as_array().unwrap() {
                let value = &case["value"];
                let valid = match kind {
                    "protocol_version" => value.as_u64() == Some(1),
                    "boolean" => value.is_boolean(),
                    "pid" => pid(value).is_some(),
                    _ => valid_result(kind, value),
                };
                assert_eq!(
                    valid,
                    case["valid"].as_bool().unwrap(),
                    "{kind}: {}",
                    case["name"]
                );
            }
        }
        // `core:status.observed` payloads: the host must send a complete set
        // of unique, nonempty segment names; anything else is dropped whole.
        for case in fixture["status_observed"].as_array().unwrap() {
            let event = serde_json::json!({
                "name": "core:status.observed",
                "payload": case["value"],
            });
            assert_eq!(
                crate::runtime::decode_event(event).is_ok(),
                case["valid"].as_bool().unwrap(),
                "status_observed: {}",
                case["name"]
            );
        }
        // `core:ax.changed` payloads name the app and the notification.
        for case in fixture["ax_changed"].as_array().unwrap() {
            let event = serde_json::json!({
                "name": "core:ax.changed",
                "payload": case["value"],
            });
            assert_eq!(
                crate::runtime::decode_event(event).is_ok(),
                case["valid"].as_bool().unwrap(),
                "ax_changed: {}",
                case["name"]
            );
        }
        // `poll` registration sets: the host decodes exactly these, so the
        // SDK may emit nothing else.
        let polls = fixture["poll"].as_array().unwrap();
        assert!(!polls.is_empty());
        for case in polls {
            assert_eq!(
                valid_poll(&case["value"]),
                case["valid"].as_bool().unwrap(),
                "poll: {}",
                case["name"]
            );
        }
        for case in fixture["encoded_rows"].as_array().unwrap() {
            let encoded = serde_json::to_vec(&case["value"]).unwrap();
            assert_eq!(
                encoded.len(),
                case["encoded_bytes"].as_u64().unwrap() as usize
            );
        }
    }

    #[test]
    fn perform_kinds_match_the_shared_protocol_contract() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        assert_eq!(
            contract["perform_kinds"],
            serde_json::json!(crate::runtime::PERFORM_KINDS)
        );
        let shape = &contract["perform_command"];
        assert_eq!(
            shape["required"],
            serde_json::json!(["command", "subcommand", "args"])
        );
        assert_eq!(shape["optional"], serde_json::json!(["context"]));
    }

    /// The one manifest `lifecycle` value, and what a plugin declaring it
    /// may carry, come from the contract the macro reads too.
    #[test]
    fn lifecycle_declarations_match_the_shared_protocol_contract() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let lifecycle = &contract["lifecycle"];
        assert_eq!(
            lifecycle["values"],
            serde_json::json!([crate::runtime::PUBLISH_THEN_EXIT])
        );
        let rules = &lifecycle[crate::runtime::PUBLISH_THEN_EXIT];
        assert_eq!(rules["requires"], serde_json::json!(["exec", "sources"]));
        assert_eq!(
            rules["forbids"],
            serde_json::json!([
                "hints",
                "query",
                "status",
                "listen",
                "commands",
                "bangs",
                "navigation"
            ])
        );
    }

    #[test]
    fn poll_bounds_match_the_shared_protocol_contract() {
        use crate::poll::{
            MAX_NAME_BYTES, MAX_REGISTRATIONS, MAX_SECONDS, MIN_EVERY, PollPriority,
        };
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let poll = &contract["poll"];
        let priorities: Vec<&str> = PollPriority::ALL.iter().map(|p| p.wire()).collect();
        assert_eq!(poll["priorities"], serde_json::json!(priorities));
        assert_eq!(poll["min_every_ms"], MIN_EVERY.as_millis() as u64);
        assert_eq!(poll["max_seconds"], MAX_SECONDS);
        assert_eq!(poll["max_registrations"], MAX_REGISTRATIONS as u64);
        assert_eq!(poll["max_name_bytes"], MAX_NAME_BYTES as u64);
    }

    /// A hint target carries exactly the contract's keys: geometry and
    /// semantics, nothing about the mode a click leaves.
    #[test]
    fn hint_target_keys_match_the_shared_protocol_contract() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let shape = &contract["hint_target"];
        assert_eq!(shape["required"], serde_json::json!(["id", "frame"]));
        let mut keys: Vec<&str> = ["required", "optional"]
            .iter()
            .flat_map(|group| shape[*group].as_array().unwrap())
            .map(|key| key.as_str().unwrap())
            .collect();
        keys.sort_unstable();
        let mut accepted = HINT_TARGET_KEYS.to_vec();
        accepted.sort_unstable();
        assert_eq!(keys, accepted);
    }

    #[test]
    fn text_grid_bounds_match_the_shared_protocol_contract() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        assert_eq!(
            contract["quotas"]["text_grid_dimension"],
            MAX_TEXT_GRID_DIMENSION
        );
        let shapes = &contract["text_grid_line"];
        assert_eq!(shapes["text"], serde_json::json!(["row", "column", "text"]));
        assert_eq!(
            shapes["format"],
            serde_json::json!(["row", "column", "width", "format"])
        );
    }

    /// The host counts `catalog_bytes` from the `rows` array as it lies in
    /// the publish frame, so what the SDK writes around it must be exactly
    /// the envelope — no whitespace, no re-ordering — and the rows must be
    /// the compact encoding. At the 4 MiB boundary: a catalog whose compact
    /// rows are exactly the quota yields a frame of quota plus envelope, and
    /// a per-source publish adds exactly its `source` member.
    #[tokio::test]
    async fn publish_frames_add_exactly_the_envelope_around_compact_rows() {
        use crate::context::Publish;
        use crate::emit::Emitter;
        use crate::types::Candidate;
        use tokio::sync::mpsc;

        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        assert_eq!(
            contract["quotas"]["catalog_bytes"],
            MAX_CATALOG_BYTES as u64
        );
        let publish = &contract["publish"]["params"];
        assert_eq!(publish["required"], serde_json::json!(["rows"]));
        assert_eq!(publish["optional"], serde_json::json!(["source"]));

        // `[{"source":"s","title":"<L bytes>"}]` is 27 + L bytes compact.
        let title = "x".repeat(MAX_CATALOG_BYTES - 27);
        let rows = vec![Candidate::new("s", title)];
        assert_eq!(serde_json::to_vec(&rows).unwrap().len(), MAX_CATALOG_BYTES);

        let (tx, mut rx) = mpsc::channel(4);
        let emitter = Emitter::new(tx);
        let whole = r#"{"method":"publish","params":{"rows":"#;
        emitter.notify_with(
            "publish",
            &Publish {
                source: None,
                rows: &rows,
            },
        );
        let frame = rx.recv().await.unwrap().payload;
        assert_eq!(frame.len(), whole.len() + MAX_CATALOG_BYTES + "}}\n".len());
        assert!(frame.starts_with(whole.as_bytes()));
        assert!(frame.ends_with(b"}}\n"));

        let scoped = r#"{"method":"publish","params":{"source":"s","rows":"#;
        emitter.notify_with(
            "publish",
            &Publish {
                source: Some("s"),
                rows: &rows,
            },
        );
        let frame = rx.recv().await.unwrap().payload;
        assert_eq!(frame.len(), scoped.len() + MAX_CATALOG_BYTES + "}}\n".len());
        assert!(frame.starts_with(scoped.as_bytes()));
    }

    /// The SDK pre-checks a script's size and clamps its timeout to the
    /// contract's bounds, so they must be the host's.
    #[test]
    fn applescript_bounds_match_the_shared_protocol_contract() {
        use crate::context::{
            APPLESCRIPT_CONCURRENCY, APPLESCRIPT_DEFAULT_TIMEOUT, APPLESCRIPT_MAX_TIMEOUT,
            APPLESCRIPT_RESULT_BYTES, APPLESCRIPT_SCRIPT_BYTES,
        };
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let bounds = &contract["applescript"];
        assert_eq!(bounds["script_bytes"], APPLESCRIPT_SCRIPT_BYTES as u64);
        assert_eq!(bounds["result_bytes"], APPLESCRIPT_RESULT_BYTES as u64);
        assert_eq!(
            bounds["default_timeout_ms"],
            APPLESCRIPT_DEFAULT_TIMEOUT.as_millis() as u64
        );
        assert_eq!(
            bounds["max_timeout_ms"],
            APPLESCRIPT_MAX_TIMEOUT.as_millis() as u64
        );
        assert_eq!(bounds["concurrency"], APPLESCRIPT_CONCURRENCY as u64);
        assert_eq!(
            contract["methods"]["plugin_to_host_rpcs"]["host.applescript"],
            "apple_events"
        );
        assert!(
            contract["capabilities"]
                .as_array()
                .unwrap()
                .contains(&Value::from("apple_events"))
        );
    }

    #[test]
    fn transport_limits_match_the_shared_protocol_contract() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        for (key, actual) in [
            ("plugin_requests", crate::runtime::REQUEST_CAPACITY),
            ("plugin_request_bytes", crate::runtime::REQUEST_BYTES),
            ("plugin_host_calls", crate::context::HOST_CALL_CAPACITY),
            (
                "plugin_outbound_frames",
                crate::emit::OUTBOUND_QUEUE_CAPACITY,
            ),
            ("plugin_outbound_bytes", crate::emit::OUTBOUND_QUEUE_BYTES),
            ("plugin_event_frames", crate::events::EVENT_QUEUE_CAPACITY),
            ("plugin_event_bytes", crate::events::EVENT_QUEUE_BYTES),
            ("plugin_replacement_slots", crate::events::REPLACEMENT_SLOTS),
        ] {
            assert_eq!(
                contract["transport_limits"][key].as_u64().unwrap() as usize,
                actual,
                "{key}"
            );
        }
    }
}
