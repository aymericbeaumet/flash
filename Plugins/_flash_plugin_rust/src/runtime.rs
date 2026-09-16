//! The plugin runtime: the [`Plugin`] trait, the [`run`] entry point, and the
//! serve loop speaking protocol v1 — immediate initialize reply, `ping`,
//! `event` notifications, `evaluate`/`search`/`hints`, the unified `perform`,
//! and stdin-EOF shutdown. Parent liveness is stdin EOF: the host owns the
//! pipe, so a dead host ends the loop.

use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, BufReader, BufWriter};
use tokio::sync::{mpsc, Semaphore};
use tokio::task::JoinSet;

use crate::context::{assemble_context, Context, PluginEnv};
use crate::emit::{Emitter, OutboundFrame, MAX_FRAME_BYTES, OUTBOUND_QUEUE_CAPACITY};
use crate::events::EventMailbox;
use crate::framing::{FrameReader, Record};
use crate::types::{
    ActionRequest, CommandRequest, EvaluateRequest, EvaluateResponse, Event, Frame, HintsRequest,
    HintsResponse, NavigateRequest, Perform, PerformResponse, RunningApplication, SearchRequest,
    SearchResponse,
};

pub(crate) const REQUEST_CAPACITY: usize = 16;
pub(crate) const REQUEST_BYTES: usize = 32 * 1024 * 1024;
const REQUEST_OVERLOAD_ERROR: &str = "plugin request capacity exceeded";

/// Wire-protocol version echoed at `initialize`. A mismatch is terminal:
/// reply `ok: false` with the canonical error, flush, exit 0. MUST stay equal
/// to `protocol_version` in `Plugins/_flash_plugin_rust/protocol.json`.
const PROTOCOL_VERSION: u64 = 1;

/// Canonical protocol error strings (pinned in `protocol.json`).
const INITIALIZE_REPEATED_ERROR: &str = "initialize may only be called once";

/// After stdin EOF, shutdown callbacks and output draining share this one
/// deadline; a hung `on_shutdown` cannot keep the process alive past it.
const SHUTDOWN_DEADLINE: Duration = Duration::from_millis(750);

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

pub(crate) struct InboundEvent {
    pub(crate) event: Event,
    pub(crate) running_applications: Vec<RunningApplication>,
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
    #[serde(default, deserialize_with = "crate::wire::deserialize_optional_pid")]
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
async fn run_event_worker<P: Plugin>(plugin: Arc<P>, ctx: Context, events: Arc<EventMailbox>) {
    loop {
        let inbound = events.next().await;
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
    serve_streams(
        plugin,
        PluginEnv::from_process(),
        tokio::io::stdin(),
        tokio::io::stdout(),
    )
    .await;
}

/// The serve loop over explicit streams and environment, so tests can run
/// it over in-memory pipes with a synthetic identity.
pub(crate) async fn serve_streams<P, R, W>(plugin: P, env: PluginEnv, input: R, output: W)
where
    P: Plugin,
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let plugin = Arc::new(plugin);
    let (out_tx, mut out_rx) = mpsc::channel::<OutboundFrame>(OUTBOUND_QUEUE_CAPACITY);
    let mut writer = tokio::spawn(async move {
        // Each payload is already one newline-terminated JSON line; flush
        // every frame to keep latency low.
        let mut out = BufWriter::with_capacity(64 * 1024, output);
        while let Some(payload) = out_rx.recv().await {
            if out.write_all(&payload.payload).await.is_err() {
                break;
            }
            if out.flush().await.is_err() {
                break;
            }
        }
    });

    let ctx = assemble_context(env, Emitter::new(out_tx));
    ctx.prepare_dirs().await;

    let events = Arc::new(EventMailbox::default());
    let event_worker = tokio::spawn(run_event_worker(
        plugin.clone(),
        ctx.clone(),
        events.clone(),
    ));
    let slots = Arc::new(Semaphore::new(REQUEST_CAPACITY));
    let request_bytes = Arc::new(Semaphore::new(REQUEST_BYTES));
    let mut tasks = JoinSet::new();
    let mut stdin = FrameReader::new(BufReader::new(input), MAX_FRAME_BYTES);
    let mut initialized = false;
    let mut mismatch_exit = false;
    let mut writer_finished = false;
    'frames: loop {
        // Buffered input can contain hundreds of complete frames. Give the
        // writer/workers a turn without ever waiting for their progress.
        tokio::task::yield_now().await;
        while tasks.try_join_next().is_some() {}
        let record = tokio::select! {
            record = stdin.next() => record,
            _ = &mut writer => { writer_finished = true; break; }
        };
        let line = match record {
            Ok(Record::Frame(line)) => line,
            Ok(Record::Oversized) => {
                ctx.log("warn", "[plugin] dropped oversized inbound frame");
                continue;
            }
            Ok(Record::Truncated | Record::Eof) | Err(_) => break,
        };
        if line.is_empty() {
            continue;
        }
        // A reader-side reply must never await stdout capacity: handlers can
        // be waiting for a host response that only this reader can deliver.
        macro_rules! reply {
            ($id:expr, $result:expr $(,)?) => {
                if ctx.emit.try_respond($id, $result).is_err() {
                    eprintln!("[plugin] control reply queue unavailable; closing transport");
                    break 'frames;
                }
            };
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
                let result = frame.get("result").cloned().unwrap_or(Value::Null);
                let result = if crate::wire::valid_result("host", &result) {
                    result
                } else {
                    json!({ "ok": false, "error": "invalid host response" })
                };
                // Responses to unknown ids are dropped silently.
                ctx.resolve_host_call(request_id, result);
            }
            continue;
        }
        if id.is_null() {
            // Notification. `event` dispatches; unknown names are ignored.
            if method == "event" {
                match decode_event(params) {
                    Ok(event) => {
                        if !events.push(event, line.len()) {
                            ctx.log("warn", "[plugin] event queue full; dropped event");
                        }
                    }
                    Err(error) => ctx.log("warn", &format!("[plugin] dropped event ({error})")),
                }
            }
            continue;
        }

