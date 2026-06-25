//! Strongly-typed tokio scaffolding for Flash plugins.
//!
//! This crate speaks the length-prefixed MessagePack wire protocol over
//! stdin/stdout — a 4-byte big-endian payload length followed by a
//! MessagePack-encoded value — plus request/response correlation, the
//! `initialize`/`heartbeat`/`shutdown` lifecycle, and structured logging.
//! Everything a plugin touches is a typed value: a plugin receives a
//! [`Request`] / [`Event`] and returns a [`Response`].

use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufWriter};
use tokio::sync::{mpsc, oneshot};

/// Generate the typed plugin surface from `manifest.json` at compile time. See
/// the `flash_plugin_macros` crate. Invoke as `flash_plugin::plugin!(MyPlugin);`
/// then write `impl FlashPlugin for MyPlugin { … }`.
pub use flash_plugin_macros::plugin;

/// Shared registry of in-flight plugin→host calls, keyed by the request id the
/// plugin assigned. The serve loop fulfils each entry when the matching host
/// response arrives. Cloned into [`Context`] so any handler can call the host.
type HostPending = Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>;

/// Warm in-memory location store, keyed by `source_id`. Plugins keep their
/// locations here via [`Context::set_locations`]; the generated
/// `candidate_query` default serves the union back to the host on demand. This
/// is the pull model — the host holds no candidate cache of its own. Cloned
/// into [`Context`] (an `Arc`), so an `on_event` write is visible to the next
/// `candidateQuery`.
type WarmLocations = Arc<Mutex<HashMap<String, Vec<Candidate>>>>;

const MAX_FRAME_BYTES: usize = 10 * 1024 * 1024;

/// Wire-protocol version negotiated in `initialize`: the host sends the version
/// it speaks, this SDK echoes the version it was built against, and a mismatch
/// is logged (not fatal) so a renamed/removed field surfaces as drift rather
/// than silently decoding to a default. Bump on any breaking wire change. MUST
/// stay in sync with `PluginProcess.protocolVersion` on the host.
const PROTOCOL_VERSION: u32 = 1;

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

    /// Build a `Frame` from a `[x, y, w, h]` rect.
    pub fn from_ax(rect: [f64; 4]) -> Self {
        Self::new(rect[0], rect[1], rect[2], rect[3])
    }
}

impl From<[f64; 4]> for Frame {
    fn from(rect: [f64; 4]) -> Self {
        Self::from_ax(rect)
    }
}

/// Shared source salience used by candidate rows, candidate source
/// declarations, and hint targets.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Priority {
    Background,
    Low,
    #[default]
    Normal,
    High,
    Critical,
}

impl Priority {
    pub fn as_str(self) -> &'static str {
        match self {
            Priority::Background => "background",
            Priority::Low => "low",
            Priority::Normal => "normal",
            Priority::High => "high",
            Priority::Critical => "critical",
        }
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
    /// Source-declared salience. `Critical` renders with the host's accent hint
    /// style.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<Priority>,
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
            priority: None,
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

    pub fn priority(mut self, priority: Priority) -> Self {
        if priority == Priority::Normal {
            self.priority = None;
        } else {
            self.priority = Some(priority);
        }
        self
    }
}

/// A flashlight candidate. Outbound (emitted via [`Context::set_locations`])
/// only `title` is required. Inbound (on [`Request::ResolveCandidate`]) the
/// host echoes back the candidate with the same shape — read structured
/// payload via [`payload_str`](Candidate::payload_str) /
/// [`payload_as`](Candidate::payload_as).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Candidate {
    /// Primary searchable string the host scores against and shows in the
    /// candidate bar — also the highest-precedence ranking field.
    pub title: String,
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
    pub const ENTITY: &str = "entity";
    pub const PID: &str = "pid";
    pub const NAVIGATION_URL: &str = "navigation_url";
    pub const BUNDLE_ID: &str = "bundle_id";
    pub const SUBTITLE: &str = "subtitle";
    pub const PAYLOAD: &str = "payload";
    pub const ALIASES: &str = "aliases";
    pub const FINISHES_COMMAND: &str = "finishes_command";
    pub const CURRENT_LOCATION: &str = "current_location";
    pub const PRIORITY: &str = "priority";
}

