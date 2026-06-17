use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use flash_plugin::{
    run, Candidate, CommandRequest, CommandResponse, Context, Event, ResolveResponse,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

const CHANNEL_SOURCE_ID: &str = "plugin:slack.channels";
const CHANNEL_SOURCE_LABEL: &str = "slack.channels";
const SLACK_BUNDLES: &[&str] = &[
    "com.tinyspeck.slackmacgap",
    "com.tinyspeck.slackmacgap.direct",
];
/// Attributes the AX broker reads for every node. We need the role
/// markers (`AXRole`/`AXSubrole`) to identify sidebar outline rows vs
/// header-bar buttons; the text-bearing attributes are where the
/// channel name actually lives in Slack's a11y tree.
const CHANNEL_COLLECT: &[&str] = &[
    "AXRole",
    "AXSubrole",
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXHelp",
    "AXIdentifier",
    "AXRoleDescription",
];
/// Slack's Electron tree is deep (collapsed sections, DMs, huddles,
/// threads, the workspace switcher). The visit budget matches the old
/// walk so busy workspaces don't silently truncate.
const MAX_NODES: u64 = 30_000;

/// Sidebar labels that match the channel-row shape (AXOutlineRow under
/// the navigator) but are Slack's own chrome rather than user channels.
/// Lowercased; compared case-insensitively.
const NON_CHANNEL_LABELS: &[&str] = &[
    "home",
    "activity",
    "files",
    "later",
    "more",
    "admin",
    "messages",
    "threads",
    "huddles",
    "drafts & sent",
    "drafts and sent",
    "directories",
    "starred",
    "direct messages",
    "channels",
    "apps",
    "canvas",
    "list",
    "folder",
    "add canvas",
    "browse channels",
    "all unreads",
    "all dms",
    "mentions & reactions",
    "saved",
    "saved items",
    "people",
    "user groups",
    "scheduled",
    "notifications",
    "preferences",
    "create",
    "search",
];

/// Discovered channels accumulate here across snapshots so virtualized
/// sidebar rows don't vanish from the candidate list every time Slack
/// re-renders. Keyed by pid → lower(name) → Channel.
static SESSION_CACHE: OnceLock<Mutex<HashMap<i64, HashMap<String, Channel>>>> = OnceLock::new();
/// Workspace metadata parsed from `root-state.json`: team_id → workspace.
static WORKSPACES: OnceLock<Mutex<HashMap<String, Workspace>>> = OnceLock::new();

#[derive(Clone, Debug, Default)]
struct Workspace {
    team_id: String,
    team_name: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct Channel {
    handle: Option<u64>,
    /// Channel slug without the `#` prefix (e.g. `general`).
    name: String,
    channel_id: Option<String>,
    team_id: Option<String>,
    team_name: Option<String>,
    pid: Option<i64>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct ChannelPayload {
    name: String,
    channel_id: Option<String>,
    team_id: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
struct ConfiguredChannel {
    name: String,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    team: Option<String>,
    #[serde(default)]
    team_name: Option<String>,
}

struct Slack;

flash_plugin::plugin!(Slack);

impl FlashPlugin for Slack {
    async fn on_start(&self, ctx: Context) {
        refresh_workspaces();
        seed_from_config(&ctx);
        refresh_snapshot(&ctx, Vec::new()).await;
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            "core:apps.snapshot" => {
                let pids = event
                    .running_applications
                    .iter()
                    .filter(|app| SLACK_BUNDLES.contains(&app.bundle_id.as_str()))
                    .map(|app| app.pid)
                    .collect::<Vec<_>>();
                refresh_workspaces();
                refresh_snapshot(&ctx, pids).await;
            }
            "core:config.changed" => {
                refresh_workspaces();
                seed_from_config(&ctx);
                refresh_snapshot(&ctx, Vec::new()).await;
            }
            "core:focus.changed" | "core:ax.changed" => {
                let bundle = event.bundle_id.unwrap_or_default();
                let Some(pid) = event.pid else {
                    return;
                };
                if SLACK_BUNDLES.contains(&bundle.as_str()) {
                    refresh_snapshot(&ctx, vec![pid]).await;
                }
            }
            _ => {}
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        self.invoke_command(&ctx, &command).await
    }

    async fn resolve_candidate(&self, ctx: Context, candidate: Candidate) -> ResolveResponse {
        resolve(&ctx, &candidate).await
    }
}

async fn refresh_snapshot(ctx: &Context, pids: Vec<i64>) {
    for pid in &pids {
        let fresh = collect_ax_channels(ctx, *pid).await;
        merge_into_session_cache(*pid, fresh);
    }
    ctx.emit_snapshot(CHANNEL_SOURCE_ID, session_candidates());
}

impl Slack {
    async fn invoke_command(&self, ctx: &Context, cmd: &CommandRequest) -> CommandResponse {
        // `[plugin.slack] cli = "/path/to/slack"` overrides the executable;
        // defaults to `slack` on PATH.
        let cli = {
            let configured = ctx.config_str("cli");
            if configured.is_empty() {
                "slack".to_string()
            } else {
                configured
            }
        };
        let (argv, timeout): (Vec<String>, u64) = match cmd.subcommand.as_str() {
            "login" => (vec![cli, "login".into()], 300),
            "version" => (vec![cli, "version".into()], 120),
            "run" => (prepend(&cli, &cmd.args), 120),
            other => {
                return CommandResponse::error(format!("unknown subcommand: {other}"));
            }
        };
        run_command(ctx, &argv, Duration::from_secs(timeout))
            .await
            .into_command()
    }
}

// ---------------------------------------------------------------------------
// AX walk
// ---------------------------------------------------------------------------

/// Walk Slack's windows and pull every channel reference out of the AX
/// tree. Three signals contribute:
///
///   1. Sidebar `AXOutlineRow` descendants — handle-bearing rows that
///      `resolve` can press directly.
///   2. Header-bar buttons whose description spells out the active
///      channel (`Channel details for #foo`, `Start huddle in foo`).
///   3. The window title (`<channel> (Channel) - <Workspace> - Slack`)
///      as a last resort.
async fn collect_ax_channels(ctx: &Context, pid: i64) -> Vec<Channel> {
    let nodes = ax_snapshot(ctx, pid, "windows", &[], CHANNEL_COLLECT, MAX_NODES, false).await;

    let mut out: HashMap<String, Channel> = HashMap::new();
    let mut window_team_name: Option<String> = None;
    let mut window_channel: Option<String> = None;

    for node in &nodes {
        if is_window(node) {
            if let Some(title) = node.attr("AXTitle") {
                if let Some((channel, workspace)) = parse_window_title(title) {
                    window_channel = Some(channel);
                    window_team_name = Some(workspace);
                }
            }
            continue;
        }

        // Sidebar outline rows: handle is what makes the candidate
        // actionable, so we always record it when we have one.
        if node.attr("AXRole") == Some("AXRow") && node.attr("AXSubrole") == Some("AXOutlineRow") {
            if let Some(name) = sidebar_channel_name(node) {
                let key = name.to_ascii_lowercase();
                let entry = out.entry(key).or_insert_with(|| Channel {
                    name: name.clone(),
                    pid: Some(pid),
                    ..Channel::default()
                });
                if entry.handle.is_none() {
                    entry.handle = Some(node.handle);
                }
            }
            continue;
        }

        // Header-bar buttons: no handle (a press would just re-open the
        // already-current channel), but the description carries the
        // current channel name.
        if let Some(name) = button_channel_hint(node) {
            let key = name.to_ascii_lowercase();
            out.entry(key).or_insert_with(|| Channel {
                name,
                pid: Some(pid),
                ..Channel::default()
            });
        }
    }

    if let Some(name) = window_channel {
        let key = name.to_ascii_lowercase();
        let entry = out.entry(key).or_insert_with(|| Channel {
            name,
            pid: Some(pid),
            ..Channel::default()
        });
        if entry.team_name.is_none() {
            entry.team_name = window_team_name;
        }
    }

    out.into_values().collect()
}

fn is_window(node: &AxNode) -> bool {
    node.attr("AXRole") == Some("AXWindow")
}

/// Extract a channel slug from an `AXOutlineRow`. Slack labels rows by
/// either AXDescription or AXTitle, then appends parenthetical status
/// indicators ("has unread messages", "muted", "N new", …). Section
/// headers ("Threads", "Huddles", "Channels", …) match the same shape,
/// so we filter against [`NON_CHANNEL_LABELS`] and require a valid
/// channel slug.
fn sidebar_channel_name(node: &AxNode) -> Option<String> {
    for attr in ["AXDescription", "AXTitle", "AXValue"] {
        if let Some(raw) = node.attr(attr) {
            if let Some(name) = parse_sidebar_label(raw) {
                return Some(name);
            }
        }
    }
    None
}

/// Buttons in Slack's header bar reveal the active channel name even
/// when the sidebar row isn't visible. The wording has stayed stable
/// across releases; missed phrasings fall through to the generic
/// `#`-token scanner.
fn button_channel_hint(node: &AxNode) -> Option<String> {
    if node.attr("AXRole") != Some("AXButton") {
        return None;
    }
    let desc = node.attr("AXDescription").unwrap_or("");
    for prefix in [
        "Channel details for ",
        "Private channel details for ",
        "Start huddle in ",
        "Search in ",
    ] {
        if let Some(rest) = desc.strip_prefix(prefix) {
            let token = rest
                .split(|c: char| c == ',' || c.is_whitespace())
                .next()
                .unwrap_or("")
                .trim_start_matches('#');
            if looks_like_channel_slug(token) {
                return Some(token.to_string());
            }
        }
    }
    parse_hash_token(desc)
}

fn parse_sidebar_label(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    // Strip trailing " (status)" segments; Slack chains them
    // ("foo (muted) (1 new)") so peel repeatedly.
    let mut stripped = trimmed;
    while stripped.ends_with(')') {
        let Some(open) = stripped.rfind(" (") else {
            break;
        };
        stripped = stripped[..open].trim_end();
    }
    if stripped.is_empty() {
        return None;
    }
    let lowered = stripped.to_ascii_lowercase();
    if NON_CHANNEL_LABELS.contains(&lowered.as_str()) {
        return None;
    }
    let slug = stripped.trim_start_matches('#');
    if !looks_like_channel_slug(slug) {
        return None;
    }
    Some(slug.to_string())
}

/// Scan an arbitrary string for a `#name` token (workspace switcher
/// labels, breadcrumbs, jumper hints). Returns the first token that
/// looks like a Slack channel slug.
fn parse_hash_token(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'#' {
            i += 1;
            continue;
        }
        let prev_is_word = i > 0 && bytes[i - 1].is_ascii_alphanumeric();
        if prev_is_word {
            i += 1;
            continue;
        }
        let start = i + 1;
        let mut end = start;
        while end < bytes.len() {
            let b = bytes[end];
            if b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'-' | b'_' | b'.') {
                end += 1;
            } else {
                break;
            }
        }
        let token = &raw[start..end];
        if looks_like_channel_slug(token) {
            return Some(token.to_string());
        }
        i = end.max(i + 1);
    }
    None
}

/// Slack channel names are lowercase ASCII letters/digits plus `-`,
/// `_`, `.`; 1..=80 chars; must start with a letter or digit.
fn looks_like_channel_slug(name: &str) -> bool {
    if name.is_empty() || name.len() > 80 {
        return false;
    }
    let bytes = name.as_bytes();
    if !(bytes[0].is_ascii_lowercase() || bytes[0].is_ascii_digit()) {
        return false;
    }
    bytes
        .iter()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'-' | b'_' | b'.'))
}

