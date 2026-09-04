//! The plugin runtime: the [`Plugin`] trait, the [`run`] entry point, and the
//! serve loop speaking protocol v1 — immediate initialize reply, `ping`,
//! `event` notifications, `evaluate`/`search`/`hints`, the unified `perform`,
//! and stdin-EOF shutdown. Parent liveness is stdin EOF: the host owns the
//! pipe, so a dead host ends the loop.

use std::collections::BTreeMap;
use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};

use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, BufWriter};
use tokio::sync::mpsc;

use crate::context::{context_from_env, Context, HostPending};
use crate::emit::{Emitter, MAX_FRAME_BYTES, OUTBOUND_QUEUE_CAPACITY};
use crate::types::{
    ActionRequest, CommandRequest, EvaluateRequest, EvaluateResponse, Event, Frame, HintsRequest,
    HintsResponse, NavigateRequest, Perform, PerformResponse, RunningApplication, SearchRequest,
    SearchResponse,
};

const EVENT_QUEUE_CAPACITY: usize = 256;

/// Wire-protocol version echoed at `initialize`. A mismatch is terminal:
/// reply `ok: false` with the canonical error, flush, exit 0. MUST stay equal
/// to `protocol_version` in `Plugins/_flash_plugin_specs/protocol.json`.
const PROTOCOL_VERSION: u64 = 1;

/// Canonical protocol error strings (spec-pinned in protocol.json).
const INITIALIZE_REPEATED_ERROR: &str = "initialize may only be called once";

/// A Flash plugin as the runtime sees it. Plugin crates never implement this
/// directly — the [`plugin!`](crate::plugin) macro generates the typed
/// `FlashPlugin` trait from `manifest.json` and adapts it to this one, so
/// required handlers are enforced at compile time.
pub trait Plugin: Send + Sync + 'static {
    /// Runs once, after the initialize reply has been sent. Warm-source
    /// plugins do their initial refresh here and
    /// [`publish`](Context::publish) when ready — initialize never waits.
    fn on_start(&self, ctx: Context) -> impl Future<Output = ()> + Send {
        let _ = ctx;
        async {}
    }

    /// Host event (`core:focus.changed`, `core:apps.changed`, …), delivered
    /// serially in wire order. Events are notifications: never replied.
    fn on_event(&self, ctx: Context, event: Event) -> impl Future<Output = ()> + Send {
        let _ = (ctx, event);
        async {}
    }

    /// The per-input evaluator: synchronous and CPU-only over state prepared
    /// earlier. Unclaimed input returns the empty default.
    fn evaluate(&self, request: EvaluateRequest) -> EvaluateResponse {
        let _ = request;
        EvaluateResponse::default()
    }

    /// Live-source pull for `live: true` sources; may do real work. Late
    /// replies are dropped host-side, not fatal.
    fn on_search(
        &self,
        ctx: Context,
        request: SearchRequest,
    ) -> impl Future<Output = SearchResponse> + Send {
        let _ = (ctx, request);
        async { SearchResponse::default() }
    }

    /// Produce hint targets for the focused app. Always live.
    fn on_hints(
        &self,
        ctx: Context,
        request: HintsRequest,
    ) -> impl Future<Output = HintsResponse> + Send {
        let _ = (ctx, request);
        async { HintsResponse::default() }
    }

    /// Dispatch one decoded `perform` request. Unregistered kinds answer
    /// `{"ok": false, "unhandled": true}`.
    fn perform(
        &self,
        ctx: Context,
        request: Perform,
    ) -> impl Future<Output = PerformResponse> + Send {
        let _ = (ctx, request);
        async { PerformResponse::unhandled() }
    }

    /// Cleanup on stdin EOF — the shutdown signal — just before exit 0.
    fn on_shutdown(&self, ctx: Context) -> impl Future<Output = ()> + Send {
        let _ = ctx;
        async {}
    }
}

struct InboundEvent {
    event: Event,
    running_applications: Vec<RunningApplication>,
}

#[derive(Deserialize)]
struct EventWire {
    name: String,
    #[serde(default)]
    payload: EventPayload,
}

