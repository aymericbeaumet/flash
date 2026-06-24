use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use flash_plugin::{
    run, Candidate, CommandRequest, CommandResponse, Context, Event, NavigationRequest, Priority,
    ResolveResponse, SourceActionResponse,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::AsyncWriteExt;

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
    "AXURL",
    "AXDocument",
];
/// Slack's Electron tree is deep (collapsed sections, DMs, huddles,
/// threads, the workspace switcher). The visit budget matches the old
/// walk so busy workspaces don't silently truncate.
const MAX_NODES: u64 = 30_000;
const LOCAL_STORAGE_REFRESH_INTERVAL: Duration = Duration::from_secs(300);

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
    "channel",
    "new message",
    "message",
    "conversation",
    "reply",
    "thread",
    "jump",
    "history",
    "profile",
    "help",
];

/// Discovered channels accumulate here across snapshots so virtualized
/// sidebar rows don't vanish from the candidate list every time Slack
/// re-renders. Keyed by pid → durable route key when known, otherwise
/// a workspace-qualified lowercased name.
static SESSION_CACHE: OnceLock<Mutex<HashMap<i64, HashMap<String, Channel>>>> = OnceLock::new();
static LOCAL_STORAGE_LAST_SEEDED: OnceLock<Mutex<Option<Instant>>> = OnceLock::new();
/// Workspace metadata parsed from `root-state.json`: team_id → workspace.
static WORKSPACES: OnceLock<Mutex<HashMap<String, Workspace>>> = OnceLock::new();
/// Archived channels discovered from durable inventory sources. When present,
/// this filters older local-cache/AX rows whose desktop storage has not caught
/// up yet.
static ARCHIVED_CHANNEL_IDS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

