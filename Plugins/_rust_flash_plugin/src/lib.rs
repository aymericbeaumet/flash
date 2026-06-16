//! Strongly-typed tokio scaffolding for Flash plugins.
//!
//! This crate speaks the length-prefixed MessagePack wire protocol over
//! stdin/stdout — a 4-byte big-endian payload length followed by a
//! MessagePack-encoded value — plus request/response correlation, the
//! `initialize`/`heartbeat`/`shutdown` lifecycle, structured logging, and a
//! sandboxed `run_cli`. Everything a plugin touches is a typed value: a plugin
//! receives a [`Request`] / [`Event`] and returns a [`Response`]; it never
//! constructs raw JSON. `serde_json` is an implementation detail of the wire
//! codec and is intentionally *not* re-exported — plugins that need a custom
//! candidate payload derive `serde` on their own struct.

use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufWriter};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

/// Generate the typed plugin surface from `manifest.json` at compile time. See
/// the `flash_plugin_macros` crate. Invoke as `flash_plugin::plugin!(MyPlugin);`
/// then write `impl FlashPlugin for MyPlugin { … }`.
pub use flash_plugin_macros::plugin;

/// Shared registry of in-flight plugin→host calls, keyed by the request id the
/// plugin assigned. The serve loop fulfils each entry when the matching host
/// response arrives. Cloned into [`Context`] so any handler can call the host.
type HostPending = Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>;

// ---------------------------------------------------------------------------
// Core value types
// ---------------------------------------------------------------------------

/// A screen-space rectangle in NSScreen coordinates (origin bottom-left), the
/// coordinate space Flash hint targets live in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Frame {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    /// Build a `Frame` from an [`AxNode::frame`] `[x, y, w, h]` rect.
    pub fn from_ax(rect: [f64; 4]) -> Self {
        Self::new(rect[0], rect[1], rect[2], rect[3])
    }
}

impl From<[f64; 4]> for Frame {
    fn from(rect: [f64; 4]) -> Self {
        Self::from_ax(rect)
    }
}

/// A hint target a plugin emits for the `f` family. `id` is echoed back on
/// [`Request::ActivateTarget`]; `frame` positions the hint label. Optional
/// fields are omitted from the wire when unset.
#[derive(Clone, Debug, Serialize)]
pub struct JumpTarget {
    pub id: String,
    pub frame: Frame,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enters_insert_mode: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_id: Option<String>,
    /// When `true`, the host should drop the plugin-side `activate` path
    /// (which fires a `target.action` RPC and races with subsequent
    /// keystrokes — `tmux select-pane` for example is async by nature)
    /// and instead synthesize a real mouse click at the target's frame.
    /// The click propagates through the windowing system atomically,
    /// reaches the underlying app (alacritty → tmux mouse mode for
    /// panes), and is observed *before* Flash forwards anything else.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prefer_host_click: Option<bool>,
    /// Mark a target as structurally important inside its source so
    /// the host's hint renderer paints it in the accent style (e.g.
    /// tmux pane chips vs. link chips; firefox tab chips vs. element
    /// chips). Purely a styling signal — the commit path doesn't
    /// branch on it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub important: Option<bool>,
}

impl JumpTarget {
    pub fn new(id: impl Into<String>, frame: Frame) -> Self {
        Self {
            id: id.into(),
            frame,
            role: None,
            label: None,
            url: None,
            pid: None,
            enters_insert_mode: None,
            source_id: None,
            prefer_host_click: None,
            important: None,
        }
    }

    pub fn role(mut self, role: impl Into<String>) -> Self {
        self.role = Some(role.into());
        self
    }

    pub fn label(mut self, label: impl Into<String>) -> Self {
        self.label = Some(label.into());
        self
    }

    pub fn url(mut self, url: impl Into<String>) -> Self {
        self.url = Some(url.into());
        self
    }

    pub fn pid(mut self, pid: i64) -> Self {
        self.pid = Some(pid);
        self
    }

    pub fn enters_insert_mode(mut self, enters: bool) -> Self {
        self.enters_insert_mode = Some(enters);
        self
    }

    pub fn source_id(mut self, source_id: impl Into<String>) -> Self {
        self.source_id = Some(source_id.into());
        self
    }

    pub fn prefer_host_click(mut self, prefer: bool) -> Self {
        self.prefer_host_click = Some(prefer);
        self
    }

    pub fn important(mut self, important: bool) -> Self {
        self.important = Some(important);
        self
    }
}

/// A flashlight candidate. Outbound (emitted via [`Context::emit_snapshot`])
/// only `title` is required. Inbound (on [`Request::ResolveCandidate`]) the
/// host echoes back the candidate with the same shape — read structured
/// payload via [`payload_str`](Candidate::payload_str) /
/// [`payload_as`](Candidate::payload_as).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Candidate {
    /// Primary searchable string the host scores against and shows in the
    /// candidate bar — also the highest-precedence ranking field.
    pub title: String,
    /// Stable identity for streaming-update reconciliation. When a plugin
    /// emits the same `id` in a later [`emit_candidate_delta`](Context::emit_candidate_delta)
    /// `upsert`, the host replaces the previous entry; the same `id` in
    /// `remove` evicts it. The host falls back to `title` for identity when
    /// `id` is absent, matching the existing snapshot-replacement semantics.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub id: Option<String>,
    /// Openable destination when one exists. Apps use the bundle file URL;
    /// browser tabs and other resources use their canonical URL.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub url: Option<String>,
    /// Free-form per-source key/value metadata. FlashCore makes no decisions on
    /// what's inside — plugins may stash arbitrary routing/state, other plugins
    /// can read it, and the matcher indexes the values at a low tier for fuzzy
    /// search.
    #[serde(default)]
    pub metadata: HashMap<String, String>,
}

/// Conventional metadata keys used by Flash's bundled host. Plugins can stash
/// arbitrary keys in `metadata`; these constants exist so plugins can speak the
/// same vocabulary as the host without re-typing the string literals. The
/// canonical `url` is a typed field on `Candidate` — not in this map.
pub mod candidate_metadata {
    pub const SOURCE: &str = "source";
    pub const SOURCE_ID: &str = "source_id";
    pub const KIND: &str = "kind";
    pub const PID: &str = "pid";
    pub const NAVIGATION_URL: &str = "navigation_url";
    pub const BUNDLE_ID: &str = "bundle_id";
    pub const SUBTITLE: &str = "subtitle";
    pub const PAYLOAD: &str = "payload";
    pub const ALIASES: &str = "aliases";
    pub const FINISHES_COMMAND: &str = "finishes_command";
}

