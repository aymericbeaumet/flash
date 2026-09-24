//! Wire probe: a generic `plugin!`-generated plugin with no Flash business
//! concepts. Its manifest opts into every surface (sources, query, hints,
//! commands, actions, navigation, status, events) so the tests below can
//! drive the complete generated `FlashPlugin` routing over the real protocol
//! through `flash_plugin::testing::WireHarness`. Test fixture only: never
//! shipped or spawned by the host.

use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};

use flash_plugin::{
    run, ActionRequest, Candidate, CommandRequest, Context, EvaluateRequest, EvaluateResponse,
    Event, Frame, HintsRequest, HintsResponse, JumpTarget, NavigateRequest, PerformResponse,
    QueryAnswer, SearchRequest, SearchResponse, TERMINAL_LINK_ROLE,
};

const SOURCE: &str = "probe.items";
const TARGET_PID: i64 = 4242;

struct Probe {
    last_event: Mutex<String>,
}

flash_plugin::plugin!(Probe);

/// The message-field encoder: compact JSON (serde_json keeps non-ASCII raw).
fn j(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "{}".to_string())
}

/// The `[plugin.probe] probe` settings table (`Null` when unset).
fn probe_config(ctx: &Context) -> Value {
    ctx.config_json("probe").unwrap_or(Value::Null)
}

fn catalog(ctx: &Context) -> Vec<Candidate> {
    if probe_config(ctx)
        .get("empty_catalog")
        .and_then(Value::as_bool)
        == Some(true)
    {
        return Vec::new();
    }
    vec![
        Candidate::new(SOURCE, "alpha").metadata("k", "v1"),
        Candidate::new(SOURCE, "béta ⚡ 名前"),
        Candidate::new(SOURCE, "gamma")
            .url("https://example.com/g")
            .open_url_effect("https://example.com/g"),
    ]
}

fn arg(args: &[String], index: usize) -> String {
    args.get(index).cloned().unwrap_or_default()
}

fn int_arg(args: &[String], index: usize, fallback: i64) -> i64 {
    arg(args, index).parse().unwrap_or(fallback)
}

/// One host-RPC arm per subcommand, with its canonical params. `None` when
/// the subcommand is not an arm.
fn host_arm(subcommand: &str, args: &[String]) -> Option<(&'static str, Value)> {
    Some(match subcommand {
        "ping" => ("host.ping", json!({})),
        "fetch" => ("host.fetch", json!({ "url": arg(args, 0) })),
        "open" => ("host.open", json!({ "url": arg(args, 0) })),
        "clipboard" => ("host.clipboard_write", json!({ "text": arg(args, 0) })),
        "notify" => ("host.notify", json!({ "message": arg(args, 0) })),
        "storage-set" => (
            "host.storage_set",
            json!({ "key": arg(args, 0), "value": arg(args, 1) }),
        ),
        "storage-get" => ("host.storage_get", json!({ "key": arg(args, 0) })),
        "media" => (
            "host.post_media_key",
            json!({ "key_code": int_arg(args, 0, 16) }),
        ),
        "ps" => ("host.process_table", json!({})),
        "signal" => (
            "host.signal",
            json!({ "pid": int_arg(args, 0, TARGET_PID) }),
        ),
        "keys" => (
            "host.post_keys",
            json!({ "pid": TARGET_PID, "keys": [{ "key_code": 4, "modifiers": ["command"] }] }),
        ),
        "global-key" => (
            "host.post_global_key",
            json!({ "key_code": 4, "modifiers": ["command"] }),
        ),
        "ax-snapshot" => (
            "host.ax_snapshot",
            json!({ "pid": TARGET_PID, "roots": "app" }),
        ),
        "activate" => ("host.activate", json!({ "pid": TARGET_PID })),
        "normal-mode-target" => ("host.normal_mode_target", json!({})),
        _ => return None,
    })
}

impl FlashPlugin for Probe {
    async fn on_start(&self, ctx: Context) {
        ctx.publish(catalog(&ctx));
    }

    async fn on_event(&self, _ctx: Context, event: Event) {
        // The status observation also records its segment set, so the wire
        // test can see the typed payload reached the hook.
        let record = match event.segments {
            Some(segments) => format!("{} [{}]", event.name, segments.join(",")),
            None => event.name,
        };
        *self
            .last_event
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = record;
    }

