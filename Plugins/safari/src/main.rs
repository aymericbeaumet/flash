use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use flash_plugin::{
    applescript_quote, run, run_osascript, ActionRequest, Candidate, Context, Event,
    PerformResponse, RefreshGate, RunningApplication,
};
use serde::{Deserialize, Serialize};

const SOURCE_TABS: &str = "safari.tabs";
const POLL_INTERVAL: Duration = Duration::from_secs(2);
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
/// Last-published rows, kept so a partial cycle (one edition's AppleScript
/// failed) can re-publish that edition's previous tabs — `publish` is a full
/// replacement, so dropped rows would vanish from the host store.
static LAST_ROWS: Mutex<Vec<Candidate>> = Mutex::new(Vec::new());
const SAFARI_BUNDLES: &[&str] = &["com.apple.Safari", "com.apple.SafariTechnologyPreview"];

/// Round-tripped through the host so on_resolve can re-match the tab
/// even after a fresh snapshot has shifted indices.
#[derive(Serialize, Deserialize)]
struct TabPayload {
    bundle_id: String,
    app_name: String,
    url: String,
}

struct Safari;

flash_plugin::plugin!(Safari);

impl FlashPlugin for Safari {
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
            | "core:apps.launched"
            | "core:apps.terminated"
            | "core:focus.changed"
            | "core:window.focus.changed" => {
                refresh_locations(&ctx).await;
            }
            _ => {}
        }
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        resolve(&ctx, &row).await
    }

    async fn on_action(&self, ctx: Context, action: ActionRequest) -> PerformResponse {
        perform_action(&ctx, &action).await
    }
}

fn safari_apps(running: &[RunningApplication]) -> Vec<(String, String, i64)> {
    running
        .iter()
        .filter(|app| SAFARI_BUNDLES.contains(&app.bundle_id.as_str()))
        .map(|app| (app.bundle_id.clone(), app.localized_name.clone(), app.pid))
        .collect()
}

fn list_script(app_name: &str) -> String {
    format!(
        r#"
set out to ""
tell application {app}
  repeat with w in windows
    repeat with t in tabs of w
      try
        set isCurrent to "0"
        try
          if ((index of w as integer) is 1) and (t is current tab of w) then set isCurrent to "1"
        end try
        set out to out & (name of t as text) & tab & (URL of t as text) & tab & isCurrent & linefeed
      end try
    end repeat
  end repeat
end tell
return out
"#,
        app = applescript_quote(app_name)
    )
}

async fn refresh_locations(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, running| async move {
            refresh_locations_for_apps(&ctx, safari_apps(&running)).await
        })
        .await
}

