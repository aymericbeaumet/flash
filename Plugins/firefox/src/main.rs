mod bridge_state;

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use bridge_state::{state_file, BridgeState, BridgeTab, BRIDGE_DIR_NAME, MAX_STATE_BYTES};
use flash_plugin::{
    run, ActionRequest, Candidate, CommandRequest, Context, Event, NavigateRequest,
    PerformResponse, RefreshGate, RunningApplication,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Safety-net poll; events (app/focus changes, flashlight open) drive the
/// authoritative refreshes, so this only bounds staleness for tab changes
/// that emit no host event.
const POLL_INTERVAL: Duration = Duration::from_secs(10);
/// Event bursts (a launch fires apps.changed + focus.changed +
/// window.focus.changed back to back) coalesce into one refresh.
const EVENT_DEBOUNCE: Duration = Duration::from_millis(300);
const MAX_NODES: u64 = 3_000;
const MAX_FIREFOX_PROFILES: usize = 32;
const MAX_SESSIONSTORE_FILES: usize = 64;
const MAX_SESSIONSTORE_COMPRESSED_BYTES: u64 = 32 * 1024 * 1024;
const MAX_SESSIONSTORE_DECODED_BYTES: usize = 64 * 1024 * 1024;
const MAX_SESSION_TABS: usize = 100_000;
/// How stale a bridge state file may be and still outrank the Accessibility
/// walk. The add-on re-publishes on every tab/window event AND on a 60 s
/// heartbeat, so a live browser with a loaded add-on stays well inside this
/// window; an add-on that was disabled, crashed or never installed falls out
/// of it and the AX path takes over.
const BRIDGE_FRESHNESS: Duration = Duration::from_secs(300);
const FIREFOX: &str = "org.mozilla.firefox";
const FIREFOX_DEV: &str = "org.mozilla.firefoxdeveloperedition";
const REPEAT_WARNING_INTERVAL: Duration = Duration::from_secs(60);
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
/// Debounce latch: one pending coalesced event refresh at a time.
static REFRESH_SCHEDULED: AtomicBool = AtomicBool::new(false);

/// Coalesce an event burst into one refresh `EVENT_DEBOUNCE` out.
fn schedule_refresh(ctx: &Context) {
    if REFRESH_SCHEDULED.swap(true, Ordering::SeqCst) {
        return;
    }
    let ctx = ctx.clone();
    tokio::spawn(async move {
        tokio::time::sleep(EVENT_DEBOUNCE).await;
        REFRESH_SCHEDULED.store(false, Ordering::SeqCst);
        refresh_locations(&ctx).await;
    });
}

#[derive(Default)]
struct RefreshLogState {
    outcome: String,
    /// Which discovery path produced the rows (`bridge`, `accessibility`,
    /// `mixed`, `none`). Part of the transition key so the switch between the
    /// add-on mirror and the AX walk is logged exactly once, not per cycle.
    mode: String,
    warning: bool,
    last_warning: Option<Instant>,
}

/// Where a refresh cycle's rows came from.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct RefreshMode {
    bridge: bool,
    accessibility: bool,
}

impl RefreshMode {
    fn label(self) -> &'static str {
        match (self.bridge, self.accessibility) {
            (true, true) => "mixed",
            (true, false) => "bridge",
            (false, true) => "accessibility",
            (false, false) => "none",
        }
    }
}

static REFRESH_LOG_STATE: LazyLock<Mutex<RefreshLogState>> =
    LazyLock::new(|| Mutex::new(RefreshLogState::default()));

/// Serialize AX work per Firefox pid. The host broker purges one pid's handle
/// table at the start of `host.ax_snapshot`, so same-pid snapshots and presses
/// must never overlap. Different Firefox editions have independent handle tables and
/// refresh concurrently so two 5-second broker deadlines still fit inside the
/// 10-second startup budget.
static AX_SESSIONS: LazyLock<Mutex<HashMap<i64, Weak<tokio::sync::Mutex<()>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn ax_session(pid: i64) -> Arc<tokio::sync::Mutex<()>> {
    let mut sessions = AX_SESSIONS.lock().unwrap();
    sessions.retain(|_, session| session.strong_count() > 0);
    if let Some(session) = sessions.get(&pid).and_then(Weak::upgrade) {
        return session;
    }
    let session = Arc::new(tokio::sync::Mutex::new(()));
    sessions.insert(pid, Arc::downgrade(&session));
    session
}

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

impl Tab {
    /// Shape one add-on mirror row as a `Tab` for candidate emission. The AX
    /// fields stay empty on purpose: handles only ever come from a live
    /// snapshot, and nothing downstream of `candidate` reads them — resolution
    /// re-finds the tab in a fresh AX walk (or jumps by keystroke) rather than
    /// trusting a handle that was minted at emit time.
    fn from_bridge(tab: &BridgeTab) -> Self {
        Self {
            handle: 0,
            parent_handle: None,
            root: 0,
            window_handle: None,
            title: tab.title.clone(),
            url: tab.url.clone(),
            selected: tab.active,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SessionTab {
    title: String,
    url: String,
}

/// Candidate payload: the raw url (the re-match key — see `resolve`) plus the
/// tab's strip position at emit time, which powers the keystroke fast path.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct TabPayload {
    #[serde(default)]
    url: String,
    /// 1-based position in the tab strip of its window.
    #[serde(default)]
    index: usize,
    /// Total tabs in that window.
    #[serde(default)]
    tab_count: usize,
    /// Firefox windows at emit time.
    #[serde(default)]
    window_count: usize,
    /// Whether this tab's window was the focused one at emit time. The ⌘digit
    /// plan only ever addresses the frontmost window, so it is the fast path's
    /// gate. The Accessibility walk can only assert it for a single-window
    /// browser; the add-on bridge names the focused window outright, which is
    /// what makes the fast path usable with several windows open.
    #[serde(default)]
    window_focused: bool,
}

/// One synthesized chord of the tab-jump plan (exactly one modifier — the
/// host's `host.post_keys` is chord-only by contract).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Chord {
    key_code: u32,
    modifier: &'static str,
}

/// ANSI keycodes for the digit row 1..9 — the same constants the host's
/// numbered-jump fallback sends as ⌘1..⌘9.
const DIGIT_KEYCODES: [u32; 9] = [18, 19, 20, 21, 23, 22, 26, 28, 25];
const KEY_PAGE_UP: u32 = 116;
const KEY_PAGE_DOWN: u32 = 121;
/// Longest ctrl+PgDn/PgUp walk the fast path takes from an anchor; past
/// this the AX press is comparable in latency and steadier visually.
const MAX_TAB_WALK: usize = 12;

/// Keystroke plan that lands on strip position `index` of `tab_count` using
/// Firefox's native bindings: ⌘1..⌘8 select positions directly, ⌘9 selects
/// the LAST tab, and ctrl+PgDn/PgUp step in strip order (layout-independent,
/// never MRU). Deep-middle positions beyond [`MAX_TAB_WALK`] return `None`
/// and fall back to the AX press.
fn tab_key_plan(index: usize, tab_count: usize) -> Option<Vec<Chord>> {
    if index == 0 || index > tab_count {
        return None;
    }
    let digit = |position: usize| Chord {
        key_code: DIGIT_KEYCODES[position - 1],
        modifier: "command",
    };
    if index <= 8 {
        return Some(vec![digit(index)]);
    }
    if index == tab_count {
        return Some(vec![digit(9)]);
    }
    let forward = index - 8;
    let backward = tab_count - index;
    if forward.min(backward) > MAX_TAB_WALK {
        return None;
    }
    let (anchor, step, count) = if forward <= backward {
        (digit(8), KEY_PAGE_DOWN, forward)
    } else {
        (digit(9), KEY_PAGE_UP, backward)
    };
    let mut plan = vec![anchor];
    plan.extend((0..count).map(|_| Chord {
        key_code: step,
        modifier: "control",
    }));
    Some(plan)
}

/// Post a chord plan to `pid` through the host. Modifier chords dispatch via
/// the target's key-equivalent path, so Firefox does not need to be
/// frontmost — the jump runs in parallel with `host.activate`.
async fn post_keys(ctx: &Context, pid: i64, plan: &[Chord]) -> bool {
    let keys: Vec<Value> = plan
        .iter()
        .map(|chord| json!({"key_code": chord.key_code, "modifiers": [chord.modifier]}))
        .collect();
    ctx.post_keys(json!({"pid": pid, "keys": keys, "interval_ms": 16}))
        .await
}

struct Firefox;

flash_plugin::plugin!(Firefox);

impl FlashPlugin for Firefox {
    async fn on_start(&self, ctx: Context) {
        // Runs after the initialize reply; a failed first cycle publishes
        // nothing (the host keeps last-good) and retries in the background.
        if !refresh_locations(&ctx).await {
            log_degraded_initial(&ctx);
            let retry_ctx = ctx.clone();
            tokio::spawn(async move {
                refresh_locations(&retry_ctx).await;
            });
        }
        start_refresh_poll(&ctx);
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            "core:apps.changed"
            | "core:focus.changed"
            | "core:window.focus.changed"
            | "core:session.opened" => schedule_refresh(&ctx),
            _ => {}
        }
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        resolve(&ctx, &row).await
    }

