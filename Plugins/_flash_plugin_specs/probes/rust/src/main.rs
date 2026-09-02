//! Conformance probe, in Rust. See ../../README.md — the normative behavior
//! contract the maintained Rust SDK follows. Test fixture only: driven
//! by Scripts/plugin-protocol-spec.py --probes, never shipped.

use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};

use flash_plugin::{
    run, ActionRequest, Candidate, CommandRequest, Context, EvaluateRequest, EvaluateResponse,
    Event, Frame, HintsRequest, HintsResponse, JumpTarget, NavigateRequest, PerformResponse,
    QueryAnswer, SearchRequest, SearchResponse, TERMINAL_LINK_ROLE,
};

const SOURCE: &str = "conformance.items";
const TARGET_PID: i64 = 4242;

struct Conformance {
    last_event: Mutex<String>,
}

flash_plugin::plugin!(Conformance);

/// The message-field encoder: compact JSON (serde_json keeps non-ASCII raw).
fn j(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "{}".to_string())
}

/// The full parsed FLASH_PLUGIN_CONFIG object ({} when unset/invalid).
fn full_config() -> Value {
    std::env::var("FLASH_PLUGIN_CONFIG")
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}))
}

fn conformance_config() -> Value {
    full_config()
        .get("conformance")
        .cloned()
        .unwrap_or(Value::Null)
}

fn catalog() -> Vec<Candidate> {
    let conf = conformance_config();
    if conf.get("empty_catalog").and_then(Value::as_bool) == Some(true) {
        return Vec::new();
    }
    if let Some(count) = conf.get("catalog_rows").and_then(Value::as_u64) {
        let pad_len = conf.get("row_pad").and_then(Value::as_u64).unwrap_or(0);
        let pad = "x".repeat(pad_len as usize);
        return (1..=count)
            .map(|i| Candidate::new(SOURCE, format!("row-{i}{pad}")))
            .collect();
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

/// One host-RPC arm: canonical params per ../../README.md. None when the
/// subcommand is not an arm.
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

impl FlashPlugin for Conformance {
    async fn on_start(&self, ctx: Context) {
        let conf = conformance_config();
        if conf.get("skip_publish").and_then(Value::as_bool) == Some(true) {
            return;
        }
        ctx.publish(catalog());
    }

    async fn on_event(&self, _ctx: Context, event: Event) {
        *self
            .last_event
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = event.name;
    }

    fn evaluate(&self, request: EvaluateRequest) -> EvaluateResponse {
        let answers = match request.query.as_str() {
            "conf:one" => vec![QueryAnswer::copy_text("one", Some("s"))],
            "conf:unicode" => vec![QueryAnswer::copy_text("héllo ⚡ 世界", None::<String>)],
            "conf:many" => (1..=17)
                .map(|i| QueryAnswer::copy_text(format!("a{i}"), None::<String>))
                .collect(),
            _ => Vec::new(),
        };
        EvaluateResponse::answers(answers)
    }

    async fn on_search(&self, _ctx: Context, request: SearchRequest) -> SearchResponse {
        SearchResponse::rows(
            catalog()
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
            "conf_performed" => PerformResponse::ok().target_pid(TARGET_PID),
            "conf_failed" => PerformResponse::fail("conformance failure probe"),
            _ => PerformResponse::unhandled(),
        }
    }

    async fn on_navigate(&self, _ctx: Context, request: NavigateRequest) -> PerformResponse {
        if request.url == "conformance://ok" {
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
            "env" => {
                let env: serde_json::Map<String, Value> = std::env::vars()
                    .map(|(key, value)| (key, Value::String(value)))
                    .collect();
                PerformResponse::ok().message(j(&Value::Object(env)))
            }
            "env-has" => {
                let present = std::env::var_os(arg(args, 0)).is_some();
                PerformResponse::ok().message(if present { "present" } else { "absent" })
            }
            "config" => PerformResponse::ok().message(j(&full_config())),
            "state" => PerformResponse::ok().message(
                self.last_event
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .clone(),
            ),
            "target-pid" => PerformResponse::ok().target_pid(TARGET_PID),
            "toast" => PerformResponse::ok().message("hello from conformance"),
            "sleep" => {
                tokio::time::sleep(Duration::from_millis(int_arg(args, 0, 0).max(0) as u64)).await;
                PerformResponse::ok()
            }
            "crash" => std::process::exit(int_arg(args, 0, 1) as i32),
            "exit-after-reply" => {
                let code = int_arg(args, 0, 0) as i32;
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    std::process::exit(code);
                });
                PerformResponse::ok()
            }
            "stderr" => {
                eprint!("{}", "x".repeat(int_arg(args, 0, 0).max(0) as usize * 1024));
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
                let mut rows = catalog();
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
        ctx.log("info", "conformance shutdown");
    }
}

fn main() {
    run(Conformance {
        last_event: Mutex::new(String::new()),
    })
}
