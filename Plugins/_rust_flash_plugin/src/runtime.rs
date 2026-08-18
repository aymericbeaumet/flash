//! The plugin runtime: the [`Plugin`] trait, [`run`] entry point, the serve
//! loop speaking the `initialize`/`heartbeat`/`shutdown` lifecycle, the
//! serialized event queue, startup-state gating, and the parent-liveness
//! watch.

use std::collections::BTreeMap;
use std::collections::HashMap;
use std::future::Future;
use std::ptr;
use std::sync::atomic::AtomicU64;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufWriter};
use tokio::sync::{mpsc, watch};

use crate::context::{context_from_env, Context, HostPending};
use crate::types::{Event, Frame, Request, Response, RunningApplication, SourceSnapshotResponse};
use crate::wire::{
    Emitter, OutboundReceiver, CONTROL_QUEUE_CAPACITY, MAX_FRAME_BYTES, TELEMETRY_QUEUE_CAPACITY,
};

const EVENT_QUEUE_CAPACITY: usize = 256;
const EVENT_HANDLER_WARN_AFTER: Duration = Duration::from_secs(1);
const EVENT_HANDLER_TIMEOUT: Duration = Duration::from_secs(15);

/// Wire-protocol version negotiated in `initialize`. A mismatch is fatal: the
/// host and plugin must agree on lifecycle and payload semantics before the
/// plugin can become ready. Bump on any breaking wire change. MUST stay in sync
/// with `PluginProcess.protocolVersion` on the host.
const PROTOCOL_VERSION: u32 = 3;

struct QueuedEvent {
    event: Event,
    running_applications: Vec<RunningApplication>,
    enqueued_at: Instant,
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

impl Event {
    fn from_params(params: Value) -> Result<QueuedEvent, String> {
        match serde_json::from_value::<EventWire>(params) {
            Ok(wire) if !wire.name.trim().is_empty() => Ok(QueuedEvent {
                event: Event {
                    name: wire.name,
                    bundle_id: wire.payload.bundle_id,
                    pid: wire.payload.pid,
                    front_window_frame: wire.payload.front_window_frame,
                    text: wire.payload.text,
                },
                running_applications: wire.payload.running_applications,
                enqueued_at: Instant::now(),
            }),
            Ok(_) => Err("event name must not be empty".to_string()),
            Err(error) => Err(format!("invalid event params: {error}")),
        }
    }
}

#[derive(Deserialize)]
struct InitializeRequest {
    protocol_version: u32,
    #[serde(default)]
    running_applications: Vec<RunningApplication>,
}

/// A Flash plugin. Implement [`handle`](Plugin::handle) for the request methods
/// the plugin understands; override the lifecycle hooks as needed. Every method
/// returns a `Send` future so the runtime can drive handlers concurrently
/// without blocking the heartbeat/serve loop.
pub trait Plugin: Send + Sync + 'static {
    /// Called once during `initialize`, on a background task. Initialization
    /// does not complete until this future returns. Candidate-source plugins
    /// must publish an initial warm snapshot (including authoritative empty)
    /// before returning.
    fn on_start(&self, ctx: Context) -> impl Future<Output = ()> + Send {
        let _ = ctx;
        async {}
    }

    /// Generated from the plugin manifest. The runtime uses this to reject a
    /// candidate plugin that returns from `on_start` without calling
    /// `set_locations`.
    fn requires_initial_locations(&self) -> bool {
        false
    }

    /// Host event (`core:focus.changed`, `core:apps.launched`, `core:config.changed`, …).
    fn on_event(&self, ctx: Context, event: Event) -> impl Future<Output = ()> + Send {
        let _ = (ctx, event);
        async {}
    }

    /// Dispatch a non-lifecycle [`Request`] and return a [`Response`]. For
    /// [`Request::ActivateTarget`] (a notification) the returned value is
    /// ignored — return [`Response::None`].
    fn handle(&self, ctx: Context, request: Request) -> impl Future<Output = Response> + Send;