    async fn on_action(&self, ctx: Context, action: ActionRequest) -> PerformResponse {
        perform_action(&ctx, &action).await
    }

    async fn on_navigate(&self, ctx: Context, request: NavigateRequest) -> PerformResponse {
        restore_navigation(&ctx, &request).await
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        run_command(&ctx, &command).await
    }
}

fn firefox_apps(apps: &[RunningApplication]) -> Vec<(String, i64)> {
    let mut matches = apps
        .iter()
        .filter(|app| app.pid > 0 && is_firefox(&app.bundle_id))
        .map(|app| (app.bundle_id.clone(), app.pid))
        .collect::<Vec<_>>();
    matches.sort();
    matches
}

async fn refresh_locations(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, running| async move {
            refresh_locations_for_apps(&ctx, firefox_apps(&running)).await
        })
        .await
}

async fn refresh_locations_for_apps(ctx: &Context, apps: Vec<(String, i64)>) -> bool {
    let started_at = Instant::now();
    if apps.is_empty() {
        let changed = publish_rows(ctx, Vec::new());
        log_refresh(ctx, "empty", RefreshMode::default(), 0, started_at, changed);
        return true;
    }
    // The add-on mirror is one small disk read and carries exact per-window
    // indices, counts and the focused window, so it is tried first for every
    // edition. Only editions without a fresh mirror pay for an AX walk (and
    // only those need the session-store decode).
    let mut mode = RefreshMode::default();
    let mut candidates = Vec::new();
    let mut successful_apps = 0;
    let mut ax_apps = Vec::new();
    for (bundle, pid) in apps {
        match read_bridge_state(ctx, pid).await {
            Some(state) => {
                mode.bridge = true;
                successful_apps += 1;
                candidates.extend(bridge_candidates(&state, &source_name(&bundle), pid));
            }
            None => ax_apps.push((bundle, pid)),
        }
    }
    let mut failed_pids = std::collections::HashSet::new();
    if !ax_apps.is_empty() {
        mode.accessibility = true;
        let session_tabs = Arc::new(firefox_session_tabs().await);
        let mut refreshes = Vec::with_capacity(ax_apps.len());
        for (bundle, pid) in ax_apps {
            let task_ctx = ctx.clone();
            let session_tabs = Arc::clone(&session_tabs);
            refreshes.push((
                pid,
                tokio::spawn(async move {
                    let session = ax_session(pid);
                    let _ax = session.lock().await;
                    let tabs = try_collect_tabs_ax(&task_ctx, pid).await.map(|mut tabs| {
                        merge_session_urls(&mut tabs, &session_tabs);
                        tabs
                    });
                    (bundle, pid, tabs)
                }),
            ));
        }
        for (expected_pid, refresh) in refreshes {
            let (bundle, pid, tabs) = match refresh.await {
                Ok((bundle, pid, Some(tabs))) => (bundle, pid, tabs),
                Ok((_, pid, None)) => {
                    failed_pids.insert(pid);
                    continue;
                }
                Err(_) => {
                    // Join failures are not expected, but preserving this pid's
                    // last-good partition is safer than clearing unknown state.
                    failed_pids.insert(expected_pid);
                    continue;
                }
            };
            successful_apps += 1;
            candidates.extend(ax_candidates(&tabs, &source_name(&bundle), pid));
        }
    }
    // Preserve only editions whose AX snapshot failed. A successful empty
    // snapshot is authoritative, and editions absent from the current running
    // app list are removed.
    if !failed_pids.is_empty() {
        candidates.extend(last_rows().into_iter().filter(|candidate| {
            candidate
                .pid_value()
                .is_some_and(|pid| failed_pids.contains(&pid))
        }));
    }
    if successful_apps == 0 {
        // Publish nothing: the host keeps its last-good catalog.
        log_refresh(ctx, "failed", mode, candidates.len(), started_at, false);
        return false;
    }
    let outcome = if !failed_pids.is_empty() {
        "partial"
    } else if candidates.is_empty() {
        "empty"
    } else {
        "ok"
    };
    let count = candidates.len();
    let changed = publish_rows(ctx, candidates);
    log_refresh(ctx, outcome, mode, count, started_at, changed);
    true
}

/// Candidates for one edition from an Accessibility walk. Strip positions come
/// from document order within each window root: 1-based index, that window's
/// total, and the window count. The AX walk cannot say which window is
/// frontmost for a multi-window browser, so `window_focused` is only asserted
/// when there is exactly one window.
fn ax_candidates(tabs: &[Tab], source: &str, pid: i64) -> Vec<Candidate> {
    let mut root_totals: BTreeMap<usize, usize> = BTreeMap::new();
    for tab in tabs {
        *root_totals.entry(tab.root).or_default() += 1;
    }
    let window_count = root_totals.len();
    let mut root_seen: BTreeMap<usize, usize> = BTreeMap::new();
    tabs.iter()
        .map(|tab| {
            let seen = root_seen.entry(tab.root).or_default();
            *seen += 1;
            let payload = TabPayload {
                url: tab.url.clone(),
                index: *seen,
                tab_count: root_totals[&tab.root],
                window_count,
                window_focused: window_count == 1,
            };
            candidate(tab, source, pid, &payload)
        })
        .collect()
}

/// Candidates for one edition from the add-on mirror. Every position here is
/// authoritative: the strip index is the browser's own, and the focused window
/// is named outright, so the keystroke fast path stays available with several
/// windows open.
fn bridge_candidates(state: &BridgeState, source: &str, pid: i64) -> Vec<Candidate> {
    let mut window_totals: BTreeMap<i64, usize> = BTreeMap::new();
    for tab in &state.tabs {
        *window_totals.entry(tab.window_id).or_default() += 1;
    }
    let window_count = window_totals.len();
    state
        .tabs
        .iter()
        .map(|tab| {
            let payload = TabPayload {
                url: tab.url.clone(),
                index: tab.index as usize + 1,
                tab_count: window_totals[&tab.window_id],
                window_count,
                window_focused: state.focused_window_id == Some(tab.window_id),
            };
            candidate(&Tab::from_bridge(tab), source, pid, &payload)
        })
        .collect()
}

