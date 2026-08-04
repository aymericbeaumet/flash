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
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt, BufWriter};
use tokio::sync::{mpsc, oneshot, watch};

#[path = "../../_bounded_process.rs"]
mod bounded_process;

/// Generate the typed plugin surface from `manifest.json` at compile time. See
/// the `flash_plugin_macros` crate. Invoke as `flash_plugin::plugin!(MyPlugin);`
/// then write `impl FlashPlugin for MyPlugin { … }`.
pub use flash_plugin_macros::plugin;

/// Shared registry of in-flight plugin→host calls, keyed by the request id the
/// plugin assigned. The serve loop fulfils each entry when the matching host
/// response arrives. Cloned into [`Context`] so any handler can call the host.
type HostPending = Arc<Mutex<HashMap<u64, oneshot::Sender<Value>>>>;

/// Warm in-memory location store, keyed by `source_id`. Plugins keep their
/// locations here via [`Context::set_locations`]; the SDK runtime serves the
/// union directly for `sources.snapshot`, so plugin code cannot put I/O on the
/// catalog-gathering path. This is the pull model — the host holds no candidate
/// cache of its own. Cloned into [`Context`] (an `Arc`), so an `on_event` write
/// is visible to the next `sources.snapshot`.
type WarmLocations = Arc<Mutex<HashMap<String, Arc<Vec<Candidate>>>>>;

const MAX_FRAME_BYTES: usize = 10 * 1024 * 1024;
const MAX_TELEMETRY_FRAME_BYTES: usize = 256 * 1024;
const CONTROL_QUEUE_CAPACITY: usize = 64;
const TELEMETRY_QUEUE_CAPACITY: usize = 128;
const EVENT_QUEUE_CAPACITY: usize = 256;
const EVENT_HANDLER_WARN_AFTER: Duration = Duration::from_secs(1);
const EVENT_HANDLER_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_CATALOG_CANDIDATES: usize = 10_000;
const MAX_CATALOG_ENCODED_BYTES: usize = 4 * 1024 * 1024;
const MAX_QUERY_ANSWERS: usize = 16;
const MAX_QUERY_ENCODED_BYTES: usize = 256 * 1024;
const MAX_CANDIDATE_TITLE_BYTES: usize = 4 * 1024;
const MAX_CANDIDATE_URL_BYTES: usize = 16 * 1024;
const MAX_CANDIDATE_METADATA_ENTRIES: usize = 64;
const MAX_CANDIDATE_METADATA_KEY_BYTES: usize = 256;
const MAX_CANDIDATE_METADATA_VALUE_BYTES: usize = 64 * 1024;
const MAX_CANDIDATE_EFFECT_BYTES: usize = 64 * 1024;
const MAX_QUERY_FIELD_BYTES: usize = 16 * 1024;
const COMMAND_STDOUT_LIMIT: usize = 4 * 1024 * 1024;
const COMMAND_STDERR_LIMIT: usize = 256 * 1024;

/// Wire-protocol version negotiated in `initialize`. A mismatch is fatal: the
/// host and plugin must agree on lifecycle and payload semantics before the
/// plugin can become ready. Bump on any breaking wire change. MUST stay in sync
/// with `PluginProcess.protocolVersion` on the host.
const PROTOCOL_VERSION: u32 = 2;

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
    /// When `true`, the host should drop the plugin-side `activate` path
    /// (which fires a `target.action` RPC and races with subsequent
    /// keystrokes — `tmux select-pane` for example is async by nature)
    /// and instead synthesize a real mouse click at the target's frame.
    /// The click propagates through the windowing system atomically,
    /// reaches the underlying app (alacritty → tmux mouse mode for
    /// panes), and is observed *before* Flash forwards anything else.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prefer_host_click: Option<bool>,
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct BoundaryViolation {
    boundary: &'static str,
    rule: &'static str,
    item_index: Option<usize>,
    actual: usize,
    limit: usize,
}

