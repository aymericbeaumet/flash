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
use tokio::sync::oneshot;

use crate::emit::Emitter;
use crate::process::{self, ManagedChild, ManagedChildError};
use crate::types::{Candidate, PerformResponse, RunningApplication};

/// Shared registry of in-flight plugin→host calls, keyed by the request id the
/// plugin assigned. The serve loop fulfils each entry when the matching host
/// response arrives and drains the registry at teardown so every waiter gets
/// the `host closed stdin` sentinel. Cloned into [`Context`] so any handler
/// can call the host.
pub(crate) type HostPending = Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>;

const COMMAND_STDOUT_LIMIT: usize = 4 * 1024 * 1024;
const COMMAND_STDERR_LIMIT: usize = 256 * 1024;

/// Canonical `call_host` sentinels (spec-pinned): `call_host` never errors and
/// never returns nil — host death and the call timeout arrive as these result
/// objects instead.
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
    /// exposes each value as `#{plugin:<plugin-id>.<segment>}` in
    /// `[statusbar].template`. An EMPTY value clears the segment host-side.
    pub fn status<I, K, V>(&self, segments: I)
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<str>,
        V: AsRef<str>,
    {
        let mut object = serde_json::Map::new();
        for (name, value) in segments {
            let name = name.as_ref().trim();
            let value = value.as_ref().trim();
            if !name.is_empty() {
                object.insert(name.to_string(), json!(value));
            }
        }
        self.emit.notify("status", json!({ "segments": object }));
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
            pending.insert(id, tx);
        }
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
            Ok(Err(crate::emit::EmitError::Closed)) => {
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

    // -- Typed host RPC wrappers (one per registry method) ------------------

    /// Probe host liveness (`host.ping`).
    pub async fn ping_host(&self) -> bool {
        ok(&self.call_host("host.ping", json!({})).await)
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
        Some(NormalModeTarget { pid, bundle_id })
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
    /// the current IPv4/IPv6 socket count. The host performs the libproc work
    /// off its main thread. Requires the `process_control` capability.
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
    /// replaced atomically by the SDK before each serialized callback.
    pub fn running_applications(&self) -> Vec<RunningApplication> {
        self.running_applications
            .lock()
            .map(|applications| applications.clone())
            .unwrap_or_default()
    }

    /// Run one background refresh at a fixed interval. The first tick waits for
    /// `period`; callers perform their authoritative initial refresh in
    /// `on_start`. The callback is awaited before scheduling the next tick, so
    /// one interval can never overlap itself.
    pub fn interval<F, Fut>(&self, period: Duration, mut callback: F) -> tokio::task::JoinHandle<()>
    where
        F: FnMut(Context) -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let ctx = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(period).await;
                callback(ctx.clone()).await;
            }
        })
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

fn ok(response: &Value) -> bool {
    response.get("ok").and_then(Value::as_bool) == Some(true)
}

fn env_or(name: &str, fallback: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| fallback.to_string())
}

/// Build a [`Context`] from the `FLASH_PLUGIN_*` environment Flash injects.
pub(crate) fn context_from_env(
    emit: Emitter,
    host_pending: HostPending,
    host_counter: Arc<AtomicU64>,
) -> Context {
    let data_dir = std::env::var("FLASH_PLUGIN_DATA_DIR")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from);
    let config = std::env::var("FLASH_PLUGIN_CONFIG")
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}));
    Context {
        plugin_id: env_or("FLASH_PLUGIN_ID", "plugin"),
        version: env_or("FLASH_PLUGIN_VERSION", "0.0.0"),
        data_dir,
        emit,
        config,
        host_pending,
        host_counter,
        running_applications: Arc::new(Mutex::new(Vec::new())),
    }
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
    let started_at = Instant::now();
    let Some((program, args)) = argv.split_first() else {
        let output = CommandOutput {
            ok: false,
            stderr: "empty argv".to_string(),
            status: -1,
            ..Default::default()
        };
        log_command_latency(ctx, "<empty>", &output, started_at.elapsed(), timeout);
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
    log_command_latency(ctx, executable, &output, started_at.elapsed(), timeout);
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

fn command_latency_requires_warning(output: &CommandOutput, elapsed: Duration) -> bool {
    output.status == 124 || elapsed >= Duration::from_secs(1)
}

fn log_command_latency(
    ctx: &Context,
    executable: &str,
    output: &CommandOutput,
    elapsed: Duration,
    timeout: Duration,
) {
    if !command_latency_requires_warning(output, elapsed) {
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

/// Assemble a [`Context`] from parts with fresh host-RPC state. Shared by the
/// crate-internal tests and the public [`crate::testing`] harness; the
/// production path stays [`context_from_env`].
pub(crate) fn assemble_context(
    plugin_id: String,
    version: String,
    data_dir: PathBuf,
    emit: Emitter,
    config: Value,
) -> Context {
    Context {
        plugin_id,
        version,
        data_dir: Some(data_dir),
        emit,
        config,
        host_pending: Arc::new(Mutex::new(HashMap::new())),
        host_counter: Arc::new(AtomicU64::new(0)),
        running_applications: Arc::new(Mutex::new(Vec::new())),
    }
}

#[cfg(test)]
pub(crate) fn test_context_with_rx() -> (Context, tokio::sync::mpsc::Receiver<Vec<u8>>) {
    let (tx, rx) = tokio::sync::mpsc::channel(16);
    let ctx = assemble_context(
        "test".to_string(),
        "0.0.0".to_string(),
        PathBuf::from("."),
        Emitter::new(tx),
        json!({}),
    );
    (ctx, rx)
}

#[cfg(test)]
pub(crate) fn test_context() -> Context {
    test_context_with_rx().0
}

#[cfg(test)]
mod tests {
    use super::*;

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
            Duration::from_millis(999)
        ));
        assert!(command_latency_requires_warning(
            &success,
            Duration::from_secs(1)
        ));
        assert!(command_latency_requires_warning(
            &timeout,
            Duration::from_millis(1)
        ));
        assert!(!command_latency_requires_warning(
            &expected_probe_failure,
            Duration::from_millis(1)
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

    #[tokio::test]
    async fn context_interval_waits_for_first_tick_and_never_overlaps_itself() {
        let ctx = test_context();
        let calls = Arc::new(AtomicU64::new(0));
        let in_flight = Arc::new(AtomicU64::new(0));
        let max_in_flight = Arc::new(AtomicU64::new(0));
        let handle = ctx.interval(Duration::from_millis(5), {
            let calls = calls.clone();
            let in_flight = in_flight.clone();
            let max_in_flight = max_in_flight.clone();
            move |_| {
                let calls = calls.clone();
                let in_flight = in_flight.clone();
                let max_in_flight = max_in_flight.clone();
                async move {
                    let active = in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                    max_in_flight.fetch_max(active, Ordering::SeqCst);
                    calls.fetch_add(1, Ordering::SeqCst);
                    tokio::time::sleep(Duration::from_millis(8)).await;
                    in_flight.fetch_sub(1, Ordering::SeqCst);
                }
            }
        });

        assert_eq!(calls.load(Ordering::SeqCst), 0);
        tokio::time::sleep(Duration::from_millis(32)).await;
        handle.abort();

        assert!(calls.load(Ordering::SeqCst) >= 2);
        assert_eq!(max_in_flight.load(Ordering::SeqCst), 1);
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
}