impl Candidate {
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            id: None,
            url: None,
            metadata: HashMap::new(),
        }
    }

    /// Set the stable identity this candidate carries across snapshot deltas.
    /// Unset by default; recommended for any plugin that uses
    /// [`emit_candidate_delta`](Context::emit_candidate_delta).
    pub fn id(mut self, id: impl Into<String>) -> Self {
        self.id = Some(id.into());
        self
    }

    fn set(mut self, key: &str, value: impl Into<String>) -> Self {
        self.metadata.insert(key.to_string(), value.into());
        self
    }

    pub fn kind(self, kind: impl Into<String>) -> Self {
        self.set(candidate_metadata::KIND, kind)
    }

    pub fn source(self, source: impl Into<String>) -> Self {
        self.set(candidate_metadata::SOURCE, source)
    }

    pub fn source_id(self, source_id: impl Into<String>) -> Self {
        self.set(candidate_metadata::SOURCE_ID, source_id)
    }

    pub fn subtitle(self, subtitle: impl Into<String>) -> Self {
        self.set(candidate_metadata::SUBTITLE, subtitle)
    }

    pub fn bundle_id(self, bundle_id: impl Into<String>) -> Self {
        self.set(candidate_metadata::BUNDLE_ID, bundle_id)
    }

    pub fn url(mut self, url: impl Into<String>) -> Self {
        self.url = Some(url.into());
        self
    }

    pub fn navigation_url(self, url: impl Into<String>) -> Self {
        self.set(candidate_metadata::NAVIGATION_URL, url)
    }

    pub fn pid(self, pid: i64) -> Self {
        self.set(candidate_metadata::PID, pid.to_string())
    }

    /// Attach search aliases — extra tokens the host's ranker treats as
    /// high-priority synonyms (e.g. emoji shortcodes: `🙏` → `["pray",
    /// "thanks"]`). Tokens are joined with spaces; empty input clears
    /// the entry.
    pub fn aliases<I, S>(mut self, aliases: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let joined: String = aliases
            .into_iter()
            .map(|s| s.as_ref().trim().to_string())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        if joined.is_empty() {
            self.metadata.remove(candidate_metadata::ALIASES);
        } else {
            self.metadata
                .insert(candidate_metadata::ALIASES.to_string(), joined);
        }
        self
    }

    /// Mark this candidate as specific enough for Return to perform
    /// immediately from the command bar. Leave unset for insert-first
    /// behavior.
    pub fn finishes_command(self, value: bool) -> Self {
        if value {
            self.set(candidate_metadata::FINISHES_COMMAND, "1")
        } else {
            let mut me = self;
            me.metadata.remove(candidate_metadata::FINISHES_COMMAND);
            me
        }
    }

    /// Attach a raw string payload.
    pub fn payload(self, payload: impl Into<String>) -> Self {
        self.set(candidate_metadata::PAYLOAD, payload)
    }

    /// Attach a structured payload, serialized to a JSON string. Read it back
    /// on resolution with [`payload_as`](Candidate::payload_as).
    pub fn payload_json<T: Serialize>(mut self, value: &T) -> Self {
        if let Ok(raw) = serde_json::to_string(value) {
            self.metadata
                .insert(candidate_metadata::PAYLOAD.to_string(), raw);
        }
        self
    }

    /// Attach an arbitrary metadata entry. Useful for source-specific routing
    /// keys outside the canonical set.
    pub fn metadata(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.metadata.insert(key.into(), value.into());
        self
    }

    /// The raw string payload, if present.
    pub fn payload_str(&self) -> Option<&str> {
        self.metadata
            .get(candidate_metadata::PAYLOAD)
            .map(String::as_str)
    }

    /// Decode the payload as `T` (set earlier with
    /// [`payload_json`](Candidate::payload_json)). `None` if absent or malformed.
    pub fn payload_as<T: DeserializeOwned>(&self) -> Option<T> {
        serde_json::from_str(self.payload_str()?).ok()
    }

    /// Read a typed metadata value. Returns `None` when the key is absent.
    /// Plugins use this in resolve handlers to read back values they set with
    /// the builders (e.g. `meta(candidate_metadata::URL)`).
    pub fn meta(&self, key: &str) -> Option<&str> {
        self.metadata.get(key).map(String::as_str)
    }

    /// Parsed `pid` metadata value, if present and well-formed.
    pub fn pid_value(&self) -> Option<i64> {
        self.meta(candidate_metadata::PID)
            .and_then(|s| s.parse().ok())
    }

    /// The candidate's openable URL string, if present.
    pub fn url_value(&self) -> Option<&str> {
        self.url.as_deref()
    }

    /// The candidate's title (primary searchable string).
    pub fn as_str(&self) -> &str {
        &self.title
    }
}

impl From<&str> for Candidate {
    fn from(title: &str) -> Self {
        Candidate::new(title)
    }
}

impl From<String> for Candidate {
    fn from(title: String) -> Self {
        Candidate::new(title)
    }
}

impl AsRef<str> for Candidate {
    fn as_ref(&self) -> &str {
        &self.title
    }
}

impl std::ops::Deref for Candidate {
    type Target = str;
    fn deref(&self) -> &str {
        &self.title
    }
}

impl std::fmt::Display for Candidate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.title)
    }
}

/// Focused non-Flash app context returned by
/// [`Context::normal_mode_target`]. Mirrors the host-side notion of
/// "what the user is working on": pid for fast activation, bundle id as the
/// durable handle that survives a relaunch.
#[derive(Clone, Debug)]
pub struct NormalModeTarget {
    pub pid: i64,
    pub bundle_id: String,
}

/// TCC (privacy) permission categories a plugin can request via
/// [`Context::tcc_request`]. Only AppleEvents is wired through the host
/// today; future kinds (Contacts, Reminders, Calendar) will land alongside
/// host-side bridges for the matching frameworks.
#[derive(Clone, Debug)]
pub enum TccKind {
    AppleEvents { target_bundle_id: String },
}

/// Result of [`Context::tcc_request`]. `granted` means the user has already
/// approved (no prompt was needed, or one was approved before); `denied` means
/// the user has explicitly declined; `unknown` means the prompt fired and
/// the system is waiting for the user's decision. `ok` is false only when the
/// underlying TCC call failed for a reason other than the user's choice — in
/// that case `error` carries the diagnostic.
#[derive(Clone, Debug, Default)]
pub struct TccGrant {
    pub ok: bool,
    pub granted: bool,
    pub denied: bool,
    pub unknown: bool,
    pub error: Option<String>,
}