impl BoundaryViolation {
    fn new(
        boundary: &'static str,
        rule: &'static str,
        item_index: Option<usize>,
        actual: usize,
        limit: usize,
    ) -> Self {
        Self {
            boundary,
            rule,
            item_index,
            actual,
            limit,
        }
    }

    fn log_fields(&self) -> BTreeMap<String, String> {
        let mut fields = BTreeMap::from([
            ("boundary".to_string(), self.boundary.to_string()),
            ("rule".to_string(), self.rule.to_string()),
            ("actual".to_string(), self.actual.to_string()),
            ("limit".to_string(), self.limit.to_string()),
        ]);
        if let Some(index) = self.item_index {
            fields.insert("item_index".to_string(), index.to_string());
        }
        fields
    }
}

#[derive(Serialize)]
struct CatalogCandidatesRef<'a> {
    candidates: &'a [Candidate],
}

#[derive(Serialize)]
struct QueryAnswersRef<'a> {
    answers: &'a [QueryAnswer],
}

fn reject_oversized_field(
    boundary: &'static str,
    rule: &'static str,
    item_index: usize,
    actual: usize,
    limit: usize,
) -> Result<(), BoundaryViolation> {
    if actual <= limit {
        Ok(())
    } else {
        Err(BoundaryViolation::new(
            boundary,
            rule,
            Some(item_index),
            actual,
            limit,
        ))
    }
}

fn add_aggregate_bytes(
    total: &mut usize,
    additional: usize,
    boundary: &'static str,
    item_index: usize,
    limit: usize,
) -> Result<(), BoundaryViolation> {
    *total = total.checked_add(additional).ok_or_else(|| {
        BoundaryViolation::new(
            boundary,
            "aggregate_string_bytes",
            Some(item_index),
            usize::MAX,
            limit,
        )
    })?;
    if *total > limit {
        return Err(BoundaryViolation::new(
            boundary,
            "aggregate_string_bytes",
            Some(item_index),
            *total,
            limit,
        ));
    }
    Ok(())
}

fn validate_catalog_candidates(candidates: &[Candidate]) -> Result<(), BoundaryViolation> {
    if candidates.len() > MAX_CATALOG_CANDIDATES {
        return Err(BoundaryViolation::new(
            "catalog",
            "candidate_count",
            None,
            candidates.len(),
            MAX_CATALOG_CANDIDATES,
        ));
    }

    let mut aggregate_string_bytes = 0usize;
    for (index, candidate) in candidates.iter().enumerate() {
        reject_oversized_field(
            "catalog",
            "title_bytes",
            index,
            candidate.title.len(),
            MAX_CANDIDATE_TITLE_BYTES,
        )?;
        add_aggregate_bytes(
            &mut aggregate_string_bytes,
            candidate.title.len(),
            "catalog",
            index,
            MAX_CATALOG_ENCODED_BYTES,
        )?;

        if let Some(url) = &candidate.url {
            reject_oversized_field(
                "catalog",
                "url_bytes",
                index,
                url.len(),
                MAX_CANDIDATE_URL_BYTES,
            )?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                url.len(),
                "catalog",
                index,
                MAX_CATALOG_ENCODED_BYTES,
            )?;
        }

        if candidate.metadata.len() > MAX_CANDIDATE_METADATA_ENTRIES {
            return Err(BoundaryViolation::new(
                "catalog",
                "metadata_entries",
                Some(index),
                candidate.metadata.len(),
                MAX_CANDIDATE_METADATA_ENTRIES,
            ));
        }
        for (key, value) in &candidate.metadata {
            reject_oversized_field(
                "catalog",
                "metadata_key_bytes",
                index,
                key.len(),
                MAX_CANDIDATE_METADATA_KEY_BYTES,
            )?;
            reject_oversized_field(
                "catalog",
                "metadata_value_bytes",
                index,
                value.len(),
                MAX_CANDIDATE_METADATA_VALUE_BYTES,
            )?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                key.len(),
                "catalog",
                index,
                MAX_CATALOG_ENCODED_BYTES,
            )?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                value.len(),
                "catalog",
                index,
                MAX_CATALOG_ENCODED_BYTES,
            )?;
        }

        if let Some(CandidateEffect::CopyText { text }) = &candidate.effect {
            reject_oversized_field(
                "catalog",
                "effect_text_bytes",
                index,
                text.len(),
                MAX_CANDIDATE_EFFECT_BYTES,
            )?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                text.len(),
                "catalog",
                index,
                MAX_CATALOG_ENCODED_BYTES,
            )?;
        }
    }

    let encoded = rmp_serde::to_vec(&CatalogCandidatesRef { candidates })
        .map_err(|_| BoundaryViolation::new("catalog", "messagepack_encoding", None, 1, 0))?;
    if encoded.len() > MAX_CATALOG_ENCODED_BYTES {
        return Err(BoundaryViolation::new(
            "catalog",
            "encoded_bytes",
            None,
            encoded.len(),
            MAX_CATALOG_ENCODED_BYTES,
        ));
    }
    Ok(())
}