    fn evaluate(&self, request: EvaluateRequest) -> EvaluateResponse {
        let answers = match request.query.as_str() {
            "probe:one" => vec![QueryAnswer::copy_text("one", Some("s"))],
            "probe:unicode" => vec![QueryAnswer::copy_text("héllo ⚡ 世界", None::<String>)],
            "probe:many" => (1..=17)
                .map(|i| QueryAnswer::copy_text(format!("a{i}"), None::<String>))
                .collect(),
            _ => Vec::new(),
        };
        EvaluateResponse::answers(answers)
    }

    async fn on_search(&self, ctx: Context, request: SearchRequest) -> SearchResponse {
        SearchResponse::rows(
            catalog(&ctx)
                .into_iter()
                .filter(|row| row.title.contains(&request.query))
                .collect(),
        )
    }

    async fn on_hints(&self, _ctx: Context, _request: HintsRequest) -> HintsResponse {
        HintsResponse::targets(vec![
            JumpTarget::new("t1", Frame::new(-10.5, 20.0, 30.0, 40.0))
                .role("AXLink")
                .label("one"),
            JumpTarget::new("t2", Frame::new(0.0, 0.0, 10.0, 10.0))
                .role(TERMINAL_LINK_ROLE)
                .label("two"),
        ])
    }

    async fn on_resolve(&self, _ctx: Context, row: Candidate) -> PerformResponse {
        if row.title == "alpha" {
            return PerformResponse::ok().target_pid(TARGET_PID);
        }
        PerformResponse::unhandled()
    }

    async fn on_action(&self, _ctx: Context, action: ActionRequest) -> PerformResponse {
        match action.name.as_str() {
            "probe_performed" => PerformResponse::ok().target_pid(TARGET_PID),
            "probe_failed" => PerformResponse::fail("probe failure"),
            _ => PerformResponse::unhandled(),
        }
    }

    async fn on_navigate(&self, _ctx: Context, request: NavigateRequest) -> PerformResponse {
        if request.url == "probe://ok" {
            return PerformResponse::ok();
        }
        PerformResponse::unhandled()
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        let args = &command.args;
        match command.subcommand.as_str() {
            "echo" => {
                PerformResponse::ok().message(j(&json!({ "args": args, "raw": command.raw })))
            }
            "config" => PerformResponse::ok().message(j(&probe_config(&ctx))),
            "state" => PerformResponse::ok().message(
                self.last_event
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .clone(),
            ),
            "sleep" => {
                tokio::time::sleep(Duration::from_millis(int_arg(args, 0, 0).max(0) as u64)).await;
                PerformResponse::ok()
            }
            "log" => {
                let level = if args.is_empty() {
                    "info".to_string()
                } else {
                    arg(args, 0)
                };
                ctx.log(
                    &level,
                    &args.iter().skip(1).cloned().collect::<Vec<_>>().join(" "),
                );
                PerformResponse::ok()
            }
            "status" => {
                ctx.status([(arg(args, 0), arg(args, 1))]);
                PerformResponse::ok()
            }
            "publish-extra" => {
                let mut rows = catalog(&ctx);
                rows.push(Candidate::new(SOURCE, "delta"));
                ctx.publish(rows);
                PerformResponse::ok()
            }
            other => match host_arm(other, args) {
                Some((method, params)) => {
                    let result = ctx.call_host(method, params).await;
                    PerformResponse::ok().message(j(&result))
                }
                None => PerformResponse::fail(format!("unsupported subcommand: {other}")),
            },
        }
    }

    async fn on_shutdown(&self, ctx: Context) {
        ctx.log("info", "probe shutdown");
    }
}

fn probe() -> Probe {
    Probe {
        last_event: Mutex::new(String::new()),
    }
}

