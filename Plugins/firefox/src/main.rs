use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use flash_plugin::{
    run, Candidate, Context, Event, NavigationRequest, ResolveResponse, SourceActionRequest,
    SourceActionResponse,
};
use serde_json::{json, Value};

const SOURCE_ID: &str = "plugin:firefox.tabs";
const MAX_NODES: u64 = 3_000;
const FIREFOX: &str = "org.mozilla.firefox";
const FIREFOX_DEV: &str = "org.mozilla.firefoxdeveloperedition";

/// Attributes the AX broker reads for every visited node. The plugin — not the
/// core — decides which of these nodes is a tab and what its title/url are; the
/// broker just hands back a flat, batched view of the subtree.
const COLLECT: &[&str] = &[
    "AXRole",
    "AXSubrole",
    "AXRoleDescription",
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXURL",
    "AXDocument",
    "AXSelected",
];

#[derive(Clone, Debug)]
struct Tab {
    handle: u64,
    parent_handle: Option<u64>,
    root: usize,
    window_handle: Option<u64>,
    title: String,
    url: String,
    selected: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SessionTab {
    title: String,
    url: String,
}

struct Firefox;

flash_plugin::plugin!(Firefox);

impl FlashPlugin for Firefox {
    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            "core:apps.snapshot" | "core:flashlight.opened" => {
                let apps = event
                    .running_applications
                    .iter()
                    .filter(|app| is_firefox(&app.bundle_id))
                    .map(|app| (app.bundle_id.clone(), app.pid))
                    .collect::<Vec<_>>();
                refresh_snapshot(&ctx, apps).await;
            }
            "core:focus.changed" | "core:window.focus.changed" => {
                let bundle = event.bundle_id.unwrap_or_default();
                let Some(pid) = event.pid else {
                    return;
                };
                if is_firefox(&bundle) {
                    refresh_snapshot(&ctx, vec![(bundle, pid)]).await;
                }
            }
            _ => {}
        }
    }

    async fn resolve_candidate(&self, ctx: Context, candidate: Candidate) -> ResolveResponse {
        resolve(&ctx, &candidate).await
    }

    async fn source_action(
        &self,
        ctx: Context,
        request: SourceActionRequest,
    ) -> SourceActionResponse {
        perform_source_action(&ctx, &request).await
    }

    async fn restore_navigation(
        &self,
        ctx: Context,
        request: NavigationRequest,
    ) -> SourceActionResponse {
        restore_navigation(&ctx, &request).await
    }
}

async fn refresh_snapshot(ctx: &Context, apps: Vec<(String, i64)>) {
    if apps.is_empty() {
        return;
    }
    let mut candidates = Vec::new();
    for (bundle, pid) in apps {
        let source = source_name(&bundle);
        let tabs = collect_tabs(ctx, pid).await;
        candidates.extend(tabs.iter().map(|tab| candidate(tab, &source, pid)));
    }
    if candidates.is_empty() {
        ctx.log("debug", "[firefox] skipped empty tab snapshot");
        return;
    }
    ctx.emit_snapshot(SOURCE_ID, candidates);
}

fn is_firefox(bundle: &str) -> bool {
    bundle == FIREFOX || bundle == FIREFOX_DEV
}

/// Plugin sources follow `<plugin>.<subsource>`. The release vs
/// developer edition distinction lives in the bundle id, not the
/// source label — both surface as `firefox.tabs` so `@firefox` /
/// `@firefox.tabs` filter them together.
fn source_name(_bundle: &str) -> String {
    "firefox.tabs".to_string()
}

/// Walk Firefox's windows and extract the tab strip. Mirrors the heuristics the
/// old in-core `BrowserTabSources.axTabElements`/`axTabTitle`/`axTabURL` used:
/// a node is a tab when it is a radio button / button / tab whose subrole or
/// role-description marks it as a tab strip entry (or any `AXTab`).
async fn collect_tabs(ctx: &Context, pid: i64) -> Vec<Tab> {
    let nodes = ax_snapshot(
        ctx,
        pid,
        "windows",
        &[],
        COLLECT,
        MAX_NODES,
        false,
        &["AXWebArea"],
    )
    .await;
    let window_roots = window_roots(&nodes);
    let mut tabs = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for node in &nodes {
        if !is_tab(node) {
            continue;
        }
        let fallback = window_roots
            .get(node.root)
            .map(|root| root.title.as_str())
            .unwrap_or("");
        let Some(title) = tab_title(node, fallback) else {
            continue;
        };
        let url = tab_url(node);
        let key = format!("{}|{title}|{url}", node.root);
        if !seen.insert(key) {
            continue;
        }
        tabs.push(Tab {
            handle: node.handle,
            parent_handle: node.parent,
            root: node.root,
            window_handle: window_roots.get(node.root).map(|root| root.handle),
            title,
            url,
            selected: attr_bool(node, "AXSelected"),
        });
    }
    merge_session_urls(&mut tabs, &firefox_session_tabs());
    apply_window_title_selection(&mut tabs, &window_roots);
    tabs
}

