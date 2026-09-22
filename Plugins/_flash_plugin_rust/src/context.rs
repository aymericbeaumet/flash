//! The per-process [`Context`] handed to every plugin callback: the
//! `publish`/`status`/`log` emitters, the typed host RPC client, config
//! accessors, interval timers, sandboxed data dirs — plus the audited
//! subprocess helpers [`run_command`] / [`run_osascript`].

use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use tokio::sync::{broadcast, oneshot};

use crate::emit::Emitter;
use crate::process::{self, ManagedChild, ManagedChildError};
use crate::status::{PreviewTooLarge, StatusSegment, StatusValue};
use crate::types::{Candidate, PerformResponse, RunningApplication};

/// Shared registry of in-flight plugin→host calls, keyed by the request id the
/// plugin assigned. The serve loop fulfils each entry when the matching host
/// response arrives and drains the registry at teardown so every waiter gets
/// the `host closed stdin` sentinel. Cloned into [`Context`] so any handler
/// can call the host.
pub(crate) type HostPending = Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>;

const COMMAND_STDOUT_LIMIT: usize = 4 * 1024 * 1024;
const COMMAND_STDERR_LIMIT: usize = 256 * 1024;
const DEFAULT_COMMAND_SLOW_THRESHOLD: Duration = Duration::from_secs(1);

/// Canonical `call_host` sentinels (pinned in `protocol.json`): `call_host`
/// never errors and never returns nil — host death and the call timeout
/// arrive as these result objects instead.
const HOST_CLOSED_ERROR: &str = "host closed stdin";
const HOST_TIMEOUT_ERROR: &str = "host call timed out";

/// Focused non-Flash app context returned by
/// [`Context::normal_mode_target`]. Mirrors the host-side notion of
/// "what the user is working on": pid for fast activation, bundle id as the
/// durable handle that survives a relaunch.
#[derive(Clone, Debug)]
pub struct NormalModeTarget {
    pub pid: i64,
    pub bundle_id: String,
    /// The frontmost window's WindowServer id, when it has one. Metadata
    /// only — it names a window without reading anything from it.
    pub window_id: Option<i64>,
}

/// Per-process runtime handed to every plugin callback. Holds identity, the
/// sandboxed data directory, and the wire emitter. Cheap to clone.
#[derive(Clone)]
pub struct Context {
    pub plugin_id: String,
    pub version: String,
    /// `None` when `FLASH_PLUGIN_DATA_DIR` is unset — dir accessors then fail
    /// loudly instead of quietly littering the current directory.
    data_dir: Option<PathBuf>,
    pub(crate) emit: Emitter,
    /// User-supplied settings from the `[plugin.<id>]` table of
    /// `~/.config/flash`, delivered as a JSON object (empty when unset).
    config: Value,
    host_pending: HostPending,
    host_counter: Arc<AtomicU64>,
    running_applications: Arc<Mutex<Vec<RunningApplication>>>,
    poll: Arc<PollRegistry>,
}

/// Cadences this plugin has asked the host to drive. Plugins never arm their
/// own timers: `interval` registers a period with the core, which folds every
/// registration in the app onto one clock and sends a `core:poll:<name>` event
/// when each is due. The broadcast fans those ticks out to the waiting tasks;
/// a receiver that lags because its callback is still running simply misses
/// ticks, which is the backpressure we want from an overrunning collector.
pub(crate) struct PollRegistry {
    intervals: Mutex<BTreeMap<String, f64>>,
    ticks: broadcast::Sender<String>,
    counter: AtomicU64,
}

/// A live cadence registration. Dropping it changes nothing — the callback
/// keeps running — but it lets a poller whose useful rate varies (a retry
/// backoff, an idle backend) move its own deadline instead of registering at
/// its fastest rate and discarding most ticks.
pub struct PollHandle {
    name: String,
    ctx: Context,
}

impl PollHandle {
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Re-register at a new cadence, effective from the host's next plan.
    pub fn set_period(&self, period: Duration) {
        self.ctx.repoll(&self.name, Some(period));
    }

    /// Stop the cadence. The callback stays alive but never ticks again.
    pub fn cancel(&self) {
        self.ctx.repoll(&self.name, None);
    }
}

impl PollRegistry {
    fn new() -> Self {
        Self {
            intervals: Mutex::new(BTreeMap::new()),
            ticks: broadcast::channel(64).0,
            counter: AtomicU64::new(0),
        }
    }

    /// Names are host-validated (`[a-z0-9_-]`), and the host carries them in
    /// the event name, so keep them boring and unique.
    fn register(&self, period: Duration) -> (String, BTreeMap<String, f64>) {
        let name = format!("i{}", self.counter.fetch_add(1, Ordering::Relaxed));
        let mut intervals = self.intervals.lock().expect("poll registry");
        intervals.insert(name.clone(), period.as_secs_f64());
        (name, intervals.clone())
    }
}

/// Serializes refresh producers and snapshots running applications only after
/// the gate is acquired. This prevents a delayed poll from publishing against
/// an app list captured before a newer `core:apps.changed` refresh.
#[derive(Clone, Default)]
pub struct RefreshGate {
    inner: Arc<tokio::sync::Mutex<()>>,
}

impl RefreshGate {
    pub async fn run<T, F, Fut>(&self, ctx: &Context, operation: F) -> T
    where
        F: FnOnce(Context, Vec<RunningApplication>) -> Fut,
        Fut: Future<Output = T>,
    {
        let _guard = self.inner.lock().await;
        let applications = ctx.running_applications();
        operation(ctx.clone(), applications).await
    }

    /// Run a refresh only when the gate is immediately available.
    ///
    /// Interactive requests should prefer this over queueing behind a slow
    /// background refresh: `None` lets them return cached state within their
    /// protocol deadline while the in-flight producer finishes normally.
    pub async fn try_run<T, F, Fut>(&self, ctx: &Context, operation: F) -> Option<T>
    where
        F: FnOnce(Context, Vec<RunningApplication>) -> Fut,
        Fut: Future<Output = T>,
    {
        let _guard = self.inner.try_lock().ok()?;
        let applications = ctx.running_applications();
        Some(operation(ctx.clone(), applications).await)
    }
}

impl Context {
    /// The plugin's sandboxed data directory (`FLASH_PLUGIN_DATA_DIR`).
    /// Panics when the variable is unset — running outside the host, export
    /// it explicitly rather than letting state litter a source tree.
    pub fn data_dir(&self) -> PathBuf {
        self.data_dir
            .clone()
            .expect("flash-plugin: FLASH_PLUGIN_DATA_DIR is not set (export it to run outside the Flash host)")
    }