/// Parsing strategy for [`Context::applescript`] stdout. Use `Raw` when the
/// script returns no structured output; `TabSep` for the common "list of rows
/// separated by newlines, columns separated by tabs" idiom; `Json` when the
/// script returns a JSON document.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum AppleScriptParse {
    Raw,
    TabSep,
    Json,
}

/// Result of [`Context::applescript`]. `rows` is populated when `parse =
/// TabSep`; `json` is populated when `parse = Json` and stdout parses
/// successfully. `stdout` is always available so plugins can fall back to
/// custom parsing.
#[derive(Clone, Debug, Default)]
pub struct AppleScriptResult {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
    pub status: i32,
    pub rows: Vec<Vec<String>>,
    pub json: Option<Value>,
}

/// Result of a [`Context::run_cli`] / [`Context::run_local`] invocation.
#[derive(Clone, Debug, Default)]
pub struct CliResult {
    pub ok: bool,
    pub stdout: String,
    pub stderr: String,
    pub status: i32,
}

impl CliResult {
    /// Map into a [`CommandResponse`]: success carries non-empty stdout as a
    /// toast; failure carries stderr as the error.
    pub fn into_command(self) -> CommandResponse {
        let stdout = (!self.stdout.is_empty()).then_some(self.stdout);
        let error = (!self.ok && !self.stderr.is_empty()).then_some(self.stderr);
        CommandResponse {
            ok: self.ok,
            target_pid: None,
            navigation_url: None,
            stdout,
            error,
        }
    }
}

/// One node from an [`ax_snapshot`](Context::ax_snapshot) walk. `handle` is an
/// opaque id the broker uses to find the real `AXUIElement` for follow-up
/// actions; `root` is the index of the root (e.g. window) this node descends
/// from; `attrs` holds the requested attributes that were present; `frame` is
/// the node's NSScreen-space `[x, y, w, h]`, present only when the snapshot was
/// taken with `geometry = true`.
#[derive(Clone, Debug)]
pub struct AxNode {
    pub handle: u64,
    pub root: usize,
    pub attrs: BTreeMap<String, String>,
    pub frame: Option<[f64; 4]>,
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
        let frame = value.get("frame").and_then(Value::as_array).and_then(|a| {
            let v: Vec<f64> = a.iter().filter_map(Value::as_f64).collect();
            <[f64; 4]>::try_from(v).ok()
        });
        Some(Self {
            handle,
            root,
            attrs,
            frame,
        })
    }

    /// The collected attribute `name`, if it was present on this node.
    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
    }
}

/// A browser tab extracted from an AX snapshot by
/// [`Context::ax_browser_tabs`]. `handle` is the AX broker handle for the
/// underlying tab element; `root` is the window index (so callers can map
/// back to `window_title`); `title`/`url` are best-effort extractions from the
/// usual tab attributes; `window_title` is the surrounding `AXWindow` title,
/// used as a fallback when a tab exposes no title of its own.
#[derive(Clone, Debug)]
pub struct BrowserTab {
    pub handle: u64,
    pub root: usize,
    pub title: String,
    pub url: String,
    pub window_title: String,
}

/// Whether an AX node looks like a browser tab. Same heuristic the firefox
/// plugin used inline before this helper landed: `AXTab` always counts; an
/// `AXRadioButton` / `AXButton` only when its `AXSubrole` is `AXTabButton` or
/// its `AXRoleDescription` matches "tab"/"... tab button".
fn is_browser_tab(node: &AxNode) -> bool {
    let role = node.attr("AXRole").unwrap_or("");
    if role == "AXTab" {
        return true;
    }
    let subrole = node.attr("AXSubrole").unwrap_or("");
    let role_desc = node.attr("AXRoleDescription").unwrap_or("").to_lowercase();
    let is_tab_button =
        subrole == "AXTabButton" || role_desc == "tab" || role_desc.contains("tab button");
    matches!(role, "AXRadioButton" | "AXButton") && is_tab_button
}

/// A value to write to an AX attribute via [`Context::ax_set`]. Construct from
/// a `bool` or a string with `.into()`.
#[derive(Clone, Debug)]
pub enum AxValue {
    Bool(bool),
    Str(String),
}

impl From<bool> for AxValue {
    fn from(value: bool) -> Self {
        AxValue::Bool(value)
    }
}

impl From<&str> for AxValue {
    fn from(value: &str) -> Self {
        AxValue::Str(value.to_string())
    }
}

impl From<String> for AxValue {
    fn from(value: String) -> Self {
        AxValue::Str(value)
    }
}

impl AxValue {
    fn to_value(&self) -> Value {
        match self {
            AxValue::Bool(b) => json!(b),
            AxValue::Str(s) => json!(s),
        }
    }
}

// ---------------------------------------------------------------------------
// Inbound requests / events
// ---------------------------------------------------------------------------

/// One running regular app visible to Flash. Used by `core:apps.snapshot` and
/// by candidate query requests so plugins can refresh app-scoped sources while
/// keeping the data in memory.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct RunningApplication {
    #[serde(default)]
    pub bundle_id: String,
    #[serde(default)]
    pub pid: i64,
    #[serde(default)]
    pub localized_name: String,
}

/// A host event delivered to [`Plugin::on_event`]. Match on
/// [`name`](Event::name) (`core:focus.changed`, `core:clipboard.changed`, …); the
/// remaining fields are the event payload, present when the event carries them.
#[derive(Clone, Debug, Default)]
pub struct Event {
    pub name: String,
    pub bundle_id: Option<String>,
    pub pid: Option<i64>,
    pub front_window_frame: Option<Frame>,
    pub text: Option<String>,
    pub running_applications: Vec<RunningApplication>,
}

#[derive(Deserialize)]
struct EventWire {
    #[serde(default)]
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
    fn from_params(params: Value) -> Self {
        match serde_json::from_value::<EventWire>(params) {
            Ok(wire) => Event {
                name: wire.name,
                bundle_id: wire.payload.bundle_id,
                pid: wire.payload.pid,
                front_window_frame: wire.payload.front_window_frame,
                text: wire.payload.text,
                running_applications: wire.payload.running_applications,
            },
            Err(_) => Event::default(),
        }
    }
}

/// A `command.invoke` request: the matched `:`-command, its subcommand, the
/// trailing args, and the raw URL. Manifest `_`-prefixed metadata is in
/// [`meta`](CommandRequest::meta).
#[derive(Clone, Debug, Default, Deserialize)]
pub struct CommandRequest {
    #[serde(default)]
    pub command: String,
    #[serde(default)]
    pub subcommand: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub raw: String,
    #[serde(flatten, default)]
    pub meta: BTreeMap<String, String>,
}

