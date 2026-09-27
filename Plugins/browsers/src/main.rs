//! Browser tab catalogs and tab actions. One engine table maps every
//! supported bundle id to how its tabs are read and driven: AppleScript for
//! Chromium-family browsers and Safari ([`applescript`]), the Accessibility
//! tab strip plus the session store for Firefox ([`firefox`]). Every row
//! carries a `flash-browser://` route ([`route`]) that movement history
//! restores through `on_navigate`.

mod applescript;
mod ax;
mod firefox;
mod lz4;
mod route;
mod session_store;

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use applescript::{Dialect, CHROMIUM, SAFARI};
use firefox::StripPosition;
use flash_plugin::{
    run, run_osascript, ActionRequest, AppWatch, Candidate, Context, Event, NavigateRequest,
    PerformResponse, RefreshGate, RunningApplication,
};
use route::{TabRoute, TabTarget};
use serde::{Deserialize, Serialize};

/// Safety-net poll; events (app/focus changes, flashlight open) drive the
/// authoritative refreshes, so this only bounds staleness for tab changes
/// that emit no host event.
const POLL_INTERVAL: Duration = Duration::from_secs(10);
/// Event bursts (a launch fires apps.changed + focus.changed +
/// window.focus.changed back to back) coalesce into one refresh.
const EVENT_DEBOUNCE: Duration = Duration::from_millis(300);
const REPEAT_WARNING_INTERVAL: Duration = Duration::from_secs(60);
const LIST_TIMEOUT: Duration = Duration::from_secs(10);
const ACTION_TIMEOUT: Duration = Duration::from_secs(5);
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
/// Debounce latch: one pending coalesced event refresh at a time.
static REFRESH_SCHEDULED: AtomicBool = AtomicBool::new(false);
/// A refresh reads every running browser, so only events touching one
/// schedule it: focus changes elsewhere cannot change a tab list.
static BROWSER_EVENTS: AppWatch = AppWatch::new();
static REFRESH_LOG_STATE: LazyLock<Mutex<RefreshLogState>> =
    LazyLock::new(|| Mutex::new(RefreshLogState::default()));
/// Last-published rows, kept so a partial cycle (one browser's read failed)
/// can re-publish that browser's previous tabs — `publish` is a full
/// replacement, so dropped rows would vanish from the host store.
static LAST_ROWS: Mutex<Option<Vec<Candidate>>> = Mutex::new(None);