    pub fn home_dir(&self) -> PathBuf {
        self.data_dir().join("home")
    }
    pub fn config_dir(&self) -> PathBuf {
        self.data_dir().join("config")
    }
    pub fn cache_dir(&self) -> PathBuf {
        self.data_dir().join("cache")
    }
    pub fn share_dir(&self) -> PathBuf {
        self.data_dir().join("share")
    }
    pub fn bin_dir(&self) -> PathBuf {
        self.data_dir().join("bin")
    }

    /// Read a string setting from the plugin's `[plugin.<id>]` config,
    /// defaulting to `""` when absent or not a string.
    pub fn config_str(&self, key: &str) -> String {
        self.config
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    }

    /// Decode a setting from the plugin's `[plugin.<id>]` config as `T`.
    pub fn config_json<T: DeserializeOwned>(&self, key: &str) -> Option<T> {
        serde_json::from_value(self.config.get(key)?.clone()).ok()
    }

    // -- Notifications ------------------------------------------------------

    /// Publish this plugin's complete catalog (the `publish` notification): a
    /// full replacement of every row across all of the plugin's sources, each
    /// row carrying its manifest `sources[].name` in
    /// [`Candidate::source`]. An empty vector is an authoritative empty. On a
    /// transient refresh failure simply don't publish — the host keeps the
    /// last-good catalog, across crashes and restarts. The host validates
    /// quotas at receipt and rejects a violating publish whole.
    pub fn publish(&self, rows: Vec<Candidate>) {
        self.emit.notify("publish", json!({ "rows": rows }));
    }

    /// Publish status-bar segment values declared by this plugin's
    /// `status` manifest section (the `status` notification). The host
    /// exposes each value as `#{flash.plugin.<plugin-id>.<segment>}` in
    /// `[statusbar].template`. Every value is a [`StatusValue`] (plain
    /// strings convert as ready-made markup); an EMPTY value clears the
    /// segment host-side. A preview that would exceed the host's inline
    /// limit is dropped with a content-free warning and the visible text is
    /// published alone.
    pub fn status<I, K, V>(&self, segments: I)
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<str>,
        V: Into<StatusSegment>,
    {
        let mut object = serde_json::Map::new();
        for (name, value) in segments {
            let name = name.as_ref().trim();
            if name.is_empty() {
                continue;
            }
            let wire = match value.into() {
                StatusSegment::Value(value) => json!(self.render_status_value(name, &value).trim()),
                StatusSegment::Carousel(carousel) => {
                    let lines: Vec<String> = carousel
                        .lines
                        .iter()
                        .map(|line| self.render_status_value(name, line).trim().to_string())
                        .filter(|line| !line.is_empty())
                        .collect();
                    json!({
                        "prefix": carousel.prefix.as_str(),
                        "lines": lines,
                        "cycle_seconds": carousel.cycle.as_secs_f64().max(1.0),
                    })
                }
            };
            object.insert(name.to_string(), wire);
        }
        self.emit.notify("status", json!({ "segments": object }));
    }

    /// The wire string for one value; a preview above the host's inline limit
    /// is dropped with a content-free warning so the visible text still lands.
    fn render_status_value(&self, name: &str, value: &StatusValue) -> String {
        match value.render() {
            Ok(rendered) => rendered,
            Err(PreviewTooLarge { encoded_bytes }) => {
                self.log_fields(
                    "warn",
                    "[plugin] status preview exceeds the inline limit; published without it",
                    BTreeMap::from([
                        ("segment".to_string(), name.to_string()),
                        ("encoded_bytes".to_string(), encoded_bytes.to_string()),
                    ]),
                );
                value.visible.as_str().to_string()
            }
        }
    }

    /// Structured, content-free logging (the `log` notification): counts,
    /// stages, elapsed ms, method names — never query text, candidate data,
    /// clipboard content, or config values.
    pub fn log(&self, level: &str, message: &str) {
        self.emit.log(level, message, BTreeMap::new());
    }

    pub fn log_fields(&self, level: &str, message: &str, fields: BTreeMap<String, String>) {
        self.emit.log(level, message, fields);
    }

    // -- Host RPC -----------------------------------------------------------

    /// Call a host RPC method and await its JSON result. This is the channel
    /// plugins use to reach native capabilities the core explicitly exposes.
    /// Never errors and never returns nil: host death and the 5 s default
    /// timeout arrive as `{"ok": false, "error": …}` sentinel objects.
    pub async fn call_host(&self, method: &str, params: Value) -> Value {
        self.call_host_timeout(method, params, Duration::from_secs(5))
            .await
    }

