//! Lightweight tokio scaffolding for Flash plugins.
//!
//! This crate is intentionally free of Flash business concepts. It knows
//! how to speak the JSOND wire protocol over stdin/stdout — framing,
//! request/response correlation, the `initialize`/`heartbeat`/`shutdown`
//! lifecycle, structured logging, and a sandboxed `run_cli` — and nothing
//! about targets, candidates, hints, or any specific integration. A plugin
//! supplies a [`Plugin`] implementation; everything domain-specific (the
//! shape of a `snapshot.updated` notification, what an `activateTarget`
//! means) lives in the plugin, not here.

use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

pub use serde_json;

/// Shared registry of in-flight plugin→host calls, keyed by the request id the
/// plugin assigned. The serve loop fulfils each entry when the matching host
/// response arrives. Cloned into [`Context`] so any handler can call the host.
type HostPending = Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>;

/// Serializes outgoing protocol frames onto a single stdout writer task so
/// frames emitted from concurrent handlers never interleave. Cheap to clone.
#[derive(Clone)]
pub struct Emitter {
    tx: mpsc::UnboundedSender<String>,
}

impl Emitter {
    /// Emit a raw JSON value as one newline-delimited frame.
    pub fn send(&self, value: Value) {
        if let Ok(line) = serde_json::to_string(&value) {
            let _ = self.tx.send(line);
        }
    }

    /// Emit a JSOND notification (no `id`, no response expected).
    pub fn notify(&self, method: &str, params: Value) {
        self.send(json!({ "jsonrpc": "2.0", "method": method, "params": params }));
    }

    /// Emit a JSOND response for a request `id`. A null id is dropped — it
    /// marks a notification the host never expects an answer to.
    pub fn respond(&self, id: Value, result: Value) {
        if id.is_null() {
            return;
        }
        self.send(json!({ "jsonrpc": "2.0", "id": id, "result": result }));
    }

    /// Emit a structured log line that Flash records as `plugin:<id>`.
    pub fn log(&self, level: &str, message: &str, fields: BTreeMap<String, String>) {
        self.notify(
            "flash.log",
            json!({ "level": level, "message": message, "fields": fields }),
        );
    }
}

/// Result of a [`Context::run_cli`] invocation. Mirrors the `{ok, stdout,
/// stderr, status}` shape that command results conventionally carry on the
/// wire, but carries no plugin-specific meaning itself.
#[derive(Clone, Debug)]
pub struct CliResult {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
    pub status: i32,
}

impl CliResult {
    pub fn value(&self) -> Value {
        json!({
            "ok": self.ok,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "status": self.status,
        })
    }
}

/// Per-process runtime handed to every plugin callback. Holds identity, the
/// sandboxed data directory, and the [`Emitter`]. Cheap to clone (an `Arc`
/// internally would be overkill — every field is small or already shared).
#[derive(Clone)]
pub struct Context {
    pub plugin_id: String,
    pub version: String,
    pub data_dir: PathBuf,
    pub emit: Emitter,
    /// User-supplied settings from the `[plugin.<id>]` table of
    /// `~/.config/flash`, delivered as a JSON object (empty when unset).
    /// Read with [`Context::config_str`] / [`Context::config_value`].
    pub config: Value,
    /// In-flight plugin→host calls awaiting a response; see [`HostPending`].
    host_pending: HostPending,
    /// Monotonic id source for plugin→host calls.
    host_counter: Arc<AtomicU64>,
}