impl CommandRequest {
    /// Read a manifest metadata field (e.g. `_url`), forwarded verbatim by the
    /// host from the matched manifest entry.
    pub fn meta(&self, key: &str) -> Option<&str> {
        self.meta.get(key).map(String::as_str)
    }

    /// The args joined by a single space, trimmed.
    pub fn query(&self) -> String {
        self.args.join(" ").trim().to_string()
    }
}

/// A `discoverTargets` request, carrying the focused app's identity and front
/// window geometry.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct DiscoverRequest {
    #[serde(default)]
    pub bundle_id: Option<String>,
    #[serde(default)]
    pub pid: Option<i64>,
    #[serde(default)]
    pub front_window_frame: Option<Frame>,
}

/// The focused-app context attached to a [`SourceActionRequest`].
#[derive(Clone, Debug, Default, Deserialize)]
pub struct ActionContext {
    #[serde(default)]
    pub bundle_id: Option<String>,
    #[serde(default)]
    pub pid: Option<i64>,
    #[serde(default)]
    pub front_window_frame: Option<Frame>,
}

/// A `sourceAction` request (e.g. `tab_select`). `index` is set for the
/// numbered-tab actions.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct SourceActionRequest {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub context: ActionContext,
    #[serde(default)]
    pub index: Option<i64>,
}

/// A `navigation.restore` request. `url` is the route the host is trying to
/// restore from movement history.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct NavigationRequest {
    #[serde(default)]
    pub url: String,
}

/// A `candidateQuery` request from the flashlight. `query` is the current
/// residual search text after source filters have been stripped. Empty
/// `source_filters` means the user has not pinned a source; plugins may return
/// any candidate source they declared.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct CandidateQueryRequest {
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub query: String,
    #[serde(default)]
    pub source_filters: Vec<String>,
    #[serde(default)]
    pub running_applications: Vec<RunningApplication>,
}

/// An `activateTarget` notification: act on the [`JumpTarget`] the plugin
/// emitted earlier (matched by `target_id`) with the given click `action`.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct ActivateRequest {
    #[serde(default)]
    pub action: String,
    #[serde(default)]
    pub target_id: String,
}

/// A non-lifecycle request dispatched to [`Plugin::handle`].
#[derive(Clone, Debug)]
pub enum Request {
    Command(CommandRequest),
    DiscoverTargets(DiscoverRequest),
    CandidateQuery(CandidateQueryRequest),
    ResolveCandidate(Candidate),
    SourceAction(SourceActionRequest),
    RestoreNavigation(NavigationRequest),
    ActivateTarget(ActivateRequest),
    /// Any other method name the host sent. Return a
    /// [`CommandResponse::error`] for these.
    Unknown {
        method: String,
    },
}

// ---------------------------------------------------------------------------
// Outbound responses
// ---------------------------------------------------------------------------

/// Response to a `command.invoke`.
#[derive(Clone, Debug, Default, Serialize)]
pub struct CommandResponse {
    pub ok: bool,
    /// An app to raise once the command succeeds (e.g. the terminal hosting a
    /// switched-to tmux session).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_pid: Option<i64>,
    /// Durable route to record into Flash movement history.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub navigation_url: Option<String>,
    /// Text for Flash to surface as a toast.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stdout: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl CommandResponse {
    pub fn ok() -> Self {
        Self {
            ok: true,
            ..Self::default()
        }
    }

    /// A successful command whose `message` Flash shows as a toast.
    pub fn toast(message: impl Into<String>) -> Self {
        Self {
            ok: true,
            stdout: Some(message.into()),
            ..Self::default()
        }
    }

    /// A failed command. The `message` is logged; the host shows no toast.
    pub fn error(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            error: Some(message.into()),
            ..Self::default()
        }
    }

    pub fn target_pid(mut self, pid: i64) -> Self {
        self.target_pid = Some(pid);
        self
    }

    pub fn navigation_url(mut self, url: impl Into<String>) -> Self {
        self.navigation_url = Some(url.into());
        self
    }
}

/// Response to a `discoverTargets`. `targets` is always sent; `candidates` is
/// omitted to preserve the host's previously emitted candidates (send
/// `Some(vec)` — even empty — to replace them).
#[derive(Clone, Debug, Default, Serialize)]
pub struct DiscoverResponse {
    pub targets: Vec<JumpTarget>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidates: Option<Vec<Candidate>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_pid: Option<i64>,
}

impl DiscoverResponse {
    pub fn targets(targets: Vec<JumpTarget>) -> Self {
        Self {
            targets,
            ..Self::default()
        }
    }

    pub fn source_id(mut self, source_id: impl Into<String>) -> Self {
        self.source_id = Some(source_id.into());
        self
    }

    pub fn context_pid(mut self, pid: i64) -> Self {
        self.context_pid = Some(pid);
        self
    }
}

/// Response to a `resolveCandidate`.
#[derive(Clone, Debug, Default, Serialize)]
pub struct ResolveResponse {
    pub did_resolve: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_pid: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub navigation_url: Option<String>,
}

impl ResolveResponse {
    pub fn unresolved() -> Self {
        Self::default()
    }

    pub fn resolved(target_pid: Option<i64>) -> Self {
        Self {
            did_resolve: true,
            target_pid,
            navigation_url: None,
        }
    }

    pub fn navigation_url(mut self, url: impl Into<String>) -> Self {
        self.navigation_url = Some(url.into());
        self
    }
}

/// Response to a `sourceAction`.
#[derive(Clone, Debug, Default, Serialize)]
pub struct SourceActionResponse {
    pub did_perform: bool,
    /// True when this source owns the action for the request's context —
    /// even when the command itself failed. The host only falls back to a
    /// generic keystroke when the action was *unhandled*; a claimed-but-
    /// failed action must not double-fire through a synthesized key.
    pub handled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_pid: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub navigation_url: Option<String>,
}

impl SourceActionResponse {
    pub fn unhandled() -> Self {
        Self::default()
    }

    pub fn performed(target_pid: Option<i64>) -> Self {
        Self {
            did_perform: true,
            handled: true,
            target_pid,
            navigation_url: None,
        }
    }

    pub fn failed(target_pid: Option<i64>) -> Self {
        Self {
            did_perform: false,
            handled: true,
            target_pid,
            navigation_url: None,
        }
    }

    pub fn navigation_url(mut self, url: impl Into<String>) -> Self {
        self.navigation_url = Some(url.into());
        self
    }
}

/// Response to a `candidateQuery`. Omit `candidates` to tell the host to keep
/// using this plugin's existing snapshot; send `Some(vec)` (even empty) to
/// replace it with an authoritative fresh result.
#[derive(Clone, Debug, Default, Serialize)]
pub struct CandidateQueryResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidates: Option<Vec<Candidate>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_id: Option<String>,
}