    pub async fn call_host_timeout(&self, method: &str, params: Value, timeout: Duration) -> Value {
        let started_at = Instant::now();
        let id = self.host_counter.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, rx) = oneshot::channel();
        if let Ok(mut pending) = self.host_pending.lock() {
            if pending.len() >= HOST_CALL_CAPACITY {
                return json!({ "ok": false, "error": "host call capacity exceeded" });
            }
            pending.insert(id, tx);
        }
        let _pending_call = PendingCall {
            pending: self.host_pending.clone(),
            id,
        };
        let outcome = tokio::time::timeout(timeout, async {
            self.emit.request(id, method, params).await?;
            rx.await.map_err(|_| crate::emit::EmitError::Closed)
        })
        .await;
        if !matches!(outcome, Ok(Ok(_))) {
            if let Ok(mut pending) = self.host_pending.lock() {
                pending.remove(&id);
            }
        }
        match outcome {
            Ok(Ok(value)) => value,
            // An outbound request above the frame cap is a plugin bug; the
            // free-form diagnostic stays content-free.
            Ok(Err(crate::emit::EmitError::Rejected)) => {
                json!({ "ok": false, "error": "host call exceeded outbound frame limit" })
            }
            Ok(Err(crate::emit::EmitError::Closed | crate::emit::EmitError::Full)) => {
                json!({ "ok": false, "error": HOST_CLOSED_ERROR })
            }
            Err(_) => {
                self.log_fields(
                    "warn",
                    "[plugin] host RPC timed out",
                    BTreeMap::from([
                        ("method".to_string(), method.to_string()),
                        (
                            "elapsed_ms".to_string(),
                            started_at.elapsed().as_millis().to_string(),
                        ),
                        ("timeout_ms".to_string(), timeout.as_millis().to_string()),
                    ]),
                );
                json!({ "ok": false, "error": HOST_TIMEOUT_ERROR })
            }
        }
    }

    /// Fulfil the in-flight host call `id` with the host's `result`; `false`
    /// when no call awaits that id (late and unsolicited replies are dropped).
    pub(crate) fn resolve_host_call(&self, id: u64, result: Value) -> bool {
        self.host_pending
            .lock()
            .ok()
            .and_then(|mut pending| pending.remove(&id))
            .is_some_and(|tx| tx.send(result).is_ok())
    }

    /// Drop every in-flight host call so each waiter observes the closed
    /// sentinel (a dropped sender resolves its receiver as an error).
    pub(crate) fn abandon_host_calls(&self) {
        if let Ok(mut pending) = self.host_pending.lock() {
            pending.clear();
        }
    }

    // -- Typed host RPC wrappers (one per registry method) ------------------

    /// Probe host liveness (`host.ping`).
    pub async fn ping_host(&self) -> bool {
        ok(&self.call_host("host.ping", json!({})).await)
    }

    /// Read the currently associated Wi-Fi network name from the host
    /// (`host.wifi_info`). Pass `true` only from an explicit user action that
    /// may show the Location authorization prompt; passive refreshes pass
    /// `false` and resolve absent immediately while authorization is
    /// undetermined. An explicit request also replies absent immediately after
    /// asking, so callers retry after the user grants access rather than
    /// retaining an RPC behind an open-ended system prompt. Requires the
    /// `wifi_info` capability. `None` also covers denied authorization, no
    /// association, malformed replies, and host-RPC failure.
    pub async fn wifi_ssid(&self, request_authorization: bool) -> Option<String> {
        let response = self
            .call_host(
                "host.wifi_info",
                json!({ "request_authorization": request_authorization }),
            )
            .await;
        wifi_ssid_from_response(&response)
    }

    /// Fetch an allowlisted HTTPS URL through the host (`host.fetch`). The
    /// host enforces the manifest's `fetch_urls` prefixes, an 8-second
    /// timeout, and a 1 MiB UTF-8 response cap — the plugin itself needs no
    /// network access (declare the `network_fetch` capability instead of
    /// `network` and keep a fully network-denied sandbox).
    pub async fn fetch(&self, url: &str) -> Result<String, String> {
        let response = self
            .call_host_timeout("host.fetch", json!({ "url": url }), Duration::from_secs(10))
            .await;
        if !ok(&response) {
            let error = response
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("host.fetch failed");
            return Err(error.to_string());
        }
        match response.get("body").and_then(Value::as_str) {
            Some(body) => Ok(body.to_string()),
            None => Err("host.fetch response missing body".to_string()),
        }
    }

    /// Query the host for the focused non-Flash app context — the same value
    /// the host treats as the "normal-mode target" (`host.normal_mode_target`).
    /// Returns `None` when no such app is focused. The `core:focus.changed`
    /// stream is insufficient because Flash itself is the focused process
    /// while normal mode is active.
    pub async fn normal_mode_target(&self) -> Option<NormalModeTarget> {
        let result = self.call_host("host.normal_mode_target", json!({})).await;
        if !result
            .get("present")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            return None;
        }
        let pid = result.get("pid").and_then(Value::as_i64).unwrap_or(0);
        let bundle_id = result
            .get("bundle_id")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if pid <= 0 || bundle_id.is_empty() {
            return None;
        }
        Some(NormalModeTarget {
            pid,
            bundle_id,
            window_id: result
                .get("window_id")
                .and_then(Value::as_i64)
                .filter(|id| *id > 0),
        })
    }

    /// Activate (raise) the app owning `pid` (`host.activate`). Requires the
    /// `app_control` capability.
    pub async fn activate(&self, pid: i64) -> bool {
        ok(&self.call_host("host.activate", json!({ "pid": pid })).await)
    }

    /// Open a URL through the host (`host.open`): LaunchServices runs
    /// host-side, so the plugin keeps a fork-free profile. Requires the
    /// `open` capability.
    pub async fn open_url(&self, url: &str) -> bool {
        ok(&self.call_host("host.open", json!({ "url": url })).await)
    }

    /// Launch or raise an app by bundle id through the host (`host.open`).
    /// Requires the `open` capability.
    pub async fn open_app(&self, bundle_id: &str) -> bool {
        ok(&self
            .call_host("host.open", json!({ "bundle_id": bundle_id }))
            .await)
    }

    /// Post an NX_SYSTEM_DEFINED media key host-side (`host.post_media_key`).
    /// Requires the `media_keys` capability.
    pub async fn post_media_key(&self, key_code: i64) -> bool {
        ok(&self
            .call_host("host.post_media_key", json!({ "key_code": key_code }))
            .await)
    }

    /// Read the host's process table (`host.process_table`), optionally
    /// sampling CPU over `sample_window_ms`. Returns the raw result object
    /// (rows under `"processes"`). Requires the `process_control` capability.
    pub async fn process_table(&self, sample_window_ms: Option<u64>) -> Value {
        let mut params = json!({});
        if let Some(window) = sample_window_ms {
            params["sample_window_ms"] = json!(window);
        }
        self.call_host("host.process_table", params).await
    }

    /// Sample one process through `host.process_table`. Exact-PID mode also
    /// includes resident bytes, lifetime disk I/O, uptime, thread count, and
    /// the open socket descriptor count across the process tree. CPU is the
    /// delta since the host's previous sample of that pid, so steady polling
    /// never sleeps host-side. Requires the `process_control` capability.
    pub async fn process_metrics(&self, pid: i64, sample_window_ms: Option<u64>) -> Value {
        let mut params = json!({ "pid": pid });
        if let Some(window) = sample_window_ms {
            params["sample_window_ms"] = json!(window);
        }
        self.call_host("host.process_table", params).await
    }

    /// SIGTERM `pid` host-side (`host.signal`). Requires the
    /// `process_control` capability.
    pub async fn signal(&self, pid: i64) -> Result<(), String> {
        let response = self.call_host("host.signal", json!({ "pid": pid })).await;
        if ok(&response) {
            return Ok(());
        }
        Err(response
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("host.signal failed")
            .to_string())
    }

    /// Replace the system clipboard through the host (`host.clipboard_write`).
    /// Requires the `clipboard` capability.
    pub async fn clipboard_write(&self, text: &str) -> bool {
        ok(&self
            .call_host("host.clipboard_write", json!({ "text": text }))
            .await)
    }

    /// Show a transient host banner (`host.notify`). Requires the `notify`
    /// capability; the host rate-limits to one banner per plugin per second.
    pub async fn notify(&self, message: &str, duration_ms: Option<u64>) -> bool {
        let mut params = json!({ "message": message });
        if let Some(duration_ms) = duration_ms {
            params["duration_ms"] = json!(duration_ms);
        }
        ok(&self.call_host("host.notify", params).await)
    }

    /// Read one key from the host-managed KV store in the plugin's data dir
    /// (`host.storage_get`). No capability required.
    pub async fn storage_get(&self, key: &str) -> Option<String> {
        let response = self
            .call_host("host.storage_get", json!({ "key": key }))
            .await;
        if !ok(&response) {
            return None;
        }
        response
            .get("value")
            .and_then(Value::as_str)
            .map(str::to_string)
    }

    /// Write (or, with `None`, delete) one key in the host-managed KV store
    /// (`host.storage_set`). Values are capped at 64 KiB, tables at 256 keys.
    pub async fn storage_set(&self, key: &str, value: Option<&str>) -> bool {
        ok(&self
            .call_host("host.storage_set", json!({ "key": key, "value": value }))
            .await)
    }

    /// Post a keystroke plan to a target app (`host.post_keys`), e.g.
    /// `{"pid": …, "keys": [{"key_code": …, "modifiers": […]}], "interval_ms": …}`.
    /// Requires the `accessibility` capability.
    pub async fn post_keys(&self, params: Value) -> bool {
        ok(&self.call_host("host.post_keys", params).await)
    }

    /// Post one modified chord through the host's session event stream for
    /// macOS-owned shortcuts (`host.post_global_key`). Returns the raw result
    /// object. Requires the `accessibility` capability.
    pub async fn post_global_key(&self, key_code: i64, modifiers: &[&str]) -> Value {
        self.call_host(
            "host.post_global_key",
            json!({ "key_code": key_code, "modifiers": modifiers }),
        )
        .await
    }

    /// BFS-walk an app's AX subtree through the host broker
    /// (`host.ax_snapshot`); nodes come back flat with opaque handles,
    /// geometry in NSScreen coordinates. Returns the raw result object.
    /// Requires the `accessibility` capability.
    pub async fn ax_snapshot(&self, params: Value) -> Value {
        self.call_host("host.ax_snapshot", params).await
    }

    /// [`ax_snapshot`](Context::ax_snapshot) with an explicit deadline for
    /// hint-discovery paths tighter than the 5 s default.
    pub async fn ax_snapshot_timeout(&self, params: Value, timeout: Duration) -> Value {
        self.call_host_timeout("host.ax_snapshot", params, timeout)
            .await
    }

    /// Perform an AX action on a broker handle (`host.ax_perform`). Requires
    /// the `accessibility` capability.
    pub async fn ax_perform(&self, handle: u64, action: &str) -> bool {
        ok(&self
            .call_host(
                "host.ax_perform",
                json!({ "handle": handle, "action": action }),
            )
            .await)
    }

    /// Set a boolean AX attribute on a broker handle (`host.ax_set`).
    /// Requires the `accessibility` capability.
    pub async fn ax_set(&self, handle: u64, attribute: &str, value: bool) -> bool {
        ok(&self
            .call_host(
                "host.ax_set",
                json!({ "handle": handle, "attribute": attribute, "value": value }),
            )
            .await)
    }

    /// Select `child` within `parent` through the AX broker
    /// (`host.ax_select_child`). Requires the `accessibility` capability.
    pub async fn ax_select_child(&self, parent: u64, child: u64) -> bool {
        ok(&self
            .call_host(
                "host.ax_select_child",
                json!({ "parent": parent, "child": child }),
            )
            .await)
    }

    // -- Runtime state ------------------------------------------------------

    pub(crate) fn set_running_applications(&self, applications: Vec<RunningApplication>) {
        if let Ok(mut current) = self.running_applications.lock() {
            *current = applications;
        }
    }

    /// Current host-owned running-app snapshot, fed by `core:apps.changed`
    /// events (the host delivers the first one right after initialize) and
    /// replaced atomically before that ordered event reaches plugin code.
    pub fn running_applications(&self) -> Vec<RunningApplication> {
        self.running_applications
            .lock()
            .map(|applications| applications.clone())
            .unwrap_or_default()
    }

    /// Run one background refresh at a fixed cadence.
    ///
    /// This does **not** arm a timer in the plugin. It registers `period` with
    /// the host, which drives every poller in Flash — core watchers included —
    /// from a single clock, and ticks this callback when the registration is
    /// due. The first tick waits for `period`; callers perform their
    /// authoritative initial refresh in `on_start`. The callback is awaited
    /// before the next tick is accepted, so one cadence can never overlap
    /// itself; ticks that arrive meanwhile are dropped rather than queued.
    ///
    /// Reach for this only when nothing else can tell you the value changed.
    /// An event (`on_event`) is always preferable, and the host exposes one
    /// for every source it can observe.
    pub fn interval<F, Fut>(&self, period: Duration, mut callback: F) -> PollHandle
    where
        F: FnMut(Context) -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let (name, intervals) = self.poll.register(period);
        self.emit.notify("poll", json!({ "intervals": intervals }));
        let mut ticks = self.poll.ticks.subscribe();
        let ctx = self.clone();
        let handle = PollHandle {
            name: name.clone(),
            ctx: self.clone(),
        };
        drop(tokio::spawn(async move {
            loop {
                match ticks.recv().await {
                    Ok(fired) if fired == name => {
                        callback(ctx.clone()).await;
                        // The host cannot see that this callback was still
                        // running — a tick is a one-way frame — so the skip
                        // happens here: anything that arrived while it ran is
                        // a stale deadline, and running the collector
                        // back-to-back to catch up is exactly the pile-up a
                        // shared clock exists to prevent.
                        while ticks.try_recv().is_ok() {}
                    }
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }));
        handle
    }

    /// Fan a host tick out to the tasks waiting on that registration.
    pub(crate) fn deliver_poll_tick(&self, name: &str) {
        drop(self.poll.ticks.send(name.to_string()));
    }

    /// Replace or remove one registration and republish the complete set, so
    /// the host's view is always the plugin's whole answer rather than a diff
    /// it has to reconcile.
    fn repoll(&self, name: &str, period: Option<Duration>) {
        let intervals = {
            let mut intervals = self.poll.intervals.lock().expect("poll registry");
            match period {
                Some(period) => {
                    intervals.insert(name.to_string(), period.as_secs_f64());
                }
                None => {
                    intervals.remove(name);
                }
            }
            intervals.clone()
        };
        self.emit.notify("poll", json!({ "intervals": intervals }));
    }

    pub(crate) async fn prepare_dirs(&self) {
        if self.data_dir.is_none() {
            return;
        }
        for dir in [
            self.home_dir(),
            self.config_dir(),
            self.cache_dir(),
            self.share_dir(),
            self.bin_dir(),
        ] {
            let _ = tokio::fs::create_dir_all(dir).await;
        }
    }
}