/// `"<channel> (Channel) - <Workspace> - Slack"` (also `"(Private
/// channel)"`). Returns `(channel, workspace)`. DMs and group DMs are
/// rejected because their channel-name slot isn't a slug.
fn parse_window_title(title: &str) -> Option<(String, String)> {
    let inner = title.trim().strip_suffix(" - Slack")?.trim();
    let (left, workspace) = inner.rsplit_once(" - ")?;
    let workspace = workspace.trim();
    let left = left.trim();
    for suffix in [" (Channel)", " (Private channel)"] {
        if let Some(name) = left.strip_suffix(suffix) {
            let name = name.trim_start_matches('#');
            if looks_like_channel_slug(name) {
                return Some((name.to_string(), workspace.to_string()));
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Session cache
// ---------------------------------------------------------------------------

fn session_cache() -> &'static Mutex<HashMap<i64, HashMap<String, Channel>>> {
    SESSION_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn merge_into_session_cache(pid: i64, channels: Vec<Channel>) {
    let Ok(mut cache) = session_cache().lock() else {
        return;
    };
    let entry = cache.entry(pid).or_default();
    let seen_keys: HashSet<String> = channels
        .iter()
        .map(|c| c.name.to_ascii_lowercase())
        .collect();
    for mut channel in channels {
        channel.pid = Some(pid);
        attach_workspace(&mut channel);
        let key = channel.name.to_ascii_lowercase();
        match entry.get_mut(&key) {
            Some(existing) => merge_channel(existing, channel),
            None => {
                entry.insert(key, channel);
            }
        }
    }
    // Cached channels that didn't reappear in this snapshot keep their
    // metadata but their AX handle becomes stale; clear it so the
    // resolver re-snapshots before pressing.
    for (key, ch) in entry.iter_mut() {
        if !seen_keys.contains(key) {
            ch.handle = None;
        }
    }
}

fn session_candidates() -> Vec<Candidate> {
    let Ok(cache) = session_cache().lock() else {
        return Vec::new();
    };
    let mut all: Vec<Channel> = cache.values().flat_map(|m| m.values().cloned()).collect();
    all.sort_by(|a, b| {
        a.team_name
            .cmp(&b.team_name)
            .then_with(|| a.team_id.cmp(&b.team_id))
            .then_with(|| a.name.cmp(&b.name))
    });
    all.iter().map(candidate).collect()
}

fn merge_channel(into: &mut Channel, other: Channel) {
    if into.channel_id.is_none() {
        into.channel_id = other.channel_id;
    }
    if into.team_id.is_none() {
        into.team_id = other.team_id;
    }
    if into.team_name.is_none() {
        into.team_name = other.team_name;
    }
    if other.handle.is_some() {
        into.handle = other.handle;
    }
    if other.pid.is_some() {
        into.pid = other.pid;
    }
}

// ---------------------------------------------------------------------------
// Workspace metadata
// ---------------------------------------------------------------------------

/// Slack writes workspace metadata (team_id → name, domain) to
/// `~/Library/Application Support/Slack/storage/root-state.json` as
/// plain JSON. It's the only Slack-local store that isn't V8-serialized
/// or snappy-compressed, so it's the only one we can read directly.
/// The actual channel list lives in IndexedDB behind a binary wrapper —
/// reachable only via the live app, hence the AX walk.
fn refresh_workspaces() {
    let Some(home) = std::env::var_os("HOME") else {
        return;
    };
    let path = PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Slack")
        .join("storage")
        .join("root-state.json");
    let Ok(text) = fs::read_to_string(&path) else {
        return;
    };
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else {
        return;
    };
    let Some(workspaces) = json.get("workspaces").and_then(|v| v.as_object()) else {
        return;
    };
    let mut map = HashMap::new();
    for (team_id, ws) in workspaces {
        map.insert(
            team_id.clone(),
            Workspace {
                team_id: team_id.clone(),
                team_name: ws.get("name").and_then(|v| v.as_str()).map(str::to_string),
            },
        );
    }
    let cell = WORKSPACES.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut guard) = cell.lock() {
        *guard = map;
    }
}

fn attach_workspace(channel: &mut Channel) {
    let Some(cell) = WORKSPACES.get() else {
        return;
    };
    let Ok(guard) = cell.lock() else {
        return;
    };
    if let Some(team_id) = channel.team_id.clone() {
        if let Some(ws) = guard.get(&team_id) {
            if channel.team_name.is_none() {
                channel.team_name = ws.team_name.clone();
            }
        }
        return;
    }
    // No team yet — if there's exactly one known workspace, attribute
    // the channel to it. (Multi-workspace Slack users would need IDs
    // from config or the IDB to disambiguate.)
    if guard.len() == 1 {
        if let Some(ws) = guard.values().next() {
            channel.team_id = Some(ws.team_id.clone());
            if channel.team_name.is_none() {
                channel.team_name = ws.team_name.clone();
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Config-driven channels (declarative fallback)
// ---------------------------------------------------------------------------

/// Users on multi-workspace Slack or who want full coverage without
/// scrolling can declare channels in their flash config:
///
/// ```toml
/// [plugin.slack]
/// channels = [
///   { name = "general", id = "C123", team = "T456" },
///   { name = "random" },
/// ]
/// ```
///
/// These are merged into the session cache so they survive snapshots.
fn seed_from_config(ctx: &Context) {
    let configured: Vec<ConfiguredChannel> = ctx.config_json("channels").unwrap_or_default();
    if configured.is_empty() {
        return;
    }
    let Ok(mut cache) = session_cache().lock() else {
        return;
    };
    // Config-declared channels live under pid 0 (no live AX press
    // target); resolve falls back to the slack:// deep link or focusing
    // a running Slack instance.
    let entry = cache.entry(0).or_default();
    for cfg in configured {
        let name = cfg.name.trim_start_matches('#').to_string();
        if name.is_empty() {
            continue;
        }
        let mut channel = Channel {
            name: name.clone(),
            channel_id: cfg.id,
            team_id: cfg.team,
            team_name: cfg.team_name,
            ..Channel::default()
        };
        attach_workspace(&mut channel);
        let key = name.to_ascii_lowercase();
        entry
            .entry(key)
            .and_modify(|existing| merge_channel(existing, channel.clone()))
            .or_insert(channel);
    }
}

// ---------------------------------------------------------------------------
// Candidate + resolve
// ---------------------------------------------------------------------------

fn candidate(channel: &Channel) -> Candidate {
    let payload = ChannelPayload {
        name: channel.name.clone(),
        channel_id: channel.channel_id.clone(),
        team_id: channel.team_id.clone(),
    };
    let display = format!("#{}", channel.name);
    let mut aliases = vec![channel.name.clone()];
    if let Some(team_name) = &channel.team_name {
        aliases.push(team_name.clone());
    }
    let mut out = Candidate::new(&display)
        .kind("slack_channel")
        .source_id(CHANNEL_SOURCE_ID)
        .source(CHANNEL_SOURCE_LABEL)
        .subtitle(channel_subtitle(channel))
        .aliases(aliases)
        .finishes_command(true)
        .payload_json(&payload);
    if let Some(pid) = channel.pid {
        if pid > 0 {
            out = out.pid(pid);
        }
    }
    if let Some(url) = slack_channel_url(channel.team_id.as_deref(), channel.channel_id.as_deref())
    {
        out = out.url(url);
    }
    out
}

fn channel_subtitle(channel: &Channel) -> String {
    if let Some(team_name) = channel.team_name.as_deref().filter(|s| !s.is_empty()) {
        format!("Slack channel - {team_name}")
    } else if let Some(team_id) = channel.team_id.as_deref().filter(|s| !s.is_empty()) {
        format!("Slack channel - {team_id}")
    } else {
        "Slack channel".to_string()
    }
}

fn slack_channel_url(team_id: Option<&str>, channel_id: Option<&str>) -> Option<String> {
    let channel_id = channel_id?;
    if channel_id.is_empty() {
        return None;
    }
    if let Some(team_id) = team_id.filter(|s| !s.is_empty()) {
        Some(format!("slack://channel?team={team_id}&id={channel_id}"))
    } else {
        Some(format!("slack://channel?id={channel_id}"))
    }
}

/// Resolve a pick: activate Slack, try the deep link first (works for
/// channels with known IDs from config), then fall back to a fresh AX
/// snapshot so we can press the live outline row by name. The cached
/// handle is treated as best-effort — Slack re-renders aggressively
/// and a stored handle is usually stale by the time the user types.
async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let payload = candidate.payload_as::<ChannelPayload>().unwrap_or_default();
    let target_name = if !payload.name.is_empty() {
        payload.name.clone()
    } else {
        candidate.title.trim_start_matches('#').to_string()
    };

    if let Some(pid) = candidate.pid_value() {
        activate_app(ctx, pid).await;
    }

    if let Some(url) = slack_channel_url(payload.team_id.as_deref(), payload.channel_id.as_deref())
    {
        let result =
            run_command(ctx, &["/usr/bin/open".into(), url], Duration::from_secs(10)).await;
        if result.ok {
            return ResolveResponse::resolved(candidate.pid_value());
        }
        ctx.log(
            "warn",
            &format!("[slack] deep link failed: {}", result.stderr.trim()),
        );
    }

    let Some(pid) = candidate.pid_value() else {
        return ResolveResponse::unresolved();
    };
    let channels = collect_ax_channels(ctx, pid).await;
    if let Some(target) = channels
        .iter()
        .find(|c| c.name.eq_ignore_ascii_case(&target_name))
    {
        if let Some(handle) = target.handle {
            if !ax_perform(ctx, handle, "AXPress").await {
                ax_set(ctx, handle, "AXSelected", true).await;
            }
        }
    }
    ResolveResponse::resolved(Some(pid))
}

fn prepend(program: &str, args: &[String]) -> Vec<String> {
    let mut argv = Vec::with_capacity(args.len() + 1);
    argv.push(program.to_string());
    argv.extend_from_slice(args);
    argv
}

#[derive(Clone, Debug, Default)]
struct AxNode {
    handle: u64,
    _root: usize,
    attrs: BTreeMap<String, String>,
    _frame: Option<[f64; 4]>,
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
                    .filter_map(|(key, value)| {
                        value
                            .as_str()
                            .map(|string| (key.clone(), string.to_string()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        let frame = value
            .get("frame")
            .and_then(Value::as_array)
            .and_then(|values| {
                if values.len() != 4 {
                    return None;
                }
                Some([
                    values[0].as_f64()?,
                    values[1].as_f64()?,
                    values[2].as_f64()?,
                    values[3].as_f64()?,
                ])
            });
        Some(Self {
            handle,
            _root: root,
            attrs,
            _frame: frame,
        })
    }

    fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
    }
}

#[derive(Clone, Debug, Default)]
struct CommandOutput {
    ok: bool,
    stdout: String,
    stderr: String,
    _status: i32,
}

impl CommandOutput {
    fn into_command(self) -> CommandResponse {
        CommandResponse {
            ok: self.ok,
            stdout: (!self.stdout.trim().is_empty()).then(|| shorten(&self.stdout)),
            error: (!self.ok && !self.stderr.trim().is_empty()).then(|| shorten(&self.stderr)),
            ..Default::default()
        }
    }
}

async fn activate_app(ctx: &Context, pid: i64) -> bool {
    ctx.call_host("app.activate", json!({ "pid": pid }))
        .await
        .get("ok")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

async fn ax_snapshot(
    ctx: &Context,
    pid: i64,
    roots: &str,
    follow: &[&str],
    collect: &[&str],
    max_nodes: u64,
    geometry: bool,
) -> Vec<AxNode> {
    let result = ctx
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

async fn ax_perform(ctx: &Context, handle: u64, action: &str) -> bool {
    ctx.call_host("ax.perform", json!({ "handle": handle, "action": action }))
        .await
        .get("ok")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

async fn ax_set(ctx: &Context, handle: u64, attribute: &str, value: bool) -> bool {
    ctx.call_host(
        "ax.set",
        json!({ "handle": handle, "attribute": attribute, "value": value }),
    )
    .await
    .get("ok")
    .and_then(Value::as_bool)
    .unwrap_or(false)
}

async fn run_command(ctx: &Context, argv: &[String], timeout: Duration) -> CommandOutput {
    let Some((program, args)) = argv.split_first() else {
        return CommandOutput {
            ok: false,
            stderr: "empty argv".to_string(),
            _status: -1,
            ..Default::default()
        };
    };
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
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    match tokio::time::timeout(timeout, command.output()).await {
        Ok(Ok(output)) => CommandOutput {
            ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            _status: output.status.code().unwrap_or(-1),
        },
        Ok(Err(err)) => CommandOutput {
            ok: false,
            stderr: err.to_string(),
            _status: -1,
            ..Default::default()
        },
        Err(_) => CommandOutput {
            ok: false,
            stderr: format!("timed out after {}ms", timeout.as_millis()),
            _status: 124,
            ..Default::default()
        },
    }
}

fn shorten(value: &str) -> String {
    const LIMIT: usize = 2000;
    let trimmed = value.trim();
    if trimmed.chars().count() <= LIMIT {
        return trimmed.to_string();
    }
    let head: String = trimmed.chars().take(LIMIT - 3).collect();
    format!("{head}...")
}

fn main() {
    run(Slack);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn node(role: &str, attrs: &[(&str, &str)]) -> AxNode {
        let mut map = BTreeMap::new();
        map.insert("AXRole".to_string(), role.to_string());
        for (k, v) in attrs {
            map.insert((*k).to_string(), (*v).to_string());
        }
        AxNode {
            handle: 1,
            _root: 0,
            attrs: map,
            _frame: None,
        }
    }

    #[test]
    fn parses_sidebar_label_strips_status_suffix() {
        assert_eq!(
            parse_sidebar_label("office-paris (has unread messages)").as_deref(),
            Some("office-paris")
        );
        assert_eq!(
            parse_sidebar_label("team-linear (muted) (3 new)").as_deref(),
            Some("team-linear")
        );
        assert_eq!(
            parse_sidebar_label("z-notif-design-partners").as_deref(),
            Some("z-notif-design-partners")
        );
        assert_eq!(parse_sidebar_label("#general").as_deref(), Some("general"));
    }

    #[test]
    fn parses_sidebar_label_rejects_chrome() {
        // Section headers and toolbar labels look identical to channel
        // rows in the AX tree — only the literal text distinguishes
        // them, hence the static deny-list.
        assert_eq!(parse_sidebar_label("Threads"), None);
        assert_eq!(parse_sidebar_label("Huddles"), None);
        assert_eq!(parse_sidebar_label("Channels"), None);
        assert_eq!(parse_sidebar_label("Direct Messages"), None);
        assert_eq!(parse_sidebar_label("Apps"), None);
        // Mixed-case names (DM display names) don't match the slug
        // pattern and are filtered out.
        assert_eq!(parse_sidebar_label("Kevin Cathaly"), None);
    }

    #[test]
    fn channel_name_from_outline_row() {
        let row = node(
            "AXRow",
            &[
                ("AXSubrole", "AXOutlineRow"),
                ("AXDescription", "z-notif-design-partners"),
                ("AXRoleDescription", "outline row"),
            ],
        );
        assert_eq!(
            sidebar_channel_name(&row).as_deref(),
            Some("z-notif-design-partners")
        );
    }

    #[test]
    fn button_hint_extracts_channel_from_header_bar() {
        // The header bar (above the message composer) always has a
        // "Channel details for #foo" button whose description carries
        // the active channel name even when the sidebar row isn't
        // visible.
        let button = node(
            "AXButton",
            &[(
                "AXDescription",
                "Channel details for #z-notif-design-partners",
            )],
        );
        assert_eq!(
            button_channel_hint(&button).as_deref(),
            Some("z-notif-design-partners")
        );
        let huddle = node(
            "AXButton",
            &[("AXDescription", "Start huddle in office-paris")],
        );
        assert_eq!(
            button_channel_hint(&huddle).as_deref(),
            Some("office-paris")
        );
    }

    #[test]
    fn window_title_yields_active_channel() {
        assert_eq!(
            parse_window_title("z-notif-design-partners (Channel) - Beside - Slack"),
            Some(("z-notif-design-partners".into(), "Beside".into()))
        );
        assert_eq!(
            parse_window_title("private-room (Private channel) - Beside - Slack"),
            Some(("private-room".into(), "Beside".into()))
        );
        // DMs and group DMs (display names, not slugs) get filtered.
        assert_eq!(
            parse_window_title("Kevin Cathaly (Direct message) - Beside - Slack"),
            None
        );
        assert_eq!(parse_window_title("Slack"), None);
    }

    #[test]
    fn hash_token_scanner_finds_loose_mentions() {
        assert_eq!(
            parse_hash_token("Search in #general").as_deref(),
            Some("general")
        );
        // No false positive for hashtag-like strings (alphanumeric prefix).
        assert_eq!(parse_hash_token("issue#42 reopened"), None);
        // Uppercase / mixed case isn't a Slack channel slug.
        assert_eq!(parse_hash_token("#Foo"), None);
    }

    #[test]
    fn looks_like_channel_slug_accepts_typical_names() {
        assert!(looks_like_channel_slug("general"));
        assert!(looks_like_channel_slug("z-notif-design-partners"));
        assert!(looks_like_channel_slug("team_linear"));
        assert!(looks_like_channel_slug("2026-planning"));
        assert!(!looks_like_channel_slug(""));
        assert!(!looks_like_channel_slug("UPPER"));
        assert!(!looks_like_channel_slug("has spaces"));
        assert!(!looks_like_channel_slug("-leading-dash"));
    }

    #[test]
    fn merge_keeps_strongest_metadata() {
        let mut into = Channel {
            name: "general".into(),
            handle: Some(1),
            ..Channel::default()
        };
        merge_channel(
            &mut into,
            Channel {
                name: "general".into(),
                channel_id: Some("C123".into()),
                team_id: Some("T456".into()),
                team_name: Some("Beside".into()),
                handle: Some(2),
                pid: Some(99),
                ..Channel::default()
            },
        );
        assert_eq!(into.channel_id.as_deref(), Some("C123"));
        assert_eq!(into.team_id.as_deref(), Some("T456"));
        assert_eq!(into.team_name.as_deref(), Some("Beside"));
        assert_eq!(into.handle, Some(2));
        assert_eq!(into.pid, Some(99));
    }

    #[test]
    fn candidate_has_deep_link_when_id_present() {
        let channel = Channel {
            name: "general".into(),
            channel_id: Some("C123".into()),
            team_id: Some("T456".into()),
            team_name: Some("Beside".into()),
            pid: Some(42),
            ..Channel::default()
        };
        let c = candidate(&channel);
        assert_eq!(c.title, "#general");
        assert_eq!(c.url_value(), Some("slack://channel?team=T456&id=C123"));
        assert_eq!(c.pid_value(), Some(42));
        let payload = c.payload_as::<ChannelPayload>().unwrap();
        assert_eq!(payload.name, "general");
    }

    #[test]
    fn candidate_omits_pid_for_config_seeded_entries() {
        let channel = Channel {
            name: "random".into(),
            pid: Some(0),
            ..Channel::default()
        };
        assert_eq!(candidate(&channel).pid_value(), None);
    }
}