const API_CACHE_PID: i64 = -1;

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
    current: bool,
    unread: bool,
    starred: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct ChannelPayload {
    name: String,
    channel_id: Option<String>,
    team_id: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct SlackRoute {
    team_id: Option<String>,
    channel_id: Option<String>,
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

#[derive(Clone, Debug, Eq, PartialEq)]
struct SidebarLabel {
    name: String,
    unread: bool,
    starred: bool,
}

struct Slack;

flash_plugin::plugin!(Slack);

impl FlashPlugin for Slack {
    async fn on_start(&self, ctx: Context) {
        refresh_workspaces(&ctx);
        seed_from_slack_api(&ctx).await;
        seed_from_local_storage_if_stale(&ctx, true);
        seed_from_config(&ctx);
        ctx.emit_snapshot(CHANNEL_SOURCE_ID, session_candidates());
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            "core:apps.snapshot" | "core:flashlight.opened" => {
                let pids = event
                    .running_applications
                    .iter()
                    .filter(|app| SLACK_BUNDLES.contains(&app.bundle_id.as_str()))
                    .map(|app| app.pid)
                    .collect::<Vec<_>>();
                refresh_workspaces(&ctx);
                refresh_snapshot(&ctx, pids).await;
            }
            "core:config.changed" => {
                refresh_workspaces(&ctx);
                seed_from_slack_api(&ctx).await;
                seed_from_local_storage_if_stale(&ctx, true);
                seed_from_config(&ctx);
                refresh_snapshot(&ctx, Vec::new()).await;
            }
            "core:focus.changed" | "core:window.focus.changed" => {
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

    async fn restore_navigation(
        &self,
        ctx: Context,
        request: NavigationRequest,
    ) -> SourceActionResponse {
        restore_navigation(&ctx, &request).await
    }
}

async fn refresh_snapshot(ctx: &Context, pids: Vec<i64>) {
    seed_from_local_storage_if_stale(ctx, false);
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
///   1. Sidebar row/text descendants — handle-bearing rows that
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
    let mut current_route: Option<SlackRoute> = None;

    for node in &nodes {
        if let Some(route) = node_slack_route(node) {
            current_route = Some(route);
        }

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
        if let Some(sidebar) = sidebar_channel(node) {
            let key = sidebar.name.to_ascii_lowercase();
            let entry = out.entry(key).or_insert_with(|| Channel {
                name: sidebar.name.clone(),
                pid: Some(pid),
                ..Channel::default()
            });
            if entry.handle.is_none() {
                entry.handle = Some(node.handle);
            }
            if sidebar.unread {
                entry.unread = true;
            }
            if sidebar.starred {
                entry.starred = true;
            }
            continue;
        }

        // Header-bar buttons: no handle (a press would just re-open the
        // already-current channel), but the description carries the
        // current channel name.
        if let Some(name) = button_channel_hint(node) {
            let key = name.to_ascii_lowercase();
            out.entry(key)
                .and_modify(|channel| channel.current = true)
                .or_insert_with(|| Channel {
                    name,
                    pid: Some(pid),
                    current: true,
                    ..Channel::default()
                });
        }
    }

    if let Some(name) = window_channel {
        let key = name.to_ascii_lowercase();
        let entry = out
            .entry(key)
            .and_modify(|channel| channel.current = true)
            .or_insert_with(|| Channel {
                name,
                pid: Some(pid),
                current: true,
                ..Channel::default()
            });
        if entry.team_name.is_none() {
            entry.team_name = window_team_name;
        }
    }
    if let Some(route) = current_route.as_ref() {
        for channel in out.values_mut().filter(|channel| channel.current) {
            apply_route(channel, route);
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
fn sidebar_channel(node: &AxNode) -> Option<SidebarLabel> {
    if !is_sidebar_channel_node(node) {
        return None;
    }
    for attr in ["AXDescription", "AXTitle", "AXValue"] {
        if let Some(raw) = node.attr(attr) {
            if let Some(label) = parse_sidebar_label_details(raw) {
                return Some(label);
            }
        }
    }
    None
}

#[cfg(test)]
fn sidebar_channel_name(node: &AxNode) -> Option<String> {
    sidebar_channel(node).map(|label| label.name)
}

fn is_sidebar_channel_node(node: &AxNode) -> bool {
    let role = node.attr("AXRole").unwrap_or("");
    let subrole = node.attr("AXSubrole").unwrap_or("");
    let role_desc = node.attr("AXRoleDescription").unwrap_or("").to_lowercase();
    subrole == "AXOutlineRow"
        || role_desc.contains("outline row")
        || matches!(role, "AXRow" | "AXCell" | "AXStaticText" | "AXGroup")
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

#[cfg(test)]
fn parse_sidebar_label(raw: &str) -> Option<String> {
    parse_sidebar_label_details(raw).map(|label| label.name)
}

fn parse_sidebar_label_details(raw: &str) -> Option<SidebarLabel> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    // Strip trailing " (status)" segments; Slack chains them
    // ("foo (muted) (1 new)") so peel repeatedly.
    let mut stripped = trimmed;
    let mut unread = false;
    let mut starred = false;
    while stripped.ends_with(')') {
        let Some(open) = stripped.rfind(" (") else {
            break;
        };
        let status = stripped[open + 2..stripped.len() - 1].to_ascii_lowercase();
        if status.contains("unread") || status.contains(" new") || status.ends_with("new") {
            unread = true;
        }
        if status.contains("starred") {
            starred = true;
        }
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
    Some(SidebarLabel {
        name: slug.to_string(),
        unread,
        starred,
    })
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
    let inner = strip_window_status(title.trim().strip_suffix(" - Slack")?.trim());
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

fn strip_window_status(title: &str) -> &str {
    let Some((prefix, suffix)) = title.rsplit_once(" - ") else {
        return title;
    };
    let suffix = suffix.trim();
    if suffix == "1 new item" || suffix.ends_with(" new items") {
        prefix.trim_end()
    } else {
        title
    }
}

fn node_slack_route(node: &AxNode) -> Option<SlackRoute> {
    for attr in ["AXURL", "AXDocument", "AXValue"] {
        if let Some(raw) = node.attr(attr) {
            if let Some(route) = parse_slack_route(raw) {
                return Some(route);
            }
        }
    }
    None
}

fn parse_slack_route(raw: &str) -> Option<SlackRoute> {
    if let Some(path) = raw.strip_prefix("https://app.slack.com/client/") {
        let mut parts = path.split(['/', '?', '#']);
        let team = parts.next().unwrap_or("").trim();
        let channel = parts.next().unwrap_or("").trim();
        if is_slack_team_id(team) && is_slack_channel_id(channel) {
            return Some(SlackRoute {
                team_id: Some(team.to_string()),
                channel_id: Some(channel.to_string()),
            });
        }
    }
    if let Some(query) = raw.strip_prefix("slack://channel?") {
        let mut route = SlackRoute::default();
        for pair in query.split('&') {
            let mut parts = pair.splitn(2, '=');
            let key = parts.next().unwrap_or("");
            let value = parts.next().unwrap_or("").trim();
            match key {
                "team" if is_slack_team_id(value) => route.team_id = Some(value.to_string()),
                "id" if is_slack_channel_id(value) => route.channel_id = Some(value.to_string()),
                _ => {}
            }
        }
        if route.channel_id.is_some() {
            return Some(route);
        }
    }
    None
}

fn apply_route(channel: &mut Channel, route: &SlackRoute) {
    if channel.team_id.is_none() {
        channel.team_id = route.team_id.clone();
    }
    if channel.channel_id.is_none() {
        channel.channel_id = route.channel_id.clone();
    }
}

fn is_slack_team_id(raw: &str) -> bool {
    raw.len() >= 9 && raw.starts_with('T') && raw.chars().all(is_slack_id_char)
}

fn is_slack_channel_id(raw: &str) -> bool {
    raw.len() >= 9
        && matches!(raw.as_bytes().first(), Some(b'C' | b'G'))
        && raw.chars().all(is_slack_id_char)
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
    for channel in entry.values_mut() {
        channel.current = false;
    }
    let seen_keys: HashSet<String> = channels
        .iter()
        .cloned()
        .map(|mut c| {
            attach_workspace(&mut c);
            channel_cache_key(&c)
        })
        .collect();
    for mut channel in channels {
        channel.pid = Some(pid);
        attach_workspace(&mut channel);
        let key = channel_cache_key(&channel);
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
    let archived = archived_channel_ids_snapshot();
    let mut merged: HashMap<String, Channel> = HashMap::new();
    for channel in cache.values().flat_map(|m| m.values().cloned()) {
        if channel
            .channel_id
            .as_deref()
            .is_some_and(|id| archived.contains(id))
        {
            continue;
        }
        let key = channel_cache_key(&channel);
        match merged.get_mut(&key) {
            Some(existing) => merge_channel(existing, channel),
            None => {
                merged.insert(key, channel);
            }
        }
    }
    let mut all: Vec<Channel> = merged.into_values().collect();
    all.sort_by(|a, b| {
        channel_priority(b)
            .cmp(&channel_priority(a))
            .then_with(|| a.team_name.cmp(&b.team_name))
            .then_with(|| a.team_id.cmp(&b.team_id))
            .then_with(|| a.name.cmp(&b.name))
    });
    all.iter().map(candidate).collect()
}

fn channel_cache_key(channel: &Channel) -> String {
    let name = channel.name.to_ascii_lowercase();
    match (channel.team_id.as_deref(), channel.channel_id.as_deref()) {
        (Some(team), Some(id)) if !team.is_empty() && !id.is_empty() => {
            format!("route:{team}:{id}")
        }
        (_, Some(id)) if !id.is_empty() => format!("id:{id}"),
        (Some(team), _) if !team.is_empty() => format!("name:{team}:{name}"),
        _ => format!("name::{name}"),
    }
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
    if other.current {
        into.current = true;
    }
    if other.unread {
        into.unread = true;
    }
    if other.starred {
        into.starred = true;
    }
}

fn channel_priority(channel: &Channel) -> Priority {
    if channel.current {
        Priority::Critical
    } else if channel.unread {
        Priority::High
    } else if channel.starred {
        Priority::High
    } else if channel.channel_id.is_some() {
        Priority::Normal
    } else {
        Priority::Background
    }
}

fn archived_channel_ids_snapshot() -> HashSet<String> {
    let Some(cell) = ARCHIVED_CHANNEL_IDS.get() else {
        return HashSet::new();
    };
    let Ok(guard) = cell.lock() else {
        return HashSet::new();
    };
    guard.clone()
}

// ---------------------------------------------------------------------------
// Workspace metadata
// ---------------------------------------------------------------------------

/// Slack writes workspace metadata (team_id → name, domain) to
/// `~/Library/Application Support/Slack/storage/root-state.json` as
/// plain JSON. Conversation records in IndexedDB/WebStorage are
/// Chromium/V8 serialized, so we scan them conservatively for the readable
/// field names Slack already writes (`id`, `name`, `is_channel`, `team_id`).
fn refresh_workspaces(ctx: &Context) {
    let path = slack_data_dir(ctx).join("storage").join("root-state.json");
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

fn slack_data_dir(ctx: &Context) -> PathBuf {
    let configured = ctx.config_str("data_dir");
    if configured.trim().is_empty() {
        default_slack_data_dir()
    } else {
        expand_home(configured.trim())
    }
}

fn default_slack_data_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Library")
        .join("Application Support")
        .join("Slack")
}

fn expand_home(path: &str) -> PathBuf {
    if path == "~" {
        return std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(path));
    }
    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(path)
}

fn seed_from_local_storage_if_stale(ctx: &Context, force: bool) {
    let now = Instant::now();
    let cell = LOCAL_STORAGE_LAST_SEEDED.get_or_init(|| Mutex::new(None));
    let Ok(mut last) = cell.lock() else {
        return seed_from_local_storage(ctx);
    };
    if !force
        && last
            .as_ref()
            .is_some_and(|instant| now.duration_since(*instant) < LOCAL_STORAGE_REFRESH_INTERVAL)
    {
        return;
    }
    *last = Some(now);
    drop(last);
    seed_from_local_storage(ctx);
}

fn seed_from_local_storage(ctx: &Context) {
    let channels = local_storage_channels(&slack_data_dir(ctx));
    if channels.is_empty() {
        return;
    }
    let Ok(mut cache) = session_cache().lock() else {
        return;
    };
    let entry = cache.entry(0).or_default();
    for mut channel in channels {
        attach_workspace(&mut channel);
        let key = channel_cache_key(&channel);
        entry
            .entry(key)
            .and_modify(|existing| merge_channel(existing, channel.clone()))
            .or_insert(channel);
    }
}

async fn seed_from_slack_api(ctx: &Context) {
    let Some(token) = slack_api_token(ctx) else {
        replace_api_channels(Vec::new());
        set_archived_channel_ids(HashSet::new());
        return;
    };
    let Some(inventory) = fetch_slack_api_inventory(ctx, &token).await else {
        return;
    };
    set_archived_channel_ids(inventory.archived_ids);
    replace_api_channels(inventory.channels);
}

fn slack_api_token(ctx: &Context) -> Option<String> {
    let configured = ctx.config_str("api_token");
    let token = if configured.trim().is_empty() {
        std::env::var("SLACK_API_TOKEN").unwrap_or_default()
    } else {
        configured
    };
    let trimmed = token.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

#[derive(Clone, Debug, Default)]
struct ApiInventory {
    channels: Vec<Channel>,
    archived_ids: HashSet<String>,
}

async fn fetch_slack_api_inventory(ctx: &Context, token: &str) -> Option<ApiInventory> {
    let fallback_team = fetch_slack_api_team_id(ctx, token).await;
    let mut inventory = ApiInventory::default();
    let mut cursor = String::new();
    for _ in 0..20 {
        let mut params = vec![
            ("types", "public_channel,private_channel".to_string()),
            ("exclude_archived", "false".to_string()),
            ("limit", "1000".to_string()),
        ];
        if !cursor.is_empty() {
            params.push(("cursor", cursor.clone()));
        }
        let json = slack_api_get(ctx, token, "conversations.list", &params).await?;
        let channels = json
            .get("channels")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for item in channels {
            if let Some(id) = api_channel_id(&item) {
                if api_bool(&item, "is_archived") {
                    inventory.archived_ids.insert(id);
                    continue;
                }
            }
            if let Some(channel) = api_channel(&item, fallback_team.as_deref()) {
                inventory.channels.push(channel);
            }
        }
        cursor = json
            .get("response_metadata")
            .and_then(|metadata| metadata.get("next_cursor"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        if cursor.is_empty() {
            break;
        }
    }
    ctx.log(
        "debug",
        &format!(
            "[slack] api seeded channels={} archived={}",
            inventory.channels.len(),
            inventory.archived_ids.len()
        ),
    );
    Some(inventory)
}

async fn fetch_slack_api_team_id(ctx: &Context, token: &str) -> Option<String> {
    let json = slack_api_get(ctx, token, "team.info", &[]).await?;
    let id = json
        .get("team")
        .and_then(|team| team.get("id"))
        .and_then(Value::as_str)
        .unwrap_or("");
    is_slack_team_id(id).then(|| id.to_string())
}

fn api_channel(value: &Value, fallback_team: Option<&str>) -> Option<Channel> {
    if api_bool(value, "is_im") || api_bool(value, "is_mpim") {
        return None;
    }
    let channel_id = api_channel_id(value)?;
    let name = value
        .get("name_normalized")
        .and_then(Value::as_str)
        .or_else(|| value.get("name").and_then(Value::as_str))
        .unwrap_or("")
        .trim()
        .trim_start_matches('#')
        .to_string();
    if !looks_like_channel_slug(&name) {
        return None;
    }
    let team_id = api_team_id(value)
        .or_else(|| fallback_team.map(str::to_string))
        .filter(|team| is_slack_team_id(team));
    Some(Channel {
        name,
        channel_id: Some(channel_id),
        team_id,
        unread: api_bool(value, "has_unreads")
            || api_bool(value, "has_unread_messages")
            || api_u64(value, "unread_count") > 0
            || api_u64(value, "unread_count_display") > 0
            || api_u64(value, "num_unreads") > 0,
        starred: api_bool(value, "is_starred") || api_bool(value, "is_user_starred"),
        ..Channel::default()
    })
}

fn api_channel_id(value: &Value) -> Option<String> {
    let id = value.get("id").and_then(Value::as_str).unwrap_or("").trim();
    is_slack_channel_id(id).then(|| id.to_string())
}

fn api_team_id(value: &Value) -> Option<String> {
    for key in ["context_team_id", "team_id", "conversation_host_id"] {
        let id = value.get(key).and_then(Value::as_str).unwrap_or("").trim();
        if is_slack_team_id(id) {
            return Some(id.to_string());
        }
    }
    value
        .get("shared_team_ids")
        .and_then(Value::as_array)
        .and_then(|ids| {
            ids.iter()
                .filter_map(Value::as_str)
                .find(|id| is_slack_team_id(id))
        })
        .map(str::to_string)
}

fn api_bool(value: &Value, key: &str) -> bool {
    value.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn api_u64(value: &Value, key: &str) -> u64 {
    value.get(key).and_then(Value::as_u64).unwrap_or(0)
}

fn replace_api_channels(channels: Vec<Channel>) {
    let Ok(mut cache) = session_cache().lock() else {
        return;
    };
    if channels.is_empty() {
        cache.remove(&API_CACHE_PID);
        return;
    }
    let mut entry = HashMap::new();
    for mut channel in channels {
        attach_workspace(&mut channel);
        let key = channel_cache_key(&channel);
        entry
            .entry(key)
            .and_modify(|existing| merge_channel(existing, channel.clone()))
            .or_insert(channel);
    }
    cache.insert(API_CACHE_PID, entry);
}

fn set_archived_channel_ids(ids: HashSet<String>) {
    let cell = ARCHIVED_CHANNEL_IDS.get_or_init(|| Mutex::new(HashSet::new()));
    if let Ok(mut guard) = cell.lock() {
        *guard = ids;
    }
}

async fn slack_api_get(
    ctx: &Context,
    token: &str,
    method: &str,
    params: &[(&str, String)],
) -> Option<Value> {
    let url = slack_api_url(method, params);
    let config = curl_config(&url, token);
    let result = run_curl_config(ctx, &config, Duration::from_secs(20)).await;
    if !result.ok {
        ctx.log(
            "warn",
            &format!("[slack] {method} failed: {}", result.stderr.trim()),
        );
        return None;
    }
    let json: Value = match serde_json::from_str(&result.stdout) {
        Ok(json) => json,
        Err(err) => {
            ctx.log(
                "warn",
                &format!("[slack] {method} JSON parse failed: {err}"),
            );
            return None;
        }
    };
    if json.get("ok").and_then(Value::as_bool) == Some(true) {
        return Some(json);
    }
    let error = json
        .get("error")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    ctx.log("warn", &format!("[slack] {method} returned error={error}"));
    None
}

fn slack_api_url(method: &str, params: &[(&str, String)]) -> String {
    let mut url = format!("https://slack.com/api/{method}");
    if !params.is_empty() {
        url.push('?');
        for (index, (key, value)) in params.iter().enumerate() {
            if index > 0 {
                url.push('&');
            }
            url.push_str(&percent_encode(key));
            url.push('=');
            url.push_str(&percent_encode(value));
        }
    }
    url
}

fn curl_config(url: &str, token: &str) -> String {
    format!(
        "url = \"{}\"\nheader = \"Authorization: Bearer {}\"\nconnect-timeout = 5\nmax-time = 20\nretry = 0\n",
        curl_config_string(url),
        curl_config_string(token)
    )
}

fn curl_config_string(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "")
        .replace('\r', "")
}

async fn run_curl_config(ctx: &Context, config: &str, timeout: Duration) -> CommandOutput {
    let mut command = tokio::process::Command::new("/usr/bin/curl");
    command
        .arg("-fsS")
        .arg("--config")
        .arg("-")
        .current_dir(&ctx.data_dir)
        .env("HOME", ctx.home_dir())
        .env("XDG_CONFIG_HOME", ctx.config_dir())
        .env("XDG_CACHE_HOME", ctx.cache_dir())
        .env("XDG_DATA_HOME", ctx.share_dir())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(err) => {
            return CommandOutput {
                ok: false,
                stderr: err.to_string(),
                _status: -1,
                ..Default::default()
            };
        }
    };
    if let Some(mut stdin) = child.stdin.take() {
        if let Err(err) = stdin.write_all(config.as_bytes()).await {
            return CommandOutput {
                ok: false,
                stderr: err.to_string(),
                _status: -1,
                ..Default::default()
            };
        }
    }
    match tokio::time::timeout(timeout, child.wait_with_output()).await {
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

fn percent_encode(raw: &str) -> String {
    let mut out = String::new();
    for byte in raw.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn local_storage_channels(data_dir: &Path) -> Vec<Channel> {
    let mut out: HashMap<String, Channel> = HashMap::new();
    for path in slack_indexeddb_files(data_dir) {
        let Ok(bytes) = fs::read(&path) else {
            continue;
        };
        for mut channel in parse_indexeddb_channels(&bytes) {
            attach_workspace(&mut channel);
            let key = channel_cache_key(&channel);
            match out.get_mut(&key) {
                Some(existing) => merge_channel(existing, channel),
                None => {
                    out.insert(key, channel);
                }
            }
        }
    }
    out.into_values().collect()
}

fn slack_indexeddb_files(data_dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect_regular_files(&data_dir.join("IndexedDB"), 8, &mut files);
    collect_regular_files(
        &data_dir.join("Local Storage").join("leveldb"),
        2,
        &mut files,
    );
    collect_regular_files(&data_dir.join("WebStorage"), 6, &mut files);
    collect_regular_files(&data_dir.join("Session Storage"), 2, &mut files);
    collect_regular_files(&data_dir.join("shared_proto_db"), 3, &mut files);
    files.retain(|path| {
        path.extension()
            .and_then(|ext| ext.to_str())
            .map(|ext| matches!(ext, "blob" | "ldb" | "log"))
            .unwrap_or_else(|| {
                path.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(is_blob_name)
            })
    });
    files.sort();
    files
}

fn collect_regular_files(path: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth == 0 {
        return;
    }
    let Ok(entries) = fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_file() {
            out.push(path);
        } else if file_type.is_dir() {
            collect_regular_files(&path, depth - 1, out);
        }
    }
}

fn is_blob_name(name: &str) -> bool {
    !name.is_empty() && name.chars().all(|c| c.is_ascii_hexdigit())
}

fn parse_indexeddb_channels(bytes: &[u8]) -> Vec<Channel> {
    let mut out: HashMap<String, Channel> = HashMap::new();
    for text in text_projections(bytes) {
        parse_indexeddb_projection(&text, &mut out);
    }
    out.into_values().collect()
}

fn parse_indexeddb_projection(text: &str, out: &mut HashMap<String, Channel>) {
    for marker_name in ["is_channel", "is_group"] {
        let mut offset = 0;
        while let Some(found) = text[offset..].find(marker_name) {
            let marker = offset + found;
            offset = marker + marker_name.len();
            let start = marker.saturating_sub(900);
            let end = (marker + 1_100).min(text.len());
            let chunk = &text[start..end];
            let Some(mut channel) = parse_channel_record(chunk) else {
                continue;
            };
            insert_parsed_channel(out, &mut channel);
        }
    }
    for marker in slack_route_offsets(text) {
        let start = marker.saturating_sub(600);
        let end = (marker + 1_400).min(text.len());
        let chunk = &text[start..end];
        if let Some(mut channel) = parse_route_channel_record(chunk) {
            insert_parsed_channel(out, &mut channel);
        }
    }
    for marker in slack_id_offsets(text, &['C', 'G']) {
        let start = marker.saturating_sub(160);
        let end = (marker + 1_200).min(text.len());
        let chunk = &text[start..end];
        if let Some(mut channel) = parse_channel_record(chunk) {
            insert_parsed_channel(out, &mut channel);
        }
    }
}

fn insert_parsed_channel(out: &mut HashMap<String, Channel>, channel: &mut Channel) {
    let key = channel_cache_key(channel);
    channel.pid = None;
    match out.get_mut(&key) {
        Some(existing) => merge_channel(existing, channel.clone()),
        None => {
            out.insert(key, channel.clone());
        }
    }
}

fn ascii_projection(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| {
            if (0x20..=0x7e).contains(b) {
                char::from(*b)
            } else {
                ' '
            }
        })
        .collect()
}

fn text_projections(bytes: &[u8]) -> Vec<String> {
    let mut projections = vec![ascii_projection(bytes)];
    for projection in [
        utf16_projection(bytes, false),
        utf16_projection(bytes, true),
    ] {
        if projection
            .as_bytes()
            .iter()
            .filter(|byte| byte.is_ascii_alphanumeric())
            .take(32)
            .count()
            >= 32
        {
            projections.push(projection);
        }
    }
    projections
}

fn utf16_projection(bytes: &[u8], big_endian: bool) -> String {
    let mut out = String::with_capacity(bytes.len() / 2);
    let mut index = 0;
    while index + 1 < bytes.len() {
        let (lo, hi) = if big_endian {
            (bytes[index + 1], bytes[index])
        } else {
            (bytes[index], bytes[index + 1])
        };
        if hi == 0 && (0x20..=0x7e).contains(&lo) {
            out.push(char::from(lo));
        } else {
            out.push(' ');
        }
        index += 2;
    }
    out
}

fn parse_channel_record(chunk: &str) -> Option<Channel> {
    if !looks_like_conversation_record(chunk) {
        return None;
    }
    if contains_field_true(chunk, "is_im") || contains_field_true(chunk, "is_mpim") {
        return None;
    }
    if contains_field_true(chunk, "is_archived") {
        return None;
    }
    let has_explicit_channel_shape =
        field_bool(chunk, "is_channel").is_some() || field_bool(chunk, "is_group").is_some();
    if has_explicit_channel_shape
        && !contains_field_true(chunk, "is_channel")
        && !contains_field_true(chunk, "is_group")
    {
        return None;
    }
    let before_channel_marker = before_first_field(chunk, &["is_channel", "is_group"]);
    let channel_id = last_slack_id(before_channel_marker, &['C', 'G'])?;
    let name = record_field_value(before_channel_marker, "name")
        .or_else(|| record_field_value(before_channel_marker, "name_normalized"))?;
    if !looks_like_channel_slug(&name) {
        return None;
    }
    Some(Channel {
        name,
        channel_id: Some(channel_id),
        team_id: last_slack_id(before_channel_marker, &['T']),
        unread: contains_field_true(chunk, "has_unreads")
            || contains_field_true(chunk, "has_unread_messages")
            || contains_positive_numeric_field(chunk, "unread_count")
            || contains_positive_numeric_field(chunk, "unread_count_display"),
        starred: contains_field_true(chunk, "is_starred")
            || contains_field_true(chunk, "is_user_starred"),
        ..Channel::default()
    })
}

fn parse_route_channel_record(chunk: &str) -> Option<Channel> {
    let route = first_slack_route(chunk)?;
    let channel_id = route.channel_id?;
    let name = record_field_value(chunk, "name_normalized")
        .or_else(|| record_field_value(chunk, "name"))
        .or_else(|| parse_hash_token(chunk))?;
    if !looks_like_channel_slug(&name) {
        return None;
    }
    if contains_field_true(chunk, "is_im")
        || contains_field_true(chunk, "is_mpim")
        || contains_field_true(chunk, "is_archived")
    {
        return None;
    }
    Some(Channel {
        name,
        channel_id: Some(channel_id),
        team_id: route.team_id.or_else(|| last_slack_id(chunk, &['T'])),
        unread: contains_field_true(chunk, "has_unreads")
            || contains_field_true(chunk, "has_unread_messages")
            || contains_positive_numeric_field(chunk, "unread_count")
            || contains_positive_numeric_field(chunk, "unread_count_display"),
        starred: contains_field_true(chunk, "is_starred")
            || contains_field_true(chunk, "is_user_starred"),
        ..Channel::default()
    })
}

fn first_slack_route(chunk: &str) -> Option<SlackRoute> {
    for offset in slack_route_offsets(chunk) {
        if let Some(route) = slack_route_at(chunk, offset) {
            return Some(route);
        }
    }
    None
}

fn slack_route_offsets(chunk: &str) -> Vec<usize> {
    let mut offsets = Vec::new();
    for needle in ["https://app.slack.com/client/", "slack://channel?"] {
        let mut offset = 0;
        while let Some(found) = chunk[offset..].find(needle) {
            let absolute = offset + found;
            offsets.push(absolute);
            offset = absolute + needle.len();
        }
    }
    offsets.sort_unstable();
    offsets
}

fn slack_route_at(chunk: &str, offset: usize) -> Option<SlackRoute> {
    let rest = chunk.get(offset..)?;
    let end = rest
        .find(|ch: char| {
            ch.is_whitespace()
                || matches!(
                    ch,
                    '"' | '\'' | '<' | '>' | ')' | '(' | '[' | ']' | '{' | '}'
                )
        })
        .unwrap_or(rest.len());
    parse_slack_route(&rest[..end])
}

fn before_first_field<'a>(chunk: &'a str, fields: &[&str]) -> &'a str {
    let marker = fields.iter().filter_map(|field| chunk.find(field)).min();
    match marker {
        Some(index) => &chunk[..index],
        None => chunk,
    }
}

fn looks_like_conversation_record(chunk: &str) -> bool {
    [
        "context_team",
        "conversation_host",
        "internalTeamIds",
        "connectedLimited",
        "fromAnotherTeam",
        "isNonExistent",
        "isUnknown",
        "is_channel",
        "is_group",
        "groupF",
        "is_im",
        "is_mpim",
        "is_private",
        "privateF",
        "is_archived",
        "team_id",
    ]
    .iter()
    .filter(|needle| chunk.contains(**needle))
    .take(2)
    .count()
        >= 2
}

fn contains_field_true(chunk: &str, field: &str) -> bool {
    field_bool(chunk, field) == Some(true)
}

fn field_bool(chunk: &str, field: &str) -> Option<bool> {
    let mut offset = 0;
    while let Some(found) = chunk[offset..].find(field) {
        let start = offset + found + field.len();
        offset = start;
        let tail = chunk[start..]
            .trim_start_matches(|ch: char| ch.is_whitespace() || matches!(ch, '"' | ':' | '='));
        if tail.starts_with('T') || tail.starts_with("true") {
            return Some(true);
        }
        if tail.starts_with('F') || tail.starts_with("false") {
            return Some(false);
        }
    }
    None
}

fn contains_positive_numeric_field(chunk: &str, field: &str) -> bool {
    let marker = field;
    let Some(index) = chunk.find(&marker) else {
        return false;
    };
    let rest = &chunk[index + marker.len()..];
    let digits: String = rest
        .chars()
        .skip_while(|ch| !ch.is_ascii_digit())
        .take_while(|ch| ch.is_ascii_digit())
        .collect();
    digits.parse::<u64>().unwrap_or(0) > 0
}

fn record_field_value(chunk: &str, field: &str) -> Option<String> {
    let mut offset = 0;
    while let Some(found) = chunk[offset..].find(field) {
        let index = offset + found;
        offset = index + field.len();
        let before = chunk[..index].chars().next_back();
        let after = chunk[offset..].chars().next();
        if before.is_some_and(|ch| ch.is_ascii_alphanumeric() || ch == '_')
            || after.is_some_and(|ch| ch.is_ascii_alphanumeric() || ch == '_')
        {
            continue;
        }
        let rest = &chunk[offset..];
        let mut started = false;
        let mut value = String::new();
        for ch in rest.chars().take(120) {
            if !started {
                if ch.is_ascii_lowercase() || ch.is_ascii_digit() {
                    started = true;
                    value.push(ch);
                }
                continue;
            }
            if ch.is_ascii_lowercase() || ch.is_ascii_digit() || matches!(ch, '-' | '_' | '.') {
                value.push(ch);
                continue;
            }
            break;
        }
        if !value.is_empty() {
            return Some(value);
        }
    }
    None
}

fn last_slack_id(chunk: &str, prefixes: &[char]) -> Option<String> {
    let bytes = chunk.as_bytes();
    let mut last = None;
    let mut i = 0;
    while i < bytes.len() {
        let ch = bytes[i] as char;
        if !prefixes.contains(&ch) {
            i += 1;
            continue;
        }
        let start = i;
        i += 1;
        while i < bytes.len() && bytes[i].is_ascii_alphanumeric() {
            i += 1;
        }
        if i - start >= 9 {
            let id = &chunk[start..i];
            if let Some(normalized) = normalized_local_slack_id(id, prefixes) {
                last = Some(normalized);
            }
        }
    }
    last
}

fn slack_id_offsets(chunk: &str, prefixes: &[char]) -> Vec<usize> {
    let bytes = chunk.as_bytes();
    let mut offsets = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let ch = bytes[i] as char;
        if !prefixes.contains(&ch) {
            i += 1;
            continue;
        }
        let start = i;
        i += 1;
        while i < bytes.len() && bytes[i].is_ascii_alphanumeric() {
            i += 1;
        }
        if i - start >= 9 && normalized_local_slack_id(&chunk[start..i], prefixes).is_some() {
            offsets.push(start);
        }
    }
    offsets
}

fn normalized_local_slack_id(raw: &str, prefixes: &[char]) -> Option<String> {
    let first = raw.chars().next()?;
    if !prefixes.contains(&first) {
        return None;
    }
    let valid_len = raw.chars().take_while(|c| is_slack_id_char(*c)).count();
    if valid_len < 9 {
        return None;
    }
    // Slack IDs in the current desktop cache are 11 chars. V8 serialized
    // strings can leave one or two marker letters adjacent to the value
    // (`C09QTP5M2SVo`), so trim those markers before building a URL.
    let id_len = valid_len.min(11);
    Some(raw.chars().take(id_len).collect())
}

fn is_slack_id_char(ch: char) -> bool {
    ch.is_ascii_uppercase() || ch.is_ascii_digit()
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
    if channel.unread {
        aliases.push("unread".to_string());
    }
    if channel.starred {
        aliases.push("starred".to_string());
    }
    let mut out = Candidate::new(&display)
        .kind("slack_channel")
        .location()
        .source_id(CHANNEL_SOURCE_ID)
        .source(CHANNEL_SOURCE_LABEL)
        .subtitle(channel_subtitle(channel))
        .aliases(aliases)
        .priority(channel_priority(channel))
        .finishes_command(true)
        .current_location(channel.current)
        .payload_json(&payload);
    if let Some(pid) = channel.pid {
        if pid > 0 {
            out = out.pid(pid);
        }
    }
    if let Some(url) = slack_channel_url(channel.team_id.as_deref(), channel.channel_id.as_deref())
    {
        out = out.url(url.clone()).navigation_url(url);
    }
    out
}

fn channel_subtitle(channel: &Channel) -> String {
    let mut status = Vec::new();
    if channel.unread {
        status.push("unread");
    }
    if channel.starred {
        status.push("starred");
    }
    if let Some(team_name) = channel.team_name.as_deref().filter(|s| !s.is_empty()) {
        status.insert(0, team_name);
    } else if let Some(team_id) = channel.team_id.as_deref().filter(|s| !s.is_empty()) {
        status.insert(0, team_id);
    }
    if status.is_empty() {
        "Slack channel".to_string()
    } else {
        format!("Slack channel - {}", status.join(", "))
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

/// Resolve a pick: try the durable Slack deep link when we have a
/// conversation ID, then fall back to a fresh AX snapshot so we can
/// press the live outline row by name. The cached handle is treated
/// as best-effort — Slack re-renders aggressively and a stored handle
/// is usually stale by the time the user types.
async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let payload = candidate.payload_as::<ChannelPayload>().unwrap_or_default();
    let target_name = if !payload.name.is_empty() {
        payload.name.clone()
    } else {
        candidate.title.trim_start_matches('#').to_string()
    };
    ctx.log(
        "debug",
        &format!(
            "[slack] resolve target=#{target_name} pid={:?} team={:?} channel={:?}",
            candidate.pid_value(),
            payload.team_id,
            payload.channel_id
        ),
    );

    if let Some(url) = slack_channel_url(payload.team_id.as_deref(), payload.channel_id.as_deref())
    {
        let result = run_command(
            ctx,
            &["/usr/bin/open".into(), url.clone()],
            Duration::from_secs(10),
        )
        .await;
        if result.ok {
            return ResolveResponse::resolved(candidate.pid_value()).navigation_url(url);
        }
        ctx.log(
            "warn",
            &format!("[slack] deep link failed: {}", result.stderr.trim()),
        );
    }

    let Some(pid) = candidate.pid_value() else {
        ctx.log(
            "warn",
            &format!("[slack] no durable channel id or live Slack pid for #{target_name}"),
        );
        return ResolveResponse::unresolved();
    };
    activate_app(ctx, pid).await;
    let channels = collect_ax_channels(ctx, pid).await;
    if let Some(target) = channels
        .iter()
        .find(|c| channel_matches_payload(c, &payload, &target_name))
    {
        if let Some(handle) = target.handle {
            if ax_perform(ctx, handle, "AXPress").await
                || ax_set_bool(ctx, handle, "AXSelected", true).await
            {
                ctx.log("debug", &format!("[slack] ax selected #{target_name}"));
                return ResolveResponse::resolved(Some(pid));
            }
        }
    }
    ctx.log(
        "warn",
        &format!("[slack] channel resolve failed: #{target_name}"),
    );
    ResolveResponse::unresolved()
}

fn channel_matches_payload(
    channel: &Channel,
    payload: &ChannelPayload,
    fallback_name: &str,
) -> bool {
    if let Some(target_id) = payload.channel_id.as_deref().filter(|s| !s.is_empty()) {
        return channel.channel_id.as_deref() == Some(target_id);
    }
    if !channel.name.eq_ignore_ascii_case(fallback_name) {
        return false;
    }
    if let Some(team_id) = payload.team_id.as_deref().filter(|s| !s.is_empty()) {
        return channel
            .team_id
            .as_deref()
            .is_none_or(|candidate| candidate == team_id);
    }
    true
}

async fn restore_navigation(ctx: &Context, request: &NavigationRequest) -> SourceActionResponse {
    if !request.url.starts_with("slack://channel?") {
        return SourceActionResponse::unhandled();
    }
    let result = run_command(
        ctx,
        &["/usr/bin/open".into(), request.url.clone()],
        Duration::from_secs(10),
    )
    .await;
    if result.ok {
        SourceActionResponse::performed(None).navigation_url(request.url.clone())
    } else {
        ctx.log(
            "warn",
            &format!(
                "[slack] navigation restore failed: {}",
                result.stderr.trim()
            ),
        );
        SourceActionResponse::failed(None).navigation_url(request.url.clone())
    }
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

async fn ax_set_bool(ctx: &Context, handle: u64, attribute: &str, value: bool) -> bool {
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
    fn parses_sidebar_label_status_flags() {
        assert_eq!(
            parse_sidebar_label_details("office-paris (has unread messages)"),
            Some(SidebarLabel {
                name: "office-paris".into(),
                unread: true,
                starred: false,
            })
        );
        assert_eq!(
            parse_sidebar_label_details("team-linear (muted) (3 new)"),
            Some(SidebarLabel {
                name: "team-linear".into(),
                unread: true,
                starred: false,
            })
        );
    }

    #[test]
    fn parses_sidebar_label_rejects_chrome() {
        // Section headers and toolbar labels look identical to channel
        // rows in the AX tree — only the literal text distinguishes
        // them, hence the static deny-list.
        assert_eq!(parse_sidebar_label("Threads"), None);
        assert_eq!(parse_sidebar_label("Huddles"), None);
        assert_eq!(parse_sidebar_label("Channels"), None);
        assert_eq!(parse_sidebar_label("Channel"), None);
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
    fn channel_name_from_group_or_static_text_row() {
        let group = node(
            "AXGroup",
            &[
                ("AXDescription", "team-platform"),
                ("AXRoleDescription", "group"),
            ],
        );
        assert_eq!(
            sidebar_channel_name(&group).as_deref(),
            Some("team-platform")
        );

        let text = node("AXStaticText", &[("AXValue", "#z-notifs-service-statuses")]);
        assert_eq!(
            sidebar_channel_name(&text).as_deref(),
            Some("z-notifs-service-statuses")
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
            parse_window_title(
                "z-notifs-service-statuses (Channel) - Beside - 2 new items - Slack"
            ),
            Some(("z-notifs-service-statuses".into(), "Beside".into()))
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
    fn slack_route_parser_accepts_web_and_native_channel_routes() {
        assert_eq!(
            parse_slack_route("https://app.slack.com/client/T05FRMFKYE9/C06D0UV6PNZR8")
                .as_ref()
                .and_then(|route| route.channel_id.as_deref()),
            Some("C06D0UV6PNZR8")
        );
        assert_eq!(
            parse_slack_route("slack://channel?team=T05FRMFKYE9&id=C06D0UV6PNZR8")
                .as_ref()
                .and_then(|route| route.team_id.as_deref()),
            Some("T05FRMFKYE9")
        );
        assert_eq!(
            parse_slack_route("https://app.slack.com/client/T05FRMFKYE9/activity-inbox"),
            None
        );
        assert_eq!(
            parse_slack_route("slack://channel?team=T05FRMFKYE9&id=Guillaume"),
            None
        );
    }

    #[test]
    fn api_channel_parser_skips_archived_and_keeps_status() {
        let json = serde_json::json!({
            "id": "C06D0UV6PNZ",
            "name": "team-platform",
            "context_team_id": "T05FRMFKYE",
            "is_archived": false,
            "is_starred": true,
            "unread_count_display": 4
        });
        let channel = api_channel(&json, None).expect("channel");
        assert_eq!(api_channel_id(&json).as_deref(), Some("C06D0UV6PNZ"));
        assert_eq!(channel.name, "team-platform");
        assert_eq!(channel.channel_id.as_deref(), Some("C06D0UV6PNZ"));
        assert_eq!(channel.team_id.as_deref(), Some("T05FRMFKYE"));
        assert!(channel.unread);
        assert!(channel.starred);

        let archived = serde_json::json!({
            "id": "C06D0UV6PNZ",
            "name": "team-platform",
            "is_archived": true
        });
        assert!(api_bool(&archived, "is_archived"));
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
                unread: true,
                starred: true,
                ..Channel::default()
            },
        );
        assert_eq!(into.channel_id.as_deref(), Some("C123"));
        assert_eq!(into.team_id.as_deref(), Some("T456"));
        assert_eq!(into.team_name.as_deref(), Some("Beside"));
        assert_eq!(into.handle, Some(2));
        assert_eq!(into.pid, Some(99));
        assert!(into.unread);
        assert!(into.starred);
    }

    #[test]
    fn channel_cache_key_prefers_route_identity() {
        let id_backed = Channel {
            name: "general".into(),
            channel_id: Some("C123456789".into()),
            team_id: Some("T123456789".into()),
            ..Channel::default()
        };
        assert_eq!(channel_cache_key(&id_backed), "route:T123456789:C123456789");

        let name_backed = Channel {
            name: "general".into(),
            team_id: Some("T999999999".into()),
            ..Channel::default()
        };
        assert_eq!(channel_cache_key(&name_backed), "name:T999999999:general");
    }

    #[test]
    fn indexeddb_record_parser_extracts_channel_identity() {
        let record = br#"
            random-prefix " C09QTP5M2SVo" id2 x" enterprise_id" "
            context_team  8 T05FRMFKYE9" conversation_host u "
            creator" U087XT0TN3D" name" speech-to-benchmark"
            is_archivedF" is_channelT" is_groupF" is_imF"
            is_mpimF" is_privateF
        "#;
        let channels = parse_indexeddb_channels(record);
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].name, "speech-to-benchmark");
        assert_eq!(channels[0].channel_id.as_deref(), Some("C09QTP5M2SV"));
        assert_eq!(channels[0].team_id.as_deref(), Some("T05FRMFKYE9"));
    }

    #[test]
    fn indexeddb_record_parser_extracts_blob_channel_without_marker() {
        let record = br#"
            internalTeamIds connectedLimited isNonExistentF isUnknownF
            fromAnotherTeamF C06M3F1T1C6o" name" z-notifs-scams"
            groupF" is_imF" privateF" context_team T05FRMFKYE9"
        "#;
        let channels = parse_indexeddb_channels(record);
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].name, "z-notifs-scams");
        assert_eq!(channels[0].channel_id.as_deref(), Some("C06M3F1T1C6"));
        assert_eq!(channels[0].team_id.as_deref(), Some("T05FRMFKYE9"));
    }

    #[test]
    fn indexeddb_record_parser_rejects_name_tokens_as_channel_ids() {
        assert_eq!(normalized_local_slack_id("Guillaume", &['C', 'G']), None);
        assert_eq!(
            normalized_local_slack_id("C09QTP5M2SVo", &['C', 'G']).as_deref(),
            Some("C09QTP5M2SV")
        );
    }

    #[test]
    fn indexeddb_record_parser_rejects_non_conversation_metadata() {
        let record = br#"
            C06M3F1T1C6o" name" small_red_triangle_down"
            emoji skin_tone unicode category
        "#;
        assert!(parse_indexeddb_channels(record).is_empty());
    }

    #[test]
    fn indexeddb_record_parser_accepts_private_channel_group_records() {
        let record = br#"
            random-prefix " G09QTP5M2SVo" id2 x" enterprise_id" "
            context_team  8 T05FRMFKYE9" conversation_host u "
            creator" U087XT0TN3D" name" private-room"
            is_archivedF" is_channelF" is_groupT" is_imF"
            is_mpimF" is_privateT
        "#;
        let channels = parse_indexeddb_channels(record);
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].name, "private-room");
        assert_eq!(channels[0].channel_id.as_deref(), Some("G09QTP5M2SV"));
    }

    #[test]
    fn indexeddb_record_parser_accepts_spaced_v8_boolean_markers() {
        let record = br#"
            random-prefix " C09QTP5M2SVo" id2 x" enterprise_id" "
            context_team  8 T05FRMFKYE9" conversation_host u "
            creator" U087XT0TN3D" name" speech-to-benchmark"
            is_archived  F" is_channel    T" is_group   F" is_im  F"
            is_mpim   F" is_privateF
        "#;
        let channels = parse_indexeddb_channels(record);
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].name, "speech-to-benchmark");
        assert_eq!(channels[0].channel_id.as_deref(), Some("C09QTP5M2SV"));
    }

    #[test]
    fn indexeddb_record_parser_accepts_route_records_with_names() {
        let record = br#"
            {"url":"https://app.slack.com/client/T05FRMFKYE9/C06D0UV6PNZ",
             "name":"team-platform","is_channel":true,"is_im":false,"is_mpim":false}
        "#;
        let channels = parse_indexeddb_channels(record);
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].name, "team-platform");
        assert_eq!(channels[0].channel_id.as_deref(), Some("C06D0UV6PNZ"));
        assert_eq!(channels[0].team_id.as_deref(), Some("T05FRMFKYE9"));
    }

    #[test]
    fn indexeddb_record_parser_projects_utf16_storage() {
        let text = r#"
            random-prefix " C09QTP5M2SVo" id2 x" enterprise_id" "
            context_team  8 T05FRMFKYE9" conversation_host u "
            creator" U087XT0TN3D" name" speech-to-benchmark"
            is_archivedF" is_channelT" is_groupF" is_imF"
            is_mpimF" is_privateF
        "#;
        let mut record = Vec::new();
        for byte in text.bytes() {
            record.push(byte);
            record.push(0);
        }
        let channels = parse_indexeddb_channels(&record);
        assert_eq!(channels.len(), 1);
        assert_eq!(channels[0].name, "speech-to-benchmark");
        assert_eq!(channels[0].channel_id.as_deref(), Some("C09QTP5M2SV"));
    }

    #[test]
    fn indexeddb_record_parser_rejects_dm_shapes() {
        let record = br#"
            " C0A1XG5V3NVo" id". " name" @lea,elsa,jeremy"
            is_channelT" is_groupF" is_imF" is_mpimT" is_privateT
            hteam_id" T05FRMFKYE9"
        "#;
        assert!(parse_indexeddb_channels(record).is_empty());
    }

    #[test]
    fn curl_config_string_escapes_quotes_and_backslashes() {
        assert_eq!(curl_config_string(r#"#foo"bar\baz"#), r#"#foo\"bar\\baz"#);
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