impl Candidate {
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            url: None,
            metadata: HashMap::new(),
        }
    }

    fn set(mut self, key: &str, value: impl Into<String>) -> Self {
        self.metadata.insert(key.to_string(), value.into());
        self
    }

    pub fn kind(self, kind: impl Into<String>) -> Self {
        self.set(candidate_metadata::KIND, kind)
    }

    pub fn entity(self, entity: impl Into<String>) -> Self {
        self.set(candidate_metadata::ENTITY, entity)
    }

    /// Mark this candidate as a navigable location. Location candidates are
    /// included in the default flashlight pool and recorded by movement history.
    pub fn location(self) -> Self {
        self.entity("location")
    }

    /// Mark this location as the source's currently focused/active destination.
    /// The host uses this to feed movement history from ambient app/window focus
    /// changes such as Cmd+Tab or Cmd+`.
    pub fn current_location(self, value: bool) -> Self {
        if value {
            self.set(candidate_metadata::CURRENT_LOCATION, "1")
        } else {
            let mut me = self;
            me.metadata.remove(candidate_metadata::CURRENT_LOCATION);
            me
        }
    }

    /// Source-provided rank nudge used only as a same-band, same-score
    /// tiebreaker by the host. Keep this semantic and domain-neutral:
    /// "active" or "attention-worthy" rows can use it without
    /// creating plugin-specific source kinds.
    pub fn priority(self, priority: Priority) -> Self {
        if priority == Priority::Normal {
            let mut me = self;
            me.metadata.remove(candidate_metadata::PRIORITY);
            me
        } else {
            self.set(candidate_metadata::PRIORITY, priority.as_str())
        }
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

// ---------------------------------------------------------------------------
// Inbound requests / events
// ---------------------------------------------------------------------------

/// One running regular app visible to Flash. Used by `core:apps.changed` and
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
/// search text for plugins that intentionally serve live query-dependent
/// results.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct CandidateQueryRequest {
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub query: String,
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
/// using this plugin's existing warm locations; send `Some(vec)` (even empty)
/// to replace them with an authoritative fresh result.
#[derive(Clone, Debug, Default, Serialize)]
pub struct CandidateQueryResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidates: Option<Vec<Candidate>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_id: Option<String>,
}