/// How one browser family's tabs are read and driven.
#[derive(Clone, Copy)]
enum Engine {
    /// Scripted over Apple Events in this dialect.
    AppleScript(&'static Dialect),
    /// Firefox: no tab scripting dictionary, so tabs come from the
    /// Accessibility tab strip and the session store, and selection goes
    /// through host key chords and the AX broker.
    Gecko,
}

/// One supported browser edition: the canonical `tell application` name (the
/// host passes only the bundle id in action context), the `<vendor>.tabs`
/// source label its rows carry so `@chrome` / `@firefox` etc. filter
/// correctly, and its engine.
struct Browser {
    bundle_id: &'static str,
    app_name: &'static str,
    source: &'static str,
    engine: Engine,
}

const fn scripted(
    bundle_id: &'static str,
    app_name: &'static str,
    source: &'static str,
    dialect: &'static Dialect,
) -> Browser {
    Browser {
        bundle_id,
        app_name,
        source,
        engine: Engine::AppleScript(dialect),
    }
}

const fn gecko(bundle_id: &'static str, app_name: &'static str) -> Browser {
    Browser {
        bundle_id,
        app_name,
        // Release, Developer Edition and Nightly filter together.
        source: "firefox.tabs",
        engine: Engine::Gecko,
    }
}

#[rustfmt::skip]
const BROWSERS: &[Browser] = &[
    scripted("com.google.Chrome", "Google Chrome", "chrome.tabs", &CHROMIUM),
    scripted("com.google.Chrome.canary", "Google Chrome Canary", "chrome.tabs", &CHROMIUM),
    scripted("com.google.Chrome.beta", "Google Chrome Beta", "chrome.tabs", &CHROMIUM),
    scripted("com.google.Chrome.dev", "Google Chrome Dev", "chrome.tabs", &CHROMIUM),
    scripted("org.chromium.Chromium", "Chromium", "chromium.tabs", &CHROMIUM),
    scripted("com.brave.Browser", "Brave Browser", "brave.tabs", &CHROMIUM),
    scripted("com.brave.Browser.beta", "Brave Browser Beta", "brave.tabs", &CHROMIUM),
    scripted("com.brave.Browser.nightly", "Brave Browser Nightly", "brave.tabs", &CHROMIUM),
    scripted("com.microsoft.edgemac", "Microsoft Edge", "edge.tabs", &CHROMIUM),
    scripted("com.microsoft.edgemac.Beta", "Microsoft Edge Beta", "edge.tabs", &CHROMIUM),
    scripted("com.microsoft.edgemac.Dev", "Microsoft Edge Dev", "edge.tabs", &CHROMIUM),
    scripted("com.microsoft.edgemac.Canary", "Microsoft Edge Canary", "edge.tabs", &CHROMIUM),
    scripted("company.thebrowser.Browser", "Arc", "arc.tabs", &CHROMIUM),
    scripted("com.vivaldi.Vivaldi", "Vivaldi", "vivaldi.tabs", &CHROMIUM),
    scripted("com.operasoftware.Opera", "Opera", "opera.tabs", &CHROMIUM),
    scripted("com.operasoftware.OperaNext", "Opera Next", "opera.tabs", &CHROMIUM),
    scripted("com.operasoftware.OperaDeveloper", "Opera Developer", "opera.tabs", &CHROMIUM),
    scripted("com.apple.Safari", "Safari", "safari.tabs", &SAFARI),
    scripted("com.apple.SafariTechnologyPreview", "Safari Technology Preview", "safari.tabs", &SAFARI),
    gecko("org.mozilla.firefox", "Firefox"),
    gecko("org.mozilla.firefoxdeveloperedition", "Firefox Developer Edition"),
    gecko("org.mozilla.nightly", "Firefox Nightly"),
];

fn browser_for(bundle_id: &str) -> Option<&'static Browser> {
    BROWSERS
        .iter()
        .find(|browser| browser.bundle_id == bundle_id)
}

/// A running edition, with the AppleScript label to address it by: the
/// localized name, or the canonical one when empty.
struct RunningBrowser {
    browser: &'static Browser,
    label: String,
    pid: i64,
}

fn running_browsers(running: &[RunningApplication]) -> Vec<RunningBrowser> {
    running
        .iter()
        .filter(|app| app.pid > 0)
        .filter_map(|app| {
            let browser = browser_for(&app.bundle_id)?;
            let label = if app.localized_name.is_empty() {
                browser.app_name.to_string()
            } else {
                app.localized_name.clone()
            };
            Some(RunningBrowser {
                browser,
                label,
                pid: app.pid,
            })
        })
        .collect()
}

/// Round-tripped through the host so `on_resolve` can re-find the tab after
/// unrelated refreshes, even across a plugin restart.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct TabPayload {
    bundle_id: String,
    /// The AppleScript label the row was listed under.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    app_name: String,
    /// The raw URL as listed (the host's copy of the row URL is re-encoded).
    #[serde(default)]
    url: String,
    /// Firefox strip position, for the key fast path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    strip: Option<StripPosition>,
}

/// One tab row. A tab without a title shows its URL.
fn tab_candidate(
    browser: &Browser,
    pid: i64,
    title: &str,
    url: &str,
    current: bool,
    payload: &TabPayload,
) -> Candidate {
    let display = if title.is_empty() { url } else { title };
    let mut candidate = Candidate::new(browser.source, display)
        .kind("browser_tab")
        .location()
        .subtitle("browser tab")
        .bundle_id(browser.bundle_id)
        .pid(pid)
        .payload_json(payload)
        .current_location(current);
    if let Some(route) = TabRoute::new(pid, url, title) {
        candidate = candidate.navigation_url(route.to_url());
    }
    if !url.is_empty() {
        candidate = candidate.url(url);
        if let Some(aliases) = url_aliases(url) {
            candidate = candidate.aliases([aliases]);
        }
    }
    candidate
}

/// A performed pick or restore, naming the route it landed on.
fn performed(pid: i64, route: Option<TabRoute>) -> PerformResponse {
    let response = PerformResponse::ok().target_pid(pid);
    match route {
        Some(route) => response.navigation_url(route.to_url()),
        None => response,
    }
}

