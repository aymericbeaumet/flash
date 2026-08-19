//! Core value types crossing the plugin↔host wire: candidates, hint targets,
//! inbound request/event payloads, outbound responses, and their builders.

use std::collections::{BTreeMap, HashMap};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::limits::{validate_catalog_candidates, validate_query_answers, BoundaryViolation};

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
    Low,
    #[default]
    Normal,
    High,
    Important,
    Urgent,
}

impl Priority {
    pub fn as_str(self) -> &'static str {
        match self {
            Priority::Low => "low",
            Priority::Normal => "normal",
            Priority::High => "high",
            Priority::Important => "important",
            Priority::Urgent => "urgent",
        }
    }
}

/// A hint target a plugin emits for the `f` family. `frame` positions the hint
/// label and the host delivers committed clicks directly to the owning app.
/// Optional fields are omitted from the wire when unset.
pub const TERMINAL_LINK_ROLE: &str = "FlashTerminalLink";

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
    /// Source-declared salience. `Important` and `Urgent` render with the
    /// host's accent hint style.
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

    pub fn priority(mut self, priority: Priority) -> Self {
        if priority == Priority::Normal {
            self.priority = None;
        } else {
            self.priority = Some(priority);
        }
        self
    }
}

/// A flashlight candidate. Outbound (emitted via
/// [`Context::set_locations`](crate::Context::set_locations)) only `title` is
/// required. Inbound (on [`Request::ResolveCandidate`]) the host echoes back
/// the candidate with the same shape — read structured payload via
/// [`payload_str`](Candidate::payload_str) /
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
    /// Explicit user-triggered effect the host validates and performs when this
    /// row is selected. Evaluation/rendering never executes it.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub effect: Option<CandidateEffect>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CandidateEffect {
    CopyText { text: String },
}

/// Narrow output from a pure query evaluator. Evaluators cannot manufacture
/// catalog/navigation metadata, URLs, pids, priorities, or routing ownership;
/// the host stamps all of those fields and only accepts this closed answer
/// shape.
#[derive(Clone, Debug, Serialize)]
pub struct QueryAnswer {
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    pub effect: CandidateEffect,
}

impl QueryAnswer {
    pub fn copy_text(title: impl Into<String>, subtitle: Option<impl Into<String>>) -> Self {
        let title = title.into();
        Self {
            effect: CandidateEffect::CopyText {
                text: title.clone(),
            },
            title,
            subtitle: subtitle.map(Into::into),
        }
    }
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
            effect: None,
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

    /// Copy `text` only after the user selects this candidate. The host owns
    /// pasteboard access; the plugin performs no clipboard I/O.
    pub fn copy_text(mut self, text: impl Into<String>) -> Self {
        self.effect = Some(CandidateEffect::CopyText { text: text.into() });
        self
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

// ---------------------------------------------------------------------------
// Inbound requests / events
// ---------------------------------------------------------------------------

/// One running regular app visible to Flash. The SDK owns one current snapshot:
/// it is initialized by the handshake and replaced atomically before each
/// serialized `core:apps.changed` callback.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct RunningApplication {
    #[serde(default)]
    pub bundle_id: String,
    #[serde(default)]
    pub pid: i64,
    #[serde(default)]
    pub localized_name: String,
}

/// A host event delivered to [`Plugin::on_event`](crate::Plugin::on_event).
/// Match on [`name`](Event::name) (`core:focus.changed`,
/// `core:clipboard.changed`, …); the remaining fields are the event payload,
/// present when the event carries them.
#[derive(Clone, Debug, Default)]
pub struct Event {
    pub name: String,
    pub bundle_id: Option<String>,
    pub pid: Option<i64>,
    pub front_window_frame: Option<Frame>,
    pub text: Option<String>,
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

/// A `hints.discover` request, carrying the focused app's identity and front
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

/// A `source.action` request (e.g. `tab_select`). `index` is set for the
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

/// One exact input sent to a pure query evaluator. Implementations must only
/// parse/compute against immutable in-memory state.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct QueryEvaluateRequest {
    #[serde(default)]
    pub surface: String,
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub query: String,
}

/// A non-lifecycle request dispatched to [`Plugin::handle`](crate::Plugin::handle).
#[derive(Clone, Debug)]
pub enum Request {
    Command(CommandRequest),
    DiscoverTargets(DiscoverRequest),
    ResolveCandidate(Candidate),
    SourceAction(SourceActionRequest),
    RestoreNavigation(NavigationRequest),
    QueryEvaluate(QueryEvaluateRequest),
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

/// Response to `hints.discover`. `targets` is always sent; `candidates` is
/// omitted to preserve the host's previously emitted candidates (send
/// `Some(vec)` — even empty — to replace them).
#[derive(Clone, Debug, Default, Serialize)]
pub struct DiscoverResponse {
    pub targets: Vec<JumpTarget>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidates: Option<Vec<Candidate>>,
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

    pub fn context_pid(mut self, pid: i64) -> Self {
        self.context_pid = Some(pid);
        self
    }
}

/// Response to `candidate.resolve`.
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

/// Response to `source.action`.
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

/// Runtime-owned response to `sources.snapshot`. Plugins publish into
/// [`Context`](crate::Context) during lifecycle callbacks; they cannot
/// override snapshot gathering or put I/O on this path.
#[derive(Clone, Debug, Default, Serialize)]
pub(crate) struct SourceSnapshotResponse {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub candidates: Option<Vec<Candidate>>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct QueryEvaluateResponse {
    pub answers: Vec<QueryAnswer>,
}

impl QueryEvaluateResponse {
    pub fn answers(answers: Vec<QueryAnswer>) -> Self {
        Self { answers }
    }
}

impl SourceSnapshotResponse {
    pub(crate) fn candidates(candidates: Vec<Candidate>) -> Self {
        Self {
            candidates: Some(candidates),
        }
    }
}

/// What [`Plugin::handle`](crate::Plugin::handle) returns. Build one from the
/// matching response type with `.into()`.
#[derive(Clone, Debug)]
pub enum Response {
    Command(CommandResponse),
    Discover(DiscoverResponse),
    Resolve(ResolveResponse),
    SourceAction(SourceActionResponse),
    QueryEvaluate(QueryEvaluateResponse),
    None,
}

impl Response {
    pub(crate) fn validate_boundary(&self) -> Result<(), BoundaryViolation> {
        match self {
            Response::Discover(response) => {
                if let Some(candidates) = &response.candidates {
                    validate_catalog_candidates(candidates)?;
                }
            }
            Response::QueryEvaluate(response) => validate_query_answers(&response.answers)?,
            Response::Command(_)
            | Response::Resolve(_)
            | Response::SourceAction(_)
            | Response::None => {}
        }
        Ok(())
    }

    pub(crate) fn to_value(&self) -> Result<Value, &'static str> {
        let value = match self {
            Response::Command(response) => serde_json::to_value(response),
            Response::Discover(response) => serde_json::to_value(response),
            Response::Resolve(response) => serde_json::to_value(response),
            Response::SourceAction(response) => serde_json::to_value(response),
            Response::QueryEvaluate(response) => serde_json::to_value(response),
            Response::None => return Ok(Value::Null),
        };
        value.map_err(|_| "plugin response could not be encoded")
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

impl From<QueryEvaluateResponse> for Response {
    fn from(value: QueryEvaluateResponse) -> Self {
        Response::QueryEvaluate(value)
    }
}