/// Aborting a request handler also releases its host correlation entry.
struct PendingCall {
    pending: HostPending,
    id: u64,
}

pub(crate) const HOST_CALL_CAPACITY: usize = 64;

impl Drop for PendingCall {
    fn drop(&mut self) {
        if let Ok(mut pending) = self.pending.lock() {
            pending.remove(&self.id);
        }
    }
}

fn ok(response: &Value) -> bool {
    response.get("ok").and_then(Value::as_bool) == Some(true)
}

fn wifi_ssid_from_response(response: &Value) -> Option<String> {
    if !ok(response) || response.get("present").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    response
        .get("ssid")
        .and_then(Value::as_str)
        .filter(|ssid| !ssid.trim().is_empty())
        .map(str::to_string)
}

/// The identity, data directory and settings Flash injects through the
/// `FLASH_PLUGIN_*` environment.
pub(crate) struct PluginEnv {
    pub(crate) plugin_id: String,
    pub(crate) version: String,
    pub(crate) data_dir: Option<PathBuf>,
    pub(crate) config: Value,
}

impl PluginEnv {
    pub(crate) fn from_process() -> Self {
        let env_or = |name: &str, fallback: &str| {
            std::env::var(name).unwrap_or_else(|_| fallback.to_string())
        };
        Self {
            plugin_id: env_or("FLASH_PLUGIN_ID", "plugin"),
            version: env_or("FLASH_PLUGIN_VERSION", "0.0.0"),
            data_dir: std::env::var("FLASH_PLUGIN_DATA_DIR")
                .ok()
                .filter(|value| !value.trim().is_empty())
                .map(PathBuf::from),
            config: parse_config(std::env::var("FLASH_PLUGIN_CONFIG").ok().as_deref()),
        }
    }
}