#[derive(Default)]
struct RefreshLogState {
    outcome: String,
    warning: bool,
    last_warning: Option<Instant>,
}

struct Browsers;

flash_plugin::plugin!(Browsers);

impl FlashPlugin for Browsers {
    async fn on_start(&self, ctx: Context) {
        // Runs after the initialize reply; a failed first cycle publishes
        // nothing (the host keeps last-good) and retries in the background.
        if !refresh_locations(&ctx).await {
            ctx.log(
                "warn",
                "[browsers] initial warm catalog degraded outcome=unpublished_failure candidates=0 retry=immediate_background",
            );
            let retry_ctx = ctx.clone();
            tokio::spawn(async move {
                refresh_locations(&retry_ctx).await;
            });
        }
        drop(ctx.interval(POLL_INTERVAL, |ctx| async move {
            refresh_locations(&ctx).await;
        }));
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if BROWSER_EVENTS.touches(
            &event,
            || ctx.running_applications(),
            |bundle| browser_for(bundle).is_some(),
        ) {
            schedule_refresh(&ctx);
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
}

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

async fn refresh_locations(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, running| async move {
            refresh_locations_for_apps(&ctx, running_browsers(&running)).await
        })
        .await
}

async fn refresh_locations_for_apps(ctx: &Context, apps: Vec<RunningBrowser>) -> bool {
    let started_at = Instant::now();
    // A complete running-app snapshot with no matching browser is authoritative:
    // clear dead tab rows.
    if apps.is_empty() {
        let changed = publish_rows(ctx, Vec::new());
        log_refresh(
            ctx,
            "empty",
            &RefreshSummary::default(),
            started_at,
            changed,
        );
        return true;
    }
    // Browsers are independent and each read costs hundreds of ms, so they
    // run concurrently: one osascript per scripted edition, one task walking
    // every running Firefox (they share the session-store read).
    let firefoxes: Vec<(&'static Browser, i64)> = apps
        .iter()
        .filter(|app| matches!(app.browser.engine, Engine::Gecko))
        .map(|app| (app.browser, app.pid))
        .collect();
    let firefox_task =
        (!firefoxes.is_empty()).then(|| tokio::spawn(firefox::list_tabs(ctx.clone(), firefoxes)));
    let mut scripts = Vec::new();
    for app in &apps {
        if let Engine::AppleScript(dialect) = app.browser.engine {
            let ctx = ctx.clone();
            let (browser, label, pid) = (app.browser, app.label.clone(), app.pid);
            scripts.push((
                pid,
                tokio::spawn(
                    async move { list_scripted(&ctx, browser, dialect, &label, pid).await },
                ),
            ));
        }
    }
    // `Some([])` is an authoritative zero-tab result; `None` (or a missing
    // pid) is the only transient-failure signal.
    let mut results: HashMap<i64, Option<Vec<Candidate>>> = HashMap::new();
    for (pid, handle) in scripts {
        results.insert(pid, handle.await.ok().flatten());
    }
    if let Some(task) = firefox_task {
        if let Ok(rows) = task.await {
            results.extend(rows);
        }
    }
    let mut candidates = Vec::new();
    let mut failed_pids = std::collections::HashSet::new();
    let mut successful_apps = 0;
    // Merge in app order so completion timing cannot reorder the catalog.
    for app in &apps {
        match results.remove(&app.pid).flatten() {
            Some(rows) => {
                successful_apps += 1;
                candidates.extend(rows);
            }
            None => {
                failed_pids.insert(app.pid);
            }
        }
    }
    // Preserve only the failed running editions. Successful empty results clear
    // that edition, and rows for browsers no longer in the host snapshot drop.
    if !failed_pids.is_empty() {
        candidates.extend(last_rows().into_iter().filter(|candidate| {
            candidate
                .pid_value()
                .is_some_and(|pid| failed_pids.contains(&pid))
        }));
    }
    if successful_apps == 0 {
        // Publish nothing: the host keeps its last-good catalog.
        log_refresh(
            ctx,
            "failed",
            &RefreshSummary::of(&candidates),
            started_at,
            false,
        );
        return false;
    }
    let outcome = if !failed_pids.is_empty() {
        "partial"
    } else if candidates.is_empty() {
        "empty"
    } else {
        "ok"
    };
    let summary = RefreshSummary::of(&candidates);
    let changed = publish_rows(ctx, candidates);
    log_refresh(ctx, outcome, &summary, started_at, changed);
    true
}

async fn list_scripted(
    ctx: &Context,
    browser: &'static Browser,
    dialect: &'static Dialect,
    label: &str,
    pid: i64,
) -> Option<Vec<Candidate>> {
    let result = run_osascript(ctx, &dialect.list_script(label), LIST_TIMEOUT).await;
    if !result.ok {
        return None;
    }
    let rows = applescript::parse_tab_list(&result.stdout)
        .into_iter()
        .map(|tab| {
            let payload = TabPayload {
                bundle_id: browser.bundle_id.to_string(),
                app_name: label.to_string(),
                url: tab.url.clone(),
                strip: None,
            };
            tab_candidate(browser, pid, &tab.title, &tab.url, tab.current, &payload)
        })
        .collect();
    Some(rows)
}

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

/// Content-free shape of a published catalog: its row count and the rows
/// per source in catalog order (`chrome.tabs:12 firefox.tabs:9`).
#[derive(Default)]
struct RefreshSummary {
    count: usize,
    sources: String,
}

impl RefreshSummary {
    fn of(rows: &[Candidate]) -> Self {
        let mut counts: Vec<(&str, usize)> = Vec::new();
        for row in rows {
            match counts.iter_mut().find(|(source, _)| *source == row.source) {
                Some((_, count)) => *count += 1,
                None => counts.push((&row.source, 1)),
            }
        }
        Self {
            count: rows.len(),
            sources: counts
                .iter()
                .map(|(source, count)| format!("{source}:{count}"))
                .collect::<Vec<_>>()
                .join(" "),
        }
    }
}

fn log_refresh(
    ctx: &Context,
    outcome: &str,
    summary: &RefreshSummary,
    started_at: Instant,
    changed: bool,
) {
    let elapsed_ms = started_at.elapsed().as_millis();
    let warning = elapsed_ms >= 1_000 || matches!(outcome, "failed" | "partial");
    let now = Instant::now();
    let (should_log, recovery) = REFRESH_LOG_STATE
        .lock()
        .map(|mut state| {
            let transition = state.outcome != outcome || state.warning != warning;
            let recovery = state.warning && !warning;
            let repeat_warning = warning
                && state
                    .last_warning
                    .is_none_or(|last| now.duration_since(last) >= REPEAT_WARNING_INTERVAL);
            let should_log = changed || transition || repeat_warning;
            state.outcome = outcome.to_string();
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
            "[browsers] refresh outcome={} count={} elapsed_ms={} sources=[{}]",
            outcome, summary.count, elapsed_ms, summary.sources
        ),
    );
}

async fn resolve(ctx: &Context, row: &Candidate) -> PerformResponse {
    let Some(pid) = row.pid_value() else {
        return PerformResponse::unhandled();
    };
    let Some((tab, browser)) = row
        .payload_as::<TabPayload>()
        .and_then(|tab| browser_for(&tab.bundle_id).map(|browser| (tab, browser)))
    else {
        ctx.activate(pid).await;
        return PerformResponse::ok().target_pid(pid);
    };
    let dialect = match browser.engine {
        Engine::Gecko => return firefox::resolve(ctx, pid, row, &tab).await,
        Engine::AppleScript(dialect) => dialect,
    };
    ctx.activate(pid).await;
    let route = TabRoute::new(pid, &tab.url, &row.title);
    if tab.url.is_empty() {
        return performed(pid, route);
    }
    let label = if tab.app_name.is_empty() {
        browser.app_name
    } else {
        tab.app_name.as_str()
    };
    let script = dialect.select_script(label, &TabTarget::Url(tab.url.clone()));
    let result = run_osascript(ctx, &script, LIST_TIMEOUT).await;
    if !result.ok || result.stdout.trim() != "ok" {
        ctx.log(
            "warn",
            &format!(
                "[browsers] tab-select did not confirm (ok={}, out={:?})",
                result.ok,
                result.stdout.trim()
            ),
        );
    }
    // The window was activated regardless, so still report a best-effort raise.
    performed(pid, route)
}

/// Restore a `flash-browser` route in the browser process it names.
async fn restore_navigation(ctx: &Context, request: &NavigateRequest) -> PerformResponse {
    let Some(route) = TabRoute::parse(&request.url) else {
        return PerformResponse::unhandled();
    };
    let Some(app) = running_browsers(&ctx.running_applications())
        .into_iter()
        .find(|app| app.pid == route.pid)
    else {
        return PerformResponse::fail("the route's browser is no longer running");
    };
    let dialect = match app.browser.engine {
        Engine::Gecko => return firefox::restore(ctx, &route).await,
        Engine::AppleScript(dialect) => dialect,
    };
    let script = dialect.select_script(&app.label, &route.target);
    let result = run_osascript(ctx, &script, ACTION_TIMEOUT).await;
    if result.ok && result.stdout.trim() == "ok" {
        performed(route.pid, Some(route))
    } else {
        ctx.log(
            "warn",
            &format!(
                "[browsers] restore target not found pid={} (ok={})",
                route.pid, result.ok
            ),
        );
        PerformResponse::fail("restore target not found")
    }
}

async fn perform_action(ctx: &Context, action: &ActionRequest) -> PerformResponse {
    let Some(pid) = action.context.pid else {
        return PerformResponse::unhandled();
    };
    let Some(browser) = action.context.bundle_id.as_deref().and_then(browser_for) else {
        return PerformResponse::unhandled();
    };
    let dialect = match browser.engine {
        Engine::Gecko => return firefox::perform_action(ctx, pid, action).await,
        Engine::AppleScript(dialect) => dialect,
    };
    let app = browser.app_name;
    let script = match action.name.as_str() {
        "tab_select" => match action.index().filter(|n| *n > 0) {
            Some(index) => dialect.tab_select_script(app, index),
            None => return PerformResponse::unhandled(),
        },
        "tab_new" => dialect.tab_new_script(app),
        "tab_close" => dialect.tab_close_script(app),
        // Unhandled for Chromium: the host then sends the manifest's chord.
        "tab_move_next" | "tab_move_previous" => {
            match dialect.tab_move_script(app, action.name == "tab_move_next") {
                Some(script) => script,
                None => return PerformResponse::unhandled(),
            }
        }
        _ => return PerformResponse::unhandled(),
    };
    let result = run_osascript(ctx, &script, ACTION_TIMEOUT).await;
    // The engine table gates this claim either way: an OK script is
    // `performed`, a non-OK is `failed` so the host doesn't fall back to a
    // ⌘<digit> keystroke that switches the wrong tab.
    if result.ok && result.stdout.trim() == "ok" {
        PerformResponse::ok().target_pid(pid)
    } else {
        PerformResponse::fail(format!("{} did not confirm", action.name))
    }
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

fn main() {
    run(Browsers);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::candidate_metadata::NAVIGATION_URL;
    use flash_plugin::ActionContext;

    #[test]
    fn engine_table_distinguishes_browser_editions() {
        let source = |bundle_id| browser_for(bundle_id).map(|browser| browser.source);
        assert_eq!(source("com.google.Chrome"), Some("chrome.tabs"));
        assert_eq!(source("com.brave.Browser"), Some("brave.tabs"));
        assert_eq!(source("com.microsoft.edgemac"), Some("edge.tabs"));
        assert_eq!(
            source("com.apple.SafariTechnologyPreview"),
            Some("safari.tabs")
        );
        for firefox in [
            "org.mozilla.firefox",
            "org.mozilla.firefoxdeveloperedition",
            "org.mozilla.nightly",
        ] {
            assert_eq!(source(firefox), Some("firefox.tabs"), "{firefox}");
            assert!(matches!(
                browser_for(firefox).unwrap().engine,
                Engine::Gecko
            ));
        }
        assert!(matches!(
            browser_for("com.apple.Safari").unwrap().engine,
            Engine::AppleScript(_)
        ));
        assert_eq!(source("org.mozilla.thunderbird"), None);
    }

    #[test]
    fn running_editions_keep_host_order_and_skip_invalid_pids() {
        let app = |bundle_id: &str, pid, name: &str| RunningApplication {
            bundle_id: bundle_id.into(),
            pid,
            localized_name: name.into(),
        };
        let running = running_browsers(&[
            app("org.mozilla.firefoxdeveloperedition", 11, ""),
            app("com.apple.Finder", 12, "Finder"),
            app("com.google.Chrome", 13, "Chrome FR"),
            app("org.mozilla.firefox", 0, "Firefox"),
        ]);
        assert_eq!(
            running
                .iter()
                .map(|app| (app.browser.bundle_id, app.label.as_str(), app.pid))
                .collect::<Vec<_>>(),
            [
                (
                    "org.mozilla.firefoxdeveloperedition",
                    "Firefox Developer Edition",
                    11
                ),
                ("com.google.Chrome", "Chrome FR", 13),
            ]
        );
    }

    #[test]
    fn gmail_urls_gain_search_aliases_and_other_urls_do_not() {
        assert_eq!(
            url_aliases("https://mail.google.com/mail/u/0/"),
            Some("gmail gmail.com")
        );
        assert_eq!(url_aliases("https://example.com/"), None);
    }

    #[test]
    fn every_tab_row_carries_a_browser_route() {
        let chrome = browser_for("com.google.Chrome").unwrap();
        let payload = TabPayload {
            bundle_id: chrome.bundle_id.into(),
            app_name: "Google Chrome".into(),
            url: "https://example.com/page".into(),
            strip: None,
        };
        let row = tab_candidate(
            chrome,
            42,
            "Page",
            "https://example.com/page",
            true,
            &payload,
        );
        let route = TabRoute::parse(row.meta(NAVIGATION_URL).unwrap()).unwrap();
        assert_eq!(route.pid, 42);
        assert_eq!(
            route.target,
            TabTarget::Url("https://example.com/page".into())
        );
        assert_eq!(row.payload_as::<TabPayload>().unwrap().strip, None);

        let firefox = browser_for("org.mozilla.firefox").unwrap();
        let untitled = tab_candidate(firefox, 7, "Docs", "", false, &TabPayload::default());
        assert_eq!(untitled.source, "firefox.tabs");
        assert_eq!(
            TabRoute::parse(untitled.meta(NAVIGATION_URL).unwrap())
                .unwrap()
                .target,
            TabTarget::Title("Docs".into())
        );
    }

    #[tokio::test]
    async fn firefox_leaves_tab_creation_closing_and_moves_to_its_chords() {
        let harness = flash_plugin::testing::Harness::new("browsers");
        let ctx = harness.context();
        for name in [
            "tab_new",
            "tab_close",
            "tab_move_next",
            "tab_move_previous",
            "tab_select",
        ] {
            let action = ActionRequest {
                name: name.into(),
                context: ActionContext {
                    bundle_id: Some("org.mozilla.firefox".into()),
                    pid: Some(4242),
                    front_window_frame: None,
                },
                // No index: even tab_select has nothing to claim.
                args: Default::default(),
            };
            assert!(perform_action(&ctx, &action).await.is_unhandled(), "{name}");
        }
    }

    #[test]
    fn manifest_scopes_exactly_the_engine_table() {
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../manifest.json")).unwrap();
        let strings = |values: &serde_json::Value| -> Vec<String> {
            values
                .as_array()
                .unwrap()
                .iter()
                .map(|value| value.as_str().unwrap().to_string())
                .collect()
        };
        let table_bundle_ids: Vec<String> =
            BROWSERS.iter().map(|b| b.bundle_id.to_string()).collect();
        assert_eq!(strings(&manifest["only_bundle_ids"]), table_bundle_ids);
        let mut table_sources: Vec<String> =
            BROWSERS.iter().map(|b| b.source.to_string()).collect();
        table_sources.dedup();
        let sources: Vec<String> = manifest["sources"]
            .as_array()
            .unwrap()
            .iter()
            .map(|source| source["name"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(sources, table_sources);
        // Firefox needs the AX broker and key posting; every row's route
        // scheme is declared so movement history dispatches it here.
        assert_eq!(
            strings(&manifest["capabilities"]),
            ["accessibility", "app_control"]
        );
        assert_eq!(strings(&manifest["navigation"]), ["flash-browser"]);
    }
}
