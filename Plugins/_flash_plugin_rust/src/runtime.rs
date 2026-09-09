//! The plugin runtime: the [`Plugin`] trait, the [`run`] entry point, and the
//! serve loop speaking protocol v1 — immediate initialize reply, `ping`,
//! `event` notifications, `evaluate`/`search`/`hints`, the unified `perform`,
//! and stdin-EOF shutdown. Parent liveness is stdin EOF: the host owns the
//! pipe, so a dead host ends the loop.

use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};

use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, BufReader, BufWriter};
use tokio::sync::{mpsc, Semaphore};
use tokio::task::JoinSet;

use crate::context::{context_from_env, Context, HostPending};
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
    serve_streams(plugin, tokio::io::stdin(), tokio::io::stdout()).await;
}

async fn serve_streams<P, R, W>(plugin: P, input: R, output: W)
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

    let host_pending: HostPending = Arc::new(Mutex::new(HashMap::new()));
    let ctx = context_from_env(
        Emitter::new(out_tx),
        host_pending.clone(),
        Arc::new(AtomicU64::new(0)),
    );
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
                if let Some(tx) = host_pending
                    .lock()
                    .ok()
                    .and_then(|mut pending| pending.remove(&request_id))
                {
                    let result = frame.get("result").cloned().unwrap_or(Value::Null);
                    let result = if crate::wire::valid_result("host", &result) {
                        result
                    } else {
                        json!({ "ok": false, "error": "invalid host response" })
                    };
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
    // Wake every in-flight call_host with the closed sentinel (dropping the
    // senders resolves their receivers as errors).
    if let Ok(mut pending) = host_pending.lock() {
        pending.clear();
    }
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    let deadline = tokio::time::Instant::now() + Duration::from_millis(750);
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
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncBufReadExt, DuplexStream, ReadHalf};

    #[tokio::test]
    async fn unread_stdout_cannot_hold_the_runtime_open_after_eof() {
        let (output, _unread) = tokio::io::duplex(1);
        let input =
            &b"{\"id\":1,\"method\":\"initialize\",\"params\":{\"protocol_version\":1}}\n"[..];
        let plugin = WaitingPlugin {
            requests: Arc::new(AtomicUsize::new(0)),
            observed_apps: Arc::new(Mutex::new(None)),
        };
        tokio::time::timeout(Duration::from_secs(2), serve_streams(plugin, input, output))
            .await
            .unwrap();
    }

    async fn host_frame(reader: &mut BufReader<ReadHalf<DuplexStream>>) -> Value {
        let mut line = String::new();
        tokio::time::timeout(Duration::from_secs(2), reader.read_line(&mut line))
            .await
            .unwrap()
            .unwrap();
        serde_json::from_str(&line).expect("runtime response")
    }

    async fn send_host(writer: &mut tokio::io::WriteHalf<DuplexStream>, value: Value) {
        let mut bytes = serde_json::to_vec(&value).unwrap();
        bytes.push(b'\n');
        writer.write_all(&bytes).await.unwrap();
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
        let (host, child) = tokio::io::duplex(1024 * 1024);
        let (input, output) = tokio::io::split(child);
        let server = tokio::spawn(serve_streams(
            WaitingPlugin {
                requests: Arc::new(AtomicUsize::new(0)),
                observed_apps: observed.clone(),
            },
            input,
            output,
        ));
        let (read, mut write) = tokio::io::split(host);
        let mut read = BufReader::new(read);
        send_host(
            &mut write,
            json!({"id":1,"method":"initialize","params":{"protocol_version":1}}),
        )
        .await;
        assert_eq!(host_frame(&mut read).await["result"]["ok"], true);
        send_host(&mut write, json!({"method":"event","params":{"name":"core:apps.changed","payload":{"text":"hold","running_applications":[{"pid":7,"bundle_id":"first"}]}}})).await;
        let rpc = host_frame(&mut read).await;
        assert_eq!(rpc["method"], "host.ping");
        for _ in 0..300 {
            send_host(&mut write, json!({"method":"event","params":{"name":"core:apps.changed","payload":{"running_applications":[{"pid":8,"bundle_id":"older"}]}}})).await;
        }
        send_host(&mut write, json!({"method":"event","params":{"name":"core:apps.changed","payload":{"running_applications":[]}}})).await;
        send_host(&mut write, json!({"id":2,"method":"ping"})).await;
        assert_eq!(host_frame(&mut read).await["id"], 2);
        send_host(&mut write, json!({"id":rpc["id"],"result":{"ok":true}})).await;
        tokio::time::timeout(Duration::from_secs(2), async {
            while *observed.lock().unwrap() != Some(0) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        write.shutdown().await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn request_overload_is_bounded_and_keeps_ping_and_eof_responsive() {
        let requests = Arc::new(AtomicUsize::new(0));
        let (host, child) = tokio::io::duplex(64 * 1024);
        let (input, output) = tokio::io::split(child);
        let server = tokio::spawn(serve_streams(
            WaitingPlugin {
                requests: requests.clone(),
                observed_apps: Arc::new(Mutex::new(None)),
            },
            input,
            output,
        ));
        let (read, mut write) = tokio::io::split(host);
        let mut read = BufReader::new(read);
        send_host(
            &mut write,
            json!({"id":1,"method":"initialize","params":{"protocol_version":1}}),
        )
        .await;
        host_frame(&mut read).await;
        for id in 2..=(REQUEST_CAPACITY + 2) {
            send_host(
                &mut write,
                json!({"id":id,"method":"search","params":{"query":"wait"}}),
            )
            .await;
        }
        let overload = host_frame(&mut read).await;
        assert_eq!(overload["result"]["error"], REQUEST_OVERLOAD_ERROR);
        assert_eq!(requests.load(Ordering::SeqCst), REQUEST_CAPACITY);
        send_host(&mut write, json!({"id":100,"method":"ping"})).await;
        assert_eq!(host_frame(&mut read).await["id"], 100);
        write.shutdown().await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn runtime_does_not_dispatch_unterminated_json_at_eof() {
        let requests = Arc::new(AtomicUsize::new(0));
        let (host, child) = tokio::io::duplex(1024);
        let (input, output) = tokio::io::split(child);
        let server = tokio::spawn(serve_streams(
            WaitingPlugin {
                requests: requests.clone(),
                observed_apps: Arc::new(Mutex::new(None)),
            },
            input,
            output,
        ));
        let (read, mut write) = tokio::io::split(host);
        let mut read = BufReader::new(read);
        send_host(
            &mut write,
            json!({"id":1,"method":"initialize","params":{"protocol_version":1}}),
        )
        .await;
        host_frame(&mut read).await;
        write
            .write_all(br#"{"id":2,"method":"search","params":{"query":"wait"}}"#)
            .await
            .unwrap();
        write.shutdown().await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), server)
            .await
            .unwrap()
            .unwrap();
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
