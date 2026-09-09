//! Shared JSON boundary rules, exercised against the host's fixture corpus.

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
    if method == "perform" {
        return only_keys(result, &["ok", "target_pid", "navigation_url", "message"])
            && present(result, "navigation_url")
                .and_then(Value::as_str)
                .is_none_or(absolute_url);
    }
    true
}

fn valid_target(target: &Value) -> bool {
    if !only_keys(
        target,
        &[
            "id",
            "frame",
            "role",
            "label",
            "url",
            "pid",
            "enters_insert_mode",
            "priority",
        ],
    ) || target
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
    if ["id", "role", "label", "url"]
        .iter()
        .any(|key| present(target, key).is_some_and(|value| !value.is_string()))
    {
        return false;
    }
    if present(target, "enters_insert_mode").is_some_and(|value| !value.is_boolean()) {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_wire_corpus_matches_the_rust_boundary() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../_flash_plugin_specs/fixtures/wire-values.fixture"
        ))
        .unwrap();
        for kind in ["protocol_version", "boolean", "pid", "perform", "hints"] {
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
        for case in fixture["encoded_rows"].as_array().unwrap() {
            let encoded = serde_json::to_vec(&case["value"]).unwrap();
            assert_eq!(
                encoded.len(),
                case["encoded_bytes"].as_u64().unwrap() as usize
            );
        }
    }

    #[test]
    fn transport_limits_match_the_shared_protocol_contract() {
        let contract: Value =
            serde_json::from_str(include_str!("../../_flash_plugin_specs/protocol.json")).unwrap();
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
        ] {
            assert_eq!(
                contract["transport_limits"][key].as_u64().unwrap() as usize,
                actual,
                "{key}"
            );
        }
    }
}
