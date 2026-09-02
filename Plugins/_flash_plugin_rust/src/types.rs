//! Core value types crossing the plugin↔host wire: catalog rows, hint
//! targets, inbound request payloads, and outbound response builders.

use std::collections::HashMap;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

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

/// Shared source salience used by catalog rows, source declarations, and hint
/// targets.
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

/// A catalog row. Outbound (via [`Context::publish`](crate::Context::publish)
/// or a `search` reply) `source` must name one of this plugin's manifest
/// `sources[].name` entries and `title` is the searchable string. Inbound (on
/// `perform {kind: "resolve"}`) the host echoes the row back with the same
/// shape — read structured payload via [`payload_str`](Candidate::payload_str)
/// / [`payload_as`](Candidate::payload_as).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Candidate {
    /// The manifest `sources[].name` this row belongs to — first-class on the
    /// wire; the host stamps its own routing `source_id`.
    #[serde(default)]
    pub source: String,
    /// Primary searchable string the host scores against and shows in the
    /// candidate bar — also the highest-precedence ranking field.
    #[serde(default)]
    pub title: String,
    /// Openable destination when one exists. Apps use the bundle file URL;
    /// browser tabs and other resources use their canonical URL.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub url: Option<String>,
    /// Free-form per-source key/value metadata. FlashCore makes no decisions on
    /// what's inside — plugins may stash arbitrary routing/state, other plugins
    /// can read it, and the matcher indexes the values at a low tier for fuzzy
    /// search.
    #[serde(skip_serializing_if = "HashMap::is_empty", default)]
    pub metadata: HashMap<String, String>,
    /// Explicit user-triggered effect the host validates and performs when this
    /// row is selected. Evaluation/rendering never executes it.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub effect: Option<CandidateEffect>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CandidateEffect {
    CopyText {
        text: String,
    },
    InsertText {
        text: String,
    },
    /// Exactly one of `url` / `bundle_id`. Catalog rows only — the host
    /// rejects `open` effects in query answers (evaluators cannot
    /// manufacture navigation).
    Open {
        #[serde(skip_serializing_if = "Option::is_none", default)]
        url: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none", default)]
        bundle_id: Option<String>,
    },
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

    /// Answer that types its title into the focused app on selection.
    /// (`open` effects are rejected in query answers — evaluators cannot
    /// manufacture navigation.)
    pub fn insert_text(title: impl Into<String>, subtitle: Option<impl Into<String>>) -> Self {
        let title = title.into();
        Self {
            effect: CandidateEffect::InsertText {
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
/// canonical `url` and `source` are typed fields on `Candidate` — not in this
/// map.
pub mod candidate_metadata {
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
    pub fn new(source: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            source: source.into(),
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

    /// Type `text` into the focused app after the user selects this
    /// candidate. The host owns the keystroke synthesis.
    pub fn insert_text(mut self, text: impl Into<String>) -> Self {
        self.effect = Some(CandidateEffect::InsertText { text: text.into() });
        self
    }

    /// Open `url` via LaunchServices after the user selects this candidate.
    pub fn open_url_effect(mut self, url: impl Into<String>) -> Self {
        self.effect = Some(CandidateEffect::Open {
            url: Some(url.into()),
            bundle_id: None,
        });
        self
    }

    /// Launch/activate the app with `bundle_id` after the user selects this
    /// candidate.
    pub fn open_app_effect(mut self, bundle_id: impl Into<String>) -> Self {
        self.effect = Some(CandidateEffect::Open {
            url: None,
            bundle_id: Some(bundle_id.into()),
        });
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
    /// the builders.
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

impl AsRef<str> for Candidate {
    fn as_ref(&self) -> &str {
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

/// One running regular app visible to Flash. The SDK owns one current
/// snapshot, replaced atomically before each serialized `core:apps.changed`
/// callback (the host delivers the first one right after initialize).
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

/// A `perform {kind: "command"}` request: the matched `:`-command or verb, its
/// subcommand, the trailing args, and the raw input. Bang dispatch arrives
/// with the bang token as `subcommand`.
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
}

impl CommandRequest {
    /// The args joined by a single space, trimmed.
    pub fn query(&self) -> String {
        self.args.join(" ").trim().to_string()
    }
}

/// A `hints` request, carrying the focused app's identity and front window
/// geometry. Always live — there is no cached-discovery path.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct HintsRequest {
    #[serde(default)]
    pub bundle_id: Option<String>,
    #[serde(default)]
    pub pid: Option<i64>,
    #[serde(default)]
    pub front_window_frame: Option<Frame>,
}

/// The focused-app context attached to a [`ActionRequest`].
#[derive(Clone, Debug, Default, Deserialize)]
pub struct ActionContext {
    #[serde(default)]
    pub bundle_id: Option<String>,
    #[serde(default)]
    pub pid: Option<i64>,
    #[serde(default)]
    pub front_window_frame: Option<Frame>,
}

/// A `perform {kind: "action"}` request (e.g. `tab_select`). Extra arguments
/// arrive in `args` (`index` for the numbered-tab actions).
#[derive(Clone, Debug, Default, Deserialize)]
pub struct ActionRequest {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub context: ActionContext,
    #[serde(default)]
    pub args: serde_json::Map<String, Value>,
}

impl ActionRequest {
    /// The `args.index` payload for numbered actions, when well-formed.
    pub fn index(&self) -> Option<i64> {
        self.arg_i64("index")
    }

    pub fn arg_i64(&self, key: &str) -> Option<i64> {
        match self.args.get(key)? {
            Value::Number(number) => number.as_i64(),
            Value::String(raw) => raw.parse().ok(),
            _ => None,
        }
    }

    pub fn arg_str(&self, key: &str) -> Option<&str> {
        self.args.get(key).and_then(Value::as_str)
    }
}

/// A `perform {kind: "navigate"}` request. `url` is the durable route the host
/// is restoring from movement history.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct NavigateRequest {
    #[serde(default)]
    pub url: String,
}

/// One exact input sent to a pure query evaluator (`evaluate`). Handlers must
/// only parse/compute against immutable in-memory state.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct EvaluateRequest {
    #[serde(default)]
    pub surface: String,
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub query: String,
}

/// One explicitly scoped query against a `live: true` source (`search`).
/// Unlike `evaluate`, the handler may do real work (subprocess, disk); the
/// host enforces its own drop-late deadline and simply ignores replies that
/// miss it.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct SearchRequest {
    #[serde(default)]
    pub scope: String,
    #[serde(default)]
    pub query: String,
}

/// A decoded `perform` request, one variant per wire `kind`.
#[derive(Clone, Debug)]
pub enum Perform {
    /// `kind: "resolve"` — the host echoes back a row this plugin published.
    Resolve(Candidate),
    /// `kind: "command"` — `:`-commands, verbs, and bang dispatch.
    Command(CommandRequest),
    /// `kind: "action"` — source-owned normal-mode actions.
    Action(ActionRequest),
    /// `kind: "navigate"` — movement-history route restoration.
    Navigate(NavigateRequest),
}

// ---------------------------------------------------------------------------
// Outbound responses
// ---------------------------------------------------------------------------

/// The uniform `perform` reply — the universal trichotomy. `ok` = performed
/// (`target_pid` raises that app and records the jump in movement history;
/// `message` shows as a toast). `unhandled` = "not my context"; the host MAY
/// fall back. `fail` = "mine, but it broke"; the host MUST NOT fall back
/// (double-fire protection).
#[derive(Clone, Debug, Serialize)]
pub struct PerformResponse {
    ok: bool,
    #[serde(skip_serializing_if = "is_false")]
    unhandled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    target_pid: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    navigation_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
}

fn is_false(value: &bool) -> bool {
    !value
}

impl PerformResponse {
    /// The action was performed.
    pub fn ok() -> Self {
        Self {
            ok: true,
            unhandled: false,
            error: None,
            target_pid: None,
            navigation_url: None,
            message: None,
        }
    }

    /// "Not my context" — the host may fall back (e.g. to a keystroke
    /// mapping).
    pub fn unhandled() -> Self {
        Self {
            ok: false,
            unhandled: true,
            error: None,
            target_pid: None,
            navigation_url: None,
            message: None,
        }
    }

    /// "Mine, but it broke" — the host must not fall back. The message is
    /// logged host-side; keep it content-free.
    pub fn fail(message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            ok: false,
            unhandled: false,
            // The response law: ok:false always carries a non-empty error.
            error: Some(if message.is_empty() {
                "perform failed".to_string()
            } else {
                message
            }),
            target_pid: None,
            navigation_url: None,
            message: None,
        }
    }

    /// An app to raise once the action succeeds (also records the jump in
    /// movement history).
    pub fn target_pid(mut self, pid: i64) -> Self {
        self.target_pid = Some(pid);
        self
    }

    /// Durable route to record into Flash movement history.
    pub fn navigation_url(mut self, url: impl Into<String>) -> Self {
        self.navigation_url = Some(url.into());
        self
    }

    /// Text for Flash to surface as a toast.
    pub fn message(mut self, message: impl Into<String>) -> Self {
        self.message = Some(message.into());
        self
    }

    /// Whether this response reports success.
    pub fn is_ok(&self) -> bool {
        self.ok
    }

    /// Whether this response declines the request as "not mine".
    pub fn is_unhandled(&self) -> bool {
        self.unhandled
    }

    /// The failure text, when this response is a `fail`.
    pub fn error_message(&self) -> Option<&str> {
        self.error.as_deref()
    }

    pub(crate) fn to_value(&self) -> Value {
        if self.unhandled {
            // The one sanctioned errorless ok:false — subsetting keeps the
            // wire shape canonical whatever builders were chained.
            return serde_json::json!({ "ok": false, "unhandled": true });
        }
        serde_json::to_value(self).unwrap_or_else(|_| {
            serde_json::json!({ "ok": false, "error": "perform response could not be encoded" })
        })
    }
}

/// Answers for one `evaluate` request. Unclaimed input returns the default
/// (empty) response — evaluators are additive parsers, never error paths.
#[derive(Clone, Debug, Default)]
pub struct EvaluateResponse {
    pub answers: Vec<QueryAnswer>,
}

impl EvaluateResponse {
    pub fn answers(answers: Vec<QueryAnswer>) -> Self {
        Self { answers }
    }
}

/// Catalog-shaped rows answering one `search` request against this plugin's
/// `live: true` sources.
#[derive(Clone, Debug, Default)]
pub struct SearchResponse {
    pub rows: Vec<Candidate>,
}

impl SearchResponse {
    pub fn rows(rows: Vec<Candidate>) -> Self {
        Self { rows }
    }
}

/// Hint targets answering one `hints` request.
#[derive(Clone, Debug, Default)]
pub struct HintsResponse {
    pub targets: Vec<JumpTarget>,
    pub context_pid: Option<i64>,
}

impl HintsResponse {
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rows_serialize_with_first_class_source_and_lean_optionals() {
        let row = Candidate::new("example.items", "Example");
        let encoded = serde_json::to_value(&row).unwrap();
        assert_eq!(
            encoded,
            json!({ "source": "example.items", "title": "Example" })
        );

        let rich = Candidate::new("example.items", "Rich")
            .url("https://example.com")
            .subtitle("sub")
            .copy_text("text");
        let encoded = serde_json::to_value(&rich).unwrap();
        assert_eq!(encoded["source"], "example.items");
        assert_eq!(encoded["metadata"]["subtitle"], "sub");
        assert_eq!(encoded["effect"]["type"], "copy_text");
    }

    #[test]
    fn inbound_rows_decode_leniently_with_defaults() {
        let row: Candidate =
            serde_json::from_value(json!({ "source": "s", "title": "t" })).unwrap();
        assert_eq!(row.source, "s");
        assert!(row.metadata.is_empty());
        assert!(row.effect.is_none());
    }

    #[test]
    fn perform_response_wire_shapes_follow_the_trichotomy() {
        assert_eq!(
            PerformResponse::ok()
                .target_pid(7)
                .message("done")
                .to_value(),
            json!({ "ok": true, "target_pid": 7, "message": "done" })
        );
        assert_eq!(
            PerformResponse::unhandled().to_value(),
            json!({ "ok": false, "unhandled": true })
        );
        assert_eq!(
            PerformResponse::fail("broke").to_value(),
            json!({ "ok": false, "error": "broke" })
        );
        // The response law: ok:false always carries a non-empty error.
        assert_eq!(
            PerformResponse::fail("").to_value(),
            json!({ "ok": false, "error": "perform failed" })
        );
    }

    #[test]
    fn action_args_read_numbers_and_numeric_strings() {
        let request: ActionRequest = serde_json::from_value(json!({
            "name": "tab_select",
            "context": { "pid": 7 },
            "args": { "index": "3" },
        }))
        .unwrap();
        assert_eq!(request.index(), Some(3));

        let request: ActionRequest = serde_json::from_value(json!({
            "name": "tab_select",
            "args": { "index": 4 },
        }))
        .unwrap();
        assert_eq!(request.index(), Some(4));
        assert_eq!(request.arg_str("index"), None);
    }
}
