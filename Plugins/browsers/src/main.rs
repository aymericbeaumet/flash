use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use flash_plugin::{
    applescript_quote, run, run_osascript, ActionRequest, AppWatch, Candidate, Context, Event,
    PerformResponse, RefreshGate, RunningApplication,
};
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
/// A refresh scripts every running browser, so only events touching one
/// schedule it: focus changes elsewhere cannot change a tab list.
static BROWSER_EVENTS: AppWatch = AppWatch::new();
static REFRESH_LOG_STATE: LazyLock<Mutex<RefreshLogState>> =
    LazyLock::new(|| Mutex::new(RefreshLogState::default()));
/// Last-published rows, kept so a partial cycle (one browser's AppleScript
/// failed) can re-publish that browser's previous tabs — `publish` is a full
/// replacement, so dropped rows would vanish from the host store.
static LAST_ROWS: Mutex<Option<Vec<Candidate>>> = Mutex::new(None);

/// The AppleScript phrases that differ between the two tab-scripting
/// dialects; every script skeleton below is shared.
struct Dialect {
    /// Expression yielding the index of window `w`'s current tab.
    active_index: &'static str,
    /// Tab property carrying the page title.
    title: &'static str,
    /// Make tab `t` the current tab of window `w`.
    select_tab: &'static str,
    /// Make tab number `tabIndex` the current tab of window `w`.
    select_nth: &'static str,
    /// Create a window when none exists.
    new_window: &'static str,
    /// Create and focus a tab, inside `tell front window`.
    new_tab: &'static str,
    /// The front window's current tab, as a `close` target.
    current_tab: &'static str,
}

const CHROMIUM: Dialect = Dialect {
    active_index: "active tab index of w",
    title: "title",
    select_tab: "set active tab index of w to (index of t)",
    select_nth: "set active tab index of w to tabIndex",
    new_window: "make new window",
    new_tab: "make new tab",
    current_tab: "active tab",
};

const SAFARI: Dialect = Dialect {
    active_index: "index of current tab of w",
    title: "name",
    select_tab: "set current tab of w to t",
    select_nth: "set current tab of w to tab tabIndex of w",
    new_window: "make new document",
    new_tab: "set current tab to (make new tab)",
    current_tab: "current tab",
};

impl Dialect {
    fn list_script(&self, app: &str) -> String {
        format!(
            r#"
set out to ""
tell application {app}
  repeat with w in windows
    set activeIndex to 0
    try
      set activeIndex to {active_index}
    end try
    repeat with t in tabs of w
      try
        set isCurrent to "0"
        try
          if ((index of w as integer) is 1) and ((index of t as integer) is activeIndex) then set isCurrent to "1"
        end try
        set out to out & ({title} of t as text) & tab & (URL of t as text) & tab & isCurrent & linefeed
      end try
    end repeat
  end repeat
end tell
return out
"#,
            app = applescript_quote(app),
            active_index = self.active_index,
            title = self.title,
        )
    }

    fn select_script(&self, app: &str, url: &str) -> String {
        format!(
            r#"
tell application {app}
  activate
  set targetURL to {target}
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t as text) is targetURL then
          {select_tab}
          set index of w to 1
          return "ok"
        end if
      end try
    end repeat
  end repeat
end tell
return "missing"
"#,
            app = applescript_quote(app),
            target = applescript_quote(url),
            select_tab = self.select_tab,
        )
    }

    /// `tab_select` walks windows front to back so `tab_select 5` can land on
    /// the second window's first tab if window 1 only had four tabs.
    fn tab_select_script(&self, app: &str, index: i64) -> String {
        format!(
            r#"
tell application {app}
  activate
  set tabIndex to {index}
  repeat with w in windows
    if (count of tabs of w) >= tabIndex then
      {select_nth}
      set index of w to 1
      return "ok"
    end if
    set tabIndex to tabIndex - (count of tabs of w)
  end repeat
end tell
return "missing"
"#,
            app = applescript_quote(app),
            select_nth = self.select_nth,
        )
    }

    fn tab_new_script(&self, app: &str) -> String {
        format!(
            r#"
tell application {app}
  activate
  if (count of windows) is 0 then
    {new_window}
  else
    tell front window to {new_tab}
  end if
  return "ok"
end tell
"#,
            app = applescript_quote(app),
            new_window = self.new_window,
            new_tab = self.new_tab,
        )
    }

    /// Closing the last tab collapses to closing the window — same as ⌘W
    /// natively. The gesture stays "close this thing in this context".
    fn tab_close_script(&self, app: &str) -> String {
        format!(
            r#"
tell application {app}
  if (count of windows) is 0 then return "missing"
  tell front window to close {current_tab}
  return "ok"
end tell
"#,
            app = applescript_quote(app),
            current_tab = self.current_tab,
        )
    }
}