impl Context {
    pub fn home_dir(&self) -> PathBuf {
        self.data_dir.join("home")
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

    /// Read an arbitrary setting from the plugin's `[plugin.<id>]` config.
    pub fn config_value(&self, key: &str) -> Option<&Value> {
        self.config.get(key)
    }
    pub fn config_dir(&self) -> PathBuf {
        self.data_dir.join("config")
    }
    pub fn cache_dir(&self) -> PathBuf {
        self.data_dir.join("cache")
    }
    pub fn share_dir(&self) -> PathBuf {
        self.data_dir.join("share")
    }
    pub fn bin_dir(&self) -> PathBuf {
        self.data_dir.join("bin")
    }

    /// Call a host RPC method and await its JSON result. This is the channel
    /// plugins use to reach native capabilities the core owns — most notably
    /// the Accessibility (AX) broker, which holds the single TCC grant and
    /// walks/acts on AX trees on the plugin's behalf. The plugin assigns the
    /// request id; the serve loop correlates the host's response back to this
    /// call. Returns a JSON error object if the host doesn't answer in time.
    pub async fn call_host(&self, method: &str, params: Value) -> Value {
        self.call_host_timeout(method, params, Duration::from_secs(5))
            .await
    }

    /// Like [`call_host`](Context::call_host) but with an explicit deadline,
    /// for host capabilities that may legitimately run longer than the default
    /// (e.g. a network-backed CLI behind `cli.run`).
    pub async fn call_host_timeout(&self, method: &str, params: Value, timeout: Duration) -> Value {
        let id = self.host_counter.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, rx) = oneshot::channel();
        if let Ok(mut pending) = self.host_pending.lock() {
            pending.insert(id, tx);
        }
        self.emit.send(json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        }));
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(value)) => value,
            _ => {
                if let Ok(mut pending) = self.host_pending.lock() {
                    pending.remove(&id);
                }
                json!({ "ok": false, "error": "host call timed out" })
            }
        }
    }

    /// Walk a subtree of an app's Accessibility tree via the core's AX broker
    /// and return a flat list of [`AxNode`]s. The broker holds the TCC grant
    /// and the real `AXUIElement` handles; the plugin receives opaque integer
    /// handles plus the requested `collect` attributes, applies its own logic
    /// (e.g. "which of these is a browser tab"), then acts on a node by handle
    /// via [`ax_perform`](Context::ax_perform) / [`ax_set`](Context::ax_set).
    ///
    /// - `pid`: target application.
    /// - `roots`: `"windows"` to start from the app's windows (the usual case),
    ///   or `"app"` to start from the application element itself.
    /// - `follow`: child attribute names to descend through; pass an empty
    ///   slice to use the broker's default (children + navigation order).
    /// - `collect`: attribute names to read for every visited node.
    /// - `max_nodes`: visit budget — the walk stops once this many nodes are
    ///   collected.
    pub async fn ax_snapshot(
        &self,
        pid: i64,
        roots: &str,
        follow: &[&str],
        collect: &[&str],
        max_nodes: u64,
    ) -> Vec<AxNode> {
        let result = self
            .call_host(
                "ax.snapshot",
                json!({
                    "pid": pid,
                    "roots": roots,
                    "follow": follow,
                    "collect": collect,
                    "max_nodes": max_nodes,
                }),
            )
            .await;
        result
            .get("nodes")
            .and_then(Value::as_array)
            .map(|nodes| nodes.iter().filter_map(AxNode::from_value).collect())
            .unwrap_or_default()
    }

    /// Perform an AX action (e.g. `AXPress`) on a handle from a prior
    /// [`ax_snapshot`](Context::ax_snapshot). Returns whether the action
    /// succeeded; a stale handle (snapshot superseded) reports `false`.
    pub async fn ax_perform(&self, handle: u64, action: &str) -> bool {
        host_ok(
            self.call_host("ax.perform", json!({ "handle": handle, "action": action }))
                .await,
        )
    }

    /// Set an AX attribute (e.g. `AXSelected = true`) on a snapshot handle.
    /// `value` may be a bool or a string. Returns whether the set succeeded.
    pub async fn ax_set(&self, handle: u64, attribute: &str, value: Value) -> bool {
        host_ok(
            self.call_host(
                "ax.set",
                json!({ "handle": handle, "attribute": attribute, "value": value }),
            )
            .await,
        )
    }

    /// Bring an application's windows to the front. Used before acting on a
    /// snapshot handle so the AX action lands on the now-frontmost app.
    pub async fn ax_activate(&self, pid: i64) -> bool {
        host_ok(self.call_host("ax.activate", json!({ "pid": pid })).await)
    }

    /// Run an AppleScript snippet via `osascript -e`. Convenience over
    /// [`run_cli`](Context::run_cli) for the many plugins that shell out to
    /// macOS apps.
    pub async fn run_osascript(&self, script: &str, timeout: Duration) -> CliResult {
        self.run_cli(
            &[
                "/usr/bin/osascript".to_string(),
                "-e".to_string(),
                script.to_string(),
            ],
            timeout,
        )
        .await
    }

    /// Emit a `snapshot.updated` notification carrying `candidates` (and no
    /// jump targets) for `source_id`. Wraps the boilerplate every
    /// candidate-emitting plugin repeats.
    pub fn emit_snapshot(&self, source_id: &str, candidates: Vec<Value>) {
        self.emit.notify(
            "snapshot.updated",
            json!({ "targets": [], "candidates": candidates, "source_id": source_id }),
        );
    }

    pub fn log(&self, level: &str, message: &str) {
        self.emit.log(level, message, BTreeMap::new());
    }

    pub fn log_fields(&self, level: &str, message: &str, fields: BTreeMap<String, String>) {
        self.emit.log(level, message, fields);
    }

    fn prepare_dirs(&self) {
        for dir in [
            self.home_dir(),
            self.config_dir(),
            self.cache_dir(),
            self.share_dir(),
            self.bin_dir(),
        ] {
            let _ = std::fs::create_dir_all(dir);
        }
    }

    /// Run an external command through the core's `cli.run` capability. The
    /// core — not the plugin — spawns the process inside this plugin's sandbox
    /// (`HOME` and the XDG base dirs redirected under its data dir, `bin/`
    /// prepended to `PATH`), bounds it by `timeout` (status 124 on overrun),
    /// and emits one structured log line per call. The template itself never
    /// touches the process API: all native execution lives in the core.
    pub async fn run_cli(&self, argv: &[String], timeout: Duration) -> CliResult {
        self.run_cli_inner(argv, timeout, false).await
    }

    /// Same as [`run_cli`](Context::run_cli) but asks the core to skip the
    /// per-call log line. Use for commands run on a tight loop where a log
    /// line per call would balloon the log file. The caller owns surfacing
    /// failures.
    pub async fn run_cli_quiet(&self, argv: &[String], timeout: Duration) -> CliResult {
        self.run_cli_inner(argv, timeout, true).await
    }

    async fn run_cli_inner(&self, argv: &[String], timeout: Duration, quiet: bool) -> CliResult {
        // Allow the host a little longer than the command's own deadline so the
        // core (which enforces the real timeout and kills the child) is what
        // reports a 124, not our outer `call_host` watchdog.
        let result = self
            .call_host_timeout(
                "cli.run",
                json!({
                    "argv": argv,
                    "timeout_ms": timeout.as_millis() as u64,
                    "quiet": quiet,
                }),
                timeout + Duration::from_secs(2),
            )
            .await;
        CliResult {
            ok: result.get("ok").and_then(Value::as_bool).unwrap_or(false),
            stdout: result
                .get("stdout")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            stderr: result
                .get("stderr")
                .and_then(Value::as_str)
                .unwrap_or_else(|| result.get("error").and_then(Value::as_str).unwrap_or(""))
                .to_string(),
            status: result.get("status").and_then(Value::as_i64).unwrap_or(-1) as i32,
        }
    }
}