/// Last-published rows, kept so a partial cycle (one edition's AX snapshot
/// failed) can re-publish that edition's previous tabs — `publish` is a full
/// replacement, so dropped rows would vanish from the host store.
static LAST_ROWS: Mutex<Option<Vec<Candidate>>> = Mutex::new(None);

fn publish_rows(ctx: &Context, rows: Vec<Candidate>) -> bool {
    if let Ok(mut last) = LAST_ROWS.lock() {
        if last.as_ref() == Some(&rows) {
            return false;
        }
        *last = Some(rows.clone());
    }
    ctx.publish(rows);
    true
}

fn last_rows() -> Vec<Candidate> {
    LAST_ROWS
        .lock()
        .ok()
        .and_then(|rows| rows.clone())
        .unwrap_or_default()
}

fn log_refresh(
    ctx: &Context,
    outcome: &str,
    mode: RefreshMode,
    count: usize,
    started_at: Instant,
    changed: bool,
) {
    let elapsed_ms = started_at.elapsed().as_millis();
    let warning = elapsed_ms >= 1_000 || matches!(outcome, "failed" | "partial");
    let now = Instant::now();
    let mode_label = mode.label();
    let (should_log, recovery) = REFRESH_LOG_STATE
        .lock()
        .map(|mut state| {
            // The discovery path joins the transition key, so falling off the
            // add-on mirror onto the AX walk (and back) logs once per switch.
            let transition =
                state.outcome != outcome || state.mode != mode_label || state.warning != warning;
            let recovery = state.warning && !warning;
            let repeat_warning = warning
                && state
                    .last_warning
                    .is_none_or(|last| now.duration_since(last) >= REPEAT_WARNING_INTERVAL);
            let should_log = changed || transition || repeat_warning;
            state.outcome = outcome.to_string();
            state.mode = mode_label.to_string();
            state.warning = warning;
            if warning && should_log {
                state.last_warning = Some(now);
            }
            (should_log, recovery)
        })
        .unwrap_or((true, false));
    if !should_log {
        return;
    }
    ctx.log(
        if warning {
            "warn"
        } else if recovery {
            "info"
        } else {
            "debug"
        },
        &format!(
            "[firefox] refresh outcome={} mode={} count={} elapsed_ms={}",
            outcome, mode_label, count, elapsed_ms
        ),
    );
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log(
        "warn",
        "[firefox] initial warm catalog degraded outcome=unpublished_failure candidates=0 retry=immediate_background",
    );
}

fn start_refresh_poll(ctx: &Context) {
    drop(ctx.interval(POLL_INTERVAL, |ctx| async move {
        refresh_locations(&ctx).await;
    }));
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
    try_collect_tabs(ctx, pid).await.unwrap_or_default()
}

async fn try_collect_tabs(ctx: &Context, pid: i64) -> Option<Vec<Tab>> {
    let mut tabs = try_collect_tabs_ax(ctx, pid).await?;
    merge_session_urls(&mut tabs, &firefox_session_tabs().await);
    Some(tabs)
}

/// AX-only tab collection: no session-store merge. Enough for verification
/// reads (`selected` + the title compare in `same_tab`), which run several
/// times per pick — skipping the session decode keeps those rounds cheap.
async fn collect_tabs_ax(ctx: &Context, pid: i64) -> Vec<Tab> {
    try_collect_tabs_ax(ctx, pid).await.unwrap_or_default()
}

async fn try_collect_tabs_ax(ctx: &Context, pid: i64) -> Option<Vec<Tab>> {
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
    .await?;
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
    apply_window_title_selection(&mut tabs, &window_roots);
    Some(tabs)
}