impl CandidateQueryResponse {
    pub fn snapshot() -> Self {
        Self::default()
    }

    pub fn candidates(candidates: Vec<Candidate>) -> Self {
        Self {
            candidates: Some(candidates),
            ..Self::default()
        }
    }

    pub fn source_id(mut self, source_id: impl Into<String>) -> Self {
        self.source_id = Some(source_id.into());
        self
    }
}

/// What [`Plugin::handle`] returns. Build one from the matching response type
/// (or a [`CliResult`]) with `.into()`; return [`Response::None`] for
/// [`Request::ActivateTarget`], which expects no reply.
#[derive(Clone, Debug)]
pub enum Response {
    Command(CommandResponse),
    Discover(DiscoverResponse),
    CandidateQuery(CandidateQueryResponse),
    Resolve(ResolveResponse),
    SourceAction(SourceActionResponse),
    None,
}

impl Response {
    fn to_value(&self) -> Value {
        match self {
            Response::Command(r) => serde_json::to_value(r).unwrap_or(Value::Null),
            Response::Discover(r) => serde_json::to_value(r).unwrap_or(Value::Null),
            Response::CandidateQuery(r) => serde_json::to_value(r).unwrap_or(Value::Null),
            Response::Resolve(r) => serde_json::to_value(r).unwrap_or(Value::Null),
            Response::SourceAction(r) => serde_json::to_value(r).unwrap_or(Value::Null),
            Response::None => Value::Null,
        }
    }
}

impl From<CommandResponse> for Response {
    fn from(value: CommandResponse) -> Self {
        Response::Command(value)
    }
}

impl From<DiscoverResponse> for Response {
    fn from(value: DiscoverResponse) -> Self {
        Response::Discover(value)
    }
}

impl From<CandidateQueryResponse> for Response {
    fn from(value: CandidateQueryResponse) -> Self {
        Response::CandidateQuery(value)
    }
}

impl From<ResolveResponse> for Response {
    fn from(value: ResolveResponse) -> Self {
        Response::Resolve(value)
    }
}

impl From<SourceActionResponse> for Response {
    fn from(value: SourceActionResponse) -> Self {
        Response::SourceAction(value)
    }
}

impl From<CliResult> for Response {
    fn from(value: CliResult) -> Self {
        Response::Command(value.into_command())
    }
}

// ---------------------------------------------------------------------------
// Emitter / Context
// ---------------------------------------------------------------------------

/// Serializes outgoing protocol frames onto a single stdout writer task so
/// frames emitted from concurrent handlers never interleave. Cheap to clone.
#[derive(Clone)]
struct Emitter {
    tx: mpsc::UnboundedSender<Vec<u8>>,
}

impl Emitter {
    fn send(&self, value: Value) {
        if let Ok(payload) = rmp_serde::to_vec(&value) {
            let _ = self.tx.send(payload);
        }
    }

    fn notify(&self, method: &str, params: Value) {
        self.send(json!({ "jsonrpc": "2.0", "method": method, "params": params }));
    }

    fn respond(&self, id: Value, result: Value) {
        if id.is_null() {
            return;
        }
        self.send(json!({ "jsonrpc": "2.0", "id": id, "result": result }));
    }

    fn log(&self, level: &str, message: &str, fields: BTreeMap<String, String>) {
        self.notify(
            "flash.log",
            json!({ "level": level, "message": message, "fields": fields }),
        );
    }
}

/// Per-process runtime handed to every plugin callback. Holds identity, the
/// sandboxed data directory, and the wire emitter. Cheap to clone.
#[derive(Clone)]
pub struct Context {
    pub plugin_id: String,
    pub version: String,
    pub data_dir: PathBuf,
    emit: Emitter,
    /// User-supplied settings from the `[plugin.<id>]` table of
    /// `~/.config/flash`, delivered as a JSON object (empty when unset).
    config: Value,
    host_pending: HostPending,
    host_counter: Arc<AtomicU64>,
    /// Named recurring tasks owned by this plugin's runtime (see
    /// [`Context::interval`]). Re-registering the same name aborts the
    /// previous handle so plugins can adjust a schedule by re-registering it.
    intervals: Arc<Mutex<HashMap<String, JoinHandle<()>>>>,
}

impl Context {
    pub fn home_dir(&self) -> PathBuf {
        self.data_dir.join("home")
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

    /// Read typed JSON state previously written with
    /// [`write_state`](Context::write_state) under `share_dir/<name>`.
    pub fn read_state<T: DeserializeOwned>(&self, name: &str) -> Option<T> {
        let raw = std::fs::read_to_string(self.share_dir().join(name)).ok()?;
        serde_json::from_str(&raw).ok()
    }

    /// Persist `value` as JSON to `share_dir/<name>`. Returns whether it wrote.
    pub fn write_state<T: Serialize>(&self, name: &str, value: &T) -> bool {
        match serde_json::to_string(value) {
            Ok(raw) => std::fs::write(self.share_dir().join(name), raw).is_ok(),
            Err(_) => false,
        }
    }

    /// Call a host RPC method and await its JSON result. This is the channel
    /// plugins use to reach native capabilities the core owns — most notably
    /// the Accessibility (AX) broker, which holds the single TCC grant. Returns
    /// a JSON error object if the host doesn't answer in time.
    pub(crate) async fn call_host(&self, method: &str, params: Value) -> Value {
        self.call_host_timeout(method, params, Duration::from_secs(5))
            .await
    }

    pub(crate) async fn call_host_timeout(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Value {
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

    /// Query the host for the focused non-Flash app context — the same value
    /// the host treats as the "normal-mode target". Returns `None` when no
    /// such app is focused. Plugins use this when they need to capture or
    /// reactivate the user's working context across mode transitions: the
    /// `core:focus.changed` stream is insufficient because Flash itself is the
    /// focused process while normal mode is active.
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

    /// Walk a subtree of an app's Accessibility tree via the core's AX broker
    /// and return a flat list of [`AxNode`]s.
    ///
    /// - `pid`: target application.
    /// - `roots`: `"windows"` to start from the app's windows (the usual case),
    ///   or `"app"` to start from the application element itself.
    /// - `follow`: child attribute names to descend through; pass an empty
    ///   slice to use the broker's default (children + navigation order).
    /// - `collect`: attribute names to read for every visited node.
    /// - `max_nodes`: visit budget — the walk stops once this many nodes are
    ///   collected.
    /// - `geometry`: when true, each node also carries [`AxNode::frame`].
    pub async fn ax_snapshot(
        &self,
        pid: i64,
        roots: &str,
        follow: &[&str],
        collect: &[&str],
        max_nodes: u64,
        geometry: bool,
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
                    "geometry": geometry,
                }),
            )
            .await;
        result
            .get("nodes")
            .and_then(Value::as_array)
            .map(|nodes| nodes.iter().filter_map(AxNode::from_value).collect())
            .unwrap_or_default()
    }