/// One node from an [`ax_snapshot`](Context::ax_snapshot) walk. `handle` is an
/// opaque id the broker uses to find the real `AXUIElement` for follow-up
/// actions; `root` is the index of the root (e.g. window) this node descends
/// from; `attrs` holds the requested attributes that were present.
#[derive(Clone, Debug)]
pub struct AxNode {
    pub handle: u64,
    pub root: usize,
    pub attrs: BTreeMap<String, String>,
}

impl AxNode {
    fn from_value(value: &Value) -> Option<Self> {
        let handle = value.get("handle")?.as_u64()?;
        let root = value.get("root").and_then(Value::as_u64).unwrap_or(0) as usize;
        let attrs = value
            .get("attrs")
            .and_then(Value::as_object)
            .map(|map| {
                map.iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                    .collect()
            })
            .unwrap_or_default();
        Some(Self {
            handle,
            root,
            attrs,
        })
    }

    /// The collected attribute `name`, if it was present on this node.
    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
    }
}

/// Read the `ok` flag from a host RPC response, defaulting to `false`.
fn host_ok(response: Value) -> bool {
    response.get("ok").and_then(Value::as_bool).unwrap_or(false)
}

/// Read a JSON object's `key` as a string slice, defaulting to `""`.
pub fn str_field<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or("")
}