#[derive(Default, Deserialize)]
struct EventPayload {
    #[serde(default)]
    bundle_id: Option<String>,
    #[serde(default)]
    pid: Option<i64>,
    #[serde(default)]
    front_window_frame: Option<Frame>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    running_applications: Vec<RunningApplication>,
}

fn decode_event(params: Value) -> Result<InboundEvent, String> {
    match serde_json::from_value::<EventWire>(params) {
        Ok(wire) if !wire.name.trim().is_empty() => Ok(InboundEvent {
            event: Event {
                name: wire.name,
                bundle_id: wire.payload.bundle_id,
                pid: wire.payload.pid,
                front_window_frame: wire.payload.front_window_frame,
                text: wire.payload.text,
            },
            running_applications: wire.payload.running_applications,
        }),
        Ok(_) => Err("event name must not be empty".to_string()),
        Err(_) => Err("invalid event params".to_string()),
    }
}

/// Decode one typed request payload. Malformed input is a protocol error,
/// never an invitation to run the handler against a fabricated default value.
/// The rejection stays content-free: no payload text, only the method name.
fn decode<T: DeserializeOwned>(params: Value, method: &str) -> Result<T, String> {
    serde_json::from_value::<T>(params).map_err(|_| format!("invalid {method} params"))
}

/// Decode a `perform` payload into its kind-specific request. An unknown kind
/// is an error reply (never `unhandled`): the host and plugin disagree about
/// the protocol, and falling back could double-fire.
fn decode_perform(params: Value) -> Result<Perform, String> {
    let kind = params
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    match kind.as_str() {
        "resolve" => params
            .get("row")
            .cloned()
            .ok_or_else(|| "invalid perform params".to_string())
            .and_then(|row| decode(row, "perform"))
            .map(Perform::Resolve),
        "command" => decode::<CommandRequest>(params, "perform").map(Perform::Command),
        "action" => decode::<ActionRequest>(params, "perform").map(Perform::Action),
        "navigate" => decode::<NavigateRequest>(params, "perform").map(Perform::Navigate),
        other => Err(format!("unknown perform kind: {other}")),
    }
}

/// Deliver host events serially in wire order: a single worker prevents a
/// slow refresh from overtaking a newer event. The running-app snapshot is
/// replaced before the `core:apps.changed` callback runs, so handlers always
/// observe the list that motivated their invocation.
async fn run_event_worker<P: Plugin>(
    plugin: Arc<P>,
    ctx: Context,
    mut events: mpsc::Receiver<InboundEvent>,
) {
    while let Some(inbound) = events.recv().await {
        if inbound.event.name == "core:apps.changed" {
            // The empty list is authoritative too: a terminated final app
            // must clear the snapshot before plugin code rebuilds from it.
            ctx.set_running_applications(inbound.running_applications);
        }
        plugin.on_event(ctx.clone(), inbound.event).await;
    }
}

/// Run the plugin on one async executor and serve NDJSON protocol v1 until
/// stdin closes. Events preserve wire order, while startup and request
/// callbacks run as independent tasks and may overlap. Async I/O and
/// `spawn_blocking` still make progress without paying for two resident worker
/// threads in every plugin process.
pub fn run<P: Plugin>(plugin: P) {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("flash-plugin: tokio runtime");
    runtime.block_on(serve(plugin));
}

