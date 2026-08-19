use std::sync::LazyLock;
use std::time::{Duration, Instant};

use flash_plugin::{
    applescript_quote, run, run_osascript, Candidate, Context, Event, RefreshGate, ResolveResponse,
    RunningApplication, SourceActionRequest, SourceActionResponse,
};
use serde::{Deserialize, Serialize};
use serde_json::json;

const SOURCE_ID: &str = "plugin:safari";
const POLL_INTERVAL: Duration = Duration::from_secs(2);
const STARTUP_REFRESH_BUDGET: Duration = Duration::from_secs(11);
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
const SAFARI_BUNDLES: &[&str] = &["com.apple.Safari", "com.apple.SafariTechnologyPreview"];

/// Round-tripped through the host so resolve_candidate can re-match the tab
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
        let initial_succeeded =
            match tokio::time::timeout(STARTUP_REFRESH_BUDGET, refresh_locations(&ctx)).await {
                Ok(succeeded) => succeeded,
                Err(_) => {
                    ctx.log(
                        "warn",
                        "[safari] initial warm refresh timed out budget_ms=11000",
                    );
                    false
                }
            };
        if !initial_succeeded && !ctx.has_locations(SOURCE_ID) {
            log_degraded_initial(&ctx);
            ctx.set_locations(SOURCE_ID, Vec::new());
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
        ctx.set_locations(SOURCE_ID, Vec::new());
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
                    let mut candidate = Candidate::new(display)
                        .kind("browser_tab")
                        .location()
                        .source_id(SOURCE_ID)
                        .source("safari.tabs")
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
        candidates.extend(ctx.warm_locations().into_iter().filter(|candidate| {
            candidate
                .pid_value()
                .is_some_and(|pid| failed_pids.contains(&pid))
        }));
    }
    if successful_apps == 0 {
        let count = candidates.len();
        if ctx.has_locations(SOURCE_ID) {
            ctx.set_locations(SOURCE_ID, candidates);
        }
        log_refresh(ctx, "failed", count, started_at);
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
    ctx.set_locations(SOURCE_ID, candidates);
    log_refresh(ctx, outcome, count, started_at);
    true
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
        "[safari] initial warm catalog degraded outcome=empty_without_last_good candidates=0 retry=immediate_background",
    );
}

fn start_refresh_poll(ctx: &Context) {
    drop(ctx.interval(POLL_INTERVAL, |ctx| async move {
        refresh_locations(&ctx).await;
    }));
}

async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let Some(pid) = candidate.pid_value() else {
        return ResolveResponse::unresolved();
    };
    let payload = candidate.payload_as::<TabPayload>();
    let url = payload
        .as_ref()
        .map(|p| p.url.clone())
        .or_else(|| candidate.url_value().map(str::to_string))
        .unwrap_or_default();
    let app_name = payload
        .as_ref()
        .map(|p| p.app_name.clone())
        .unwrap_or_else(|| "Safari".to_string());
    activate_app(ctx, pid).await;
    if url.is_empty() {
        return ResolveResponse::resolved(Some(pid));
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
    ResolveResponse::resolved(Some(pid))
}

async fn perform_source_action(
    ctx: &Context,
    action: &SourceActionRequest,
) -> SourceActionResponse {
    let Some(pid) = action.context.pid else {
        return SourceActionResponse::unhandled();
    };
    let bundle = action.context.bundle_id.clone().unwrap_or_default();
    if !SAFARI_BUNDLES.contains(&bundle.as_str()) {
        return SourceActionResponse::unhandled();
    }
    let app_name = canonical_app_name(&bundle).to_string();
    match action.name.as_str() {
        "tab_select" => {
            let Some(index) = action.index.filter(|n| *n > 0) else {
                return SourceActionResponse::unhandled();
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
                SourceActionResponse::performed(Some(pid))
            } else {
                SourceActionResponse::failed(Some(pid))
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
                SourceActionResponse::performed(Some(pid))
            } else {
                SourceActionResponse::failed(Some(pid))
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
                SourceActionResponse::performed(Some(pid))
            } else {
                SourceActionResponse::failed(Some(pid))
            }
        }
        _ => SourceActionResponse::unhandled(),
    }
}

fn canonical_app_name(bundle_id: &str) -> &'static str {
    match bundle_id {
        "com.apple.SafariTechnologyPreview" => "Safari Technology Preview",
        _ => "Safari",
    }
}

async fn activate_app(ctx: &Context, pid: i64) -> bool {
    ctx.call_host("app.activate", json!({ "pid": pid }))
        .await
        .get("ok")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
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
mod refresh_tests {
    use super::*;

    #[test]
    fn startup_refresh_budget_stays_below_host_initialize_timeout() {
        assert!(STARTUP_REFRESH_BUDGET < Duration::from_secs(15));
    }
}