fn main() {
    run(probe());
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::WireHarness;

    fn initialize() -> Value {
        json!({ "id": 1, "method": "initialize", "params": { "protocol_version": 1 } })
    }

    fn command(id: u64, subcommand: &str, args: &[&str]) -> Value {
        json!({ "id": id, "method": "perform", "params": {
            "kind": "command", "command": "probe", "subcommand": subcommand,
            "args": args, "raw": format!(":probe {subcommand} {}", args.join(" ")),
        }})
    }

    fn catalog_rows() -> Value {
        json!([
            { "source": SOURCE, "title": "alpha", "metadata": { "k": "v1" } },
            { "source": SOURCE, "title": "béta ⚡ 名前" },
            { "source": SOURCE, "title": "gamma", "url": "https://example.com/g",
              "effect": { "type": "open", "url": "https://example.com/g" } },
        ])
    }

    /// Serve the probe with `config` and complete the handshake.
    async fn serve(config: Value) -> WireHarness {
        let mut wire = WireHarness::with_config(probe(), config);
        wire.send(initialize()).await;
        assert_eq!(
            wire.recv().await,
            json!({ "id": 1, "result": { "ok": true, "protocol_version": 1 } })
        );
        wire
    }

    #[tokio::test]
    async fn publishes_its_catalog_after_the_handshake_and_logs_on_shutdown() {
        let mut wire = serve(json!({})).await;
        assert_eq!(
            wire.recv().await,
            json!({ "method": "publish", "params": { "rows": catalog_rows() } })
        );
        wire.close_stdin().await;
        let frames = wire.finished().await;
        assert_eq!(frames.len(), 1, "{frames:?}");
        assert_eq!(frames[0]["method"], "log");
        assert_eq!(frames[0]["params"]["message"], "probe shutdown");
    }

    #[tokio::test]
    async fn an_empty_catalog_is_still_published() {
        let mut wire = serve(json!({ "probe": { "empty_catalog": true } })).await;
        assert_eq!(
            wire.recv_notification("publish").await,
            json!({ "rows": [] })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn publish_is_a_full_replacement_each_time() {
        let mut wire = serve(json!({})).await;
        assert_eq!(
            wire.recv_notification("publish").await["rows"],
            catalog_rows()
        );
        wire.send(command(82, "publish-extra", &[])).await;
        let rows = wire.recv_notification("publish").await["rows"].clone();
        assert_eq!(rows.as_array().unwrap().len(), 4);
        assert_eq!(rows[3]["title"], "delta");
        assert_eq!(wire.recv_response(82).await, json!({ "ok": true }));
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn perform_routes_every_kind_through_the_trichotomy() {
        let mut wire = serve(json!({})).await;
        let context = json!({ "bundle_id": "dev.flash.probe", "pid": 999 });
        for (id, params, expected) in [
            (
                90,
                json!({ "kind": "action", "name": "probe_performed", "context": context }),
                json!({ "ok": true, "target_pid": TARGET_PID }),
            ),
            (
                91,
                json!({ "kind": "action", "name": "probe_unhandled", "context": context }),
                json!({ "ok": false, "unhandled": true }),
            ),
            (
                92,
                json!({ "kind": "action", "name": "probe_failed", "context": context }),
                json!({ "ok": false, "error": "probe failure" }),
            ),
            (
                93,
                json!({ "kind": "resolve", "row": { "source": SOURCE, "title": "alpha", "metadata": { "k": "v1" } } }),
                json!({ "ok": true, "target_pid": TARGET_PID }),
            ),
            (
                94,
                json!({ "kind": "resolve", "row": { "source": SOURCE, "title": "zzz" } }),
                json!({ "ok": false, "unhandled": true }),
            ),
            (
                95,
                json!({ "kind": "navigate", "url": "probe://ok" }),
                json!({ "ok": true }),
            ),
            (
                96,
                json!({ "kind": "navigate", "url": "probe://nope" }),
                json!({ "ok": false, "unhandled": true }),
            ),
            (
                97,
                json!({ "kind": "command", "command": "probe", "subcommand": "nope", "args": [], "raw": "" }),
                json!({ "ok": false, "error": "unsupported subcommand: nope" }),
            ),
        ] {
            wire.send(json!({ "id": id, "method": "perform", "params": params }))
                .await;
            assert_eq!(wire.recv_response(id).await, expected, "{id}");
        }
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn command_echo_round_trips_unicode_args_and_raw_input() {
        let mut wire = serve(json!({})).await;
        wire.send(json!({ "id": 62, "method": "perform", "params": {
            "kind": "command", "command": "probe", "subcommand": "echo",
            "args": ["héllo ⚡ 世界", "名前", "café"], "raw": "rawé ⚡ check 名前",
        }}))
        .await;
        assert_eq!(
            wire.recv_response(62).await,
            json!({ "ok": true, "message": r#"{"args":["héllo ⚡ 世界","名前","café"],"raw":"rawé ⚡ check 名前"}"# })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn hints_reply_carries_exact_targets() {
        let mut wire = serve(json!({})).await;
        wire.send(json!({ "id": 97, "method": "hints", "params": {
            "bundle_id": "dev.flash.probe", "pid": 999,
            "front_window_frame": { "x": 0, "y": 0, "width": 1512, "height": 982 },
        }}))
        .await;
        assert_eq!(
            wire.recv_response(97).await,
            json!({ "ok": true, "targets": [
                { "id": "t1", "frame": { "x": -10.5, "y": 20.0, "width": 30.0, "height": 40.0 }, "role": "AXLink", "label": "one" },
                { "id": "t2", "frame": { "x": 0.0, "y": 0.0, "width": 10.0, "height": 10.0 }, "role": TERMINAL_LINK_ROLE, "label": "two" },
            ]})
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn evaluate_answers_are_literal_and_never_truncated() {
        let mut wire = serve(json!({})).await;
        let evaluate = |id: u64, query: &str| json!({ "id": id, "method": "evaluate", "params": { "surface": "flashlight", "scope": "", "query": query } });
        wire.send(evaluate(85, "probe:one")).await;
        assert_eq!(
            wire.recv_response(85).await,
            json!({ "ok": true, "answers": [
                { "title": "one", "subtitle": "s", "effect": { "type": "copy_text", "text": "one" } }
            ]})
        );
        wire.send(evaluate(86, "probe:unicode")).await;
        assert_eq!(
            wire.recv_response(86).await,
            json!({ "ok": true, "answers": [
                { "title": "héllo ⚡ 世界", "effect": { "type": "copy_text", "text": "héllo ⚡ 世界" } }
            ]})
        );
        // One past the host's 16-answer quota: the SDK transmits all 17
        // faithfully; the host rejects over-quota replies atomically.
        wire.send(evaluate(88, "probe:many")).await;
        let answers = wire.recv_response(88).await["answers"].clone();
        assert_eq!(answers.as_array().unwrap().len(), 17);
        assert_eq!(answers[16]["title"], "a17");
        wire.send(evaluate(87, "probe:none")).await;
        assert_eq!(
            wire.recv_response(87).await,
            json!({ "ok": true, "answers": [] })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn search_returns_catalog_rows_or_an_empty_array() {
        let mut wire = serve(json!({})).await;
        wire.send(
            json!({ "id": 83, "method": "search", "params": { "query": "alpha", "scope": "" } }),
        )
        .await;
        assert_eq!(
            wire.recv_response(83).await,
            json!({ "ok": true, "rows": [{ "source": SOURCE, "title": "alpha", "metadata": { "k": "v1" } }] })
        );
        wire.send(
            json!({ "id": 84, "method": "search", "params": { "query": "zzz", "scope": "" } }),
        )
        .await;
        assert_eq!(
            wire.recv_response(84).await,
            json!({ "ok": true, "rows": [] })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn status_and_log_notifications_precede_their_replies() {
        let mut wire = serve(json!({})).await;
        wire.recv_notification("publish").await;
        wire.send(command(81, "status", &["state", "on"])).await;
        assert_eq!(
            wire.recv().await,
            json!({ "method": "status", "params": { "segments": { "state": "on" } } })
        );
        assert_eq!(wire.recv_response(81).await, json!({ "ok": true }));
        wire.send(command(80, "log", &["warn", "hello-probe"]))
            .await;
        assert_eq!(
            wire.recv().await,
            json!({ "method": "log", "params": { "level": "warn", "message": "hello-probe", "fields": {} } })
        );
        assert_eq!(wire.recv_response(80).await, json!({ "ok": true }));
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn config_echo_round_trips_nested_settings() {
        let mut wire = serve(json!({ "probe": { "greeting": "hi", "n": 3 } })).await;
        wire.send(command(102, "config", &[])).await;
        assert_eq!(
            wire.recv_response(102).await,
            json!({ "ok": true, "message": r#"{"greeting":"hi","n":3}"# })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    /// Poll the probe's `state` command until the event hook has recorded
    /// `expected`: events run on their own serialized worker.
    async fn await_event_state(wire: &mut WireHarness, first_id: u64, expected: &str) {
        let mut id = first_id;
        loop {
            wire.send(command(id, "state", &[])).await;
            let state = wire.recv_response(id).await["message"].clone();
            if state == expected {
                return;
            }
            id += 1;
            assert!(id < first_id + 100, "event never reached the hook: {state}");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    #[tokio::test]
    async fn events_reach_the_event_hook() {
        let mut wire = serve(json!({})).await;
        wire.send(json!({ "method": "event", "params": {
            "name": "core:apps.changed", "payload": { "running_applications": [] }
        }}))
        .await;
        await_event_state(&mut wire, 103, "core:apps.changed").await;
        wire.close_stdin().await;
        wire.finished().await;
    }

    /// The status observation arrives typed: its segment set, an empty set
    /// included, reaches the hook as `Event::segments`.
    #[tokio::test]
    async fn status_observation_reaches_the_event_hook_with_its_segments() {
        let mut wire = serve(json!({})).await;
        wire.send(json!({ "method": "event", "params": {
            "name": "core:status.observed", "payload": { "segments": ["state"] }
        }}))
        .await;
        await_event_state(&mut wire, 300, "core:status.observed [state]").await;
        wire.send(json!({ "method": "event", "params": {
            "name": "core:status.observed", "payload": { "segments": [] }
        }}))
        .await;
        await_event_state(&mut wire, 400, "core:status.observed []").await;
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn host_rpc_arms_correlate_over_the_wire() {
        let mut wire = serve(json!({})).await;
        wire.recv_notification("publish").await;
        let mut id = 100;
        for (subcommand, args, method, params) in [
            ("ping", vec![], "host.ping", json!({})),
            (
                "fetch",
                vec!["https://example.com/x"],
                "host.fetch",
                json!({ "url": "https://example.com/x" }),
            ),
            (
                "open",
                vec!["https://example.com/x"],
                "host.open",
                json!({ "url": "https://example.com/x" }),
            ),
            (
                "clipboard",
                vec!["copy-me"],
                "host.clipboard_write",
                json!({ "text": "copy-me" }),
            ),
            (
                "notify",
                vec!["hi"],
                "host.notify",
                json!({ "message": "hi" }),
            ),
            (
                "storage-set",
                vec!["k1", "v1"],
                "host.storage_set",
                json!({ "key": "k1", "value": "v1" }),
            ),
            (
                "storage-get",
                vec!["k1"],
                "host.storage_get",
                json!({ "key": "k1" }),
            ),
            (
                "media",
                vec![],
                "host.post_media_key",
                json!({ "key_code": 16 }),
            ),
            ("ps", vec![], "host.process_table", json!({})),
            (
                "signal",
                vec!["4242"],
                "host.signal",
                json!({ "pid": 4242 }),
            ),
            (
                "keys",
                vec![],
                "host.post_keys",
                json!({ "pid": TARGET_PID, "keys": [{ "key_code": 4, "modifiers": ["command"] }] }),
            ),
            (
                "global-key",
                vec![],
                "host.post_global_key",
                json!({ "key_code": 4, "modifiers": ["command"] }),
            ),
            (
                "ax-snapshot",
                vec![],
                "host.ax_snapshot",
                json!({ "pid": TARGET_PID, "roots": "app" }),
            ),
            (
                "activate",
                vec![],
                "host.activate",
                json!({ "pid": TARGET_PID }),
            ),
            (
                "normal-mode-target",
                vec![],
                "host.normal_mode_target",
                json!({}),
            ),
        ] {
            id += 1;
            wire.send(command(id, subcommand, &args)).await;
            let request = wire.recv().await;
            assert_eq!(request["method"], method, "{subcommand}");
            assert_eq!(request["params"], params, "{subcommand}");
            wire.send(
                json!({ "id": request["id"], "result": { "ok": true, "detail": "scripted" } }),
            )
            .await;
            assert_eq!(
                wire.recv_response(id).await,
                json!({ "ok": true, "message": r#"{"detail":"scripted","ok":true}"# }),
                "{subcommand}"
            );
        }
        // A NAK'd call is an ordinary result object, never an error path.
        wire.send(command(200, "fetch", &["https://example.com/x"]))
            .await;
        let request = wire.recv().await;
        wire.send(json!({ "id": request["id"], "result": { "ok": false, "error": "missing network_fetch capability" } }))
            .await;
        assert_eq!(
            wire.recv_response(200).await,
            json!({ "ok": true, "message": r#"{"error":"missing network_fetch capability","ok":false}"# })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn a_busy_perform_and_a_ping_both_answer() {
        let mut wire = serve(json!({})).await;
        wire.recv_notification("publish").await;
        wire.send_raw(
            format!(
                "{}\n{}\n",
                command(40, "sleep", &["200"]),
                json!({ "id": 41, "method": "ping", "params": {} })
            )
            .as_bytes(),
        )
        .await;
        // Order is deliberately unconstrained; both must land.
        let mut ids = vec![
            wire.recv().await["id"].clone(),
            wire.recv().await["id"].clone(),
        ];
        ids.sort_by_key(|id| id.as_u64());
        assert_eq!(ids, [json!(40), json!(41)]);
        wire.close_stdin().await;
        wire.finished().await;
    }
}