fn validate_query_answers(answers: &[QueryAnswer]) -> Result<(), BoundaryViolation> {
    if answers.len() > MAX_QUERY_ANSWERS {
        return Err(BoundaryViolation::new(
            "query",
            "answer_count",
            None,
            answers.len(),
            MAX_QUERY_ANSWERS,
        ));
    }

    let mut aggregate_string_bytes = 0usize;
    for (index, answer) in answers.iter().enumerate() {
        for (rule, value) in [
            ("title_bytes", answer.title.as_str()),
            (
                "effect_text_bytes",
                match &answer.effect {
                    CandidateEffect::CopyText { text } => text.as_str(),
                },
            ),
        ] {
            reject_oversized_field("query", rule, index, value.len(), MAX_QUERY_FIELD_BYTES)?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                value.len(),
                "query",
                index,
                MAX_QUERY_ENCODED_BYTES,
            )?;
        }
        if let Some(subtitle) = &answer.subtitle {
            reject_oversized_field(
                "query",
                "subtitle_bytes",
                index,
                subtitle.len(),
                MAX_QUERY_FIELD_BYTES,
            )?;
            add_aggregate_bytes(
                &mut aggregate_string_bytes,
                subtitle.len(),
                "query",
                index,
                MAX_QUERY_ENCODED_BYTES,
            )?;
        }
    }

    let encoded = rmp_serde::to_vec(&QueryAnswersRef { answers })
        .map_err(|_| BoundaryViolation::new("query", "messagepack_encoding", None, 1, 0))?;
    if encoded.len() > MAX_QUERY_ENCODED_BYTES {
        return Err(BoundaryViolation::new(
            "query",
            "encoded_bytes",
            None,
            encoded.len(),
            MAX_QUERY_ENCODED_BYTES,
        ));
    }
    Ok(())
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
}

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

#[derive(Deserialize)]
struct InitializeRequest {
    protocol_version: u32,
    #[serde(default)]
    running_applications: Vec<RunningApplication>,
}

/// A `hints.activate` notification: act on the [`JumpTarget`] the plugin
/// emitted earlier (matched by `target_id`) with the given click `action`.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct ActivateRequest {
    #[serde(default)]
    pub action: String,
    #[serde(default)]
    pub target_id: String,
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