/// One scriptable browser edition: the canonical `tell application` name
/// (the host passes only the bundle id in action context), the `<vendor>.tabs`
/// source label its rows carry so `@chrome` / `@brave` etc. filter correctly,
/// and the dialect its scripts use.
struct Browser {
    bundle_id: &'static str,
    app_name: &'static str,
    source: &'static str,
    dialect: &'static Dialect,
}

const fn browser(
    bundle_id: &'static str,
    app_name: &'static str,
    source: &'static str,
    dialect: &'static Dialect,
) -> Browser {
    Browser {
        bundle_id,
        app_name,
        source,
        dialect,
    }
}

#[rustfmt::skip]
const BROWSERS: &[Browser] = &[
    browser("com.google.Chrome", "Google Chrome", "chrome.tabs", &CHROMIUM),
    browser("com.google.Chrome.canary", "Google Chrome Canary", "chrome.tabs", &CHROMIUM),
    browser("com.google.Chrome.beta", "Google Chrome Beta", "chrome.tabs", &CHROMIUM),
    browser("com.google.Chrome.dev", "Google Chrome Dev", "chrome.tabs", &CHROMIUM),
    browser("org.chromium.Chromium", "Chromium", "chromium.tabs", &CHROMIUM),
    browser("com.brave.Browser", "Brave Browser", "brave.tabs", &CHROMIUM),
    browser("com.brave.Browser.beta", "Brave Browser Beta", "brave.tabs", &CHROMIUM),
    browser("com.brave.Browser.nightly", "Brave Browser Nightly", "brave.tabs", &CHROMIUM),
    browser("com.microsoft.edgemac", "Microsoft Edge", "edge.tabs", &CHROMIUM),
    browser("com.microsoft.edgemac.Beta", "Microsoft Edge Beta", "edge.tabs", &CHROMIUM),
    browser("com.microsoft.edgemac.Dev", "Microsoft Edge Dev", "edge.tabs", &CHROMIUM),
    browser("com.microsoft.edgemac.Canary", "Microsoft Edge Canary", "edge.tabs", &CHROMIUM),
    browser("company.thebrowser.Browser", "Arc", "arc.tabs", &CHROMIUM),
    browser("com.vivaldi.Vivaldi", "Vivaldi", "vivaldi.tabs", &CHROMIUM),
    browser("com.operasoftware.Opera", "Opera", "opera.tabs", &CHROMIUM),
    browser("com.operasoftware.OperaNext", "Opera Next", "opera.tabs", &CHROMIUM),
    browser("com.operasoftware.OperaDeveloper", "Opera Developer", "opera.tabs", &CHROMIUM),
    browser("com.apple.Safari", "Safari", "safari.tabs", &SAFARI),
    browser("com.apple.SafariTechnologyPreview", "Safari Technology Preview", "safari.tabs", &SAFARI),
];

fn browser_for(bundle_id: &str) -> Option<&'static Browser> {
    BROWSERS
        .iter()
        .find(|browser| browser.bundle_id == bundle_id)
}

/// Round-tripped through the host so on_resolve can re-match the tab
/// after an unrelated snapshot has run.
#[derive(Serialize, Deserialize)]
struct TabPayload {
    bundle_id: String,
    app_name: String,
    url: String,
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

/// Running editions from the engine table with the AppleScript label to
/// address them by: the localized name, or the canonical one when empty.
fn scriptable_apps(running: &[RunningApplication]) -> Vec<(&'static Browser, String, i64)> {
    running
        .iter()
        .filter_map(|app| {
            let browser = browser_for(&app.bundle_id)?;
            let label = if app.localized_name.is_empty() {
                browser.app_name.to_string()
            } else {
                app.localized_name.clone()
            };
            Some((browser, label, app.pid))
        })
        .collect()
}

async fn refresh_locations(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, running| async move {
            refresh_locations_for_apps(&ctx, scriptable_apps(&running)).await
        })
        .await
}