#[derive(Clone, Debug, Default)]
struct WindowRoot {
    handle: u64,
    title: String,
}

/// Window metadata per root index, taken from the `AXWindow` node the broker
/// emits as the first node of each root. The title is a tab-title fallback; the
/// handle lets resolution raise the exact Firefox window that owns the tab.
fn window_roots(nodes: &[AxNode]) -> Vec<WindowRoot> {
    let mut roots: Vec<WindowRoot> = Vec::new();
    for node in nodes {
        if node.attr("AXRole") == Some("AXWindow") {
            if node.root >= roots.len() {
                roots.resize(node.root + 1, WindowRoot::default());
            }
            roots[node.root] = WindowRoot {
                handle: node.handle,
                title: node.attr("AXTitle").unwrap_or("").to_string(),
            };
        }
    }
    roots
}

fn is_tab(node: &AxNode) -> bool {
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

fn tab_title(node: &AxNode, fallback: &str) -> Option<String> {
    let raw = node
        .attr("AXTitle")
        .or_else(|| node.attr("AXDescription"))
        .or_else(|| node.attr("AXValue"))
        .unwrap_or(fallback);
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn tab_url(node: &AxNode) -> String {
    node.attr("AXURL")
        .or_else(|| node.attr("AXDocument"))
        .unwrap_or("")
        .trim()
        .to_string()
}

fn merge_session_urls(tabs: &mut [Tab], session_tabs: &[SessionTab]) {
    let mut used = vec![false; session_tabs.len()];
    for tab in tabs.iter_mut() {
        if !tab.url.is_empty() || tab.title.is_empty() {
            continue;
        }
        let Some((index, session)) = session_tabs.iter().enumerate().find(|(index, session)| {
            !used[*index] && !session.url.is_empty() && titles_match(&tab.title, &session.title)
        }) else {
            continue;
        };
        tab.url = session.url.clone();
        used[index] = true;
    }
}

fn titles_match(ax_title: &str, session_title: &str) -> bool {
    let ax = ax_title.trim();
    let session = session_title.trim();
    !ax.is_empty() && !session.is_empty() && ax == session
}

fn apply_window_title_selection(tabs: &mut [Tab], window_roots: &[WindowRoot]) {
    for root_index in 0..window_roots.len() {
        let window_title = window_roots[root_index].title.trim();
        if window_title.is_empty() {
            continue;
        }
        let matches = tabs
            .iter()
            .enumerate()
            .filter(|(_, tab)| {
                tab.root == root_index && title_matches_window(&tab.title, window_title)
            })
            .map(|(index, _)| index)
            .collect::<Vec<_>>();
        if matches.len() != 1 {
            continue;
        }
        let selected_index = matches[0];
        for (index, tab) in tabs
            .iter_mut()
            .enumerate()
            .filter(|(_, tab)| tab.root == root_index)
        {
            tab.selected = index == selected_index;
        }
    }
}

fn title_matches_window(tab_title: &str, window_title: &str) -> bool {
    let tab = tab_title.trim();
    let window = window_title.trim();
    if tab.is_empty() || window.is_empty() {
        return false;
    }
    window == tab
        || window
            .strip_suffix(" — Mozilla Firefox")
            .is_some_and(|title| title.trim() == tab)
        || window
            .strip_suffix(" - Mozilla Firefox")
            .is_some_and(|title| title.trim() == tab)
}

fn firefox_session_tabs() -> Vec<SessionTab> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for path in firefox_sessionstore_paths() {
        let Some(text) = read_moz_lz4_json(&path) else {
            continue;
        };
        for tab in parse_session_tabs(&text) {
            if seen.insert((tab.title.clone(), tab.url.clone())) {
                out.push(tab);
            }
        }
    }
    out
}

fn firefox_sessionstore_paths() -> Vec<PathBuf> {
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let profiles = PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Firefox")
        .join("Profiles");
    let Ok(entries) = fs::read_dir(profiles) else {
        return Vec::new();
    };
    let mut paths = Vec::new();
    for entry in entries.flatten() {
        let profile = entry.path();
        push_sessionstore_path(
            &mut paths,
            0,
            profile
                .join("sessionstore-backups")
                .join("recovery.jsonlz4"),
        );
        push_sessionstore_path(
            &mut paths,
            1,
            profile
                .join("sessionstore-backups")
                .join("previous.jsonlz4"),
        );
        push_sessionstore_path(&mut paths, 2, profile.join("sessionstore.jsonlz4"));
    }
    paths.sort_by(|lhs, rhs| {
        rhs.0
            .cmp(&lhs.0)
            .then_with(|| lhs.1.cmp(&rhs.1))
            .then_with(|| lhs.2.cmp(&rhs.2))
    });
    paths.into_iter().map(|(_, _, path)| path).collect()
}

fn push_sessionstore_path(paths: &mut Vec<(u128, usize, PathBuf)>, priority: usize, path: PathBuf) {
    let Ok(metadata) = fs::metadata(&path) else {
        return;
    };
    if !metadata.is_file() {
        return;
    }
    let modified_ms = metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_millis())
        .unwrap_or(0);
    paths.push((modified_ms, priority, path));
}