/// Raise Firefox and snapshot its tabs (with session urls) concurrently.
/// Activation only needs the pid, so it's independent of the snapshot +
/// session-store read — running both under `join!` overlaps the
/// `host.activate` round-trip with the (disk-bound) tab collection. Used by
/// the numbered `tab_select` jump; resolve/restore go through
/// [`activate_and_find_tab`], whose fast path skips the session read.
async fn activate_and_collect_tabs(ctx: &Context, pid: i64) -> Vec<Tab> {
    let (_, tabs) = tokio::join!(activate_app(ctx, pid), collect_tabs(ctx, pid));
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
    for (root_index, root) in window_roots.iter().enumerate() {
        let window_title = root.title.trim();
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

// ---------------------------------------------------------------------------
// Add-on bridge state
// ---------------------------------------------------------------------------

/// Stat key for [`BRIDGE_STATE_CACHE`]: the state file, its mtime in ms and
/// its length. Mirrors the session-store cache's (path, mtime) key — the file
/// is rewritten whole by a rename, so a stat match means identical bytes.
type BridgeStateKey = (PathBuf, u128, u64);

/// Parsed bridge state, keyed by the stat of the file it came from. A
/// flashlight open plus a resolve reads the same file several times; the
/// add-on only rewrites it when a tab actually changes.
static BRIDGE_STATE_CACHE: Mutex<Option<(BridgeStateKey, Arc<BridgeState>)>> = Mutex::new(None);

fn bridge_dir(ctx: &Context) -> PathBuf {
    ctx.data_dir().join(BRIDGE_DIR_NAME)
}

/// Read the add-on's mirror for `pid`, or `None` when it is missing, stale,
/// oversized, of a version this binary does not speak, or unparsable — every
/// one of which simply hands the cycle back to the Accessibility walk.
async fn read_bridge_state(ctx: &Context, pid: i64) -> Option<Arc<BridgeState>> {
    let path = state_file(&bridge_dir(ctx), pid);
    let metadata = tokio::fs::metadata(&path).await.ok()?;
    if !metadata.is_file() || metadata.len() > MAX_STATE_BYTES {
        return None;
    }
    let modified = metadata.modified().ok()?;
    if SystemTime::now()
        .duration_since(modified)
        .is_ok_and(|age| age > BRIDGE_FRESHNESS)
    {
        return None;
    }
    let key: BridgeStateKey = (
        path.clone(),
        modified
            .duration_since(UNIX_EPOCH)
            .ok()
            .map(|since| since.as_millis())
            .unwrap_or(0),
        metadata.len(),
    );
    if let Some((cached_key, state)) = BRIDGE_STATE_CACHE.lock().unwrap().as_ref() {
        if *cached_key == key {
            return Some(Arc::clone(state));
        }
    }
    let bytes = tokio::fs::read(&path).await.ok()?;
    let mut state: BridgeState = serde_json::from_slice(&bytes).ok()?;
    if !state.is_supported() {
        return None;
    }
    state.normalize();
    let state = Arc::new(state);
    *BRIDGE_STATE_CACHE.lock().unwrap() = Some((key, Arc::clone(&state)));
    Some(state)
}

/// Tabs of `window_id` in strip order.
fn bridge_window_tabs(state: &BridgeState, window_id: i64) -> Vec<&BridgeTab> {
    let mut tabs: Vec<&BridgeTab> = state
        .tabs
        .iter()
        .filter(|tab| tab.window_id == window_id)
        .collect();
    tabs.sort_by_key(|tab| tab.index);
    tabs
}

/// The (path, mtime) list a session-store scan resolved; doubles as the
/// cache key for [`SESSION_TABS_CACHE`].
type SessionStorePaths = Vec<(PathBuf, u128)>;

/// Session tabs cache, keyed by the exact (path, mtime) list the scan
/// resolved. The recovery store is several MB of LZ4'd JSON and Firefox only
/// rewrites it every ~15s, while a single tab pick collects tabs multiple
/// times — decoding it on every collect dominated tab-switch latency.
static SESSION_TABS_CACHE: std::sync::Mutex<Option<(SessionStorePaths, Vec<SessionTab>)>> =
    std::sync::Mutex::new(None);

async fn firefox_session_tabs() -> Vec<SessionTab> {
    let keyed_paths = firefox_sessionstore_paths().await;
    if let Some((key, tabs)) = SESSION_TABS_CACHE.lock().unwrap().as_ref() {
        if *key == keyed_paths {
            return tabs.clone();
        }
    }
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for (path, _) in &keyed_paths {
        let Some(text) = read_moz_lz4_json(path).await else {
            continue;
        };
        for tab in parse_session_tabs(&text) {
            if seen.insert((tab.title.clone(), tab.url.clone())) {
                out.push(tab);
            }
        }
    }
    *SESSION_TABS_CACHE.lock().unwrap() = Some((keyed_paths, out.clone()));
    out
}

async fn firefox_sessionstore_paths() -> SessionStorePaths {
    let Some(home) = std::env::var_os("HOME") else {
        return Vec::new();
    };
    let profiles = PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Firefox")
        .join("Profiles");
    let Ok(mut entries) = tokio::fs::read_dir(profiles).await else {
        return Vec::new();
    };
    let mut paths = Vec::new();
    let mut profile_count = 0usize;
    while profile_count < MAX_FIREFOX_PROFILES {
        let Some(entry) = entries.next_entry().await.ok().flatten() else {
            break;
        };
        profile_count += 1;
        let profile = entry.path();
        push_sessionstore_path(
            &mut paths,
            0,
            profile
                .join("sessionstore-backups")
                .join("recovery.jsonlz4"),
        )
        .await;
        push_sessionstore_path(
            &mut paths,
            1,
            profile
                .join("sessionstore-backups")
                .join("previous.jsonlz4"),
        )
        .await;
        push_sessionstore_path(&mut paths, 2, profile.join("sessionstore.jsonlz4")).await;
    }
    paths.sort_by(|lhs, rhs| {
        rhs.0
            .cmp(&lhs.0)
            .then_with(|| lhs.1.cmp(&rhs.1))
            .then_with(|| lhs.2.cmp(&rhs.2))
    });
    paths.truncate(MAX_SESSIONSTORE_FILES);
    paths
        .into_iter()
        .map(|(modified_ms, _, path)| (path, modified_ms))
        .collect()
}

async fn push_sessionstore_path(
    paths: &mut Vec<(u128, usize, PathBuf)>,
    priority: usize,
    path: PathBuf,
) {
    let Ok(metadata) = tokio::fs::metadata(&path).await else {
        return;
    };
    if !metadata.is_file() {
        return;
    }
    if metadata.len() > MAX_SESSIONSTORE_COMPRESSED_BYTES {
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

async fn read_moz_lz4_json(path: &Path) -> Option<String> {
    let metadata = tokio::fs::metadata(path).await.ok()?;
    if !metadata.is_file() || metadata.len() > MAX_SESSIONSTORE_COMPRESSED_BYTES {
        return None;
    }
    let bytes = tokio::fs::read(path).await.ok()?;
    if bytes.len() as u64 > MAX_SESSIONSTORE_COMPRESSED_BYTES {
        return None;
    }
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
    if expected_len > MAX_SESSIONSTORE_DECODED_BYTES {
        return None;
    }
    let decoded = lz4_block_decode(&payload[4..], expected_len)?;
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
            if out.len() >= MAX_SESSION_TABS {
                return out;
            }
        }
    }
    out
}

fn lz4_block_decode(input: &[u8], expected_len: usize) -> Option<Vec<u8>> {
    if expected_len > MAX_SESSIONSTORE_DECODED_BYTES {
        return None;
    }
    let mut i = 0;
    let mut out = Vec::with_capacity(expected_len);
    while i < input.len() {
        let token = *input.get(i)?;
        i += 1;

        let mut literal_len = (token >> 4) as usize;
        if literal_len == 15 {
            literal_len = literal_len.checked_add(read_lz4_len(input, &mut i)?)?;
        }
        let literal_end = i.checked_add(literal_len)?;
        let output_after_literals = out.len().checked_add(literal_len)?;
        if literal_end > input.len() || output_after_literals > expected_len {
            return None;
        }
        out.extend_from_slice(&input[i..literal_end]);
        i = literal_end;
        if i >= input.len() {
            break;
        }

        let offset_end = i.checked_add(2)?;
        if offset_end > input.len() {
            return None;
        }
        let offset = u16::from_le_bytes([input[i], input[i + 1]]) as usize;
        i += 2;
        if offset == 0 || offset > out.len() {
            return None;
        }

        let mut match_len = (token & 0x0f) as usize + 4;
        if (token & 0x0f) == 15 {
            match_len = match_len.checked_add(read_lz4_len(input, &mut i)?)?;
        }
        if out.len().checked_add(match_len)? > expected_len {
            return None;
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
        *i = (*i).checked_add(1)?;
        len = len.checked_add(value)?;
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
/// filter; the payload carries the url (so resolution can re-match the tab
/// after a fresh snapshot) plus the strip position for the keystroke jump.
fn candidate(tab: &Tab, source: &str, pid: i64, payload: &TabPayload) -> Candidate {
    let name = if tab.title.is_empty() {
        tab.url.clone()
    } else {
        tab.title.clone()
    };
    let mut candidate = Candidate::new(source, name)
        .kind("browser_tab")
        .location()
        .subtitle("browser tab")
        .pid(pid)
        .payload_json(payload)
        .current_location(tab.selected);
    if !tab.url.is_empty() {
        candidate = candidate
            .url(tab.url.clone())
            .navigation_url(firefox_navigation_url(pid, &tab.url, &tab.title));
        if let Some(aliases) = url_aliases(&tab.url) {
            candidate = candidate.aliases([aliases]);
        }
    }
    candidate
}

/// Match `url` (primary key), then `name`, against a fresh tab snapshot.
fn find_tab<'a>(tabs: &'a [Tab], url: &str, name: &str) -> Option<&'a Tab> {
    tabs.iter()
        .find(|tab| !url.is_empty() && tab.url == url)
        .or_else(|| tabs.iter().find(|tab| tab.title == name))
}

/// Match against an AX-only collect: the url when the strip exposes one,
/// else a title hit that is unique across every window. Ambiguity (or no
/// hit) returns `None` so the caller can disambiguate with session-store
/// urls before falling back to first-title-match.
fn find_tab_unambiguous<'a>(tabs: &'a [Tab], url: &str, name: &str) -> Option<&'a Tab> {
    if let Some(hit) = tabs.iter().find(|tab| !url.is_empty() && tab.url == url) {
        return Some(hit);
    }
    let mut hits = tabs.iter().filter(|tab| tab.title == name);
    match (hits.next(), hits.next()) {
        (Some(only), None) => Some(only),
        _ => None,
    }
}

/// Raise Firefox and locate the `url`/`name` tab in its strip. The AX
/// snapshot deliberately races the raise, and the fast path is AX-only: a
/// unique title hit is already unambiguous, so the session-store decode
/// only joins the critical path when the strip is genuinely ambiguous.
/// `AXWindows` can be empty or partial while Firefox is still activating
/// (e.g. coming forward from another Space) — the warm-refresh path logs
/// "skipped empty tab list" for exactly that state — so a full miss retries
/// once after the activation settles, instead of leaving Firefox raised on
/// the wrong tab.
async fn activate_and_find_tab(ctx: &Context, pid: i64, url: &str, name: &str) -> Option<Tab> {
    let (_, mut tabs) = tokio::join!(activate_app(ctx, pid), collect_tabs_ax(ctx, pid));
    if let Some(tab) = find_tab_unambiguous(&tabs, url, name) {
        return Some(tab.clone());
    }
    merge_session_urls(&mut tabs, &firefox_session_tabs().await);
    if let Some(tab) = find_tab(&tabs, url, name) {
        return Some(tab.clone());
    }
    tokio::time::sleep(Duration::from_millis(250)).await;
    let tabs = collect_tabs(ctx, pid).await;
    find_tab(&tabs, url, name).cloned()
}

/// Resolve a flashlight pick. Fast path first: when the candidate carries a
/// usable strip position in the FOCUSED window (plan within the walk budget),
/// post Firefox's own tab shortcuts (⌘1..⌘8 / ⌘9 / ctrl+PgDn/PgUp) straight to
/// the pid in parallel with the raise — no AX read on the critical path at
/// all — then verify and, if the strip drifted since emit, correct through
/// the AX ladder in the background. Otherwise: re-snapshot and match by url,
/// then title, before pressing the tab via AX. The url key is read from the
/// payload — the raw string stashed at emit time — because the host
/// round-trips the `url` field through Foundation's URL parser, which can
/// percent-encode it away from what the fresh snapshot reports.
async fn resolve(ctx: &Context, row: &Candidate) -> PerformResponse {
    let Some(pid) = row.pid_value() else {
        return PerformResponse::unhandled();
    };
    let payload: Option<TabPayload> = row.payload_as();
    let url_owned = payload
        .as_ref()
        .map(|payload| payload.url.clone())
        .filter(|url| !url.is_empty())
        .or_else(|| {
            row.payload_str()
                .filter(|raw| !raw.is_empty() && !raw.starts_with('{'))
                .map(str::to_string)
        })
        .or_else(|| row.url_value().map(str::to_string))
        .unwrap_or_default();
    let url = url_owned.as_str();
    let name = row.title.as_str();

    // `window_focused` is the gate, not `window_count == 1`: ⌘1..⌘8 and
    // ctrl+PgDn/PgUp always address the frontmost window, so what matters is
    // that the target tab lives there. A single-window browser satisfies it
    // trivially; with several windows only the add-on mirror can assert it.
    if let Some(payload) = payload.as_ref().filter(|payload| payload.window_focused) {
        if let Some(plan) = tab_key_plan(payload.index, payload.tab_count) {
            let plan_len = plan.len();
            let (keys_ok, _) = tokio::join!(post_keys(ctx, pid, &plan), activate_app(ctx, pid));
            if keys_ok {
                spawn_fast_jump_verify(ctx, pid, url, name, plan_len);
                let mut response = PerformResponse::ok().target_pid(pid);
                if !url.is_empty() {
                    response = response.navigation_url(firefox_navigation_url(pid, url, name));
                }
                return response;
            }
            ctx.log(
                "debug",
                "[firefox] key plan rejected by host; using AX path",
            );
        }
    }

    let ax = ax_session(pid).lock_owned().await;
    let Some(target) = activate_and_find_tab(ctx, pid, url, name).await else {
        ctx.log(
            "warn",
            &format!(
                "[firefox] resolve target not found pid={pid} title_present={} url_present={}",
                !name.is_empty(),
                !url.is_empty()
            ),
        );
        return PerformResponse::fail("resolve target not found");
    };
    // Reply as soon as the target is in hand: the press lands within a few
    // ms of the spawn, while the 120ms settle + verify collect behind it
    // only ever gated the host's post-resolve bookkeeping, not the visible
    // switch. The owned guard rides into the task so warm refreshes stay
    // locked out until the selection settles; a press that doesn't stick
    // downgrades from an unresolved reply to a warn breadcrumb.
    let task_ctx = ctx.clone();
    let task_target = target.clone();
    tokio::spawn(async move {
        let _ax = ax;
        if select_tab(&task_ctx, pid, &task_target).await {
            task_ctx.log("debug", &format!("[firefox] resolve selected pid={pid}"));
        } else {
            task_ctx.log(
                "warn",
                &format!("[firefox] resolve select did not stick pid={pid}"),
            );
        }
    });
    let mut response = PerformResponse::ok().target_pid(pid);
    if !url.is_empty() {
        response = response.navigation_url(firefox_navigation_url(pid, url, name));
    }
    response
}

/// Verify a keystroke tab jump once the chord chain has landed, and correct
/// through the AX ladder when the strip drifted since the candidate was
/// emitted (a tab opened/closed/moved, so the plan hit a neighbour). Runs
/// detached — the jump itself was already answered.
fn spawn_fast_jump_verify(ctx: &Context, pid: i64, url: &str, name: &str, plan_len: usize) {
    let ctx = ctx.clone();
    let url = url.to_string();
    let name = name.to_string();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(120 + 40 * plan_len as u64)).await;
        let _ax = ax_session(pid).lock_owned().await;
        let tabs = collect_tabs_ax(&ctx, pid).await;
        if let Some(hit) = find_tab(&tabs, &url, &name) {
            if hit.selected {
                ctx.log(
                    "debug",
                    &format!("[firefox] fast tab jump verified pid={pid}"),
                );
                return;
            }
            ctx.log(
                "debug",
                &format!("[firefox] fast tab jump missed; correcting via AX pid={pid}"),
            );
            let target = hit.clone();
            if select_tab(&ctx, pid, &target).await {
                return;
            }
        } else if let Some(target) = activate_and_find_tab(&ctx, pid, &url, &name).await {
            if select_tab(&ctx, pid, &target).await {
                return;
            }
        }
        ctx.log(
            "warn",
            &format!("[firefox] fast tab jump could not be corrected pid={pid}"),
        );
    });
}