        if id.as_u64().is_none_or(|id| id == 0) {
            continue;
        }
        let permits = if matches!(method.as_str(), "evaluate" | "search" | "hints" | "perform") {
            match (
                slots.clone().try_acquire_owned(),
                request_bytes
                    .clone()
                    .try_acquire_many_owned(line.len() as u32),
            ) {
                (Ok(slot), Ok(bytes)) => Some((slot, bytes)),
                _ => {
                    reply!(id, json!({ "ok": false, "error": REQUEST_OVERLOAD_ERROR }));
                    continue;
                }
            }
        } else {
            None
        };
        match method.as_str() {
            "initialize" => {
                if initialized {
                    // The one non-terminal protocol NAK: reply and keep
                    // serving.
                    reply!(
                        id,
                        json!({ "ok": false, "error": INITIALIZE_REPEATED_ERROR }),
                    );
                    continue;
                }
                let host_version = params
                    .get("protocol_version")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                if host_version != PROTOCOL_VERSION {
                    reply!(
                        id,
                        json!({
                            "ok": false,
                            "protocol_version": PROTOCOL_VERSION,
                            "error": format!(
                                "protocol version mismatch: host v{host_version}, plugin v{PROTOCOL_VERSION}"
                            ),
                        }),
                    );
                    // A version mismatch is terminal: flush and exit 0.
                    mismatch_exit = true;
                    break;
                }
                initialized = true;
                // Reply immediately — no warm-catalog wait; on_start runs
                // after the reply and publishes when ready.
                reply!(
                    id,
                    json!({ "ok": true, "protocol_version": PROTOCOL_VERSION }),
                );
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                tasks.spawn(async move { plugin.on_start(ctx).await });
            }
            "ping" => reply!(id, json!({ "ok": true })),
            "evaluate" => match decode::<EvaluateRequest>(params, "evaluate") {
                Ok(request) => {
                    let plugin = plugin.clone();
                    let ctx = ctx.clone();
                    tasks.spawn(async move {
                        let _permits = permits;
                        let response = plugin.evaluate(request);
                        let answers =
                            serde_json::to_value(&response.answers).unwrap_or_else(|_| json!([]));
                        ctx.emit
                            .respond(id, json!({ "ok": true, "answers": answers }))
                            .await;
                    });
                }
                Err(error) => {
                    reply!(id, json!({ "ok": false, "error": error }));
                }
            },
            "search" => match decode::<SearchRequest>(params, "search") {
                Ok(request) => {
                    let plugin = plugin.clone();
                    let ctx = ctx.clone();
                    tasks.spawn(async move {
                        let _permits = permits;
                        let response = plugin.on_search(ctx.clone(), request).await;
                        let rows =
                            serde_json::to_value(&response.rows).unwrap_or_else(|_| json!([]));
                        ctx.emit
                            .respond(id, json!({ "ok": true, "rows": rows }))
                            .await;
                    });
                }
                Err(error) => {
                    reply!(id, json!({ "ok": false, "error": error }));
                }
            },
            "hints" => match decode::<HintsRequest>(params, "hints") {
                Ok(request) => {
                    let plugin = plugin.clone();
                    let ctx = ctx.clone();
                    tasks.spawn(async move {
                        let _permits = permits;
                        let response = plugin.on_hints(ctx.clone(), request).await;
                        let targets =
                            serde_json::to_value(&response.targets).unwrap_or_else(|_| json!([]));
                        let mut result = json!({ "ok": true, "targets": targets });
                        if let Some(pid) = response.context_pid {
                            result["context_pid"] = json!(pid);
                        }
                        if !crate::wire::valid_result("hints", &result) {
                            result = json!({ "ok": false, "error": "invalid hints response" });
                        }
                        ctx.emit.respond(id, result).await;
                    });
                }
                Err(error) => {
                    reply!(id, json!({ "ok": false, "error": error }));
                }
            },
            "perform" => match decode_perform(params) {
                Ok(request) => {
                    let plugin = plugin.clone();
                    let ctx = ctx.clone();
                    tasks.spawn(async move {
                        let _permits = permits;
                        let response = plugin.perform(ctx.clone(), request).await;
                        ctx.emit.respond(id, response.to_value()).await;
                    });
                }
                Err(error) => {
                    reply!(id, json!({ "ok": false, "error": error }));
                }
            },
            other => {
                reply!(
                    id,
                    json!({ "ok": false, "error": format!("unknown method: {other}") }),
                );
            }
        }
    }
    // The worker may be mid-handler; a closing plugin owes the host nothing
    // further, so cancel instead of draining.
    event_worker.abort();
    let _ = event_worker.await;
    // Wake every in-flight call_host with the closed sentinel.
    ctx.abandon_host_calls();
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    let deadline = tokio::time::Instant::now() + SHUTDOWN_DEADLINE;
    if !mismatch_exit {
        let _ = tokio::time::timeout_at(deadline, plugin.on_shutdown(ctx.clone())).await;
    }
    // Detached interval/background tasks may retain Context clones
    // indefinitely. Close their shared emitter explicitly, then drain queued
    // frames before the runtime drops and cancels those tasks.
    ctx.emit.close();
    drop(ctx);
    if !writer_finished
        && tokio::time::timeout_at(deadline, &mut writer)
            .await
            .is_err()
    {
        writer.abort();
        let _ = writer.await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::test_context;
    use crate::emit::MAX_FRAME_BYTES;
    use crate::testing::{test_env, WireHarness};
    use crate::types::{Candidate, JumpTarget, QueryAnswer};
    use std::collections::BTreeMap;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::Mutex;
    use std::time::Instant;

    const INITIALIZE: &str = r#"{"id":1,"method":"initialize","params":{"protocol_version":1}}"#;

    fn initialize() -> Value {
        serde_json::from_str(INITIALIZE).unwrap()
    }

    fn command(id: u64, subcommand: &str) -> Value {
        json!({ "id": id, "method": "perform", "params": {
            "kind": "command", "command": "test", "subcommand": subcommand, "args": [], "raw": ""
        }})
    }

    /// Serve `plugin` and complete the handshake.
    async fn serve<P: Plugin>(plugin: P) -> WireHarness {
        let mut wire = WireHarness::new(plugin);
        wire.send(initialize()).await;
        assert_eq!(
            wire.recv().await,
            json!({ "id": 1, "result": { "ok": true, "protocol_version": 1 } })
        );
        wire
    }

    /// A plugin exercising every surface the runtime routes.
    #[derive(Default)]
    struct TestPlugin {
        publish_on_start: bool,
        hang_on_shutdown: bool,
        shutdown_ran: Arc<AtomicBool>,
    }

    impl Plugin for TestPlugin {
        async fn on_start(&self, ctx: Context) {
            if self.publish_on_start {
                ctx.publish(vec![Candidate::new("test.items", "warm")]);
            }
        }

        fn evaluate(&self, request: EvaluateRequest) -> EvaluateResponse {
            if request.query == "one" {
                return EvaluateResponse::answers(vec![QueryAnswer::copy_text("one", Some("s"))]);
            }
            EvaluateResponse::default()
        }

        async fn on_search(&self, _: Context, request: SearchRequest) -> SearchResponse {
            if request.query == "hit" {
                return SearchResponse::rows(vec![Candidate::new("test.items", "hit")]);
            }
            SearchResponse::default()
        }

        async fn on_hints(&self, _: Context, request: HintsRequest) -> HintsResponse {
            if request.bundle_id.as_deref() == Some("invalid") {
                // A zero-width frame fails the shared target validation.
                return HintsResponse::targets(vec![JumpTarget::new(
                    "t",
                    Frame::new(0.0, 0.0, 0.0, 10.0),
                )]);
            }
            HintsResponse::targets(vec![JumpTarget::new(
                "t1",
                Frame::new(-10.5, 20.0, 30.0, 40.0),
            )
            .role("AXLink")
            .context_id("surface-1")
            .label("one")])
            .context_pid(77)
        }

        async fn perform(&self, ctx: Context, request: Perform) -> PerformResponse {
            let Perform::Command(command) = request else {
                return PerformResponse::unhandled();
            };
            match command.subcommand.as_str() {
                "notify" => {
                    ctx.status([(" state ", "on"), ("", "dropped")]);
                    ctx.log_fields(
                        "warn",
                        "hello",
                        BTreeMap::from([("k".to_string(), "v".to_string())]),
                    );
                    PerformResponse::ok()
                }
                "oversized" => {
                    ctx.publish(vec![Candidate::new(
                        "test.items",
                        "x".repeat(MAX_FRAME_BYTES),
                    )]);
                    ctx.publish(vec![Candidate::new("test.items", "fits")]);
                    PerformResponse::ok()
                }
                "host-ping" => {
                    let result = ctx.call_host("host.ping", json!({})).await;
                    PerformResponse::ok().message(result.to_string())
                }
                _ => PerformResponse::unhandled(),
            }
        }

        async fn on_shutdown(&self, ctx: Context) {
            self.shutdown_ran.store(true, Ordering::SeqCst);
            if self.hang_on_shutdown {
                std::future::pending::<()>().await;
            }
            ctx.log("info", "shutdown");
        }
    }

    #[tokio::test]
    async fn handshake_echoes_the_version_and_naks_a_repeated_initialize() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send(json!({ "id": 2, "method": "ping", "params": {} }))
            .await;
        assert_eq!(wire.recv_response(2).await, json!({ "ok": true }));
        wire.send(json!({ "id": 3, "method": "initialize", "params": { "protocol_version": 1 } }))
            .await;
        assert_eq!(
            wire.recv_response(3).await,
            json!({ "ok": false, "error": INITIALIZE_REPEATED_ERROR })
        );
        // Still serving after the NAK.
        wire.send(json!({ "id": 4, "method": "ping", "params": {} }))
            .await;
        assert_eq!(wire.recv_response(4).await, json!({ "ok": true }));
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn unknown_methods_reply_the_canonical_error() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send(json!({ "id": 7, "method": "driver.unknown", "params": { "x": -1912.5 } }))
            .await;
        assert_eq!(
            wire.recv_response(7).await,
            json!({ "ok": false, "error": "unknown method: driver.unknown" })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn notifications_are_never_replied() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send(json!({ "method": "event", "params": {
            "name": "core:window.focus.changed",
            "payload": { "bundle_id": "dev.flash.test", "pid": 999,
                "front_window_frame": { "x": -1912.5, "y": -140.25, "width": 1512.0, "height": 982.0 } }
        }}))
        .await;
        wire.send(json!({ "method": "driver.mystery", "params": { "noise": true } }))
            .await;
        wire.send(json!({ "id": 8, "method": "ping", "params": {} }))
            .await;
        // The ping reply is the very next frame: nothing answered the notifications.
        assert_eq!(
            wire.recv().await,
            json!({ "id": 8, "result": { "ok": true } })
        );
        wire.close_stdin().await;
        assert!(wire
            .finished()
            .await
            .iter()
            .all(|frame| frame["method"] == "log"));
    }

    #[tokio::test]
    async fn protocol_mismatch_replies_then_terminates_without_running_shutdown() {
        for (version, host) in [
            (json!(99), "99"),
            (json!(true), "0"),
            (json!(1.0), "0"),
            (json!("1"), "0"),
            (json!(0), "0"),
            (json!(-1), "0"),
            (json!(2147483648_u64), "2147483648"),
        ] {
            let shutdown_ran = Arc::new(AtomicBool::new(false));
            let mut wire = WireHarness::new(TestPlugin {
                shutdown_ran: shutdown_ran.clone(),
                ..TestPlugin::default()
            });
            wire.send(json!({ "id": 1, "method": "initialize", "params": { "protocol_version": version } }))
                .await;
            assert_eq!(
                wire.recv().await,
                json!({ "id": 1, "result": {
                    "ok": false,
                    "protocol_version": 1,
                    "error": format!("protocol version mismatch: host v{host}, plugin v1"),
                }}),
                "{version}"
            );
            // No EOF from the host: the mismatch itself ends the loop.
            assert!(wire.finished().await.is_empty(), "{version}");
            assert!(!shutdown_ran.load(Ordering::SeqCst), "{version}");
        }
    }

    #[tokio::test]
    async fn batched_frames_are_each_answered_exactly_once() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send_raw(
            br#"{"id":10,"method":"ping","params":{}}
{"id":11,"method":"ping","params":{}}
{"id":12,"method":"driver.unknown","params":{}}
{"id":13,"method":"ping","params":{}}
{"id":14,"method":"ping","params":{}}
"#,
        )
        .await;
        let mut replies = Vec::new();
        for _ in 0..5 {
            replies.push(wire.recv().await);
        }
        replies.sort_by_key(|frame| frame["id"].as_u64());
        assert_eq!(
            replies,
            [
                json!({ "id": 10, "result": { "ok": true } }),
                json!({ "id": 11, "result": { "ok": true } }),
                json!({ "id": 12, "result": { "ok": false, "error": "unknown method: driver.unknown" } }),
                json!({ "id": 13, "result": { "ok": true } }),
                json!({ "id": 14, "result": { "ok": true } }),
            ]
        );
        wire.close_stdin().await;
        assert!(
            wire.finished()
                .await
                .iter()
                .all(|frame| frame.get("id").is_none()),
            "no duplicate replies"
        );
    }

    #[tokio::test]
    async fn ids_round_trip_and_malformed_ids_are_ignored() {
        let mut wire = serve(TestPlugin::default()).await;
        for id in [7_u64, 7, 9007199254740991] {
            wire.send(json!({ "id": id, "method": "ping", "params": {} }))
                .await;
            assert_eq!(
                wire.recv().await,
                json!({ "id": id, "result": { "ok": true } })
            );
        }
        for id in [json!(0), json!(-1), json!(1.5), json!(true), json!("x")] {
            wire.send(json!({ "id": id, "method": "ping", "params": {} }))
                .await;
        }
        wire.send(json!({ "id": 8, "method": "ping", "params": {} }))
            .await;
        assert_eq!(
            wire.recv().await,
            json!({ "id": 8, "result": { "ok": true } })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn wire_noise_is_dropped_and_ping_survives() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send_raw(b"\n").await;
        wire.send_raw(b"this is not json\n").await;
        wire.send_raw(b"{\"truncated\": \n").await;
        wire.send(json!({ "method": "driver.mystery", "params": { "noise": true } }))
            .await;
        wire.send(json!({ "id": 424242, "result": { "ok": true } }))
            .await;
        wire.send(json!({ "id": 4, "method": "ping", "params": {} }))
            .await;
        let mut frames = Vec::new();
        loop {
            let frame = wire.recv().await;
            let reply = frame.get("id").is_some();
            frames.push(frame);
            if reply {
                break;
            }
        }
        let (reply, dropped) = frames.split_last().unwrap();
        assert_eq!(*reply, json!({ "id": 4, "result": { "ok": true } }));
        assert_eq!(
            dropped.len(),
            2,
            "one warning per undecodable line: {dropped:?}"
        );
        for frame in dropped {
            assert_eq!(frame["method"], "log");
            assert_eq!(
                frame["params"]["message"],
                "[plugin] dropped undecodable frame"
            );
        }
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn oversized_inbound_lines_are_dropped_with_a_warning() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send_raw(&vec![b'x'; MAX_FRAME_BYTES + 1]).await;
        wire.send_raw(b"\n").await;
        wire.send(json!({ "id": 4, "method": "ping", "params": {} }))
            .await;
        let warning = wire.recv().await;
        assert_eq!(warning["method"], "log");
        assert_eq!(warning["params"]["level"], "warn");
        assert_eq!(
            warning["params"]["message"],
            "[plugin] dropped oversized inbound frame"
        );
        assert_eq!(
            wire.recv().await,
            json!({ "id": 4, "result": { "ok": true } })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn unicode_params_and_invalid_surrogates_do_not_break_the_loop() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send(json!({ "id": 5, "method": "driver.unicode", "params": {
            "text": "héllo ⚡ 世界 🧪 éé\u{0301} \t\u{001f}"
        }}))
        .await;
        assert_eq!(
            wire.recv_response(5).await,
            json!({ "ok": false, "error": "unknown method: driver.unicode" })
        );
        wire.send_raw(br#"{"id":6,"method":"driver.surrogate","params":{"s":"\ud800"}}"#)
            .await;
        wire.send_raw(b"\n").await;
        wire.send(json!({ "id": 7, "method": "ping", "params": {} }))
            .await;
        let dropped = wire.recv().await;
        assert_eq!(
            dropped["params"]["message"],
            "[plugin] dropped undecodable frame"
        );
        assert_eq!(
            wire.recv().await,
            json!({ "id": 7, "result": { "ok": true } })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn on_start_runs_after_the_initialize_reply() {
        let mut wire = WireHarness::new(TestPlugin {
            publish_on_start: true,
            ..TestPlugin::default()
        });
        wire.send(initialize()).await;
        assert_eq!(wire.recv().await["result"]["ok"], true);
        assert_eq!(
            wire.recv().await,
            json!({ "method": "publish", "params": { "rows": [{ "source": "test.items", "title": "warm" }] } })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn unknown_perform_kinds_are_errors_not_fallbacks() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send(json!({ "id": 5, "method": "perform", "params": { "kind": "zzz-probe" } }))
            .await;
        assert_eq!(
            wire.recv_response(5).await,
            json!({ "ok": false, "error": "unknown perform kind: zzz-probe" })
        );
        wire.send(json!({ "id": 6, "method": "ping", "params": {} }))
            .await;
        assert_eq!(wire.recv_response(6).await, json!({ "ok": true }));
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn evaluate_and_search_reply_their_arrays_even_when_empty() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send(json!({ "id": 2, "method": "evaluate", "params": { "surface": "flashlight", "scope": "", "query": "one" } }))
            .await;
        assert_eq!(
            wire.recv_response(2).await,
            json!({ "ok": true, "answers": [
                { "title": "one", "subtitle": "s", "effect": { "type": "copy_text", "text": "one" } }
            ]})
        );
        wire.send(json!({ "id": 3, "method": "evaluate", "params": { "surface": "flashlight", "scope": "", "query": "zzz" } }))
            .await;
        assert_eq!(
            wire.recv_response(3).await,
            json!({ "ok": true, "answers": [] })
        );
        wire.send(
            json!({ "id": 4, "method": "search", "params": { "query": "hit", "scope": "" } }),
        )
        .await;
        assert_eq!(
            wire.recv_response(4).await,
            json!({ "ok": true, "rows": [{ "source": "test.items", "title": "hit" }] })
        );
        wire.send(
            json!({ "id": 5, "method": "search", "params": { "query": "zzz", "scope": "" } }),
        )
        .await;
        assert_eq!(
            wire.recv_response(5).await,
            json!({ "ok": true, "rows": [] })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn hints_replies_carry_targets_and_context_pid_or_the_validation_error() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send(json!({ "id": 2, "method": "hints", "params": { "bundle_id": "dev.flash.test", "pid": 999 } }))
            .await;
        assert_eq!(
            wire.recv_response(2).await,
            json!({ "ok": true, "context_pid": 77, "targets": [
                { "id": "t1", "frame": { "x": -10.5, "y": 20.0, "width": 30.0, "height": 40.0 }, "role": "AXLink", "label": "one", "context_id": "surface-1" }
            ]})
        );
        wire.send(json!({ "id": 3, "method": "hints", "params": { "bundle_id": "invalid" } }))
            .await;
        assert_eq!(
            wire.recv_response(3).await,
            json!({ "ok": false, "error": "invalid hints response" })
        );
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn malformed_request_params_reply_the_method_specific_error() {
        let mut wire = serve(TestPlugin::default()).await;
        for (id, method, params) in [
            (2, "evaluate", json!({ "query": 42 })),
            (3, "search", json!({ "query": 42 })),
            (4, "hints", json!({ "pid": 2147483648_u64 })),
            (
                5,
                "perform",
                json!({ "kind": "command", "command": "x", "args": "not-an-array" }),
            ),
            (6, "perform", json!({ "kind": "resolve" })),
        ] {
            wire.send(json!({ "id": id, "method": method, "params": params }))
                .await;
            assert_eq!(
                wire.recv_response(id).await,
                json!({ "ok": false, "error": format!("invalid {method} params") })
            );
        }
        wire.send(json!({ "id": 7, "method": "ping", "params": {} }))
            .await;
        assert_eq!(wire.recv_response(7).await, json!({ "ok": true }));
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn eof_runs_shutdown_and_drains_its_log_before_returning() {
        let shutdown_ran = Arc::new(AtomicBool::new(false));
        let mut wire = serve(TestPlugin {
            shutdown_ran: shutdown_ran.clone(),
            ..TestPlugin::default()
        })
        .await;
        wire.close_stdin().await;
        let frames = wire.finished().await;
        assert!(shutdown_ran.load(Ordering::SeqCst));
        assert_eq!(
            frames,
            [
                json!({ "method": "log", "params": { "level": "info", "message": "shutdown", "fields": {} } })
            ]
        );
    }

    #[tokio::test]
    async fn shutdown_is_bounded_by_the_deadline() {
        let mut wire = serve(TestPlugin {
            hang_on_shutdown: true,
            ..TestPlugin::default()
        })
        .await;
        wire.close_stdin().await;
        let started = Instant::now();
        assert!(wire.finished().await.is_empty());
        let elapsed = started.elapsed();
        assert!(elapsed >= SHUTDOWN_DEADLINE, "{elapsed:?}");
        assert!(elapsed < SHUTDOWN_DEADLINE * 2, "{elapsed:?}");
    }

    #[tokio::test]
    async fn oversized_notifications_are_dropped_whole_without_blocking() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send(command(2, "oversized")).await;
        assert_eq!(
            wire.recv_notification("publish").await,
            json!({ "rows": [{ "source": "test.items", "title": "fits" }] })
        );
        assert_eq!(wire.recv_response(2).await, json!({ "ok": true }));
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn status_and_log_notifications_carry_their_canonical_shapes() {
        let mut wire = serve(TestPlugin::default()).await;
        wire.send(command(2, "notify")).await;
        assert_eq!(
            wire.recv().await,
            json!({ "method": "status", "params": { "segments": { "state": "on" } } })
        );
        assert_eq!(
            wire.recv().await,
            json!({ "method": "log", "params": { "level": "warn", "message": "hello", "fields": { "k": "v" } } })
        );
        assert_eq!(wire.recv_response(2).await, json!({ "ok": true }));
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn malformed_host_responses_become_the_invalid_host_response_sentinel() {
        let mut wire = serve(TestPlugin::default()).await;
        for (id, reply) in [
            (2, json!({ "result": { "ok": "yes" } })),
            (3, json!({ "result": { "ok": false } })),
            (4, json!({})),
        ] {
            wire.send(command(id, "host-ping")).await;
            let request = wire.recv().await;
            assert_eq!(request["method"], "host.ping");
            let mut response = reply;
            response["id"] = request["id"].clone();
            wire.send(response).await;
            let result = wire.recv_response(id).await;
            assert_eq!(result["ok"], true);
            let message = result["message"].as_str().unwrap();
            assert!(message.contains("invalid host response"), "{message}");
        }
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn unread_stdout_cannot_hold_the_runtime_open_after_eof() {
        let (output, _unread) = tokio::io::duplex(1);
        let input = INITIALIZE.as_bytes();
        let plugin = WaitingPlugin {
            requests: Arc::new(AtomicUsize::new(0)),
            observed_apps: Arc::new(Mutex::new(None)),
        };
        tokio::time::timeout(
            Duration::from_secs(2),
            serve_streams(plugin, test_env("unread", json!({})), input, output),
        )
        .await
        .unwrap();
    }

    struct WaitingPlugin {
        requests: Arc<AtomicUsize>,
        observed_apps: Arc<Mutex<Option<usize>>>,
    }

    impl Plugin for WaitingPlugin {
        async fn on_search(&self, _: Context, _: SearchRequest) -> SearchResponse {
            self.requests.fetch_add(1, Ordering::SeqCst);
            std::future::pending().await
        }

        async fn on_event(&self, ctx: Context, event: Event) {
            if event.text.as_deref() == Some("hold") {
                assert_eq!(
                    ctx.call_host("host.ping", json!({})).await,
                    json!({"ok":true})
                );
            }
            *self.observed_apps.lock().unwrap() = Some(ctx.running_applications().len());
        }
    }

    #[tokio::test]
    async fn live_reader_preserves_final_snapshot_while_event_handler_awaits_host_rpc() {
        let observed = Arc::new(Mutex::new(None));
        let mut wire = serve(WaitingPlugin {
            requests: Arc::new(AtomicUsize::new(0)),
            observed_apps: observed.clone(),
        })
        .await;
        wire.send(json!({"method":"event","params":{"name":"core:apps.changed","payload":{"text":"hold","running_applications":[{"pid":7,"bundle_id":"first"}]}}})).await;
        let rpc = wire.recv().await;
        assert_eq!(rpc["method"], "host.ping");
        for _ in 0..300 {
            wire.send(json!({"method":"event","params":{"name":"core:apps.changed","payload":{"running_applications":[{"pid":8,"bundle_id":"older"}]}}})).await;
        }
        wire.send(json!({"method":"event","params":{"name":"core:apps.changed","payload":{"running_applications":[]}}})).await;
        wire.send(json!({"id":2,"method":"ping"})).await;
        assert_eq!(wire.recv().await["id"], 2);
        wire.send(json!({"id":rpc["id"],"result":{"ok":true}}))
            .await;
        tokio::time::timeout(Duration::from_secs(2), async {
            while *observed.lock().unwrap() != Some(0) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn request_overload_is_bounded_and_keeps_ping_and_eof_responsive() {
        let requests = Arc::new(AtomicUsize::new(0));
        let mut wire = serve(WaitingPlugin {
            requests: requests.clone(),
            observed_apps: Arc::new(Mutex::new(None)),
        })
        .await;
        for id in 2..=(REQUEST_CAPACITY + 2) {
            wire.send(json!({"id":id,"method":"search","params":{"query":"wait"}}))
                .await;
        }
        let overload = wire.recv().await;
        assert_eq!(overload["result"]["error"], REQUEST_OVERLOAD_ERROR);
        assert_eq!(requests.load(Ordering::SeqCst), REQUEST_CAPACITY);
        wire.send(json!({"id":100,"method":"ping"})).await;
        assert_eq!(wire.recv().await["id"], 100);
        wire.close_stdin().await;
        wire.finished().await;
    }

    #[tokio::test]
    async fn runtime_does_not_dispatch_unterminated_json_at_eof() {
        let requests = Arc::new(AtomicUsize::new(0));
        let mut wire = serve(WaitingPlugin {
            requests: requests.clone(),
            observed_apps: Arc::new(Mutex::new(None)),
        })
        .await;
        wire.send_raw(br#"{"id":2,"method":"search","params":{"query":"wait"}}"#)
            .await;
        wire.close_stdin().await;
        assert!(wire.finished().await.is_empty());
        assert_eq!(requests.load(Ordering::SeqCst), 0);
    }

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
        let events = Arc::new(EventMailbox::default());
        let worker = tokio::spawn(run_event_worker(plugin, ctx, events.clone()));

        for (marker, bundle) in [
            ("first", "com.example.First"),
            ("second", "com.example.Second"),
        ] {
            assert!(events.push(
                InboundEvent {
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
                },
                100
            ));
        }
        tokio::time::timeout(Duration::from_secs(1), async {
            while observations.lock().unwrap().len() != 2 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        worker.abort();
        let _ = worker.await;

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
}