    /// Perform an AX action (e.g. `AXPress`) on a snapshot handle. A stale
    /// handle (snapshot superseded) reports `false`.
    pub async fn ax_perform(&self, handle: u64, action: &str) -> bool {
        host_ok(
            self.call_host("ax.perform", json!({ "handle": handle, "action": action }))
                .await,
        )
    }

    /// Set an AX attribute (e.g. `AXSelected = true`) on a snapshot handle.
    pub async fn ax_set(&self, handle: u64, attribute: &str, value: impl Into<AxValue>) -> bool {
        let value = value.into();
        host_ok(
            self.call_host(
                "ax.set",
                json!({ "handle": handle, "attribute": attribute, "value": value.to_value() }),
            )
            .await,
        )
    }

    /// Bring an application's windows to the front.
    pub async fn ax_activate(&self, pid: i64) -> bool {
        host_ok(self.call_host("ax.activate", json!({ "pid": pid })).await)
    }

    /// Walk `pid`'s windows and return up to `max` AX nodes whose `AXRole`
    /// matches `role` exactly. Built on top of [`ax_snapshot`](Context::ax_snapshot);
    /// the snapshot collects only `AXRole`, so callers needing more attributes
    /// should use `ax_snapshot` directly.
    pub async fn ax_find_by_role(&self, pid: i64, role: &str, max: u64) -> Vec<AxNode> {
        self.ax_snapshot(pid, "windows", &[], &["AXRole"], max, false)
            .await
            .into_iter()
            .filter(|n| n.attr("AXRole") == Some(role))
            .collect()
    }

    /// Walk `pid`'s windows and return up to `max` AX nodes whose `AXTitle`,
    /// `AXDescription`, or `AXValue` contains `needle` (case-insensitive
    /// substring).
    pub async fn ax_find_by_text(&self, pid: i64, needle: &str, max: u64) -> Vec<AxNode> {
        let lower = needle.to_lowercase();
        self.ax_snapshot(
            pid,
            "windows",
            &[],
            &["AXRole", "AXTitle", "AXDescription", "AXValue"],
            max,
            false,
        )
        .await
        .into_iter()
        .filter(|n| {
            for attr in ["AXTitle", "AXDescription", "AXValue"] {
                if let Some(v) = n.attr(attr) {
                    if v.to_lowercase().contains(&lower) {
                        return true;
                    }
                }
            }
            false
        })
        .collect()
    }

    /// Walk `pid`'s windows and return its browser tabs, sourced from the
    /// AXTab-shaped nodes the host emits. Ports the heuristics the firefox
    /// plugin uses (`AXTab`, plus `AXRadioButton`/`AXButton` with an `AXTabButton`
    /// subrole or "tab" role description). Each tab carries the handle the
    /// plugin can pass to [`ax_perform`](Context::ax_perform) or
    /// [`ax_set`](Context::ax_set), plus extracted title/url and the owning
    /// window title.
    pub async fn ax_browser_tabs(&self, pid: i64) -> Vec<BrowserTab> {
        const COLLECT: &[&str] = &[
            "AXRole",
            "AXSubrole",
            "AXRoleDescription",
            "AXTitle",
            "AXDescription",
            "AXValue",
            "AXURL",
            "AXDocument",
        ];
        let nodes = self
            .ax_snapshot(pid, "windows", &[], COLLECT, 3_000, false)
            .await;
        let mut window_titles: Vec<String> = Vec::new();
        for node in &nodes {
            if node.attr("AXRole") == Some("AXWindow") {
                if node.root >= window_titles.len() {
                    window_titles.resize(node.root + 1, String::new());
                }
                window_titles[node.root] = node.attr("AXTitle").unwrap_or("").to_string();
            }
        }
        let mut out: Vec<BrowserTab> = Vec::new();
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        for node in nodes {
            if !is_browser_tab(&node) {
                continue;
            }
            let window_title = window_titles
                .get(node.root)
                .map(String::as_str)
                .unwrap_or("");
            let raw_title = node
                .attr("AXTitle")
                .or_else(|| node.attr("AXDescription"))
                .or_else(|| node.attr("AXValue"))
                .unwrap_or(window_title);
            let title = raw_title.trim().to_string();
            if title.is_empty() {
                continue;
            }
            let url = node
                .attr("AXURL")
                .or_else(|| node.attr("AXDocument"))
                .unwrap_or("")
                .trim()
                .to_string();
            let key = format!("{}|{title}|{url}", node.root);
            if !seen.insert(key) {
                continue;
            }
            out.push(BrowserTab {
                handle: node.handle,
                root: node.root,
                title,
                url,
                window_title: window_title.to_string(),
            });
        }
        out
    }

    /// Ask the host to trigger a TCC (privacy) permission prompt on this
    /// plugin's behalf. The only `kind` supported today is
    /// [`TccKind::AppleEvents`] for AppleEvents access to a specific target
    /// bundle id. Plugins that drive other apps via `osascript` should call
    /// this once at startup so the prompt fires up-front instead of mid-
    /// operation. Requires the `tcc.request` capability in the manifest.
    pub async fn tcc_request(&self, kind: TccKind) -> TccGrant {
        let params = match &kind {
            TccKind::AppleEvents { target_bundle_id } => json!({
                "kind": "applescript",
                "target": target_bundle_id,
            }),
        };
        let result = self.call_host("tcc.request", params).await;
        TccGrant {
            ok: result.get("ok").and_then(Value::as_bool).unwrap_or(false),
            granted: result
                .get("granted")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            denied: result
                .get("denied")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            unknown: result
                .get("unknown")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            error: result
                .get("error")
                .and_then(Value::as_str)
                .map(str::to_string),
        }
    }

    /// Ask the host to synthesize one parsed hotkey to `pid`. `keys` uses the
    /// same syntax as Flash config mappings (`e`, `cmd+r`, `shift+tab`, ...).
    /// The host owns the native CGEvent posting API; plugins only describe the
    /// key they want sent.
    pub async fn send_key(&self, pid: i64, keys: &str) -> bool {
        host_ok(
            self.call_host("input.send_key", json!({ "pid": pid, "keys": keys }))
                .await,
        )
    }