async fn restore_navigation(ctx: &Context, request: &NavigateRequest) -> PerformResponse {
    let Some(route) = parse_firefox_navigation_url(&request.url) else {
        return PerformResponse::unhandled();
    };
    let pid = route.pid;
    let session = ax_session(pid);
    let _ax = session.lock().await;
    let Some(target) = activate_and_find_tab(ctx, pid, &route.url, &route.title).await else {
        ctx.log(
            "warn",
            &format!("[firefox] restore target not found pid={pid}"),
        );
        return PerformResponse::fail("restore target not found");
    };
    if select_tab(ctx, pid, &target).await {
        PerformResponse::ok()
            .target_pid(pid)
            .navigation_url(request.url.clone())
    } else {
        ctx.log(
            "warn",
            &format!("[firefox] restore target press failed pid={pid}"),
        );
        PerformResponse::fail("restore target press failed")
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

/// `tab_select` (numbered-tab jump): select the Nth tab OF THE INTENDED WINDOW
/// — the focused one. The index is a strip position, so it has to be resolved
/// inside a single window; indexing the flattened multi-window tab list lands
/// in whichever window happens to come first in the walk. An index past the
/// end of that window's strip is `unhandled` rather than a jump into another
/// window.
///
/// With the add-on mirror the window and its strip are known exactly, so the
/// jump is a plain keystroke plan against the frontmost window. Without it the
/// Accessibility walk supplies the strip, and the frontmost window is the
/// first `AXWindows` root (front-to-back order) that actually has tabs.
async fn perform_action(ctx: &Context, action: &ActionRequest) -> PerformResponse {
    if action.name != "tab_select" {
        return PerformResponse::unhandled();
    }
    let index = action.index().unwrap_or(0);
    let (Some(pid), true) = (action.context.pid, index > 0) else {
        return PerformResponse::unhandled();
    };
    let index = index as usize;
    if let Some(state) = read_bridge_state(ctx, pid).await {
        return bridge_tab_select(ctx, pid, index, &state).await;
    }
    let session = ax_session(pid);
    let _ax = session.lock().await;
    let tabs = activate_and_collect_tabs(ctx, pid).await;
    let Some(target) = nth_tab_in_front_window(&tabs, index) else {
        return PerformResponse::unhandled();
    };
    let target = target.clone();
    // Firefox owns this tab_select claim either way: a successful press is
    // ok, but a failed press must be an error (not `unhandled`) so the host
    // doesn't fall back to a ⌘<digit> keystroke that switches the wrong tab.
    if select_tab(ctx, pid, &target).await {
        PerformResponse::ok().target_pid(pid)
    } else {
        PerformResponse::fail("tab press did not stick")
    }
}

/// The 1-based `index`th tab of the frontmost window that contributed tabs.
/// `AXWindows` is front-to-back, so the lowest root index present is the
/// window the user is looking at.
fn nth_tab_in_front_window(tabs: &[Tab], index: usize) -> Option<&Tab> {
    let front = tabs.iter().map(|tab| tab.root).min()?;
    tabs.iter()
        .filter(|tab| tab.root == front)
        .nth(index.checked_sub(1)?)
}

/// `tab_select` against the add-on mirror: the focused window's strip is
/// authoritative, so the jump is Firefox's own shortcut chain with no AX round
/// trip. A plan the walk budget rejects falls through to the AX ladder.
async fn bridge_tab_select(
    ctx: &Context,
    pid: i64,
    index: usize,
    state: &BridgeState,
) -> PerformResponse {
    let Some(window_id) = state.focused_window_id else {
        return PerformResponse::unhandled();
    };
    let tabs = bridge_window_tabs(state, window_id);
    if index > tabs.len() {
        return PerformResponse::unhandled();
    }
    let Some(plan) = tab_key_plan(index, tabs.len()) else {
        let session = ax_session(pid);
        let _ax = session.lock().await;
        let collected = activate_and_collect_tabs(ctx, pid).await;
        let Some(target) = nth_tab_in_front_window(&collected, index) else {
            return PerformResponse::unhandled();
        };
        let target = target.clone();
        return if select_tab(ctx, pid, &target).await {
            PerformResponse::ok().target_pid(pid)
        } else {
            PerformResponse::fail("tab press did not stick")
        };
    };
    let (keys_ok, _) = tokio::join!(post_keys(ctx, pid, &plan), activate_app(ctx, pid));
    if keys_ok {
        PerformResponse::ok().target_pid(pid)
    } else {
        PerformResponse::fail("tab key plan rejected by host")
    }
}

/// Select `tab`, escalating through three AX strategies. AXPress leads:
/// Firefox accepts the AXSelectedChildren / AXSelected writes with a success
/// status without moving the visible tab (observed in the field — both
/// "returned ok but not selected"), so leading with them costs a 120ms
/// verify round each on every pick; the press is what actually switches.
/// A strategy that succeeds is verified against a fresh AX-only collect —
/// that snapshot purges the previous generation's handles broker-side, so
/// the next strategy re-finds the tab in it. A strategy the element rejects
/// (`ok == false`) purges nothing (the caller holds the pid's AX session, so nothing
/// else snapshots either) and the next strategy reuses the same handles.
async fn select_tab(ctx: &Context, pid: i64, tab: &Tab) -> bool {
    raise_tab_window(ctx, tab).await;
    if tab.selected {
        return true;
    }

    let mut current = tab.clone();
    for strategy in ["press", "select_child", "set_selected"] {
        let ok = match strategy {
            "press" => ax_perform(ctx, current.handle, "AXPress").await,
            "select_child" => match current.parent_handle {
                Some(parent) => ax_select_child(ctx, parent, current.handle).await,
                None => false,
            },
            _ => ax_set(ctx, current.handle, "AXSelected", true).await,
        };
        if !ok {
            ctx.log(
                "debug",
                &format!("[firefox] select strategy {strategy} rejected"),
            );
            continue;
        }
        tokio::time::sleep(Duration::from_millis(120)).await;
        let tabs = collect_tabs_ax(ctx, pid).await;
        match tabs.iter().find(|candidate| same_tab(candidate, &current)) {
            Some(fresh) if fresh.selected => {
                raise_tab_window(ctx, fresh).await;
                return true;
            }
            Some(fresh) => {
                current = fresh.clone();
                ctx.log(
                    "debug",
                    &format!(
                        "[firefox] select strategy {strategy} returned ok but tab did not become selected"
                    ),
                );
            }
            None => {
                // Transient empty/partial snapshot (Firefox still settling
                // after the raise). The verify snapshot purged our handles,
                // so later strategies will be rejected too — but losing the
                // tab here is rare enough that a diagnostic beats plumbing a
                // re-find loop through.
                ctx.log(
                    "debug",
                    &format!(
                        "[firefox] select strategy {strategy} lost the tab in a {}-tab re-collect",
                        tabs.len()
                    ),
                );
            }
        }
    }

    false
}

async fn raise_tab_window(ctx: &Context, tab: &Tab) {
    if let Some(window_handle) = tab.window_handle {
        ax_perform(ctx, window_handle, "AXRaise").await;
        ax_set(ctx, window_handle, "AXMain", true).await;
        ax_set(ctx, window_handle, "AXFocused", true).await;
    }
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
    ctx.activate(pid).await
}

#[allow(clippy::too_many_arguments)]
async fn ax_snapshot(
    ctx: &Context,
    pid: i64,
    roots: &str,
    follow: &[&str],
    collect: &[&str],
    max_nodes: u64,
    geometry: bool,
    prune_roles: &[&str],
) -> Option<Vec<AxNode>> {
    let result = ctx
        .ax_snapshot(json!({
            "pid": pid,
            "roots": roots,
            "follow": follow,
            "collect": collect,
            "max_nodes": max_nodes,
            "geometry": geometry,
            "prune_roles": prune_roles,
        }))
        .await;
    if !result.get("ok").and_then(Value::as_bool).unwrap_or(false) {
        ctx.log(
            "warn",
            &format!(
                "[firefox] host.ax_snapshot failed pid={} error={}",
                pid,
                result
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
            ),
        );
        return None;
    }
    Some(
        result
            .get("nodes")
            .and_then(Value::as_array)
            .map(|nodes| nodes.iter().filter_map(AxNode::from_value).collect())
            .unwrap_or_default(),
    )
}

async fn ax_perform(ctx: &Context, handle: u64, action: &str) -> bool {
    ctx.ax_perform(handle, action).await
}

async fn ax_set(ctx: &Context, handle: u64, attribute: &str, value: bool) -> bool {
    ctx.ax_set(handle, attribute, value).await
}

async fn ax_select_child(ctx: &Context, parent: u64, child: u64) -> bool {
    ctx.ax_select_child(parent, child).await
}

/// Site aliases are per-app content the plugin owns — the host ranker has
/// no per-site knowledge. Space-separated tokens land in the top-scoring
/// alias tier.
fn url_aliases(url: &str) -> Option<&'static str> {
    if url.starts_with("https://mail.google.com") {
        return Some("gmail gmail.com");
    }
    None
}

// ---------------------------------------------------------------------------
// `:firefox setup` / `:firefox status`
// ---------------------------------------------------------------------------

/// Sibling of the running plugin binary. Both binaries of this crate ship side
/// by side inside the plugin directory, in the source tree and in the signed
/// bundle alike.
fn sibling_path(name: &str) -> Option<PathBuf> {
    Some(std::env::current_exe().ok()?.parent()?.join(name))
}

/// Single-quote a path for a shell command the user is going to paste.
fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}