    /// Called on `shutdown` just before the process exits.
    fn on_shutdown(&self, ctx: Context, reason: String) -> impl Future<Output = ()> + Send {
        let _ = (ctx, reason);
        async {}
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StartupState {
    Pending,
    Ready,
    Failed,
}

async fn startup_succeeded(mut state: watch::Receiver<StartupState>) -> bool {
    loop {
        match *state.borrow() {
            StartupState::Ready => return true,
            StartupState::Failed => return false,
            StartupState::Pending => {}
        }
        if state.changed().await.is_err() {
            return false;
        }
    }
}

fn startup_is_ready(state: &watch::Receiver<StartupState>) -> bool {
    *state.borrow() == StartupState::Ready
}

/// Deliver host events after initialization, exactly once and in wire order.
/// A single worker prevents a slow stale refresh from overtaking a newer
/// `core:apps.changed` publication. Warm snapshots never join this queue: they
/// clone the last atomically published store immediately while maintenance
/// continues in the background.
async fn run_event_worker<P: Plugin>(
    plugin: Arc<P>,
    ctx: Context,
    mut events: mpsc::Receiver<QueuedEvent>,
    startup: watch::Receiver<StartupState>,
    handler_timeout: Duration,
) {
    if !startup_succeeded(startup).await {
        return;
    }

    while let Some(queued) = events.recv().await {
        let event_name = queued.event.name.clone();
        let queue_elapsed = queued.enqueued_at.elapsed();
        if event_name == "core:apps.changed" {
            // The empty list is authoritative too: a terminated final app must
            // clear the snapshot before plugin code rebuilds its warm catalog.
            ctx.set_running_applications(queued.running_applications);
        }

        let started_at = Instant::now();
        let outcome =
            tokio::time::timeout(handler_timeout, plugin.on_event(ctx.clone(), queued.event)).await;
        let handler_elapsed = started_at.elapsed();
        let fields = BTreeMap::from([
            ("event".to_string(), event_name),
            (
                "queue_ms".to_string(),
                queue_elapsed.as_millis().to_string(),
            ),
            (
                "handler_ms".to_string(),
                handler_elapsed.as_millis().to_string(),
            ),
        ]);
        match outcome {
            Err(_) => {
                let mut fields = fields;
                fields.insert(
                    "timeout_ms".to_string(),
                    handler_timeout.as_millis().to_string(),
                );
                ctx.log_fields("warn", "[plugin] event handler timed out", fields);
            }
            Ok(()) if handler_elapsed >= EVENT_HANDLER_WARN_AFTER => {
                ctx.log_fields("warn", "[plugin] slow event handler", fields);
            }
            Ok(()) if queue_elapsed >= EVENT_HANDLER_WARN_AFTER => {
                ctx.log_fields("warn", "[plugin] event queue delayed", fields);
            }
            Ok(()) => {}
        }
    }
}

fn parent_pid_from_env() -> Option<i32> {
    std::env::var("FLASH_PLUGIN_PARENT_PID")
        .ok()
        .and_then(|raw| raw.parse::<i32>().ok())
        .filter(|pid| *pid > 1)
}

fn start_parent_liveness_watch() {
    let Some(parent_pid) = parent_pid_from_env() else {
        return;
    };
    let _ = std::thread::Builder::new()
        .name("flash-plugin-parent-watch".to_string())
        .spawn(move || {
            wait_for_parent_exit(parent_pid);
            std::process::exit(0);
        });
}

#[cfg(target_os = "macos")]
fn wait_for_parent_exit(parent_pid: i32) {
    unsafe {
        let kq = libc::kqueue();
        if kq == -1 {
            return;
        }
        let change = libc::kevent {
            ident: parent_pid as libc::uintptr_t,
            filter: libc::EVFILT_PROC as libc::c_short,
            flags: (libc::EV_ADD | libc::EV_ENABLE | libc::EV_CLEAR) as libc::c_ushort,
            fflags: libc::NOTE_EXIT as libc::c_uint,
            data: 0,
            udata: ptr::null_mut(),
        };
        let registered = libc::kevent(kq, &change, 1, ptr::null_mut(), 0, ptr::null());
        if registered == -1 {
            libc::close(kq);
            return;
        }
        loop {
            let mut event = libc::kevent {
                ident: 0,
                filter: 0,
                flags: 0,
                fflags: 0,
                data: 0,
                udata: ptr::null_mut(),
            };
            let rc = libc::kevent(kq, ptr::null(), 0, &mut event, 1, ptr::null());
            if rc > 0 {
                libc::close(kq);
                return;
            }
            if rc == -1 {
                let interrupted =
                    std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR);
                if !interrupted {
                    libc::close(kq);
                    return;
                }
            }
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn wait_for_parent_exit(_parent_pid: i32) {
    loop {
        std::thread::park();
    }
}

/// Run the plugin: spin up a bounded multi-thread tokio runtime and serve the
/// length-prefixed MessagePack protocol until `shutdown` or stdin closes. This
/// is the single entry point a plugin's `main` calls.
pub fn run<P: Plugin>(plugin: P) {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("flash-plugin: tokio runtime");
    runtime.block_on(serve(plugin));
}

/// Decode one typed request payload. Malformed input is a protocol error, never
/// an invitation to run the handler against a fabricated default value.
fn decode<T: DeserializeOwned>(params: Value, what: &str) -> Result<T, String> {
    serde_json::from_value::<T>(params).map_err(|error| format!("invalid {what} params: {error}"))
}

async fn reject_request(ctx: &Context, id: Value, error: String) {
    ctx.log(
        "warn",
        &format!("[plugin] rejected malformed request ({error})"),
    );
    ctx.emit
        .respond(id, json!({ "ok": false, "error": error }))
        .await;
}

fn validated_response_value(ctx: &Context, response: &Response) -> Value {
    if let Err(violation) = response.validate_boundary() {
        ctx.log_fields(
            "warn",
            "[plugin] rejected response at SDK boundary",
            violation.log_fields(),
        );
        return json!({
            "ok": false,
            "error": "plugin response rejected by SDK candidate limits",
        });
    }
    match response.to_value() {
        Ok(value) => value,
        Err(error) => {
            ctx.log(
                "warn",
                "[plugin] rejected response that could not be encoded",
            );
            json!({ "ok": false, "error": error })
        }
    }
}

async fn serve<P: Plugin>(plugin: P) {
    let plugin = Arc::new(plugin);
    let (control_tx, control_rx) = mpsc::channel::<Vec<u8>>(CONTROL_QUEUE_CAPACITY);
    let (telemetry_tx, telemetry_rx) = mpsc::channel::<Vec<u8>>(TELEMETRY_QUEUE_CAPACITY);
    let writer = tokio::spawn(async move {
        // 64 KiB buffer coalesces the 4-byte header and payload into one write
        // syscall per frame; we flush every frame to keep latency low.
        let mut out = BufWriter::with_capacity(64 * 1024, tokio::io::stdout());
        let mut outbound = OutboundReceiver::new(control_rx, telemetry_rx);
        while let Some(payload) = outbound.recv().await {
            let len = (payload.len() as u32).to_be_bytes();
            if out.write_all(&len).await.is_err() {
                break;
            }
            if out.write_all(&payload).await.is_err() {
                break;
            }
            let _ = out.flush().await;
        }
    });

    let host_pending: HostPending = Arc::new(Mutex::new(HashMap::new()));
    let host_counter = Arc::new(AtomicU64::new(0));
    let ctx = context_from_env(
        Emitter::new(control_tx, telemetry_tx),
        host_pending.clone(),
        host_counter,
    );
    ctx.prepare_dirs().await;
    start_parent_liveness_watch();
    ctx.log("info", "[plugin] process ready");

    let mut stdin = tokio::io::stdin();
    let mut len_buf = [0u8; 4];
    let mut started = false;
    let (startup_tx, startup_rx) = watch::channel(StartupState::Pending);
    let (event_tx, event_rx) = mpsc::channel::<QueuedEvent>(EVENT_QUEUE_CAPACITY);
    let event_worker = tokio::spawn(run_event_worker(
        plugin.clone(),
        ctx.clone(),
        event_rx,
        startup_rx.clone(),
        EVENT_HANDLER_TIMEOUT,
    ));
    loop {
        // Read the 4-byte big-endian length prefix. A clean EOF here means the
        // host closed our stdin; anything mid-frame is an unexpected EOF — both
        // end the serve loop and let the process exit.
        if stdin.read_exact(&mut len_buf).await.is_err() {
            break;
        }
        let len = u32::from_be_bytes(len_buf) as usize;
        if len == 0 {
            continue;
        }
        if len > MAX_FRAME_BYTES {
            ctx.log_fields(
                "warn",
                "[plugin] rejected oversized inbound frame",
                BTreeMap::from([
                    ("encoded_bytes".to_string(), len.to_string()),
                    ("limit_bytes".to_string(), MAX_FRAME_BYTES.to_string()),
                ]),
            );
            break;
        }
        let mut payload = vec![0u8; len];
        if stdin.read_exact(&mut payload).await.is_err() {
            break;
        }
        let request = match rmp_serde::from_slice::<Value>(&payload) {
            Ok(request) => request,
            Err(err) => {
                ctx.log(
                    "warn",
                    &format!("[plugin] dropped undecodable frame ({err})"),
                );
                continue;
            }
        };
        if !request.is_object() {
            continue;
        }
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let params = request.get("params").cloned().unwrap_or_else(|| json!({}));

        // A frame carrying an id but no method is the host's response to a
        // plugin-initiated `call_host`; route it to the waiting caller. (Host
        // *requests* always carry a method, so they fall through below.)
        if method.is_empty() {
            if let Some(req_id) = id.as_u64() {
                if let Some(tx) = host_pending
                    .lock()
                    .ok()
                    .and_then(|mut pending| pending.remove(&req_id))
                {
                    let result = request.get("result").cloned().unwrap_or(Value::Null);
                    let _ = tx.send(result);
                }
            }
            continue;
        }

        match method.as_str() {
            "initialize" => {
                if started {
                    ctx.emit
                        .respond(
                            id,
                            json!({
                                "ok": false,
                                "protocol_version": PROTOCOL_VERSION,
                                "error": "initialize may only be called once",
                            }),
                        )
                        .await;
                    continue;
                }
                let initialize = match serde_json::from_value::<InitializeRequest>(params) {
                    Ok(initialize) => initialize,
                    Err(err) => {
                        let _ = startup_tx.send(StartupState::Failed);
                        ctx.emit
                            .respond(
                                id,
                                json!({
                                    "ok": false,
                                    "protocol_version": PROTOCOL_VERSION,
                                    "error": format!("invalid initialize params: {err}"),
                                }),
                            )
                            .await;
                        continue;
                    }
                };
                if initialize.protocol_version != PROTOCOL_VERSION {
                    let _ = startup_tx.send(StartupState::Failed);
                    ctx.emit
                        .respond(
                            id,
                            json!({
                                "ok": false,
                                "protocol_version": PROTOCOL_VERSION,
                                "error": format!(
                                    "protocol_version mismatch: host v{}, plugin v{}",
                                    initialize.protocol_version, PROTOCOL_VERSION
                                ),
                            }),
                        )
                        .await;
                    continue;
                }
                started = true;
                ctx.set_running_applications(initialize.running_applications);
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                let startup_tx = startup_tx.clone();
                tokio::spawn(async move {
                    plugin.on_start(ctx.clone()).await;
                    let published_sources = ctx.published_location_source_ids();
                    let canonical_source = ctx.canonical_location_source_id();
                    if plugin.requires_initial_locations() && !ctx.has_locations(&canonical_source)
                    {
                        let error = format!(
                            "candidate plugin returned from on_start without set_locations({canonical_source:?}, ...)"
                        );
                        ctx.log("error", &error);
                        let _ = startup_tx.send(StartupState::Failed);
                        ctx.emit
                            .respond(
                                id,
                                json!({
                                    "ok": false,
                                    "protocol_version": PROTOCOL_VERSION,
                                    "error": error,
                                }),
                            )
                            .await;
                        return;
                    }
                    let _ = startup_tx.send(StartupState::Ready);
                    ctx.emit
                        .respond(
                            id,
                            json!({
                                "ok": true,
                                "protocol_version": PROTOCOL_VERSION,
                                "published_sources": published_sources,
                            }),
                        )
                        .await;
                });
            }
            "heartbeat" => ctx.emit.respond(id, json!({ "ok": true })).await,
            "shutdown" => {
                let reason = params
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .to_string();
                plugin.on_shutdown(ctx.clone(), reason).await;
                ctx.emit.respond(id, json!({ "ok": true })).await;
                break;
            }
            "event" => {
                let event = match Event::from_params(params) {
                    Ok(event) => event,
                    Err(error) => {
                        ctx.log(
                            "warn",
                            &format!("[plugin] rejected malformed event ({error})"),
                        );
                        ctx.emit
                            .respond(id, json!({ "ok": false, "error": error }))
                            .await;
                        continue;
                    }
                };
                let event_name = event.event.name.clone();
                match event_tx.try_send(event) {
                    Ok(()) => ctx.emit.respond(id, json!({ "ok": true })).await,
                    Err(mpsc::error::TrySendError::Full(_)) => {
                        ctx.log_fields(
                            "warn",
                            "[plugin] event queue full; dropped event",
                            BTreeMap::from([
                                ("event".to_string(), event_name),
                                ("capacity".to_string(), EVENT_QUEUE_CAPACITY.to_string()),
                            ]),
                        );
                        ctx.emit
                            .respond(
                                id,
                                json!({ "ok": false, "error": "plugin event queue full" }),
                            )
                            .await;
                    }
                    Err(mpsc::error::TrySendError::Closed(_)) => {
                        ctx.log_fields(
                            "warn",
                            "[plugin] dropped event after startup failure",
                            BTreeMap::from([("event".to_string(), event_name)]),
                        );
                        ctx.emit
                            .respond(
                                id,
                                json!({ "ok": false, "error": "plugin event worker stopped" }),
                            )
                            .await;
                    }
                }
            }
            "hints.activate" => {
                // Notification: dispatch through `handle`, never respond.
                let request = match decode(params, "hints.activate") {
                    Ok(request) => Request::ActivateTarget(request),
                    Err(error) => {
                        ctx.log(
                            "warn",
                            &format!("[plugin] dropped malformed hints.activate ({error})"),
                        );
                        continue;
                    }
                };
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                let startup_rx = startup_rx.clone();
                tokio::spawn(async move {
                    if startup_succeeded(startup_rx).await {
                        plugin.handle(ctx, request).await;
                    }
                });
            }
            "sources.snapshot" => {
                // Binding hot-path contract: clone the last complete atomically
                // published store immediately. Event/poll maintenance continues
                // independently and can only affect a later read.
                if !startup_is_ready(&startup_rx) {
                    ctx.emit
                        .respond(
                            id,
                            json!({ "ok": false, "error": "plugin startup incomplete" }),
                        )
                        .await;
                    continue;
                }
                let candidates = match ctx.validated_warm_locations() {
                    Ok(candidates) => candidates,
                    Err(violation) => {
                        ctx.log_fields(
                            "warn",
                            "[plugin] rejected catalog snapshot at SDK boundary",
                            violation.log_fields(),
                        );
                        ctx.emit
                            .respond(
                                id,
                                json!({
                                    "ok": false,
                                    "error": "plugin catalog rejected by SDK candidate limits",
                                }),
                            )
                            .await;
                        continue;
                    }
                };
                let result = serde_json::to_value(SourceSnapshotResponse::candidates(candidates))
                    .unwrap_or_else(|_| {
                        json!({
                            "ok": false,
                            "error": "plugin catalog response could not be encoded",
                        })
                    });
                ctx.emit.respond(id, result).await;
            }
            "query.evaluate" => {
                // Query evaluators may depend on immutable state established by
                // `on_start` (calculator exchange rates, local indexes, …). The
                // host only dispatches to ready/degraded processes, so this path
                // never waits for startup or lifecycle-event I/O.
                if !startup_is_ready(&startup_rx) {
                    ctx.emit
                        .respond(
                            id,
                            json!({ "ok": false, "error": "plugin startup incomplete" }),
                        )
                        .await;
                    continue;
                }
                let request = match decode(params, "query.evaluate") {
                    Ok(request) => Request::QueryEvaluate(request),
                    Err(error) => {
                        reject_request(&ctx, id, error).await;
                        continue;
                    }
                };
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                tokio::spawn(async move {
                    let evaluation_started_at = Instant::now();
                    let response = plugin.handle(ctx.clone(), request).await;
                    let evaluation_elapsed_ms = evaluation_started_at.elapsed().as_millis();
                    if evaluation_elapsed_ms > 10 {
                        ctx.log_fields(
                            "warn",
                            "[plugin] slow query evaluator",
                            BTreeMap::from([(
                                "elapsed_ms".to_string(),
                                evaluation_elapsed_ms.to_string(),
                            )]),
                        );
                    }
                    let result = validated_response_value(&ctx, &response);
                    ctx.emit.respond(id, result).await;
                });
            }
            other => {
                let request = match other {
                    "command.invoke" => decode(params, "command.invoke").map(Request::Command),
                    "hints.discover" => {
                        decode(params, "hints.discover").map(Request::DiscoverTargets)
                    }
                    "candidate.resolve" => params
                        .get("candidate")
                        .cloned()
                        .ok_or_else(|| {
                            "invalid candidate.resolve params: missing candidate".to_string()
                        })
                        .and_then(|candidate| decode(candidate, "candidate.resolve"))
                        .map(Request::ResolveCandidate),
                    "source.action" => decode(params, "source.action").map(Request::SourceAction),
                    "navigation.restore" => {
                        decode(params, "navigation.restore").map(Request::RestoreNavigation)
                    }
                    _ => Ok(Request::Unknown {
                        method: other.to_string(),
                    }),
                };
                let request = match request {
                    Ok(request) => request,
                    Err(error) => {
                        reject_request(&ctx, id, error).await;
                        continue;
                    }
                };
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                let startup_rx = startup_rx.clone();
                tokio::spawn(async move {
                    if !startup_succeeded(startup_rx).await {
                        ctx.emit
                            .respond(id, json!({ "ok": false, "error": "plugin startup failed" }))
                            .await;
                        return;
                    }
                    let response = plugin.handle(ctx.clone(), request).await;
                    let result = validated_response_value(&ctx, &response);
                    ctx.emit.respond(id, result).await;
                });
            }
        }
    }

    // The worker owns an emitter clone and may still be waiting for startup;
    // cancel it before draining stdout so process teardown cannot hang.
    event_worker.abort();
    let _ = event_worker.await;
    // Detached interval/background tasks may retain Context clones indefinitely.
    // Close their shared emitter explicitly, then drain queued frames (notably a
    // shutdown response) before the runtime drops and cancels those tasks.
    ctx.emit.close();
    drop(ctx);
    let _ = writer.await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::test_context;
    use crate::types::{Candidate, CommandRequest, SourceActionRequest};
    use tokio::sync::oneshot;

    #[test]
    fn malformed_events_are_rejected_instead_of_becoming_default_events() {
        assert!(Event::from_params(json!({ "payload": {} })).is_err());
        assert!(Event::from_params(json!({ "name": "", "payload": {} })).is_err());
        assert!(Event::from_params(json!({
            "name": "core:apps.changed",
            "payload": { "running_applications": "not-an-array" }
        }))
        .is_err());
    }

    #[test]
    fn malformed_request_params_are_rejected_without_default_fallback() {
        assert!(decode::<CommandRequest>(
            json!({ "command": "calc", "args": "not-an-array" }),
            "command.invoke"
        )
        .is_err());
        assert!(decode::<SourceActionRequest>(
            json!({ "name": "tab_select", "index": "not-an-integer" }),
            "source.action"
        )
        .is_err());
        assert!(decode::<Candidate>(json!({}), "candidate.resolve").is_err());
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
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
                let bundle = ctx
                    .running_applications()
                    .first()
                    .map(|app| app.bundle_id.clone())
                    .unwrap_or_default();
                ctx.set_locations(
                    "plugin:test",
                    vec![Candidate::new(format!("published:{marker}"))],
                );
                observations.lock().unwrap().push((marker, bundle));
            }
        }

        async fn handle(&self, _ctx: Context, _request: Request) -> Response {
            Response::None
        }
    }

    struct BlockingPublicationPlugin {
        started: Mutex<Option<oneshot::Sender<()>>>,
        release: Mutex<Option<oneshot::Receiver<()>>>,
    }

    impl Plugin for BlockingPublicationPlugin {
        fn on_event(&self, ctx: Context, event: Event) -> impl Future<Output = ()> + Send {
            let started = self.started.lock().unwrap().take();
            let release = self.release.lock().unwrap().take();
            async move {
                if let Some(started) = started {
                    let _ = started.send(());
                }
                if let Some(release) = release {
                    let _ = release.await;
                }
                ctx.set_locations(
                    "plugin:test",
                    vec![Candidate::new(
                        event.text.unwrap_or_else(|| "published".to_string()),
                    )],
                );
            }
        }

        async fn handle(&self, _ctx: Context, _request: Request) -> Response {
            Response::None
        }
    }

    struct TimeoutRecoveryPlugin {
        completed: Arc<Mutex<Vec<String>>>,
    }

    impl Plugin for TimeoutRecoveryPlugin {
        fn on_event(&self, _ctx: Context, event: Event) -> impl Future<Output = ()> + Send {
            let completed = self.completed.clone();
            async move {
                if event.text.as_deref() == Some("stuck") {
                    std::future::pending::<()>().await;
                }
                completed
                    .lock()
                    .unwrap()
                    .push(event.text.unwrap_or_default());
            }
        }

        async fn handle(&self, _ctx: Context, _request: Request) -> Response {
            Response::None
        }
    }

    #[tokio::test]
    async fn event_worker_waits_for_startup_and_applies_app_snapshots_in_wire_order() {
        let ctx = test_context();
        let observations = Arc::new(Mutex::new(Vec::new()));
        let plugin = Arc::new(RecordingPlugin {
            observations: observations.clone(),
        });
        let (event_tx, event_rx) = mpsc::channel(4);
        let (startup_tx, startup_rx) = watch::channel(StartupState::Pending);
        let worker = tokio::spawn(run_event_worker(
            plugin,
            ctx,
            event_rx,
            startup_rx,
            EVENT_HANDLER_TIMEOUT,
        ));

        for (marker, bundle) in [
            ("first", "com.example.First"),
            ("second", "com.example.Second"),
        ] {
            event_tx
                .send(QueuedEvent {
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
                    enqueued_at: Instant::now(),
                })
                .await
                .unwrap();
        }
        tokio::task::yield_now().await;
        assert!(observations.lock().unwrap().is_empty());

        startup_tx.send(StartupState::Ready).unwrap();
        drop(event_tx);
        worker.await.unwrap();

        assert_eq!(
            *observations.lock().unwrap(),
            vec![
                ("first".to_string(), "com.example.First".to_string()),
                ("second".to_string(), "com.example.Second".to_string()),
            ]
        );
    }

    #[tokio::test]
    async fn in_flight_event_refresh_does_not_block_atomic_warm_store_read() {
        let ctx = test_context();
        ctx.set_locations("plugin:test", vec![Candidate::new("old")]);
        let (started_tx, started_rx) = oneshot::channel();
        let (release_tx, release_rx) = oneshot::channel();
        let plugin = Arc::new(BlockingPublicationPlugin {
            started: Mutex::new(Some(started_tx)),
            release: Mutex::new(Some(release_rx)),
        });
        let (event_tx, event_rx) = mpsc::channel(1);
        let (_startup_tx, startup_rx) = watch::channel(StartupState::Ready);
        let worker = tokio::spawn(run_event_worker(
            plugin,
            ctx.clone(),
            event_rx,
            startup_rx,
            EVENT_HANDLER_TIMEOUT,
        ));

        event_tx
            .send(QueuedEvent {
                event: Event {
                    name: "core:focus.changed".to_string(),
                    text: Some("new".to_string()),
                    ..Event::default()
                },
                running_applications: Vec::new(),
                enqueued_at: Instant::now(),
            })
            .await
            .unwrap();
        started_rx.await.unwrap();

        // `sources.snapshot` is exactly this clone. Maintenance can be slow,
        // but gathering always receives one complete last-published vector.
        assert_eq!(ctx.warm_locations()[0].title, "old");

        release_tx.send(()).unwrap();
        drop(event_tx);
        worker.await.unwrap();
        assert_eq!(ctx.warm_locations()[0].title, "new");
    }

    #[tokio::test]
    async fn event_watchdog_cancels_a_stuck_handler_and_delivers_the_next_event() {
        let ctx = test_context();
        let completed = Arc::new(Mutex::new(Vec::new()));
        let plugin = Arc::new(TimeoutRecoveryPlugin {
            completed: completed.clone(),
        });
        let (event_tx, event_rx) = mpsc::channel(2);
        let (_startup_tx, startup_rx) = watch::channel(StartupState::Ready);
        let worker = tokio::spawn(run_event_worker(
            plugin,
            ctx,
            event_rx,
            startup_rx,
            Duration::from_millis(10),
        ));

        for marker in ["stuck", "next"] {
            event_tx
                .send(QueuedEvent {
                    event: Event {
                        name: "core:focus.changed".to_string(),
                        text: Some(marker.to_string()),
                        ..Event::default()
                    },
                    running_applications: Vec::new(),
                    enqueued_at: Instant::now(),
                })
                .await
                .unwrap();
        }
        drop(event_tx);
        worker.await.unwrap();

        assert_eq!(*completed.lock().unwrap(), vec!["next".to_string()]);
    }

    #[tokio::test]
    async fn bounded_event_queue_rejects_excess_work_without_waiting() {
        let (event_tx, _event_rx) = mpsc::channel(1);
        let event = || QueuedEvent {
            event: Event {
                name: "core:focus.changed".to_string(),
                ..Event::default()
            },
            running_applications: Vec::new(),
            enqueued_at: Instant::now(),
        };

        event_tx.try_send(event()).unwrap();
        assert!(matches!(
            event_tx.try_send(event()),
            Err(mpsc::error::TrySendError::Full(_))
        ));
    }

    #[tokio::test]
    async fn lifecycle_gate_waits_for_startup_readiness() {
        let (tx, rx) = watch::channel(StartupState::Pending);
        let waiter = tokio::spawn(startup_succeeded(rx));
        tokio::task::yield_now().await;
        assert!(!waiter.is_finished());

        tx.send(StartupState::Ready).unwrap();

        assert!(waiter.await.unwrap());
    }

    #[test]
    fn warm_request_readiness_check_is_immediate_and_requires_ready() {
        let (_pending_tx, pending_rx) = watch::channel(StartupState::Pending);
        let (_ready_tx, ready_rx) = watch::channel(StartupState::Ready);
        let (_failed_tx, failed_rx) = watch::channel(StartupState::Failed);

        assert!(!startup_is_ready(&pending_rx));
        assert!(startup_is_ready(&ready_rx));
        assert!(!startup_is_ready(&failed_rx));
    }

    #[tokio::test]
    async fn lifecycle_gate_unblocks_false_when_startup_fails() {
        let (tx, rx) = watch::channel(StartupState::Pending);
        let waiter = tokio::spawn(startup_succeeded(rx));

        tx.send(StartupState::Failed).unwrap();

        assert!(!waiter.await.unwrap());
    }
}