async fn refresh_locations_for_apps(
    ctx: &Context,
    apps: Vec<(&'static Browser, String, i64)>,
) -> bool {
    let started_at = Instant::now();
    // A complete running-app snapshot with no matching browser is authoritative:
    // clear dead tab rows.
    if apps.is_empty() {
        let changed = publish_rows(ctx, Vec::new());
        log_refresh(ctx, "empty", 0, started_at, changed);
        return true;
    }
    // Fetch each browser's tab list concurrently: each osascript is hundreds of
    // ms and the browsers are independent, so serializing made a refresh cost the
    // sum. Spawn per app, then join and dedup in app order (deterministic).
    let mut handles = Vec::with_capacity(apps.len());
    for (browser, label, pid) in apps {
        let ctx = ctx.clone();
        handles.push((
            pid,
            tokio::spawn(async move {
                let result =
                    run_osascript(&ctx, &browser.dialect.list_script(&label), LIST_TIMEOUT).await;
                if !result.ok {
                    return None;
                }
                let mut rows = Vec::new();
                for line in result.stdout.lines() {
                    let mut parts = line.splitn(3, '\t');
                    let title = parts.next().unwrap_or("").trim();
                    let url = parts.next().unwrap_or("").trim();
                    let current = parts
                        .next()
                        .map(|value| value.trim() == "1")
                        .unwrap_or(false);
                    if title.is_empty() && url.is_empty() {
                        continue;
                    }
                    let key = format!("{pid}|{title}|{url}");
                    let display = if title.is_empty() {
                        url.to_string()
                    } else {
                        title.to_string()
                    };
                    let payload = TabPayload {
                        bundle_id: browser.bundle_id.to_string(),
                        app_name: label.clone(),
                        url: url.to_string(),
                    };
                    let mut candidate = Candidate::new(browser.source, display)
                        .kind("browser_tab")
                        .location()
                        .subtitle("browser tab")
                        .bundle_id(browser.bundle_id)
                        .pid(pid)
                        .payload_json(&payload)
                        .current_location(current);
                    if !url.is_empty() {
                        candidate = candidate.url(url);
                        if let Some(aliases) = url_aliases(url) {
                            candidate = candidate.aliases([aliases]);
                        }
                    }
                    rows.push((key, candidate));
                }
                // `Some([])` is a successful authoritative zero-tab result;
                // `None` above is the only transient-failure signal.
                Some(rows)
            }),
        ));
    }
    let mut candidates = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut failed_pids = std::collections::HashSet::new();
    let mut successful_apps = 0;
    // Await in input order so completion timing cannot reorder the catalog.
    for (pid, handle) in handles {
        match handle.await {
            Ok(Some(rows)) => {
                successful_apps += 1;
                for (key, candidate) in rows {
                    if seen.insert(key) {
                        candidates.push(candidate);
                    }
                }
            }
            Ok(None) | Err(_) => {
                failed_pids.insert(pid);
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
        log_refresh(ctx, "failed", candidates.len(), started_at, false);
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
    log_refresh(ctx, outcome, count, started_at, changed);
    true
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

fn log_refresh(ctx: &Context, outcome: &str, count: usize, started_at: Instant, changed: bool) {
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
            "[browsers] refresh outcome={} count={} elapsed_ms={}",
            outcome, count, elapsed_ms
        ),
    );
}

async fn resolve(ctx: &Context, row: &Candidate) -> PerformResponse {
    let Some(pid) = row.pid_value() else {
        return PerformResponse::unhandled();
    };
    ctx.activate(pid).await;
    let Some(tab) = row.payload_as::<TabPayload>() else {
        return PerformResponse::ok().target_pid(pid);
    };
    let Some(browser) = browser_for(&tab.bundle_id).filter(|_| !tab.url.is_empty()) else {
        return PerformResponse::ok().target_pid(pid);
    };
    let script = browser.dialect.select_script(&tab.app_name, &tab.url);
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
    PerformResponse::ok().target_pid(pid)
}

async fn perform_action(ctx: &Context, action: &ActionRequest) -> PerformResponse {
    let Some(pid) = action.context.pid else {
        return PerformResponse::unhandled();
    };
    let Some(browser) = action.context.bundle_id.as_deref().and_then(browser_for) else {
        return PerformResponse::unhandled();
    };
    let (dialect, app) = (browser.dialect, browser.app_name);
    let script = match action.name.as_str() {
        "tab_select" => match action.index().filter(|n| *n > 0) {
            Some(index) => dialect.tab_select_script(app, index),
            None => return PerformResponse::unhandled(),
        },
        "tab_new" => dialect.tab_new_script(app),
        "tab_close" => dialect.tab_close_script(app),
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
        assert_eq!(source("org.mozilla.firefox"), None);
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
    fn manifest_scopes_exactly_the_engine_table() {
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../manifest.json")).unwrap();
        let strings = |values: &serde_json::Value, key: &str| -> Vec<String> {
            values
                .as_array()
                .unwrap()
                .iter()
                .map(|value| value[key].as_str().unwrap().to_string())
                .collect()
        };
        let bundle_ids: Vec<String> = manifest["only_bundle_ids"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap().to_string())
            .collect();
        let table_bundle_ids: Vec<String> =
            BROWSERS.iter().map(|b| b.bundle_id.to_string()).collect();
        assert_eq!(bundle_ids, table_bundle_ids);
        let mut table_sources: Vec<String> =
            BROWSERS.iter().map(|b| b.source.to_string()).collect();
        table_sources.dedup();
        assert_eq!(strings(&manifest["sources"], "name"), table_sources);
    }
}