async fn run_command(ctx: &Context, command: &CommandRequest) -> PerformResponse {
    match command.subcommand.as_str() {
        "setup" => setup(ctx).await,
        "status" => bridge_status(ctx).await,
        _ => PerformResponse::unhandled(),
    }
}

/// Tell the user how to install the add-on. The extension cannot be installed
/// for them — Firefox only loads an add-on the user loads themselves — so this
/// puts the one privileged step (writing the native-messaging host manifest)
/// on the clipboard and names the directory to load.
async fn setup(ctx: &Context) -> PerformResponse {
    let Some(bridge) = sibling_path("flash-plugin-firefox-bridge") else {
        return PerformResponse::fail("cannot resolve the bridge binary path");
    };
    let Some(extension) = sibling_path("extension") else {
        return PerformResponse::fail("cannot resolve the extension directory");
    };
    let install = format!("{} install", shell_quote(&bridge));
    let copied = ctx.clipboard_write(&install).await;
    let message = format!(
        "Firefox tab bridge setup\n\n1. Run this in a terminal{}:\n   {}\n\n\
         2. In Firefox open about:debugging#/runtime/this-firefox, choose \"Load Temporary \
         Add-on\", and pick:\n   {}/manifest.json\n\n\
         A temporary add-on is dropped on browser restart; install a signed build for a \
         permanent one. Flash keeps working without it — the add-on only sharpens tab \
         indices and titles.",
        if copied {
            " (copied to the clipboard)"
        } else {
            ""
        },
        install,
        extension.display()
    );
    PerformResponse::ok().message(message)
}