fn read_moz_lz4_json(path: &Path) -> Option<String> {
    let bytes = fs::read(path).ok()?;
    decode_moz_lz4_json(&bytes)
}

fn decode_moz_lz4_json(bytes: &[u8]) -> Option<String> {
    const MOZ_LZ4_MAGIC: &[u8] = b"mozLz40\0";
    let payload = bytes.strip_prefix(MOZ_LZ4_MAGIC)?;
    if payload.len() < 4 {
        return None;
    }
    let expected_len =
        u32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize;
    let decoded = lz4_block_decode(&payload[4..])?;
    if decoded.len() != expected_len {
        return None;
    }
    String::from_utf8(decoded).ok()
}

fn parse_session_tabs(text: &str) -> Vec<SessionTab> {
    let Ok(root) = serde_json::from_str::<Value>(text) else {
        return Vec::new();
    };
    let Some(windows) = root.get("windows").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for window in windows {
        let Some(tabs) = window.get("tabs").and_then(Value::as_array) else {
            continue;
        };
        for tab in tabs {
            let Some(entries) = tab.get("entries").and_then(Value::as_array) else {
                continue;
            };
            let index = tab
                .get("index")
                .and_then(Value::as_u64)
                .map(|value| value.saturating_sub(1) as usize)
                .unwrap_or_else(|| entries.len().saturating_sub(1));
            let Some(entry) = entries.get(index).or_else(|| entries.last()) else {
                continue;
            };
            let url = entry
                .get("url")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim();
            if url.is_empty() {
                continue;
            }
            let title = entry
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or(url)
                .trim();
            out.push(SessionTab {
                title: title.to_string(),
                url: url.to_string(),
            });
        }
    }
    out
}

fn lz4_block_decode(input: &[u8]) -> Option<Vec<u8>> {
    let mut i = 0;
    let mut out = Vec::new();
    while i < input.len() {
        let token = *input.get(i)?;
        i += 1;

        let mut literal_len = (token >> 4) as usize;
        if literal_len == 15 {
            literal_len += read_lz4_len(input, &mut i)?;
        }
        if i + literal_len > input.len() {
            return None;
        }
        out.extend_from_slice(&input[i..i + literal_len]);
        i += literal_len;
        if i >= input.len() {
            break;
        }

        if i + 2 > input.len() {
            return None;
        }
        let offset = u16::from_le_bytes([input[i], input[i + 1]]) as usize;
        i += 2;
        if offset == 0 || offset > out.len() {
            return None;
        }

        let mut match_len = (token & 0x0f) as usize + 4;
        if (token & 0x0f) == 15 {
            match_len += read_lz4_len(input, &mut i)?;
        }
        for _ in 0..match_len {
            let next = out[out.len() - offset];
            out.push(next);
        }
    }
    Some(out)
}