    /// Register a system-wide Carbon hotkey, identified by the plugin-chosen
    /// `id`. Re-registering the same `id` replaces the previous binding so
    /// callers can swap chords without first calling
    /// [`hotkey_unregister`](Context::hotkey_unregister). When the hotkey
    /// fires, the host emits a `core:hotkey.fired` event whose payload
    /// carries `hotkey_id` matching `id` — the plugin must declare both the
    /// `hotkey` capability and a subscription to `core:hotkey.fired` for the
    /// chord to actually reach `on_event`. Returns `false` when the spec
    /// fails to parse, Carbon refuses the chord (typically because another
    /// process already owns it), or the plugin lacks the capability.
    pub async fn hotkey_register(&self, id: &str, spec: &str) -> bool {
        host_ok(
            self.call_host("hotkey.register", json!({ "id": id, "spec": spec }))
                .await,
        )
    }

    /// Drop the registration previously installed by
    /// [`hotkey_register`](Context::hotkey_register) under `id`. No-op when
    /// `id` is unknown.
    pub async fn hotkey_unregister(&self, id: &str) -> bool {
        host_ok(
            self.call_host("hotkey.unregister", json!({ "id": id }))
                .await,
        )
    }

    /// Run an AppleScript snippet via `osascript -e` (through the sandboxed
    /// [`run_cli`](Context::run_cli)).
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

    /// Higher-level AppleScript wrapper. Substitutes `${name}` markers in
    /// `script` with [`applescript_quote`]-quoted values from `bindings`, runs
    /// the resulting script via [`run_osascript`](Context::run_osascript), then
    /// parses stdout per `parse`:
    ///
    /// - [`AppleScriptParse::Raw`] returns stdout verbatim.
    /// - [`AppleScriptParse::TabSep`] splits stdout into one row per line and
    ///   tab-separated columns (trimmed). Empty rows are dropped.
    /// - [`AppleScriptParse::Json`] tries to parse stdout as JSON.
    ///
    /// Callers that need a raw, unquoted numeral or token in the script (where
    /// quoting would break AppleScript) should `format!` it into the script
    /// before passing, and leave it out of `bindings`.
    pub async fn applescript(
        &self,
        script: &str,
        bindings: &[(&str, &str)],
        parse: AppleScriptParse,
        timeout: Duration,
    ) -> AppleScriptResult {
        let mut rendered = script.to_string();
        for (name, value) in bindings {
            let needle = format!("${{{name}}}");
            rendered = rendered.replace(&needle, &applescript_quote(value));
        }
        let cli = self.run_osascript(&rendered, timeout).await;
        let mut result = AppleScriptResult {
            ok: cli.ok,
            stdout: cli.stdout,
            stderr: cli.stderr,
            status: cli.status,
            rows: Vec::new(),
            json: None,
        };
        match parse {
            AppleScriptParse::Raw => {}
            AppleScriptParse::TabSep => {
                for line in result.stdout.lines() {
                    let cols: Vec<String> =
                        line.split('\t').map(|c| c.trim().to_string()).collect();
                    if cols.iter().any(|c| !c.is_empty()) {
                        result.rows.push(cols);
                    }
                }
            }
            AppleScriptParse::Json => {
                result.json = serde_json::from_str(result.stdout.trim()).ok();
            }
        }
        result
    }

    /// Emit a `snapshot.updated` notification carrying `candidates` (and no
    /// jump targets) for `source_id`.
    pub fn emit_snapshot(&self, source_id: &str, candidates: Vec<Candidate>) {
        let candidates: Vec<Value> = candidates
            .iter()
            .filter_map(|c| serde_json::to_value(c).ok())
            .collect();
        self.emit.notify(
            "snapshot.updated",
            json!({ "targets": [], "candidates": candidates, "source_id": source_id }),
        );
    }

    /// Apply an incremental change to a candidate source. `upsert` replaces or
    /// inserts candidates keyed by `Candidate.id` (falling back to `title`
    /// when `id` is absent); `remove` evicts candidates matching the listed
    /// ids. Use this instead of [`emit_snapshot`](Context::emit_snapshot)
    /// when the plugin owns a long-lived list whose authoring cost dominates
    /// republishing it on every change — `media`/`spotify`/`processes` are
    /// the canonical cases. Sending an empty `upsert` and `remove` is a
    /// no-op the host drops without churn.
    pub fn emit_candidate_delta(
        &self,
        source_id: &str,
        upsert: Vec<Candidate>,
        remove: Vec<String>,
    ) {
        if upsert.is_empty() && remove.is_empty() {
            return;
        }
        let upsert_values: Vec<Value> = upsert
            .iter()
            .filter_map(|c| serde_json::to_value(c).ok())
            .collect();
        self.emit.notify(
            "snapshot.delta",
            json!({
                "source_id": source_id,
                "upsert": upsert_values,
                "remove": remove,
            }),
        );
    }

    /// Publish status-bar segment values declared by this plugin's
    /// `providers[]` `status` entry. The host exposes each value as
    /// `#{plugin:<plugin-id>.<segment>}` in `[statusbar].template`.
    pub fn emit_status_segments<I, K, V>(&self, segments: I)
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<str>,
        V: AsRef<str>,
    {
        let mut object = serde_json::Map::new();
        for (name, value) in segments {
            let name = name.as_ref().trim();
            let value = value.as_ref().trim();
            if !name.is_empty() && !value.is_empty() {
                object.insert(name.to_string(), json!(value));
            }
        }
        self.emit
            .notify("status.updated", json!({ "segments": object }));
    }

    pub fn log(&self, level: &str, message: &str) {
        self.emit.log(level, message, BTreeMap::new());
    }