/// Content-free bridge report: counts and ages only, never a title or a URL.
async fn bridge_status(ctx: &Context) -> PerformResponse {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let host_manifest = match home.as_deref() {
        Some(home) => tokio::fs::metadata(bridge_state::host_manifest_path(home))
            .await
            .is_ok(),
        None => false,
    };
    let mut lines = vec![format!(
        "Firefox tab bridge: host manifest {}",
        if host_manifest {
            "installed"
        } else {
            "missing"
        }
    )];
    let apps = firefox_apps(&ctx.running_applications());
    if apps.is_empty() {
        lines.push("no Firefox process is running".to_string());
    }
    for (bundle, pid) in apps {
        let path = state_file(&bridge_dir(ctx), pid);
        let Ok(metadata) = tokio::fs::metadata(&path).await else {
            lines.push(format!(
                "{bundle} pid={pid}: no bridge state (Accessibility walk)"
            ));
            continue;
        };
        let age_s = metadata
            .modified()
            .ok()
            .and_then(|modified| SystemTime::now().duration_since(modified).ok())
            .map(|age| age.as_secs())
            .unwrap_or(0);
        match read_bridge_state(ctx, pid).await {
            Some(state) => lines.push(format!(
                "{bundle} pid={pid}: bridge age={age_s}s windows={} tabs={}",
                state.windows.len(),
                state.tabs.len()
            )),
            None if age_s > BRIDGE_FRESHNESS.as_secs() => lines.push(format!(
                "{bundle} pid={pid}: state stale age={age_s}s (Accessibility walk)"
            )),
            None => lines.push(format!(
                "{bundle} pid={pid}: state unusable age={age_s}s (Accessibility walk)"
            )),
        }
    }
    PerformResponse::ok().message(lines.join("\n"))
}