impl CandidateQueryResponse {
    pub fn keep() -> Self {
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
/// with `.into()`; return [`Response::None`] for [`Request::ActivateTarget`],
/// which expects no reply.
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
            if payload.len() > MAX_FRAME_BYTES {
                return;
            }
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
    locations: WarmLocations,
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

    /// Call a host RPC method and await its JSON result. This is the channel
    /// plugins use to reach native capabilities the core explicitly exposes.
    /// Returns a JSON error object if the host doesn't answer in time.
    pub async fn call_host(&self, method: &str, params: Value) -> Value {
        self.call_host_timeout(method, params, Duration::from_secs(5))
            .await
    }

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

    /// Store this plugin's warm locations for `source_id`, replacing any
    /// previous set. Nothing is sent to the host — the plugin owns its
    /// locations in memory and the host pulls them via `candidateQuery` (served
    /// by the generated `candidate_query` default from [`warm_locations`]). Call
    /// it whenever the plugin's locations change (`on_start`, `on_event`, polls).
    ///
    /// Passing an empty vector clears the source. A source whose refresh can
    /// transiently fail (e.g. an AX read that comes back empty) should guard
    /// against overwriting a good set with an empty one at the call site, the
    /// same way it did before this was a pull (see `Plugins/firefox/src/main.rs`).
    ///
    /// [`warm_locations`]: Context::warm_locations
    pub fn set_locations(&self, source_id: &str, candidates: Vec<Candidate>) {
        if let Ok(mut store) = self.locations.lock() {
            store.insert(source_id.to_string(), candidates);
        }
    }

    /// The union of every warm location set this plugin has published, ordered
    /// by `source_id` for determinism. The generated `candidate_query` default
    /// returns this; the host applies its own fuzzy narrowing against the query.
    pub fn warm_locations(&self) -> Vec<Candidate> {
        let Ok(store) = self.locations.lock() else {
            return Vec::new();
        };
        let mut entries: Vec<(&String, &Vec<Candidate>)> = store.iter().collect();
        entries.sort_by(|a, b| a.0.cmp(b.0));
        entries
            .into_iter()
            .flat_map(|(_, candidates)| candidates.iter().cloned())
            .collect()
    }

    /// Publish status-bar segment values declared by this plugin's
    /// `status` manifest section. The host exposes each value as
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

    pub fn log_fields(&self, level: &str, message: &str, fields: BTreeMap<String, String>) {
        self.emit.log(level, message, fields);
    }

    async fn prepare_dirs(&self) {
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
            poll_parent_exit(parent_pid);
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
            poll_parent_exit(parent_pid);
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
                    poll_parent_exit(parent_pid);
                    return;
                }
            }
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn wait_for_parent_exit(parent_pid: i32) {
    poll_parent_exit(parent_pid);
}

fn poll_parent_exit(parent_pid: i32) {
    loop {
        let missing = unsafe { libc::kill(parent_pid, 0) == -1 }
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
        if missing {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
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
        locations: Arc::new(Mutex::new(HashMap::new())),
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

/// Decode `params` into a typed request payload, falling back to its default
/// when the shape doesn't match (so a malformed frame degrades to an empty
/// request rather than a panic).
fn decode<T: DeserializeOwned + Default>(params: Value, ctx: &Context, what: &str) -> T {
    match serde_json::from_value::<T>(params) {
        Ok(value) => value,
        Err(err) => {
            // Don't silently fall back to a default — a renamed/removed field
            // would otherwise make the handler run on empty params with no
            // signal. Surface it through the host's structured log channel.
            ctx.log(
                "warn",
                &format!("[plugin] could not decode {what} params ({err}); using defaults"),
            );
            T::default()
        }
    }
}

async fn serve<P: Plugin>(plugin: P) {
    let plugin = Arc::new(plugin);
    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let writer = tokio::spawn(async move {
        // 64 KiB buffer coalesces the 4-byte header and payload into one write
        // syscall per frame; we flush every frame to keep latency low.
        let mut out = BufWriter::with_capacity(64 * 1024, tokio::io::stdout());
        while let Some(payload) = rx.recv().await {
            if payload.len() > MAX_FRAME_BYTES {
                continue;
            }
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
    ctx.prepare_dirs().await;
    start_parent_liveness_watch();
    ctx.log("info", "[plugin] process ready");

    let mut stdin = tokio::io::stdin();
    let mut len_buf = [0u8; 4];
    let mut started = false;
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
                if let Some(host_version) = params.get("protocol_version").and_then(Value::as_u64) {
                    if host_version != u64::from(PROTOCOL_VERSION) {
                        ctx.log(
                            "warn",
                            &format!(
                                "[plugin] protocol_version mismatch: host v{host_version}, \
                                 plugin v{PROTOCOL_VERSION} — wire contract may have drifted"
                            ),
                        );
                    }
                }
                ctx.emit.respond(
                    id,
                    json!({ "ok": true, "protocol_version": PROTOCOL_VERSION }),
                );
                if !started {
                    started = true;
                    let plugin = plugin.clone();
                    let ctx = ctx.clone();
                    tokio::spawn(async move { plugin.on_start(ctx).await });
                }
            }
            "heartbeat" => ctx.emit.respond(id, json!({ "ok": true })),
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
                let request = Request::ActivateTarget(decode(params, &ctx, "activateTarget"));
                let plugin = plugin.clone();
                let ctx = ctx.clone();
                tokio::spawn(async move {
                    plugin.handle(ctx, request).await;
                });
            }
            other => {
                let request = match other {
                    "command.invoke" => Request::Command(decode(params, &ctx, "command.invoke")),
                    "discoverTargets" => {
                        Request::DiscoverTargets(decode(params, &ctx, "discoverTargets"))
                    }
                    "candidateQuery" => {
                        Request::CandidateQuery(decode(params, &ctx, "candidateQuery"))
                    }
                    "resolveCandidate" => Request::ResolveCandidate(decode(
                        params
                            .get("candidate")
                            .cloned()
                            .unwrap_or_else(|| json!({})),
                        &ctx,
                        "resolveCandidate",
                    )),
                    "sourceAction" => Request::SourceAction(decode(params, &ctx, "sourceAction")),
                    "navigation.restore" => {
                        Request::RestoreNavigation(decode(params, &ctx, "navigation.restore"))
                    }
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