async fn serve<P: Plugin>(plugin: P) {
    let plugin = Arc::new(plugin);
    let (out_tx, mut out_rx) = mpsc::channel::<Vec<u8>>(OUTBOUND_QUEUE_CAPACITY);
    let writer = tokio::spawn(async move {
        // Each payload is already one newline-terminated JSON line; flush
        // every frame to keep latency low.
        let mut out = BufWriter::with_capacity(64 * 1024, tokio::io::stdout());
        while let Some(payload) = out_rx.recv().await {
            if out.write_all(&payload).await.is_err() {
                break;
            }
            let _ = out.flush().await;
        }
    });

    let host_pending: HostPending = Arc::new(Mutex::new(HashMap::new()));
    let ctx = context_from_env(
        Emitter::new(out_tx),
        host_pending.clone(),
        Arc::new(AtomicU64::new(0)),
    );
    ctx.prepare_dirs().await;

    let (event_tx, event_rx) = mpsc::channel::<InboundEvent>(EVENT_QUEUE_CAPACITY);
    let event_worker = tokio::spawn(run_event_worker(plugin.clone(), ctx.clone(), event_rx));

    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut line: Vec<u8> = Vec::new();
    let mut initialized = false;
    let mut mismatch_exit = false;
    loop {
        // One frame per newline-terminated line. EOF means the host closed
        // our stdin (it owns the pipe) — that is the shutdown signal.
        line.clear();
        match stdin.read_until(b'\n', &mut line).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if line.last() == Some(&b'\n') {
            line.pop();
        }
        if line.is_empty() {
            continue;
        }
        // Oversized and undecodable lines are dropped (never fatal); the
        // stream self-heals at the next newline.
        if line.len() > MAX_FRAME_BYTES {
            ctx.log_fields(
                "warn",
                "[plugin] dropped oversized inbound frame",
                BTreeMap::from([
                    ("encoded_bytes".to_string(), line.len().to_string()),
                    ("limit_bytes".to_string(), MAX_FRAME_BYTES.to_string()),
                ]),
            );
            continue;
        }
        let Ok(frame) = serde_json::from_slice::<Value>(&line) else {
            ctx.log("warn", "[plugin] dropped undecodable frame");
            continue;
        };
        if !frame.is_object() {
            continue;
        }
        let id = frame.get("id").cloned().unwrap_or(Value::Null);
        let method = frame
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let params = frame.get("params").cloned().unwrap_or_else(|| json!({}));

        // Frame triage: id+method = request, id alone = the host's response
        // to a plugin-initiated call, method alone = notification.
        if method.is_empty() {
            if let Some(request_id) = id.as_u64() {
                if let Some(tx) = host_pending
                    .lock()
                    .ok()
                    .and_then(|mut pending| pending.remove(&request_id))
                {
                    let result = frame.get("result").cloned().unwrap_or(Value::Null);
                    let _ = tx.send(result);
                }
                // Responses to unknown ids are dropped silently.
            }
            continue;
        }
        if id.is_null() {
            // Notification. `event` dispatches; unknown names are ignored.
            if method == "event" {
                match decode_event(params) {
                    Ok(event) => {
                        if event_tx.try_send(event).is_err() {
                            ctx.log("warn", "[plugin] event queue full; dropped event");
                        }
                    }
                    Err(error) => ctx.log("warn", &format!("[plugin] dropped event ({error})")),
                }
            }
            continue;
        }

        match method.as_str() {
            "initialize" => {
                if initialized {
                    // The one non-terminal protocol NAK: reply and keep
                    // serving.
                    ctx.emit
                        .respond(
                            id,
                            json!({ "ok": false, "error": INITIALIZE_REPEATED_ERROR }),
                        )
                        .await;
                    continue;
                }
                let host_version = params
                    .get("protocol_version")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                if host_version != PROTOCOL_VERSION {
                    ctx.emit
                        .respond(
                            id,
                            json!({
                                "ok": false,
                                "protocol_version": PROTOCOL_VERSION,
                                "error": format!(
                                    "protocol version mismatch: host v{host_version}, plugin v{PROTOCOL_VERSION}"
                                ),
                            }),
                        )
                        .await;
                    // A version mismatch is terminal: flush and exit 0.
                    mismatch_exit = true;
                    break;
                }
                initialized = true;
                // Reply immediately — no warm-catalog wait; on_start runs
                // after the reply and publishes when ready.
                ctx.emit
                    .respond(
                        id,
                        json!({ "ok": true, "protocol_version": PROTOCOL_VERSION }),
                    )
                    .await;
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                tokio::spawn(async move { plugin.on_start(ctx).await });
            }
            "ping" => ctx.emit.respond(id, json!({ "ok": true })).await,
            "evaluate" => match decode::<EvaluateRequest>(params, "evaluate") {
                Ok(request) => {
                    let plugin = plugin.clone();
                    let ctx = ctx.clone();
                    tokio::spawn(async move {
                        let response = plugin.evaluate(request);
                        let answers =
                            serde_json::to_value(&response.answers).unwrap_or_else(|_| json!([]));
                        ctx.emit
                            .respond(id, json!({ "ok": true, "answers": answers }))
                            .await;
                    });
                }
                Err(error) => {
                    ctx.emit
                        .respond(id, json!({ "ok": false, "error": error }))
                        .await
                }
            },
            "search" => match decode::<SearchRequest>(params, "search") {
                Ok(request) => {
                    let plugin = plugin.clone();
                    let ctx = ctx.clone();
                    tokio::spawn(async move {
                        let response = plugin.on_search(ctx.clone(), request).await;
                        let rows =
                            serde_json::to_value(&response.rows).unwrap_or_else(|_| json!([]));
                        ctx.emit
                            .respond(id, json!({ "ok": true, "rows": rows }))
                            .await;
                    });
                }
                Err(error) => {
                    ctx.emit
                        .respond(id, json!({ "ok": false, "error": error }))
                        .await
                }
            },
            "hints" => match decode::<HintsRequest>(params, "hints") {
                Ok(request) => {
                    let plugin = plugin.clone();
                    let ctx = ctx.clone();
                    tokio::spawn(async move {
                        let response = plugin.on_hints(ctx.clone(), request).await;
                        let targets =
                            serde_json::to_value(&response.targets).unwrap_or_else(|_| json!([]));
                        let mut result = json!({ "ok": true, "targets": targets });
                        if let Some(pid) = response.context_pid {
                            result["context_pid"] = json!(pid);
                        }
                        ctx.emit.respond(id, result).await;
                    });
                }
                Err(error) => {
                    ctx.emit
                        .respond(id, json!({ "ok": false, "error": error }))
                        .await
                }
            },
            "perform" => match decode_perform(params) {
                Ok(request) => {
                    let plugin = plugin.clone();
                    let ctx = ctx.clone();
                    tokio::spawn(async move {
                        let response = plugin.perform(ctx.clone(), request).await;
                        ctx.emit.respond(id, response.to_value()).await;
                    });
                }
                Err(error) => {
                    ctx.emit
                        .respond(id, json!({ "ok": false, "error": error }))
                        .await
                }
            },
            other => {
                ctx.emit
                    .respond(
                        id,
                        json!({ "ok": false, "error": format!("unknown method: {other}") }),
                    )
                    .await
            }
        }
    }

    // The worker may be mid-handler; a closing plugin owes the host nothing
    // further, so cancel instead of draining.
    event_worker.abort();
    let _ = event_worker.await;
    // Wake every in-flight call_host with the closed sentinel (dropping the
    // senders resolves their receivers as errors).
    if let Ok(mut pending) = host_pending.lock() {
        pending.clear();
    }
    if !mismatch_exit {
        plugin.on_shutdown(ctx.clone()).await;
    }
    // Detached interval/background tasks may retain Context clones
    // indefinitely. Close their shared emitter explicitly, then drain queued
    // frames before the runtime drops and cancels those tasks.
    ctx.emit.close();
    drop(ctx);
    let _ = writer.await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::test_context;

    #[test]
    fn malformed_events_are_rejected_instead_of_becoming_default_events() {
        assert!(decode_event(json!({ "payload": {} })).is_err());
        assert!(decode_event(json!({ "name": "", "payload": {} })).is_err());
        assert!(decode_event(json!({
            "name": "core:apps.changed",
            "payload": { "running_applications": "not-an-array" }
        }))
        .is_err());

        let event = decode_event(json!({
            "name": "core:apps.changed",
            "payload": { "running_applications": [{ "bundle_id": "com.example", "pid": 7 }] }
        }))
        .unwrap();
        assert_eq!(event.running_applications.len(), 1);
    }

    #[test]
    fn perform_decodes_every_kind_and_rejects_unknown_kinds() {
        assert!(matches!(
            decode_perform(json!({ "kind": "resolve", "row": { "source": "s", "title": "t" } })),
            Ok(Perform::Resolve(row)) if row.title == "t"
        ));
        assert!(matches!(
            decode_perform(json!({ "kind": "command", "command": "tmux", "subcommand": "window" })),
            Ok(Perform::Command(command)) if command.subcommand == "window"
        ));
        assert!(matches!(
            decode_perform(json!({ "kind": "action", "name": "tab_select", "args": { "index": 2 } })),
            Ok(Perform::Action(action)) if action.index() == Some(2)
        ));
        assert!(matches!(
            decode_perform(json!({ "kind": "navigate", "url": "tmux://window/a:1" })),
            Ok(Perform::Navigate(request)) if request.url == "tmux://window/a:1"
        ));

        assert!(matches!(
            decode_perform(json!({ "kind": "mystery" })),
            Err(error) if error == "unknown perform kind: mystery"
        ));
        assert!(matches!(
            decode_perform(json!({})),
            Err(error) if error == "unknown perform kind: "
        ));
        // A resolve without a row is malformed, not a fabricated empty row.
        assert!(decode_perform(json!({ "kind": "resolve" })).is_err());
    }

    #[test]
    fn malformed_request_params_are_rejected_without_default_fallback() {
        assert!(decode::<CommandRequest>(
            json!({ "command": "x", "args": "not-an-array" }),
            "perform"
        )
        .is_err());
        assert!(decode::<EvaluateRequest>(json!({ "query": 42 }), "evaluate").is_err());
    }

    struct RecordingPlugin {
        observations: Arc<Mutex<Vec<(String, String)>>>,
    }

    impl Plugin for RecordingPlugin {
        fn on_event(&self, ctx: Context, event: Event) -> impl Future<Output = ()> + Send {
            let observations = self.observations.clone();
            async move {
                let marker = event.text.unwrap_or_default();
                if marker == "first" {
                    tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                }
                let bundle = ctx
                    .running_applications()
                    .first()
                    .map(|app| app.bundle_id.clone())
                    .unwrap_or_default();
                observations.lock().unwrap().push((marker, bundle));
            }
        }
    }

    #[tokio::test]
    async fn event_worker_delivers_serially_and_applies_app_snapshots_in_wire_order() {
        let ctx = test_context();
        let observations = Arc::new(Mutex::new(Vec::new()));
        let plugin = Arc::new(RecordingPlugin {
            observations: observations.clone(),
        });
        let (event_tx, event_rx) = mpsc::channel(4);
        let worker = tokio::spawn(run_event_worker(plugin, ctx, event_rx));

        for (marker, bundle) in [
            ("first", "com.example.First"),
            ("second", "com.example.Second"),
        ] {
            event_tx
                .send(InboundEvent {
                    event: Event {
                        name: "core:apps.changed".to_string(),
                        text: Some(marker.to_string()),
                        ..Event::default()
                    },
                    running_applications: vec![RunningApplication {
                        bundle_id: bundle.to_string(),
                        pid: 1,
                        localized_name: String::new(),
                    }],
                })
                .await
                .unwrap();
        }
        drop(event_tx);
        worker.await.unwrap();

        // The slow first handler must not be overtaken by the second event,
        // and each callback observes exactly the snapshot that motivated it.
        assert_eq!(
            *observations.lock().unwrap(),
            vec![
                ("first".to_string(), "com.example.First".to_string()),
                ("second".to_string(), "com.example.Second".to_string()),
            ]
        );
    }

    #[tokio::test]
    async fn bounded_event_queue_rejects_excess_work_without_waiting() {
        let (event_tx, _event_rx) = mpsc::channel(1);
        let event = || InboundEvent {
            event: Event {
                name: "core:focus.changed".to_string(),
                ..Event::default()
            },
            running_applications: Vec::new(),
        };

        event_tx.try_send(event()).unwrap();
        assert!(matches!(
            event_tx.try_send(event()),
            Err(mpsc::error::TrySendError::Full(_))
        ));
    }
}