fn read_lz4_len(input: &[u8], i: &mut usize) -> Option<usize> {
    let mut len = 0usize;
    loop {
        let value = *input.get(*i)? as usize;
        *i += 1;
        len += value;
        if value != 255 {
            return Some(len);
        }
    }
}

fn attr_bool(node: &AxNode, key: &str) -> bool {
    matches!(
        node.attr(key).map(|value| value.to_ascii_lowercase()),
        Some(value) if matches!(value.as_str(), "1" | "true" | "yes")
    )
}

/// One flashlight candidate for a tab. `source` drives the `@firefox` source
/// filter; `payload` carries the url so resolution can re-match the tab after
/// a fresh snapshot.
fn candidate(tab: &Tab, source: &str, pid: i64) -> Candidate {
    let name = if tab.title.is_empty() {
        tab.url.clone()
    } else {
        tab.title.clone()
    };
    let mut candidate = Candidate::new(name)
        .kind("browser_tab")
        .location()
        .source_id(SOURCE_ID)
        .source(source)
        .subtitle("browser tab")
        .pid(pid)
        .payload(tab.url.clone())
        .current_location(tab.selected);
    if !tab.url.is_empty() {
        candidate = candidate
            .url(tab.url.clone())
            .navigation_url(firefox_navigation_url(pid, &tab.url, &tab.title));
    }
    candidate
}

/// Resolve a flashlight pick: raise Firefox, then select the matching tab. The
/// candidate's handle from emit time may be stale (any later snapshot for the
/// pid supersedes it), so re-snapshot and match by url, then title, before
/// selecting. This path is AX-only: it sets the selected child on the tab
/// container and verifies the visible selection instead of synthesizing a
/// pointer click.
async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let Some(pid) = candidate.pid_value() else {
        return ResolveResponse::unresolved();
    };
    activate_app(ctx, pid).await;
    let url = candidate.url_value().unwrap_or("");
    let name = candidate.title.as_str();
    let tabs = collect_tabs(ctx, pid).await;
    let target = tabs
        .iter()
        .find(|tab| !url.is_empty() && tab.url == url)
        .or_else(|| tabs.iter().find(|tab| tab.title == name));
    let Some(target) = target else {
        ctx.log(
            "warn",
            &format!("[firefox] resolve target not found title={name:?} url={url:?}"),
        );
        return ResolveResponse::unresolved();
    };
    if !select_tab(ctx, pid, target).await {
        ctx.log(
            "warn",
            &format!("[firefox] resolve target press failed title={name:?} url={url:?}"),
        );
        return ResolveResponse::unresolved();
    }
    let mut response = ResolveResponse::resolved(Some(pid));
    if !url.is_empty() {
        response = response.navigation_url(firefox_navigation_url(pid, url, name));
    }
    response
}

async fn restore_navigation(ctx: &Context, request: &NavigationRequest) -> SourceActionResponse {
    let Some(route) = parse_firefox_navigation_url(&request.url) else {
        return SourceActionResponse::unhandled();
    };
    let pid = route.pid;
    activate_app(ctx, pid).await;
    let tabs = collect_tabs(ctx, pid).await;
    let target = tabs
        .iter()
        .find(|tab| !route.url.is_empty() && tab.url == route.url)
        .or_else(|| tabs.iter().find(|tab| tab.title == route.title));
    let Some(target) = target else {
        ctx.log(
            "warn",
            &format!(
                "[firefox] restore target not found title={:?} url={:?}",
                route.title, route.url
            ),
        );
        return SourceActionResponse::failed(Some(pid)).navigation_url(request.url.clone());
    };
    if select_tab(ctx, pid, target).await {
        SourceActionResponse::performed(Some(pid)).navigation_url(request.url.clone())
    } else {
        ctx.log(
            "warn",
            &format!(
                "[firefox] restore target press failed title={:?} url={:?}",
                route.title, route.url
            ),
        );
        SourceActionResponse::failed(Some(pid)).navigation_url(request.url.clone())
    }
}

struct FirefoxRoute {
    pid: i64,
    url: String,
    title: String,
}

fn firefox_navigation_url(pid: i64, url: &str, title: &str) -> String {
    format!(
        "flash-firefox://tab?pid={}&url={}&title={}",
        pid,
        percent_encode(url),
        percent_encode(title)
    )
}