    /// Run `handler` every `period`, sleeping for `period` between iterations.
    /// Re-registering with the same `name` aborts the previous handle so
    /// callers can swap schedules without leaking tasks. The schedule is owned
    /// by this plugin's tokio runtime and runs until the process exits or
    /// [`cancel_interval`](Context::cancel_interval) is called. Sleep-first
    /// semantics: the handler is invoked after the first `period` has elapsed,
    /// so plugins that also want an immediate refresh should call the work
    /// directly in `on_start` before registering the interval.
    pub fn interval<F, Fut>(&self, name: &str, period: Duration, handler: F)
    where
        F: Fn(Context) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let ctx = self.clone();
        let handle = tokio::spawn(async move {
            loop {
                tokio::time::sleep(period).await;
                handler(ctx.clone()).await;
            }
        });
        if let Ok(mut intervals) = self.intervals.lock() {
            if let Some(previous) = intervals.insert(name.to_string(), handle) {
                previous.abort();
            }
        }
    }

    /// Cancel the interval previously registered under `name`. No-op when the
    /// name is unknown.
    pub fn cancel_interval(&self, name: &str) {
        if let Ok(mut intervals) = self.intervals.lock() {
            if let Some(handle) = intervals.remove(name) {
                handle.abort();
            }
        }
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
    /// and emits one structured log line per call.
    pub async fn run_cli(&self, argv: &[String], timeout: Duration) -> CliResult {
        self.run_cli_inner(argv, timeout, false).await
    }

    /// Same as [`run_cli`](Context::run_cli) but asks the core to skip the
    /// per-call log line.
    pub async fn run_cli_quiet(&self, argv: &[String], timeout: Duration) -> CliResult {
        self.run_cli_inner(argv, timeout, true).await
    }

    async fn run_cli_inner(&self, argv: &[String], timeout: Duration, quiet: bool) -> CliResult {
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

/// Read the `ok` flag from a host RPC response, defaulting to `false`.
fn host_ok(response: Value) -> bool {
    response.get("ok").and_then(Value::as_bool).unwrap_or(false)
}

/// Quote a string as an AppleScript literal, escaping backslashes and double
/// quotes. Use for any value interpolated into an `osascript` snippet.
pub fn applescript_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
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

/// Run a command in the plugin's *own* process environment (NOT the sandbox),
/// bounded by `timeout`. Use this only when a plugin genuinely needs the user's
/// real environment — e.g. the tmux CLI talking to the user's server socket.
/// Prefer [`Context::run_cli`] otherwise.
pub async fn run_local(argv: &[String], timeout: Duration) -> CliResult {
    let Some((program, args)) = argv.split_first() else {
        return CliResult {
            ok: false,
            stderr: "empty argv".to_string(),
            status: -1,
            ..CliResult::default()
        };
    };
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    match tokio::time::timeout(timeout, command.output()).await {
        Ok(Ok(output)) => CliResult {
            ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            status: output.status.code().unwrap_or(-1),
        },
        Ok(Err(err)) => CliResult {
            ok: false,
            stderr: err.to_string(),
            status: -1,
            ..CliResult::default()
        },
        Err(_) => CliResult {
            ok: false,
            stderr: "timed out".to_string(),
            status: 124,
            ..CliResult::default()
        },
    }
}

/// Run a background task on the plugin runtime. Prefer this SDK helper over a
/// direct tokio dependency in plugins; it keeps runtime ownership centralized
/// in `flash_plugin`.
pub fn spawn_background<F>(future: F)
where
    F: Future<Output = ()> + Send + 'static,
{
    tokio::spawn(future);
}

/// Sleep on the plugin runtime timer. Used by polling fallbacks when a source
/// has no lighter host event stream.
pub async fn sleep(duration: Duration) {
    tokio::time::sleep(duration).await;
}

// ---------------------------------------------------------------------------
// Plugin trait + runtime
// ---------------------------------------------------------------------------

/// A Flash plugin. Implement [`handle`](Plugin::handle) for the request methods
/// the plugin understands; override the lifecycle hooks as needed. Every method
/// returns a `Send` future so the runtime can drive handlers concurrently
/// without blocking the heartbeat/serve loop.
pub trait Plugin: Send + Sync + 'static {
    /// Called once after `initialize`, on a background task. Use it to seed an
    /// initial snapshot or kick off provisioning.
    fn on_start(&self, ctx: Context) -> impl Future<Output = ()> + Send {
        let _ = ctx;
        async {}
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
        intervals: Arc::new(Mutex::new(HashMap::new())),
    }
}

/// Run the plugin: spin up a multi-thread tokio runtime and serve the
/// length-prefixed MessagePack protocol until `shutdown` or stdin closes. This
/// is the single entry point a plugin's `main` calls.
pub fn run<P: Plugin>(plugin: P) {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("flash-plugin: tokio runtime");
    runtime.block_on(serve(plugin));
}

/// Decode `params` into a typed request payload, falling back to its default
/// when the shape doesn't match (so a malformed frame degrades to an empty
/// request rather than a panic).
fn decode<T: DeserializeOwned + Default>(params: Value) -> T {
    serde_json::from_value(params).unwrap_or_default()
}

async fn serve<P: Plugin>(plugin: P) {
    let plugin = Arc::new(plugin);
    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let writer = tokio::spawn(async move {
        // 64 KiB buffer coalesces the 4-byte header and payload into one write
        // syscall per frame; we flush every frame to keep latency low.
        let mut out = BufWriter::with_capacity(64 * 1024, tokio::io::stdout());
        while let Some(payload) = rx.recv().await {
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
    let ctx = context_from_env(Emitter { tx }, host_pending.clone(), host_counter);
    ctx.prepare_dirs();
    ctx.log("info", "[plugin] process ready");

    {
        let plugin = plugin.clone();
        let ctx = ctx.clone();
        tokio::spawn(async move { plugin.on_start(ctx).await });
    }

    let mut stdin = tokio::io::stdin();
    let mut len_buf = [0u8; 4];
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
        let mut payload = vec![0u8; len];
        if stdin.read_exact(&mut payload).await.is_err() {
            break;
        }
        let Ok(request) = rmp_serde::from_slice::<Value>(&payload) else {
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
                let event = Event::from_params(params);
                ctx.emit.respond(id, json!({ "ok": true }));
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                tokio::spawn(async move { plugin.on_event(ctx, event).await });
            }
            "activateTarget" => {
                // Notification: dispatch through `handle`, never respond.
                let request = Request::ActivateTarget(decode(params));
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                tokio::spawn(async move {
                    plugin.handle(ctx, request).await;
                });
            }
            other => {
                let request = match other {
                    "command.invoke" => Request::Command(decode(params)),
                    "discoverTargets" => Request::DiscoverTargets(decode(params)),
                    "candidateQuery" => Request::CandidateQuery(decode(params)),
                    "resolveCandidate" => Request::ResolveCandidate(decode(
                        params
                            .get("candidate")
                            .cloned()
                            .unwrap_or_else(|| json!({})),
                    )),
                    "sourceAction" => Request::SourceAction(decode(params)),
                    "navigation.restore" => Request::RestoreNavigation(decode(params)),
                    _ => Request::Unknown {
                        method: other.to_string(),
                    },
                };
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                tokio::spawn(async move {
                    let response = plugin.handle(ctx.clone(), request).await;
                    ctx.emit.respond(id, response.to_value());
                });
            }
        }
    }

    // Drop the last emitter handle so the writer task can drain and flush any
    // queued frames (notably the shutdown response) before we exit.
    drop(ctx);
    let _ = writer.await;
}