async fn refresh_locations_for_apps(ctx: &Context, apps: Vec<(String, String, i64)>) -> bool {
    let started_at = Instant::now();
    // A complete running-app snapshot with no Safari process is authoritative;
    // clear dead tabs.
    if apps.is_empty() {
        publish_rows(ctx, Vec::new());
        log_refresh(ctx, "empty", 0, started_at);
        return true;
    }
    let mut handles = Vec::with_capacity(apps.len());
    for (bundle_id, app_name, pid) in apps {
        let ctx = ctx.clone();
        handles.push((
            pid,
            tokio::spawn(async move {
                let label = if app_name.is_empty() {
                    "Safari".to_string()
                } else {
                    app_name
                };
                let result =
                    run_osascript(&ctx, &list_script(&label), Duration::from_secs(10)).await;
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
                        bundle_id: bundle_id.clone(),
                        app_name: label.clone(),
                        url: url.to_string(),
                    };
                    let mut candidate = Candidate::new(SOURCE_TABS, display)
                        .kind("browser_tab")
                        .location()
                        .subtitle("browser tab")
                        .bundle_id(&bundle_id)
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
    // Preserve only editions whose AppleScript request failed. A successful
    // empty reply is an authoritative zero-tab snapshot, and apps absent from
    // the current host snapshot are removed.
    if !failed_pids.is_empty() {
        candidates.extend(last_rows().into_iter().filter(|candidate| {
            candidate
                .pid_value()
                .is_some_and(|pid| failed_pids.contains(&pid))
        }));
    }
    if successful_apps == 0 {
        // Publish nothing: the host keeps its last-good catalog.
        log_refresh(ctx, "failed", candidates.len(), started_at);
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
    publish_rows(ctx, candidates);
    log_refresh(ctx, outcome, count, started_at);
    true
}

fn publish_rows(ctx: &Context, rows: Vec<Candidate>) {
    if let Ok(mut last) = LAST_ROWS.lock() {
        *last = rows.clone();
    }
    ctx.publish(rows);
}

fn last_rows() -> Vec<Candidate> {
    LAST_ROWS
        .lock()
        .map(|rows| rows.clone())
        .unwrap_or_default()
}

fn log_refresh(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    let elapsed_ms = started_at.elapsed().as_millis();
    ctx.log(
        if elapsed_ms >= 1_000 { "warn" } else { "debug" },
        &format!(
            "[safari] refresh outcome={} count={} elapsed_ms={}",
            outcome, count, elapsed_ms
        ),
    );
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log(
        "warn",
        "[safari] initial warm catalog degraded outcome=unpublished_failure candidates=0 retry=immediate_background",
    );
}

fn start_refresh_poll(ctx: &Context) {
    drop(ctx.interval(POLL_INTERVAL, |ctx| async move {
        refresh_locations(&ctx).await;
    }));
}

async fn resolve(ctx: &Context, row: &Candidate) -> PerformResponse {
    let Some(pid) = row.pid_value() else {
        return PerformResponse::unhandled();
    };
    let payload = row.payload_as::<TabPayload>();
    let url = payload
        .as_ref()
        .map(|p| p.url.clone())
        .or_else(|| row.url_value().map(str::to_string))
        .unwrap_or_default();
    let app_name = payload
        .as_ref()
        .map(|p| p.app_name.clone())
        .unwrap_or_else(|| "Safari".to_string());
    ctx.activate(pid).await;
    if url.is_empty() {
        return PerformResponse::ok().target_pid(pid);
    }
    let script = format!(
        r#"
tell application {app}
  activate
  set targetURL to {target}
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (URL of t as text) is targetURL then
          set current tab of w to t
          set index of w to 1
          return "ok"
        end if
      end try
    end repeat
  end repeat
end tell
return "missing"
"#,
        app = applescript_quote(&app_name),
        target = applescript_quote(&url)
    );
    let result = run_osascript(ctx, &script, Duration::from_secs(10)).await;
    if !result.ok || result.stdout.trim() != "ok" {
        ctx.log(
            "warn",
            &format!(
                "[safari] tab-select did not confirm (ok={}, out={:?})",
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
    let bundle = action.context.bundle_id.clone().unwrap_or_default();
    if !SAFARI_BUNDLES.contains(&bundle.as_str()) {
        return PerformResponse::unhandled();
    }
    let app_name = canonical_app_name(&bundle).to_string();
    match action.name.as_str() {
        "tab_select" => {
            let Some(index) = action.index().filter(|n| *n > 0) else {
                return PerformResponse::unhandled();
            };
            // Safari's AppleScript uses `set current tab of w to tab N of w`
            // rather than Chromium's `set active tab index`. The walk-windows
            // pattern accumulates tabs across all windows so `tab_select 5`
            // can land on the second window's first tab if window 1 only had
            // four tabs.
            let script = format!(
                r#"
tell application {app}
  activate
  set tabIndex to {idx}
  repeat with w in windows
    if (count of tabs of w) >= tabIndex then
      set current tab of w to tab tabIndex of w
      set index of w to 1
      return "ok"
    end if
    set tabIndex to tabIndex - (count of tabs of w)
  end repeat
end tell
return "missing"
"#,
                app = applescript_quote(&app_name),
                idx = index
            );
            let result = run_osascript(ctx, &script, Duration::from_secs(5)).await;
            if result.ok && result.stdout.trim() == "ok" {
                PerformResponse::ok().target_pid(pid)
            } else {
                PerformResponse::fail("tab_select did not confirm")
            }
        }
        "tab_new" => {
            let script = format!(
                r#"
tell application {app}
  activate
  if (count of windows) is 0 then
    make new document
  else
    tell front window
      set current tab to (make new tab)
    end tell
  end if
  return "ok"
end tell
"#,
                app = applescript_quote(&app_name)
            );
            let result = run_osascript(ctx, &script, Duration::from_secs(5)).await;
            if result.ok && result.stdout.trim() == "ok" {
                PerformResponse::ok().target_pid(pid)
            } else {
                PerformResponse::fail("tab_new did not confirm")
            }
        }
        "tab_close" => {
            // Closing the last tab via `close current tab` collapses to closing
            // the window — same as the user pressing ⌘W natively, which is what
            // we want: the gesture stays "close this thing in this context".
            let script = format!(
                r#"
tell application {app}
  if (count of windows) is 0 then return "missing"
  tell front window to close current tab
  return "ok"
end tell
"#,
                app = applescript_quote(&app_name)
            );
            let result = run_osascript(ctx, &script, Duration::from_secs(5)).await;
            if result.ok && result.stdout.trim() == "ok" {
                PerformResponse::ok().target_pid(pid)
            } else {
                PerformResponse::fail("tab_close did not confirm")
            }
        }
        _ => PerformResponse::unhandled(),
    }
}

fn canonical_app_name(bundle_id: &str) -> &'static str {
    match bundle_id {
        "com.apple.SafariTechnologyPreview" => "Safari Technology Preview",
        _ => "Safari",
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
    run(Safari);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gmail_urls_gain_search_aliases_and_other_urls_do_not() {
        assert_eq!(
            url_aliases("https://mail.google.com/mail/u/0/"),
            Some("gmail gmail.com")
        );
        assert_eq!(url_aliases("https://example.com/"), None);
    }
}