/// `FLASH_PLUGIN_CONFIG` carries the `[plugin.<id>]` settings as a JSON
/// object. Configuration is optional at the protocol level, so an absent,
/// empty, malformed or non-object value is an empty table — never a refusal
/// to start.
pub(crate) fn parse_config(raw: Option<&str>) -> Value {
    raw.and_then(|raw| serde_json::from_str::<Value>(raw).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}))
}

// ---------------------------------------------------------------------------
// Subprocess helpers
// ---------------------------------------------------------------------------

/// The result of running a subprocess via `run_command` / `run_osascript`:
/// exit success plus captured stdout/stderr. `into_perform` folds it into a
/// `PerformResponse` (trimmed + length-capped). This lives in the SDK so the
/// subprocess sandbox policy has exactly one audited home instead of being
/// copy-pasted into every plugin.
#[derive(Default)]
pub struct CommandOutput {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
    pub status: i32,
}

impl CommandOutput {
    pub fn into_perform(self) -> PerformResponse {
        if self.ok {
            let mut response = PerformResponse::ok();
            if !self.stdout.trim().is_empty() {
                response = response.message(shorten(&self.stdout));
            }
            response
        } else if self.stderr.trim().is_empty() {
            PerformResponse::fail(format!("command exited with status {}", self.status))
        } else {
            PerformResponse::fail(shorten(&self.stderr))
        }
    }
}

/// Run `osascript -e <script>` with the same sandboxed env + timeout as
/// `run_command`.
pub async fn run_osascript(ctx: &Context, script: &str, timeout: Duration) -> CommandOutput {
    run_command(
        ctx,
        &[
            "/usr/bin/osascript".to_string(),
            "-e".to_string(),
            script.to_string(),
        ],
        timeout,
    )
    .await
}

/// Run a subprocess with Flash's plugin sandbox environment: the plugin data
/// dir as cwd, `HOME`/`XDG_*` pointed at the plugin's own dirs, the plugin bin
/// dir prepended to `PATH`, no stdin, piped stdout/stderr, `kill_on_drop`, and a
/// hard timeout. The single audited home for how a plugin shells out.
pub async fn run_command(ctx: &Context, argv: &[String], timeout: Duration) -> CommandOutput {
    run_command_with_slow_threshold(ctx, argv, timeout, DEFAULT_COMMAND_SLOW_THRESHOLD).await
}

/// Run a subprocess while treating only durations at or above `slow_threshold`
/// as unexpectedly slow. Use this for commands whose documented operation
/// deliberately includes a sampling delay; timeouts are always warned.
pub async fn run_command_with_slow_threshold(
    ctx: &Context,
    argv: &[String],
    timeout: Duration,
    slow_threshold: Duration,
) -> CommandOutput {
    let started_at = Instant::now();
    let Some((program, args)) = argv.split_first() else {
        let output = CommandOutput {
            ok: false,
            stderr: "empty argv".to_string(),
            status: -1,
            ..Default::default()
        };
        log_command_latency(
            ctx,
            "<empty>",
            &output,
            started_at.elapsed(),
            timeout,
            slow_threshold,
        );
        return output;
    };
    let executable = Path::new(program)
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("<unknown>");
    let mut command = tokio::process::Command::new(program);
    command.args(args);
    configure_command(ctx, &mut command);
    let output = match process::capture(
        &mut command,
        None,
        timeout,
        COMMAND_STDOUT_LIMIT,
        COMMAND_STDERR_LIMIT,
    )
    .await
    {
        Ok(output) => CommandOutput {
            ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            status: output.status.code().unwrap_or(-1),
        },
        Err(error) => {
            let diagnostic = error.diagnostic();
            ctx.log_fields(
                "warn",
                "[plugin] subprocess capture failed",
                BTreeMap::from([
                    ("executable".to_string(), executable.to_string()),
                    ("diagnostic".to_string(), diagnostic.clone()),
                    (
                        "elapsed_ms".to_string(),
                        started_at.elapsed().as_millis().to_string(),
                    ),
                ]),
            );
            CommandOutput {
                ok: false,
                stderr: diagnostic,
                status: error.status(),
                ..Default::default()
            }
        }
    };
    log_command_latency(
        ctx,
        executable,
        &output,
        started_at.elapsed(),
        timeout,
        slow_threshold,
    );
    output
}

/// Spawn a long-lived subprocess with the same scrubbed directories and PATH
/// as [`run_command`]. The child has null stdio and a dedicated process group;
/// callers own its complete replacement and shutdown lifecycle through
/// [`ManagedChild`].
pub fn spawn_managed(ctx: &Context, argv: &[String]) -> Result<ManagedChild, ManagedChildError> {
    let Some((program, args)) = argv.split_first() else {
        return Err(ManagedChildError::EmptyArgv);
    };
    let mut command = tokio::process::Command::new(program);
    command.args(args);
    configure_command(ctx, &mut command);
    ManagedChild::spawn(&mut command)
}