/// Read a JSON object's `key` as a `Vec<String>` (non-strings skipped).
pub fn string_list(value: &Value, key: &str) -> Vec<String> {
    value
        .get(key)
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// Quote a string as an AppleScript literal, escaping backslashes and double
/// quotes. Use for any value interpolated into an `osascript` snippet.
pub fn applescript_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// Parse a candidate's `payload` field, which conventionally carries either a
/// stringified JSON object or an inline object. Returns `{}` when absent or
/// unparseable.
pub fn parse_payload(candidate: &Value) -> Value {
    match candidate.get("payload") {
        Some(Value::String(raw)) => serde_json::from_str(raw).unwrap_or_else(|_| json!({})),
        Some(value @ Value::Object(_)) => value.clone(),
        _ => json!({}),
    }
}

/// Truncate a string to a fixed character budget, appending an ellipsis when
/// it overflows. Used to keep logged/forwarded output bounded.
pub fn shorten(value: &str) -> String {
    const LIMIT: usize = 2000;
    let trimmed = value.trim();
    if trimmed.chars().count() <= LIMIT {
        return trimmed.to_string();
    }
    let head: String = trimmed.chars().take(LIMIT - 3).collect();
    format!("{head}...")
}

/// A Flash plugin. Implement [`handle`](Plugin::handle) for request methods
/// the plugin understands; override the lifecycle hooks as needed. Every
/// method returns a `Send` future so the runtime can drive handlers
/// concurrently without blocking the heartbeat/serve loop.
pub trait Plugin: Send + Sync + 'static {
    /// Called once after `initialize`, on a background task. Use it to seed
    /// an initial snapshot or kick off provisioning. Blocking here never
    /// stalls heartbeats.
    fn on_start(&self, ctx: Context) -> impl Future<Output = ()> + Send {
        let _ = ctx;
        async {}
    }

    /// Host event (`focus.changed`, `apps.launched`, `config.changed`, …).
    fn on_event(
        &self,
        ctx: Context,
        name: String,
        payload: Value,
    ) -> impl Future<Output = ()> + Send {
        let _ = (ctx, name, payload);
        async {}
    }

    /// Dispatch a non-lifecycle request (`discoverTargets`, `sourceAction`,
    /// `resolveCandidate`, `activateTarget`, `command.invoke`, …) and return
    /// the JSON result. For notification-style methods the returned value is
    /// ignored.
    fn handle(
        &self,
        ctx: Context,
        method: String,
        params: Value,
    ) -> impl Future<Output = Value> + Send;

    /// Called on `shutdown` just before the process exits.
    fn on_shutdown(&self, ctx: Context, reason: String) -> impl Future<Output = ()> + Send {
        let _ = (ctx, reason);
        async {}
    }
}

fn env_or(name: &str, fallback: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| fallback.to_string())
}

/// Build a [`Context`] from the `FLASH_PLUGIN_*` environment Flash injects.
fn context_from_env(
    emit: Emitter,
    host_pending: HostPending,
    host_counter: Arc<AtomicU64>,
) -> Context {
    let data_dir = PathBuf::from(env_or(
        "FLASH_PLUGIN_DATA_DIR",
        Path::new(".").to_str().unwrap_or("."),
    ));
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
    }
}

/// Run the plugin: spin up a multi-thread tokio runtime and serve the JSOND
/// protocol until `shutdown` or stdin closes. This is the single entry point
/// a plugin's `main` calls.
pub fn run<P: Plugin>(plugin: P) {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("flash-plugin: tokio runtime");
    runtime.block_on(serve(plugin));
}

async fn serve<P: Plugin>(plugin: P) {
    let plugin = Arc::new(plugin);
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(async move {
        let mut out = tokio::io::stdout();
        while let Some(line) = rx.recv().await {
            if out.write_all(line.as_bytes()).await.is_err() {
                break;
            }
            let _ = out.write_all(b"\n").await;
            let _ = out.flush().await;
        }
    });

    let host_pending: HostPending = Arc::new(Mutex::new(HashMap::new()));
    let host_counter = Arc::new(AtomicU64::new(0));
    let ctx = context_from_env(Emitter { tx }, host_pending.clone(), host_counter);
    ctx.prepare_dirs();
    ctx.log("info", "[plugin] process ready");

    {
        let plugin = plugin.clone();
        let ctx = ctx.clone();
        tokio::spawn(async move { plugin.on_start(ctx).await });
    }

    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(request) = serde_json::from_str::<Value>(line) else {
            continue;
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
            "initialize" | "heartbeat" => ctx.emit.respond(id, json!({ "ok": true })),
            "shutdown" => {
                let reason = params
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .to_string();
                plugin.on_shutdown(ctx.clone(), reason).await;
                ctx.emit.respond(id, json!({ "ok": true }));
                break;
            }
            "event" => {
                let name = params
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let payload = params.get("payload").cloned().unwrap_or_else(|| json!({}));
                ctx.emit.respond(id, json!({ "ok": true }));
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                tokio::spawn(async move { plugin.on_event(ctx, name, payload).await });
            }
            "activateTarget" => {
                // Notification: dispatch through `handle`, never respond.
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                tokio::spawn(async move {
                    plugin
                        .handle(ctx, "activateTarget".to_string(), params)
                        .await;
                });
            }
            _ => {
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                let method = method.clone();
                tokio::spawn(async move {
                    let result = plugin.handle(ctx.clone(), method, params).await;
                    ctx.emit.respond(id, result);
                });
            }
        }
    }

    // Drop the last emitter handle so the writer task can drain and flush
    // any queued frames (notably the shutdown response) before we exit.
    drop(ctx);
    let _ = writer.await;
}