fn parse_firefox_navigation_url(raw: &str) -> Option<FirefoxRoute> {
    let prefix = "flash-firefox://tab?";
    let query = raw.strip_prefix(prefix)?;
    let mut pid = None;
    let mut url = String::new();
    let mut title = String::new();
    for pair in query.split('&') {
        let mut parts = pair.splitn(2, '=');
        let key = parts.next().unwrap_or("");
        let value = percent_decode(parts.next().unwrap_or(""));
        match key {
            "pid" => pid = value.parse::<i64>().ok(),
            "url" => url = value,
            "title" => title = value,
            _ => {}
        }
    }
    Some(FirefoxRoute {
        pid: pid?,
        url,
        title,
    })
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

fn percent_decode(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex) = std::str::from_utf8(&bytes[i + 1..i + 3]) {
                if let Ok(value) = u8::from_str_radix(hex, 16) {
                    out.push(value);
                    i += 3;
                    continue;
                }
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `tab_select` (numbered-tab jump): press the Nth tab in document order within
/// the first window that has at least that many tabs. Ports the old
/// `FirefoxTabsSource.tabSelect` semantics.
async fn perform_source_action(
    ctx: &Context,
    action: &SourceActionRequest,
) -> SourceActionResponse {
    if action.name != "tab_select" {
        return SourceActionResponse::unhandled();
    }
    let index = action.index.unwrap_or(0);
    let (Some(pid), true) = (action.context.pid, index > 0) else {
        return SourceActionResponse::unhandled();
    };
    activate_app(ctx, pid).await;
    let tabs = collect_tabs(ctx, pid).await;
    let Some(target) = tabs.get((index - 1) as usize) else {
        return SourceActionResponse::unhandled();
    };
    // Firefox owns this tab_select claim either way: a successful press is
    // `performed`, but a failed press must be `failed` (not `unhandled`) so
    // the host doesn't fall back to a ⌘<digit> keystroke that switches the
    // wrong tab.
    if select_tab(ctx, pid, target).await {
        SourceActionResponse::performed(Some(pid))
    } else {
        SourceActionResponse::failed(Some(pid))
    }
}

async fn select_tab(ctx: &Context, pid: i64, tab: &Tab) -> bool {
    if let Some(window_handle) = tab.window_handle {
        ax_perform(ctx, window_handle, "AXRaise").await;
        ax_set(ctx, window_handle, "AXMain", true).await;
        ax_set(ctx, window_handle, "AXFocused", true).await;
    }
    if tab.selected {
        return true;
    }

    if let Some(parent_handle) = tab.parent_handle {
        if ax_select_child(ctx, parent_handle, tab.handle).await {
            tokio::time::sleep(Duration::from_millis(120)).await;
            if tab_is_selected(ctx, pid, tab).await {
                if let Some(window_handle) = tab.window_handle {
                    ax_perform(ctx, window_handle, "AXRaise").await;
                }
                return true;
            }
            ctx.log(
                "debug",
                &format!(
                    "[firefox] AXSelectedChildren write returned ok but tab did not become selected title={:?} url={:?}",
                    tab.title, tab.url
                ),
            );
        }
    }

    if ax_set(ctx, tab.handle, "AXSelected", true).await {
        tokio::time::sleep(Duration::from_millis(120)).await;
        if tab_is_selected(ctx, pid, tab).await {
            if let Some(window_handle) = tab.window_handle {
                ax_perform(ctx, window_handle, "AXRaise").await;
            }
            return true;
        }
        ctx.log(
            "debug",
            &format!(
                "[firefox] AXSelected write returned ok but tab did not become selected title={:?} url={:?}",
                tab.title, tab.url
            ),
        );
    }

    if ax_perform(ctx, tab.handle, "AXPress").await {
        tokio::time::sleep(Duration::from_millis(120)).await;
        if tab_is_selected(ctx, pid, tab).await {
            if let Some(window_handle) = tab.window_handle {
                ax_perform(ctx, window_handle, "AXRaise").await;
            }
            return true;
        }
        ctx.log(
            "debug",
            &format!(
                "[firefox] AXPress returned ok but tab did not become selected title={:?} url={:?}",
                tab.title, tab.url
            ),
        );
    }

    false
}

async fn tab_is_selected(ctx: &Context, pid: i64, target: &Tab) -> bool {
    collect_tabs(ctx, pid)
        .await
        .iter()
        .any(|tab| tab.selected && same_tab(tab, target))
}

fn same_tab(tab: &Tab, target: &Tab) -> bool {
    if !target.url.is_empty() && !tab.url.is_empty() {
        return tab.url == target.url;
    }
    if !target.title.is_empty() {
        return tab.title == target.title;
    }
    false
}

#[derive(Clone, Debug)]
struct AxNode {
    handle: u64,
    parent: Option<u64>,
    root: usize,
    attrs: BTreeMap<String, String>,
}

impl AxNode {
    fn from_value(value: &Value) -> Option<Self> {
        let handle = value.get("handle")?.as_u64()?;
        let parent = value.get("parent").and_then(Value::as_u64);
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
            parent,
            root,
            attrs,
        })
    }

    fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
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
    prune_roles: &[&str],
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
                "prune_roles": prune_roles,
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

async fn ax_select_child(ctx: &Context, parent: u64, child: u64) -> bool {
    ctx.call_host(
        "ax.select_child",
        json!({ "parent": parent, "child": child }),
    )
    .await
    .get("ok")
    .and_then(Value::as_bool)
    .unwrap_or(false)
}

fn main() {
    run(Firefox);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_current_session_entries_as_tabs() {
        let tabs = parse_session_tabs(
            r##"{
              "windows": [{
                "tabs": [
                  {
                    "index": 2,
                    "entries": [
                      {"url": "https://example.com/old", "title": "Old"},
                      {"url": "https://mail.google.com/mail/u/0/#inbox", "title": "Gmail"}
                    ]
                  },
                  {
                    "entries": [
                      {"url": "https://github.com/aymericbeaumet/flash", "title": "flash"}
                    ]
                  }
                ]
              }]
            }"##,
        );

        assert_eq!(
            tabs,
            vec![
                SessionTab {
                    title: "Gmail".into(),
                    url: "https://mail.google.com/mail/u/0/#inbox".into(),
                },
                SessionTab {
                    title: "flash".into(),
                    url: "https://github.com/aymericbeaumet/flash".into(),
                },
            ]
        );
    }

    #[test]
    fn merge_session_urls_fills_ax_title_only_tabs() {
        let mut tabs = vec![Tab {
            handle: 1,
            parent_handle: Some(10),
            root: 0,
            window_handle: Some(100),
            title: "Gmail".into(),
            url: String::new(),
            selected: true,
        }];
        merge_session_urls(
            &mut tabs,
            &[SessionTab {
                title: "Gmail".into(),
                url: "https://mail.google.com/mail/u/0/#inbox".into(),
            }],
        );

        assert_eq!(tabs[0].url, "https://mail.google.com/mail/u/0/#inbox");
    }

    #[test]
    fn window_title_selection_overrides_unreliable_ax_selected_flags() {
        let mut tabs = vec![
            Tab {
                handle: 1,
                parent_handle: Some(10),
                root: 0,
                window_handle: Some(100),
                title: "Inbox".into(),
                url: String::new(),
                selected: true,
            },
            Tab {
                handle: 2,
                parent_handle: Some(10),
                root: 0,
                window_handle: Some(100),
                title: "Calendar".into(),
                url: String::new(),
                selected: true,
            },
        ];
        apply_window_title_selection(
            &mut tabs,
            &[WindowRoot {
                handle: 100,
                title: "Calendar — Mozilla Firefox".into(),
            }],
        );

        assert!(!tabs[0].selected);
        assert!(tabs[1].selected);
    }

    #[test]
    fn lz4_block_decoder_expands_backreferences() {
        let compressed = [0x32, b'a', b'b', b'c', 3, 0];
        assert_eq!(
            lz4_block_decode(&compressed).as_deref(),
            Some(&b"abcabcabc"[..])
        );
    }

    #[test]
    fn decodes_mozilla_lz4_sessionstore_frame() {
        let json = br#"{"windows":[]}"#;
        let mut frame = b"mozLz40\0".to_vec();
        frame.extend_from_slice(&(json.len() as u32).to_le_bytes());
        frame.push((json.len() as u8) << 4);
        frame.extend_from_slice(json);

        assert_eq!(
            decode_moz_lz4_json(&frame).as_deref(),
            Some(r#"{"windows":[]}"#)
        );
    }
}