fn configure_command(ctx: &Context, command: &mut tokio::process::Command) {
    command
        .current_dir(ctx.data_dir())
        .env("HOME", ctx.home_dir())
        .env("XDG_CONFIG_HOME", ctx.config_dir())
        .env("XDG_CACHE_HOME", ctx.cache_dir())
        .env("XDG_DATA_HOME", ctx.share_dir())
        .env(
            "PATH",
            format!(
                "{}:{}",
                ctx.bin_dir().display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        );
}

fn command_latency_requires_warning(
    output: &CommandOutput,
    elapsed: Duration,
    slow_threshold: Duration,
) -> bool {
    output.status == 124 || elapsed >= slow_threshold
}

fn log_command_latency(
    ctx: &Context,
    executable: &str,
    output: &CommandOutput,
    elapsed: Duration,
    timeout: Duration,
    slow_threshold: Duration,
) {
    if !command_latency_requires_warning(output, elapsed, slow_threshold) {
        return;
    }
    ctx.log_fields(
        "warn",
        "[plugin] subprocess slow",
        BTreeMap::from([
            ("executable".to_string(), executable.to_string()),
            ("elapsed_ms".to_string(), elapsed.as_millis().to_string()),
            ("timeout_ms".to_string(), timeout.as_millis().to_string()),
            ("status".to_string(), output.status.to_string()),
        ]),
    );
}

/// Wrap `value` as an AppleScript string literal (escaping `\` and `"`).
pub fn applescript_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// Trim + cap a string for a toast / diagnostic (2000 chars, `...` suffix).
pub fn shorten(value: &str) -> String {
    const LIMIT: usize = 2000;
    let trimmed = value.trim();
    if trimmed.chars().count() <= LIMIT {
        return trimmed.to_string();
    }
    let head: String = trimmed.chars().take(LIMIT - 3).collect();
    format!("{head}...")
}

/// Assemble a [`Context`] with fresh host-RPC state. The runtime feeds it the
/// process environment; the [`crate::testing`] harnesses feed it a synthetic
/// one.
pub(crate) fn assemble_context(env: PluginEnv, emit: Emitter) -> Context {
    Context {
        plugin_id: env.plugin_id,
        version: env.version,
        data_dir: env.data_dir,
        emit,
        config: env.config,
        host_pending: Arc::new(Mutex::new(HashMap::new())),
        host_counter: Arc::new(AtomicU64::new(0)),
        running_applications: Arc::new(Mutex::new(Vec::new())),
        poll: Arc::new(PollRegistry::new()),
    }
}

#[cfg(test)]
pub(crate) fn test_context_with_rx() -> (
    Context,
    tokio::sync::mpsc::Receiver<crate::emit::OutboundFrame>,
) {
    let (tx, rx) = tokio::sync::mpsc::channel(16);
    let env = PluginEnv {
        plugin_id: "test".to_string(),
        version: "0.0.0".to_string(),
        data_dir: Some(PathBuf::from(".")),
        config: json!({}),
    };
    (assemble_context(env, Emitter::new(tx)), rx)
}

#[cfg(test)]
pub(crate) fn test_context() -> Context {
    test_context_with_rx().0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn host_call_admission_is_bounded_and_abort_releases_pending_entries() {
        let (ctx, _rx) = test_context_with_rx();
        let mut calls = tokio::task::JoinSet::new();
        for _ in 0..HOST_CALL_CAPACITY {
            let ctx = ctx.clone();
            calls.spawn(async move {
                ctx.call_host_timeout("host.ping", json!({}), Duration::from_secs(60))
                    .await
            });
        }
        tokio::time::timeout(Duration::from_secs(2), async {
            while ctx.host_pending.lock().unwrap().len() != HOST_CALL_CAPACITY {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(
            ctx.call_host("host.ping", json!({})).await["error"],
            "host call capacity exceeded"
        );
        calls.abort_all();
        while calls.join_next().await.is_some() {}
        assert!(ctx.host_pending.lock().unwrap().is_empty());
    }

    #[test]
    fn running_applications_snapshot_is_clone_isolated() {
        let ctx = test_context();
        ctx.set_running_applications(vec![RunningApplication {
            bundle_id: "com.example.App".to_string(),
            pid: 42,
            localized_name: "Example".to_string(),
        }]);

        let mut first_read = ctx.running_applications();
        first_read.clear();
        let second_read = ctx.running_applications();

        assert_eq!(second_read.len(), 1);
        assert_eq!(second_read[0].bundle_id, "com.example.App");
        assert_eq!(second_read[0].pid, 42);
    }

    #[tokio::test]
    async fn call_host_returns_the_closed_sentinel_when_the_writer_is_gone() {
        let ctx = test_context();
        ctx.emit.close();

        let result = ctx.call_host("host.ping", json!({})).await;

        assert_eq!(result["ok"], json!(false));
        assert_eq!(result["error"], json!(HOST_CLOSED_ERROR));
    }

    #[tokio::test]
    async fn call_host_returns_the_timeout_sentinel_when_no_reply_arrives() {
        // Keep the outbound receiver alive so the request is written and the
        // failure is genuinely the missing reply, not a closed channel.
        let (ctx, _rx) = test_context_with_rx();

        let result = ctx
            .call_host_timeout("host.ping", json!({}), Duration::from_millis(10))
            .await;

        assert_eq!(result["error"], json!(HOST_TIMEOUT_ERROR));
        assert!(ctx.host_pending.lock().unwrap().is_empty());
    }

    #[test]
    fn config_parses_to_the_settings_object_or_an_empty_table() {
        assert_eq!(
            parse_config(Some(r#"{"greeting":"hi","n":3}"#)),
            json!({ "greeting": "hi", "n": 3 })
        );
        for raw in [
            None,
            Some(""),
            Some("{}"),
            Some("{not json"),
            Some("[1]"),
            Some("\"x\""),
        ] {
            assert_eq!(parse_config(raw), json!({}), "{raw:?}");
        }
    }

    #[tokio::test]
    async fn typed_host_wrappers_emit_their_registry_method_and_pinned_params() {
        use crate::testing::Harness;
        use std::pin::Pin;

        type Call = Box<dyn FnOnce(Context) -> Pin<Box<dyn Future<Output = Value> + Send>>>;
        macro_rules! call {
            (|$ctx:ident| $body:expr) => {
                Box::new(
                    |$ctx: Context| -> Pin<Box<dyn Future<Output = Value> + Send>> {
                        Box::pin(async move { json!($body) })
                    },
                ) as Call
            };
        }
        // One permissive reply satisfies every wrapper's result decoder.
        let host_reply = json!({
            "ok": true, "present": true, "ssid": "Atelier", "body": "b",
            "pid": 7, "bundle_id": "com.example.App", "value": "v"
        });
        let table: Vec<(&str, Value, Call, Value)> = vec![
            (
                "host.ping",
                json!({}),
                call!(|ctx| ctx.ping_host().await),
                json!(true),
            ),
            (
                "host.wifi_info",
                json!({ "request_authorization": false }),
                call!(|ctx| ctx.wifi_ssid(false).await),
                json!("Atelier"),
            ),
            (
                "host.wifi_info",
                json!({ "request_authorization": true }),
                call!(|ctx| ctx.wifi_ssid(true).await),
                json!("Atelier"),
            ),
            (
                "host.fetch",
                json!({ "url": "https://example.com/x" }),
                call!(|ctx| ctx.fetch("https://example.com/x").await.unwrap()),
                json!("b"),
            ),
            (
                "host.normal_mode_target",
                json!({}),
                call!(|ctx| ctx
                    .normal_mode_target()
                    .await
                    .map(|target| (target.pid, target.bundle_id))),
                json!([7, "com.example.App"]),
            ),
            (
                "host.activate",
                json!({ "pid": 7 }),
                call!(|ctx| ctx.activate(7).await),
                json!(true),
            ),
            (
                "host.open",
                json!({ "url": "https://example.com/x" }),
                call!(|ctx| ctx.open_url("https://example.com/x").await),
                json!(true),
            ),
            (
                "host.open",
                json!({ "bundle_id": "com.example.App" }),
                call!(|ctx| ctx.open_app("com.example.App").await),
                json!(true),
            ),
            (
                "host.post_media_key",
                json!({ "key_code": 16 }),
                call!(|ctx| ctx.post_media_key(16).await),
                json!(true),
            ),
            (
                "host.process_table",
                json!({ "sample_window_ms": 150 }),
                call!(|ctx| ctx.process_table(Some(150)).await["ok"].clone()),
                json!(true),
            ),
            (
                "host.process_table",
                json!({ "pid": 7 }),
                call!(|ctx| ctx.process_metrics(7, None).await["ok"].clone()),
                json!(true),
            ),
            (
                "host.signal",
                json!({ "pid": 7 }),
                call!(|ctx| ctx.signal(7).await.is_ok()),
                json!(true),
            ),
            (
                "host.clipboard_write",
                json!({ "text": "copy" }),
                call!(|ctx| ctx.clipboard_write("copy").await),
                json!(true),
            ),
            (
                "host.notify",
                json!({ "message": "hi", "duration_ms": 900 }),
                call!(|ctx| ctx.notify("hi", Some(900)).await),
                json!(true),
            ),
            (
                "host.storage_get",
                json!({ "key": "k" }),
                call!(|ctx| ctx.storage_get("k").await),
                json!("v"),
            ),
            (
                "host.storage_set",
                json!({ "key": "k", "value": null }),
                call!(|ctx| ctx.storage_set("k", None).await),
                json!(true),
            ),
            (
                "host.post_keys",
                json!({ "pid": 7, "keys": [] }),
                call!(|ctx| ctx.post_keys(json!({ "pid": 7, "keys": [] })).await),
                json!(true),
            ),
            (
                "host.post_global_key",
                json!({ "key_code": 4, "modifiers": ["command"] }),
                call!(|ctx| ctx.post_global_key(4, &["command"]).await["ok"].clone()),
                json!(true),
            ),
            (
                "host.ax_snapshot",
                json!({ "pid": 7 }),
                call!(|ctx| ctx.ax_snapshot(json!({ "pid": 7 })).await["ok"].clone()),
                json!(true),
            ),
            (
                "host.ax_snapshot",
                json!({ "pid": 8 }),
                call!(|ctx| ctx
                    .ax_snapshot_timeout(json!({ "pid": 8 }), Duration::from_secs(1))
                    .await["ok"]
                    .clone()),
                json!(true),
            ),
            (
                "host.ax_perform",
                json!({ "handle": 3, "action": "AXPress" }),
                call!(|ctx| ctx.ax_perform(3, "AXPress").await),
                json!(true),
            ),
            (
                "host.ax_set",
                json!({ "handle": 3, "attribute": "AXFocused", "value": true }),
                call!(|ctx| ctx.ax_set(3, "AXFocused", true).await),
                json!(true),
            ),
            (
                "host.ax_select_child",
                json!({ "parent": 3, "child": 4 }),
                call!(|ctx| ctx.ax_select_child(3, 4).await),
                json!(true),
            ),
        ];
        let mut harness = Harness::new("host-rpc");
        for (method, params, call, expected) in table {
            let task = tokio::spawn(call(harness.context()));
            let (id, actual_method, actual_params) =
                harness.next_host_request().await.expect(method);
            assert_eq!((actual_method.as_str(), actual_params), (method, params));
            assert!(harness.reply_host(id, host_reply.clone()), "{method}");
            assert_eq!(task.await.unwrap(), expected, "{method}");
        }
    }

    #[test]
    fn wifi_ssid_response_requires_ok_present_and_nonempty_ssid() {
        assert_eq!(
            wifi_ssid_from_response(&json!({
                "ok": true,
                "present": true,
                "ssid": "Studio: 5 GHz"
            }))
            .as_deref(),
            Some("Studio: 5 GHz")
        );
        for invalid in [
            json!({ "ok": false, "present": true, "ssid": "Atelier" }),
            json!({ "ok": true, "present": false, "ssid": "Atelier" }),
            json!({ "ok": true, "present": true }),
            json!({ "ok": true, "present": true, "ssid": "  " }),
        ] {
            assert_eq!(wifi_ssid_from_response(&invalid), None, "{invalid}");
        }
    }

    #[test]
    fn subprocess_latency_warning_classification_covers_slow_and_timed_out_runs() {
        let success = CommandOutput {
            ok: true,
            status: 0,
            ..Default::default()
        };
        let expected_probe_failure = CommandOutput {
            ok: false,
            status: 1,
            ..Default::default()
        };
        let timeout = CommandOutput {
            ok: false,
            status: 124,
            ..Default::default()
        };

        assert!(!command_latency_requires_warning(
            &success,
            Duration::from_millis(999),
            Duration::from_secs(1)
        ));
        assert!(command_latency_requires_warning(
            &success,
            Duration::from_secs(1),
            Duration::from_secs(1)
        ));
        assert!(!command_latency_requires_warning(
            &success,
            Duration::from_secs(1),
            Duration::from_millis(1_500)
        ));
        assert!(command_latency_requires_warning(
            &success,
            Duration::from_millis(1_500),
            Duration::from_millis(1_500)
        ));
        assert!(command_latency_requires_warning(
            &timeout,
            Duration::from_millis(1),
            Duration::from_secs(10)
        ));
        assert!(!command_latency_requires_warning(
            &expected_probe_failure,
            Duration::from_millis(1),
            Duration::from_secs(1)
        ));
    }

    #[test]
    fn command_output_folds_into_the_perform_trichotomy() {
        let ok = CommandOutput {
            ok: true,
            stdout: " done \n".to_string(),
            ..Default::default()
        };
        assert_eq!(
            ok.into_perform().to_value(),
            serde_json::json!({ "ok": true, "message": "done" })
        );

        let failed = CommandOutput {
            ok: false,
            status: 2,
            ..Default::default()
        };
        assert_eq!(
            failed.into_perform().to_value(),
            serde_json::json!({ "ok": false, "error": "command exited with status 2" })
        );
    }

    fn drain_frames(
        rx: &mut tokio::sync::mpsc::Receiver<crate::emit::OutboundFrame>,
    ) -> Vec<Value> {
        let mut frames = Vec::new();
        while let Ok(frame) = rx.try_recv() {
            frames.push(serde_json::from_slice(&frame.payload).unwrap());
        }
        frames
    }

    #[test]
    fn status_renders_values_trims_them_and_drops_unnamed_segments() {
        use crate::status::{Preview, StatusValue};

        let (ctx, mut rx) = test_context_with_rx();
        ctx.status([
            (
                " summary ",
                StatusValue::text(" v ").with_preview(Preview::from_markup("b")),
            ),
            ("", StatusValue::text("ignored")),
            ("cleared", StatusValue::empty()),
        ]);
        ctx.status([("raw", "#[bold]on#[default]")]);
        ctx.status([("owned", String::from(" x "))]);

        let frames = drain_frames(&mut rx);
        assert_eq!(frames.len(), 3);
        assert_eq!(
            frames[0]["params"]["segments"],
            json!({ "summary": "#[popup=inline:b] v #[nopopup]", "cleared": "" })
        );
        assert_eq!(
            frames[1]["params"]["segments"],
            json!({ "raw": "#[bold]on#[default]" })
        );
        assert_eq!(frames[2]["params"]["segments"], json!({ "owned": "x" }));
    }

    #[test]
    fn oversized_status_preview_publishes_the_visible_text_with_a_content_free_warning() {
        use crate::status::{Preview, StatusValue, MAX_INLINE_PREVIEW_ENCODED_BYTES};

        let (ctx, mut rx) = test_context_with_rx();
        let body = "secret ".repeat(MAX_INLINE_PREVIEW_ENCODED_BYTES);
        ctx.status([(
            "summary",
            StatusValue::text("CPU 18%").with_preview(Preview::from_markup(body.as_str())),
        )]);

        let frames = drain_frames(&mut rx);
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0]["method"], json!("log"));
        assert_eq!(frames[0]["params"]["level"], json!("warn"));
        let fields = frames[0]["params"]["fields"].as_object().unwrap();
        assert_eq!(fields.len(), 2);
        assert_eq!(fields["segment"], json!("summary"));
        assert!(
            fields["encoded_bytes"]
                .as_str()
                .unwrap()
                .parse::<usize>()
                .unwrap()
                > MAX_INLINE_PREVIEW_ENCODED_BYTES
        );
        assert!(!frames[0].to_string().contains("secret"));
        assert_eq!(
            frames[1]["params"]["segments"],
            json!({ "summary": "CPU 18%" })
        );
    }

    #[tokio::test]
    async fn context_interval_registers_with_the_host_and_never_overlaps_itself() {
        let (ctx, mut rx) = test_context_with_rx();
        let period = Duration::from_millis(50);
        let (started_tx, mut started_rx) = tokio::sync::mpsc::channel(4);
        let (finished_tx, mut finished_rx) = tokio::sync::mpsc::channel(4);
        let release = Arc::new(tokio::sync::Semaphore::new(0));
        ctx.interval(period, {
            let release = release.clone();
            move |_| {
                let started_tx = started_tx.clone();
                let finished_tx = finished_tx.clone();
                let release = release.clone();
                async move {
                    started_tx.send(()).await.unwrap();
                    release.acquire().await.unwrap().forget();
                    finished_tx.send(()).await.unwrap();
                }
            }
        });

        // The plugin arms no timer of its own: it publishes the cadence and
        // waits for the host, which drives every poller in the app.
        let frames = drain_frames(&mut rx);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0]["method"], json!("poll"));
        let intervals = frames[0]["params"]["intervals"].as_object().unwrap();
        assert_eq!(intervals.len(), 1);
        let name = intervals.keys().next().unwrap().clone();
        assert_eq!(intervals[&name], json!(period.as_secs_f64()));

        tokio::time::timeout(Duration::from_secs(5), async {
            // Nothing runs until the host says so.
            assert!(
                tokio::time::timeout(period, started_rx.recv())
                    .await
                    .is_err(),
                "a callback ran without a host tick"
            );

            ctx.deliver_poll_tick(&name);
            started_rx.recv().await.expect("first tick starts");

            // Ticks arriving while the callback is still running are dropped,
            // not queued behind it.
            for _ in 0..4 {
                ctx.deliver_poll_tick(&name);
            }
            assert!(
                tokio::time::timeout(period, started_rx.recv())
                    .await
                    .is_err(),
                "a second callback started while the first was blocked"
            );

            release.add_permits(1);
            finished_rx.recv().await.expect("first callback finishes");

            // A tick for another registration is ignored.
            ctx.deliver_poll_tick("someone-else");
            assert!(
                tokio::time::timeout(period, started_rx.recv())
                    .await
                    .is_err(),
                "a foreign registration's tick ran this callback"
            );

            ctx.deliver_poll_tick(&name);
            started_rx.recv().await.expect("next tick starts");
        })
        .await
        .expect("interval observations complete within the test deadline");
    }

    #[tokio::test]
    async fn refresh_gate_reads_running_apps_after_waiting_for_older_refresh() {
        let ctx = test_context();
        ctx.set_running_applications(vec![RunningApplication {
            bundle_id: "com.example.Old".to_string(),
            pid: 1,
            localized_name: String::new(),
        }]);
        let gate = RefreshGate::default();
        let (first_started_tx, first_started_rx) = oneshot::channel();
        let (release_first_tx, release_first_rx) = oneshot::channel();
        let first = {
            let gate = gate.clone();
            let ctx = ctx.clone();
            tokio::spawn(async move {
                gate.run(&ctx, move |_, apps| async move {
                    first_started_tx.send(()).unwrap();
                    release_first_rx.await.unwrap();
                    apps[0].bundle_id.clone()
                })
                .await
            })
        };
        first_started_rx.await.unwrap();

        let second = {
            let gate = gate.clone();
            let ctx = ctx.clone();
            tokio::spawn(async move {
                gate.run(&ctx, |_, apps| async move { apps[0].bundle_id.clone() })
                    .await
            })
        };
        tokio::task::yield_now().await;
        ctx.set_running_applications(vec![RunningApplication {
            bundle_id: "com.example.New".to_string(),
            pid: 2,
            localized_name: String::new(),
        }]);
        release_first_tx.send(()).unwrap();

        assert_eq!(first.await.unwrap(), "com.example.Old");
        assert_eq!(second.await.unwrap(), "com.example.New");
    }

    #[tokio::test]
    async fn refresh_gate_try_run_skips_instead_of_queueing() {
        let ctx = test_context();
        let gate = RefreshGate::default();
        let (started_tx, started_rx) = oneshot::channel();
        let (release_tx, release_rx) = oneshot::channel();
        let running = {
            let gate = gate.clone();
            let ctx = ctx.clone();
            tokio::spawn(async move {
                gate.run(&ctx, move |_, _| async move {
                    started_tx.send(()).unwrap();
                    release_rx.await.unwrap();
                })
                .await;
            })
        };
        started_rx.await.unwrap();

        let skipped = gate.try_run(&ctx, |_, _| async { 42 }).await;

        assert_eq!(skipped, None);
        release_tx.send(()).unwrap();
        running.await.unwrap();
        assert_eq!(gate.try_run(&ctx, |_, _| async { 42 }).await, Some(42));
    }
}