/// A non-lifecycle request dispatched to [`Plugin::handle`].
#[derive(Clone, Debug)]
pub enum Request {
    Command(CommandRequest),
    DiscoverTargets(DiscoverRequest),
    ResolveCandidate(Candidate),
    SourceAction(SourceActionRequest),
    RestoreNavigation(NavigationRequest),
    ActivateTarget(ActivateRequest),
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

/// The result of running a subprocess via `run_command` / `run_osascript`:
/// exit success plus captured stdout/stderr. `into_command` folds it into a
/// `CommandResponse` (trimmed + length-capped). This lives in the SDK so the
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
    pub fn into_command(self) -> CommandResponse {
        CommandResponse {
            ok: self.ok,
            stdout: (!self.stdout.trim().is_empty()).then(|| shorten(&self.stdout)),
            error: (!self.ok && !self.stderr.trim().is_empty()).then(|| shorten(&self.stderr)),
            ..Default::default()
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
    command
        .args(args)
        .current_dir(&ctx.data_dir)
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
    let output = match bounded_process::capture(
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
/// [`Context`] during lifecycle callbacks; they cannot override snapshot
/// gathering or put I/O on this path.
#[derive(Clone, Debug, Default, Serialize)]
struct SourceSnapshotResponse {
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
    fn candidates(candidates: Vec<Candidate>) -> Self {
        Self {
            candidates: Some(candidates),
        }
    }
}

/// What [`Plugin::handle`] returns. Build one from the matching response type
/// with `.into()`; return [`Response::None`] for [`Request::ActivateTarget`],
/// which expects no reply.
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
    fn validate_boundary(&self) -> Result<(), BoundaryViolation> {
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

    fn to_value(&self) -> Result<Value, &'static str> {
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

// ---------------------------------------------------------------------------
// Emitter / Context
// ---------------------------------------------------------------------------

/// Protocol responses and plugin→host calls use a bounded control lane.
/// Telemetry/status notifications use a separate bounded lane. The writer
/// always drains ready control frames first, so log storms cannot delay a
/// `sources.snapshot`, query, heartbeat, or shutdown response.
#[derive(Clone)]
struct Emitter {
    senders: Arc<Mutex<EmitterSenders>>,
    telemetry_drops: Arc<AtomicU64>,
}

struct EmitterSenders {
    control: Option<mpsc::Sender<Vec<u8>>>,
    telemetry: Option<mpsc::Sender<Vec<u8>>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FrameEncodingError {
    Serialization,
    Oversized {
        encoded_bytes: usize,
        limit_bytes: usize,
    },
}

impl FrameEncodingError {
    fn reason(self) -> &'static str {
        match self {
            FrameEncodingError::Serialization => "serialization_failed",
            FrameEncodingError::Oversized { .. } => "frame_too_large",
        }
    }

    fn response_error(self) -> &'static str {
        match self {
            FrameEncodingError::Serialization => "plugin response serialization failed",
            FrameEncodingError::Oversized { .. } => "plugin response exceeded outbound frame limit",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ControlSendError {
    Encoding(FrameEncodingError),
    Closed,
}

struct OutboundReceiver {
    control: mpsc::Receiver<Vec<u8>>,
    telemetry: mpsc::Receiver<Vec<u8>>,
    control_open: bool,
    telemetry_open: bool,
}

impl OutboundReceiver {
    fn new(control: mpsc::Receiver<Vec<u8>>, telemetry: mpsc::Receiver<Vec<u8>>) -> Self {
        Self {
            control,
            telemetry,
            control_open: true,
            telemetry_open: true,
        }
    }

    async fn recv(&mut self) -> Option<Vec<u8>> {
        while self.control_open || self.telemetry_open {
            tokio::select! {
                biased;
                payload = self.control.recv(), if self.control_open => {
                    match payload {
                        Some(payload) => return Some(payload),
                        None => self.control_open = false,
                    }
                }
                payload = self.telemetry.recv(), if self.telemetry_open => {
                    match payload {
                        Some(payload) => return Some(payload),
                        None => self.telemetry_open = false,
                    }
                }
            }
        }
        None
    }
}

impl Emitter {
    fn new(control: mpsc::Sender<Vec<u8>>, telemetry: mpsc::Sender<Vec<u8>>) -> Self {
        Self {
            senders: Arc::new(Mutex::new(EmitterSenders {
                control: Some(control),
                telemetry: Some(telemetry),
            })),
            telemetry_drops: Arc::new(AtomicU64::new(0)),
        }
    }

    fn encode(value: &Value, limit_bytes: usize) -> Result<Vec<u8>, FrameEncodingError> {
        let payload = rmp_serde::to_vec(value).map_err(|_| FrameEncodingError::Serialization)?;
        if payload.len() > limit_bytes {
            return Err(FrameEncodingError::Oversized {
                encoded_bytes: payload.len(),
                limit_bytes,
            });
        }
        Ok(payload)
    }

    fn report_frame_rejection(&self, lane: &'static str, error: FrameEncodingError) {
        let mut fields = BTreeMap::from([
            ("lane".to_string(), lane.to_string()),
            ("reason".to_string(), error.reason().to_string()),
        ]);
        match error {
            FrameEncodingError::Serialization => {
                eprintln!(
                    "[plugin] outbound frame rejected lane={lane} reason={}",
                    error.reason(),
                );
            }
            FrameEncodingError::Oversized {
                encoded_bytes,
                limit_bytes,
            } => {
                fields.insert("encoded_bytes".to_string(), encoded_bytes.to_string());
                fields.insert("limit_bytes".to_string(), limit_bytes.to_string());
                eprintln!(
                    "[plugin] outbound frame rejected lane={lane} reason={} limit_bytes={limit_bytes}",
                    error.reason(),
                );
            }
        }

        // stderr is the last-resort diagnostic channel when the rejected frame
        // itself cannot traverse stdout. Never include the original payload.
        let diagnostic = json!({
            "jsonrpc": "2.0",
            "method": "flash.log",
            "params": {
                "level": "warn",
                "message": "[plugin] outbound frame rejected",
                "fields": fields,
            },
        });
        if let Ok(payload) = Self::encode(&diagnostic, MAX_TELEMETRY_FRAME_BYTES) {
            self.try_send_telemetry(payload);
        }
    }

    async fn send_control(&self, lane: &'static str, value: Value) -> Result<(), ControlSendError> {
        let payload = match Self::encode(&value, MAX_FRAME_BYTES) {
            Ok(payload) => payload,
            Err(error) => {
                self.report_frame_rejection(lane, error);
                return Err(ControlSendError::Encoding(error));
            }
        };
        let sender = self
            .senders
            .lock()
            .ok()
            .and_then(|senders| senders.control.clone())
            .ok_or(ControlSendError::Closed)?;
        sender
            .send(payload)
            .await
            .map_err(|_| ControlSendError::Closed)
    }

    fn try_send_telemetry(&self, payload: Vec<u8>) {
        let sender = self
            .senders
            .lock()
            .ok()
            .and_then(|senders| senders.telemetry.clone());
        let Some(sender) = sender else {
            return;
        };
        match sender.try_send(payload) {
            Ok(()) => {}
            Err(mpsc::error::TrySendError::Full(_)) => {
                let dropped = self.telemetry_drops.fetch_add(1, Ordering::Relaxed) + 1;
                if dropped == 1 || dropped.is_power_of_two() {
                    eprintln!(
                        "[plugin] outbound telemetry queue full; dropped_frames={dropped} capacity={TELEMETRY_QUEUE_CAPACITY}"
                    );
                }
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {}
        }
    }

    /// Close both shared output lanes even when detached plugin tasks still
    /// retain `Context` clones. Queued frames drain first; later emits become
    /// no-ops. This lets graceful shutdown finish without waiting for interval
    /// loops that the tokio runtime will cancel as it drops.
    fn close(&self) {
        if let Ok(mut senders) = self.senders.lock() {
            senders.control.take();
            senders.telemetry.take();
        }
    }

    fn notify(&self, method: &str, params: Value) {
        let value = json!({ "jsonrpc": "2.0", "method": method, "params": params });
        match Self::encode(&value, MAX_TELEMETRY_FRAME_BYTES) {
            Ok(payload) => self.try_send_telemetry(payload),
            Err(error) => self.report_frame_rejection("telemetry", error),
        }
    }

    async fn request(&self, id: u64, method: &str, params: Value) -> Result<(), ControlSendError> {
        self.send_control(
            "host_request",
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "method": method,
                "params": params,
            }),
        )
        .await
    }

    async fn respond(&self, id: Value, result: Value) {
        if id.is_null() {
            return;
        }
        let response = json!({ "jsonrpc": "2.0", "id": id.clone(), "result": result });
        if let Err(error) = self.send_control("response", response).await {
            let ControlSendError::Encoding(encoding_error) = error else {
                return;
            };
            let fallback = json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "ok": false,
                    "error": encoding_error.response_error(),
                },
            });
            // The fallback is fixed-size and content-free. Failure here means
            // stdout has closed; there is no remaining protocol path to report.
            let _ = self.send_control("response_error", fallback).await;
        }
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
        let started_at = Instant::now();
        let id = self.host_counter.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, rx) = oneshot::channel();
        if let Ok(mut pending) = self.host_pending.lock() {
            pending.insert(id, tx);
        }
        let outcome = tokio::time::timeout(timeout, async {
            self.emit.request(id, method, params).await?;
            rx.await.map_err(|_| ControlSendError::Closed)
        })
        .await;
        match outcome {
            Ok(Ok(value)) => value,
            Ok(Err(ControlSendError::Encoding(_))) => {
                if let Ok(mut pending) = self.host_pending.lock() {
                    pending.remove(&id);
                }
                json!({ "ok": false, "error": "host call exceeded outbound frame limit" })
            }
            Ok(Err(ControlSendError::Closed)) => {
                if let Ok(mut pending) = self.host_pending.lock() {
                    pending.remove(&id);
                }
                json!({ "ok": false, "error": "host call output closed" })
            }
            Err(_) => {
                if let Ok(mut pending) = self.host_pending.lock() {
                    pending.remove(&id);
                }
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
    /// locations in memory and the SDK runtime serves them directly when the
    /// host requests `sources.snapshot`. Call it whenever the plugin's locations
    /// change (`on_start`, `on_event`, polls).
    ///
    /// Passing an empty vector is an authoritative successful clear. Refresh
    /// code must model source failure separately (for example
    /// `Result<Vec<Candidate>, Failure>`): publish every `Ok`, including
    /// `Ok([])`, and preserve the last-good vector only for `Err`. Publications
    /// outside the SDK's count, field, or encoded-byte limits are rejected
    /// atomically with a content-free warning and also preserve the last-good
    /// vector.
    ///
    /// [`warm_locations`]: Context::warm_locations
    pub fn set_locations(&self, source_id: &str, candidates: Vec<Candidate>) {
        if source_id.len() > MAX_CANDIDATE_METADATA_KEY_BYTES {
            self.log_fields(
                "warn",
                "[plugin] rejected catalog publication",
                BoundaryViolation::new(
                    "catalog",
                    "source_id_bytes",
                    None,
                    source_id.len(),
                    MAX_CANDIDATE_METADATA_KEY_BYTES,
                )
                .log_fields(),
            );
            return;
        }
        if let Err(violation) = validate_catalog_candidates(&candidates) {
            self.log_fields(
                "warn",
                "[plugin] rejected catalog publication",
                violation.log_fields(),
            );
            return;
        }
        let candidates = Arc::new(candidates);
        if let Ok(mut store) = self.locations.lock() {
            store.insert(source_id.to_string(), candidates);
        }
    }

    /// Whether this source has published an initial warm snapshot. An
    /// authoritative empty vector counts as published.
    pub fn has_locations(&self, source_id: &str) -> bool {
        self.locations
            .lock()
            .map(|store| store.contains_key(source_id))
            .unwrap_or(false)
    }

    fn canonical_location_source_id(&self) -> String {
        format!("plugin:{}", self.plugin_id)
    }

    fn published_location_source_ids(&self) -> Vec<String> {
        let Ok(store) = self.locations.lock() else {
            return Vec::new();
        };
        let mut ids = store.keys().cloned().collect::<Vec<_>>();
        ids.sort();
        ids
    }

    fn set_running_applications(&self, applications: Vec<RunningApplication>) {
        if let Ok(mut current) = self.running_applications.lock() {
            *current = applications;
        }
    }

    /// Current host-owned running-app snapshot. It is available during
    /// `on_start` from the initialize handshake, then replaced atomically by
    /// the SDK before each serialized `core:apps.changed` callback.
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

    /// The union of every warm location set this plugin has published, ordered
    /// by `source_id` for determinism. The SDK runtime returns this directly;
    /// the host applies its own fuzzy narrowing against the query.
    pub fn warm_locations(&self) -> Vec<Candidate> {
        let entries = {
            let Ok(store) = self.locations.lock() else {
                return Vec::new();
            };
            let mut entries = store
                .iter()
                .map(|(source_id, candidates)| (source_id.clone(), Arc::clone(candidates)))
                .collect::<Vec<_>>();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            entries
        };
        entries
            .into_iter()
            .flat_map(|(_, candidates)| candidates.as_ref().clone())
            .collect()
    }

    fn validated_warm_locations(&self) -> Result<Vec<Candidate>, BoundaryViolation> {
        let candidates = self.warm_locations();
        validate_catalog_candidates(&candidates)?;
        Ok(candidates)
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
        running_applications: Arc::new(Mutex::new(Vec::new())),
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

    fn test_context() -> Context {
        let (control_tx, _control_rx) = mpsc::channel(16);
        let (telemetry_tx, _telemetry_rx) = mpsc::channel(16);
        Context {
            plugin_id: "test".to_string(),
            version: "0.0.0".to_string(),
            data_dir: PathBuf::from("."),
            emit: Emitter::new(control_tx, telemetry_tx),
            config: json!({}),
            host_pending: Arc::new(Mutex::new(HashMap::new())),
            host_counter: Arc::new(AtomicU64::new(0)),
            locations: Arc::new(Mutex::new(HashMap::new())),
            running_applications: Arc::new(Mutex::new(Vec::new())),
        }
    }

    #[test]
    fn authoritative_empty_locations_count_as_initialized() {
        let ctx = test_context();
        assert!(!ctx.has_locations("plugin:test"));

        ctx.set_locations("plugin:test", Vec::new());

        assert!(ctx.has_locations("plugin:test"));
        assert_eq!(
            ctx.published_location_source_ids(),
            vec!["plugin:test".to_string()]
        );
        assert!(ctx.warm_locations().is_empty());
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

    #[test]
    fn catalog_boundary_rejects_counts_fields_and_aggregate_bytes() {
        let too_many = vec![Candidate::new("x"); MAX_CATALOG_CANDIDATES + 1];
        assert_eq!(
            validate_catalog_candidates(&too_many).unwrap_err().rule,
            "candidate_count"
        );

        let oversized_title = vec![Candidate::new("x".repeat(MAX_CANDIDATE_TITLE_BYTES + 1))];
        assert_eq!(
            validate_catalog_candidates(&oversized_title)
                .unwrap_err()
                .rule,
            "title_bytes"
        );

        let aggregate = (0..65)
            .map(|index| {
                Candidate::new(format!("candidate {index}"))
                    .metadata("payload", "x".repeat(MAX_CANDIDATE_METADATA_VALUE_BYTES))
            })
            .collect::<Vec<_>>();
        assert_eq!(
            validate_catalog_candidates(&aggregate).unwrap_err().rule,
            "aggregate_string_bytes"
        );
    }

    #[test]
    fn invalid_catalog_publication_preserves_last_good_snapshot() {
        let ctx = test_context();
        ctx.set_locations("plugin:test", vec![Candidate::new("last good")]);

        ctx.set_locations(
            "plugin:test",
            vec![Candidate::new("x".repeat(MAX_CANDIDATE_TITLE_BYTES + 1))],
        );

        let candidates = ctx.warm_locations();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].title, "last good");
    }

    #[test]
    fn query_boundary_rejects_counts_fields_and_aggregate_bytes() {
        let too_many = vec![QueryAnswer::copy_text("1", None::<String>); MAX_QUERY_ANSWERS + 1];
        assert_eq!(
            validate_query_answers(&too_many).unwrap_err().rule,
            "answer_count"
        );

        let oversized =
            QueryAnswer::copy_text("x".repeat(MAX_QUERY_FIELD_BYTES + 1), None::<String>);
        assert_eq!(
            validate_query_answers(&[oversized]).unwrap_err().rule,
            "title_bytes"
        );

        let aggregate = (0..MAX_QUERY_ANSWERS)
            .map(|_| QueryAnswer::copy_text("x".repeat(10 * 1024), None::<String>))
            .collect::<Vec<_>>();
        assert_eq!(
            validate_query_answers(&aggregate).unwrap_err().rule,
            "aggregate_string_bytes"
        );
    }

    #[tokio::test]
    async fn control_responses_overtake_queued_telemetry() {
        let (control_tx, control_rx) = mpsc::channel(4);
        let (telemetry_tx, telemetry_rx) = mpsc::channel(4);
        let emitter = Emitter::new(control_tx, telemetry_tx);
        let mut outbound = OutboundReceiver::new(control_rx, telemetry_rx);

        emitter.notify("status.updated", json!({ "segments": {} }));
        emitter.respond(json!(7), json!({ "ok": true })).await;

        let first = outbound.recv().await.unwrap();
        let first: Value = rmp_serde::from_slice(&first).unwrap();
        assert_eq!(first.get("id"), Some(&json!(7)));

        let second = outbound.recv().await.unwrap();
        let second: Value = rmp_serde::from_slice(&second).unwrap();
        assert_eq!(
            second.get("method").and_then(Value::as_str),
            Some("status.updated")
        );
    }

    #[tokio::test]
    async fn outbound_telemetry_queue_is_bounded() {
        let (control_tx, _control_rx) = mpsc::channel(1);
        let (telemetry_tx, _telemetry_rx) = mpsc::channel(1);
        let emitter = Emitter::new(control_tx, telemetry_tx);

        emitter.notify("status.updated", json!({ "segments": {} }));
        emitter.notify("status.updated", json!({ "segments": {} }));

        assert_eq!(emitter.telemetry_drops.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn oversized_response_becomes_small_explicit_error() {
        let (control_tx, control_rx) = mpsc::channel(4);
        let (telemetry_tx, telemetry_rx) = mpsc::channel(4);
        let emitter = Emitter::new(control_tx, telemetry_tx);
        let mut outbound = OutboundReceiver::new(control_rx, telemetry_rx);

        emitter
            .respond(json!(9), json!({ "value": "x".repeat(MAX_FRAME_BYTES) }))
            .await;

        let payload = outbound.recv().await.unwrap();
        let response: Value = rmp_serde::from_slice(&payload).unwrap();
        assert_eq!(response.get("id"), Some(&json!(9)));
        assert_eq!(
            response.pointer("/result/error").and_then(Value::as_str),
            Some("plugin response exceeded outbound frame limit")
        );
    }

    #[tokio::test]
    async fn oversized_notification_emits_content_free_warning() {
        let (control_tx, control_rx) = mpsc::channel(4);
        let (telemetry_tx, telemetry_rx) = mpsc::channel(4);
        let emitter = Emitter::new(control_tx, telemetry_tx);
        let mut outbound = OutboundReceiver::new(control_rx, telemetry_rx);

        emitter.notify(
            "status.updated",
            json!({ "value": "x".repeat(MAX_TELEMETRY_FRAME_BYTES) }),
        );

        let payload = outbound.recv().await.unwrap();
        let warning: Value = rmp_serde::from_slice(&payload).unwrap();
        assert_eq!(
            warning.get("method").and_then(Value::as_str),
            Some("flash.log")
        );
        assert_eq!(
            warning.pointer("/params/message").and_then(Value::as_str),
            Some("[plugin] outbound frame rejected")
        );
        assert!(warning.to_string().len() < 1_000);
    }

    #[tokio::test]
    async fn closing_emitter_releases_writer_despite_retained_context_clone() {
        let (control_tx, control_rx) = mpsc::channel(4);
        let (telemetry_tx, telemetry_rx) = mpsc::channel(4);
        let emitter = Emitter::new(control_tx, telemetry_tx);
        let mut outbound = OutboundReceiver::new(control_rx, telemetry_rx);
        let retained = emitter.clone();

        emitter.notify("before.close", json!({}));
        assert!(outbound.recv().await.is_some());

        emitter.close();
        retained.notify("after.close", json!({}));
        assert!(outbound.recv().await.is_none());
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