fn main() {
    run(Firefox);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tab(title: &str, url: &str) -> Tab {
        Tab {
            handle: 0,
            parent_handle: None,
            root: 0,
            window_handle: None,
            title: title.to_string(),
            url: url.to_string(),
            selected: false,
        }
    }

    fn bridge_tab(id: i64, window_id: i64, index: u32, title: &str, active: bool) -> BridgeTab {
        BridgeTab {
            id,
            window_id,
            index,
            title: title.to_string(),
            url: format!("https://example.com/{id}"),
            active,
            pinned: false,
        }
    }

    fn ax_tab(root: usize, title: &str) -> Tab {
        Tab {
            handle: 0,
            parent_handle: None,
            root,
            window_handle: None,
            title: title.to_string(),
            url: String::new(),
            selected: false,
        }
    }

    #[test]
    fn bridge_candidates_carry_per_window_positions_and_focus() {
        let state = BridgeState {
            version: bridge_state::STATE_VERSION,
            sequence: 7,
            timestamp_ms: 1,
            focused_window_id: Some(2),
            windows: vec![
                bridge_state::BridgeWindow {
                    id: 1,
                    focused: false,
                },
                bridge_state::BridgeWindow {
                    id: 2,
                    focused: true,
                },
            ],
            tabs: vec![
                bridge_tab(10, 1, 0, "One", true),
                bridge_tab(11, 1, 1, "Two", false),
                bridge_tab(12, 1, 2, "Three", false),
                bridge_tab(20, 2, 0, "Alpha", false),
                bridge_tab(21, 2, 1, "Beta", true),
            ],
        };
        let rows = bridge_candidates(&state, "firefox.tabs", 99);
        let payloads: Vec<TabPayload> = rows
            .iter()
            .map(|row| row.payload_as::<TabPayload>().unwrap())
            .collect();
        // 1-based strip position within the tab's OWN window, that window's
        // total, and focus reserved for the window the browser says is front.
        assert_eq!(
            payloads
                .iter()
                .map(|payload| (payload.index, payload.tab_count, payload.window_focused))
                .collect::<Vec<_>>(),
            vec![
                (1, 3, false),
                (2, 3, false),
                (3, 3, false),
                (1, 2, true),
                (2, 2, true)
            ]
        );
        assert!(payloads.iter().all(|payload| payload.window_count == 2));
    }

    #[test]
    fn ax_candidates_only_claim_focus_for_a_single_window() {
        let one = ax_candidates(&[ax_tab(0, "Only")], "firefox.tabs", 1);
        assert!(one[0].payload_as::<TabPayload>().unwrap().window_focused);
        let two = ax_candidates(&[ax_tab(0, "Front"), ax_tab(1, "Back")], "firefox.tabs", 1);
        assert!(two
            .iter()
            .all(|row| !row.payload_as::<TabPayload>().unwrap().window_focused));
    }

    #[test]
    fn tab_select_index_stays_inside_the_front_window() {
        let tabs = [
            ax_tab(0, "Front 1"),
            ax_tab(0, "Front 2"),
            ax_tab(1, "Back 1"),
            ax_tab(1, "Back 2"),
            ax_tab(1, "Back 3"),
        ];
        assert_eq!(nth_tab_in_front_window(&tabs, 2).unwrap().title, "Front 2");
        // The front window has 2 tabs: index 3 must NOT spill into the other
        // window (the flat-index bug this replaces returned "Back 1").
        assert!(nth_tab_in_front_window(&tabs, 3).is_none());
        assert!(nth_tab_in_front_window(&tabs, 0).is_none());
        assert!(nth_tab_in_front_window(&[], 1).is_none());
    }

    #[test]
    fn bridge_window_tabs_are_returned_in_strip_order() {
        let state = BridgeState {
            version: bridge_state::STATE_VERSION,
            focused_window_id: Some(1),
            windows: vec![bridge_state::BridgeWindow {
                id: 1,
                focused: true,
            }],
            tabs: vec![
                bridge_tab(3, 1, 2, "Third", false),
                bridge_tab(1, 1, 0, "First", false),
                bridge_tab(2, 1, 1, "Second", true),
            ],
            ..BridgeState::default()
        };
        assert_eq!(
            bridge_window_tabs(&state, 1)
                .iter()
                .map(|tab| tab.title.as_str())
                .collect::<Vec<_>>(),
            vec!["First", "Second", "Third"]
        );
        assert!(bridge_window_tabs(&state, 9).is_empty());
    }

    #[test]
    fn normalizing_bridge_state_drops_orphans_and_repairs_focus() {
        let mut state = BridgeState {
            version: bridge_state::STATE_VERSION,
            focused_window_id: Some(404),
            windows: vec![bridge_state::BridgeWindow {
                id: 1,
                focused: true,
            }],
            tabs: vec![
                bridge_tab(1, 1, 0, "Kept", true),
                bridge_tab(2, 77, 0, "Orphan", false),
            ],
            ..BridgeState::default()
        };
        state.normalize();
        assert_eq!(state.tabs.len(), 1);
        assert_eq!(state.tabs[0].title, "Kept");
        // A focused window id no window claims is replaced by the window that
        // reports itself focused, never left dangling.
        assert_eq!(state.focused_window_id, Some(1));
    }

    #[test]
    fn unsupported_bridge_state_versions_are_rejected() {
        let mut state = BridgeState::default();
        assert!(!state.is_supported());
        state.version = bridge_state::STATE_VERSION;
        assert!(state.is_supported());
    }

    #[test]
    fn find_tab_prefers_url_over_title() {
        let tabs = [
            tab("Inbox", "https://mail.example.com/"),
            tab("Inbox", "https://other.example.com/"),
        ];
        let hit = find_tab(&tabs, "https://other.example.com/", "Inbox").unwrap();
        assert_eq!(hit.url, "https://other.example.com/");
    }

    #[test]
    fn tab_key_plan_uses_direct_anchors() {
        // ⌘1..⌘8 are direct positions.
        assert_eq!(
            tab_key_plan(3, 26),
            Some(vec![Chord {
                key_code: 20,
                modifier: "command"
            }])
        );
        // ⌘9 is "last tab", whatever the count.
        assert_eq!(
            tab_key_plan(26, 26),
            Some(vec![Chord {
                key_code: 25,
                modifier: "command"
            }])
        );
        // Small strips: the last tab is still within the digit row.
        assert_eq!(
            tab_key_plan(5, 5),
            Some(vec![Chord {
                key_code: 23,
                modifier: "command"
            }])
        );
    }

    #[test]
    fn tab_key_plan_walks_from_the_nearest_anchor() {
        // 10 of 26: ⌘8 then 2 × ctrl+PgDn.
        let plan = tab_key_plan(10, 26).unwrap();
        assert_eq!(plan[0].key_code, 28);
        assert_eq!(plan[0].modifier, "command");
        assert_eq!(plan.len(), 3);
        assert!(plan[1..]
            .iter()
            .all(|c| c.key_code == KEY_PAGE_DOWN && c.modifier == "control"));

        // 24 of 26: ⌘9 then 2 × ctrl+PgUp.
        let plan = tab_key_plan(24, 26).unwrap();
        assert_eq!(plan[0].key_code, 25);
        assert_eq!(plan.len(), 3);
        assert!(plan[1..]
            .iter()
            .all(|c| c.key_code == KEY_PAGE_UP && c.modifier == "control"));
    }

    #[test]
    fn tab_key_plan_rejects_deep_middles_and_stale_indexes() {
        // 40 of 80: both walks exceed MAX_TAB_WALK → AX path.
        assert_eq!(tab_key_plan(40, 80), None);
        // Stale index beyond the strip, or nonsense zero.
        assert_eq!(tab_key_plan(9, 8), None);
        assert_eq!(tab_key_plan(0, 8), None);
    }

    #[test]
    fn find_tab_unambiguous_requires_a_unique_title_hit() {
        let unique = [tab("Docs", ""), tab("Inbox", "")];
        assert_eq!(
            find_tab_unambiguous(&unique, "https://gone.example.com/", "Docs")
                .unwrap()
                .title,
            "Docs"
        );
        // Two same-titled tabs without urls: ambiguous, so the caller must
        // disambiguate with session urls instead of first-match.
        let dup = [tab("Inbox", ""), tab("Inbox", "")];
        assert!(find_tab_unambiguous(&dup, "", "Inbox").is_none());
        // A url hit resolves the ambiguity outright.
        let with_urls = [
            tab("Inbox", "https://a.example.com/"),
            tab("Inbox", "https://b.example.com/"),
        ];
        assert_eq!(
            find_tab_unambiguous(&with_urls, "https://b.example.com/", "Inbox")
                .unwrap()
                .url,
            "https://b.example.com/"
        );
    }

    #[test]
    fn find_tab_falls_back_to_title_when_url_is_empty_or_misses() {
        let tabs = [tab("Docs", ""), tab("Inbox", "https://mail.example.com/")];
        assert_eq!(find_tab(&tabs, "", "Docs").unwrap().title, "Docs");
        // A stale candidate url (tab navigated away) still lands on the title.
        assert_eq!(
            find_tab(&tabs, "https://gone.example.com/", "Inbox")
                .unwrap()
                .title,
            "Inbox"
        );
        assert!(find_tab(&tabs, "https://gone.example.com/", "Nope").is_none());
    }

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
    fn initial_snapshot_filters_running_firefox_apps() {
        let apps = vec![
            RunningApplication {
                bundle_id: FIREFOX.into(),
                pid: 10,
                localized_name: "Firefox".into(),
            },
            RunningApplication {
                bundle_id: FIREFOX_DEV.into(),
                pid: 11,
                localized_name: "Firefox Developer Edition".into(),
            },
            RunningApplication {
                bundle_id: "com.apple.Safari".into(),
                pid: 12,
                localized_name: "Safari".into(),
            },
            RunningApplication {
                bundle_id: FIREFOX.into(),
                pid: 0,
                localized_name: "Firefox".into(),
            },
        ];

        assert_eq!(
            firefox_apps(&apps),
            vec![(FIREFOX.into(), 10), (FIREFOX_DEV.into(), 11)]
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
            lz4_block_decode(&compressed, 9).as_deref(),
            Some(&b"abcabcabc"[..])
        );
    }

    #[test]
    fn lz4_block_decoder_rejects_output_beyond_the_advertised_length() {
        let compressed = [0x32, b'a', b'b', b'c', 3, 0];
        assert!(lz4_block_decode(&compressed, 8).is_none());
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

    #[test]
    fn rejects_sessionstore_with_oversized_advertised_output() {
        let mut frame = b"mozLz40\0".to_vec();
        frame.extend_from_slice(&((MAX_SESSIONSTORE_DECODED_BYTES as u32) + 1).to_le_bytes());
        frame.push(0);

        assert!(decode_moz_lz4_json(&frame).is_none());
    }
}
