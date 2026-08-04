use std::sync::LazyLock;
use std::time::{Duration, Instant};

use flash_plugin::{
    applescript_quote, run, run_osascript, Candidate, Context, Event, RefreshGate, ResolveResponse,
    RunningApplication, SourceActionRequest, SourceActionResponse,
};
use serde::{Deserialize, Serialize};
use serde_json::json;

const SOURCE_ID: &str = "plugin:chromium";
const POLL_INTERVAL: Duration = Duration::from_secs(2);
const STARTUP_REFRESH_BUDGET: Duration = Duration::from_secs(11);
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);

const CHROMIUM_BUNDLES: &[&str] = &[
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.google.Chrome.beta",
    "com.google.Chrome.dev",
    "org.chromium.Chromium",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.brave.Browser.nightly",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    "com.microsoft.edgemac.Dev",
    "com.microsoft.edgemac.Canary",
    "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "com.operasoftware.OperaNext",
    "com.operasoftware.OperaDeveloper",
];

/// Round-tripped through the host so resolve_candidate can re-match the tab
/// after an unrelated snapshot has run.
#[derive(Serialize, Deserialize)]
struct TabPayload {
    bundle_id: String,
    app_name: String,
    url: String,
}

struct Chromium;

flash_plugin::plugin!(Chromium);

impl FlashPlugin for Chromium {
    async fn on_start(&self, ctx: Context) {
        let initial_succeeded =
            match tokio::time::timeout(STARTUP_REFRESH_BUDGET, refresh_locations(&ctx)).await {
                Ok(succeeded) => succeeded,
                Err(_) => {
                    ctx.log(
                        "warn",
                        "[chromium] initial warm refresh timed out budget_ms=11000",
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

fn chromium_apps(running: &[RunningApplication]) -> Vec<(String, String, i64)> {
    running
        .iter()
        .filter(|app| CHROMIUM_BUNDLES.contains(&app.bundle_id.as_str()))
        .map(|app| (app.bundle_id.clone(), app.localized_name.clone(), app.pid))
        .collect()
}

/// Source label convention: `<vendor>.tabs`. The plugin namespaces a few
/// well-known bundles so `@chrome` / `@brave` etc. filter correctly; everything
/// else falls back to the localized app name (lowercased, spaces → dashes).
fn source_name(bundle_id: &str, app_name: &str) -> String {
    match bundle_id {
        "com.google.Chrome"
        | "com.google.Chrome.canary"
        | "com.google.Chrome.beta"
        | "com.google.Chrome.dev" => "chrome.tabs".to_string(),
        "org.chromium.Chromium" => "chromium.tabs".to_string(),
        "com.brave.Browser" | "com.brave.Browser.beta" | "com.brave.Browser.nightly" => {
            "brave.tabs".to_string()
        }
        "com.microsoft.edgemac"
        | "com.microsoft.edgemac.Beta"
        | "com.microsoft.edgemac.Dev"
        | "com.microsoft.edgemac.Canary" => "edge.tabs".to_string(),
        "company.thebrowser.Browser" => "arc.tabs".to_string(),
        "com.vivaldi.Vivaldi" => "vivaldi.tabs".to_string(),
        "com.operasoftware.Opera"
        | "com.operasoftware.OperaNext"
        | "com.operasoftware.OperaDeveloper" => "opera.tabs".to_string(),
        _ => {
            let mut out = app_name.to_lowercase();
            out = out.replace(' ', "-");
            if out.is_empty() {
                out = "chromium".to_string();
            }
            out.push_str(".tabs");
            out
        }
    }
}

fn list_script(app_name: &str) -> String {
    format!(
        r#"
set out to ""
tell application {app}
  repeat with w in windows
    set activeIndex to 0
    try
      set activeIndex to active tab index of w
    end try
    repeat with t in tabs of w
      try
        set isCurrent to "0"
        try
          if ((index of w as integer) is 1) and ((index of t as integer) is activeIndex) then set isCurrent to "1"
        end try
        set out to out & (title of t as text) & tab & (URL of t as text) & tab & isCurrent & linefeed
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
            refresh_locations_for_apps(&ctx, chromium_apps(&running)).await
        })
        .await
}

async fn refresh_locations_for_apps(ctx: &Context, apps: Vec<(String, String, i64)>) -> bool {
    let started_at = Instant::now();
    // A complete running-app snapshot with no matching browser is authoritative:
    // clear dead tab rows.
    if apps.is_empty() {
        ctx.set_locations(SOURCE_ID, Vec::new());
        log_refresh(ctx, "empty", 0, started_at);
        return true;
    }
    // Fetch each browser's tab list concurrently: each osascript is hundreds of
    // ms and the browsers are independent, so serializing made a refresh cost the
    // sum. Spawn per app, then join and dedup in app order (deterministic).
    let mut handles = Vec::with_capacity(apps.len());
    for (bundle_id, app_name, pid) in apps {
        let ctx = ctx.clone();
        handles.push((
            pid,
            tokio::spawn(async move {
                let app_label = if app_name.is_empty() {
                    "Browser".to_string()
                } else {
                    app_name
                };
                let source = source_name(&bundle_id, &app_label);
                let result =
                    run_osascript(&ctx, &list_script(&app_label), Duration::from_secs(10)).await;
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
                        app_name: app_label.clone(),
                        url: url.to_string(),
                    };
                    let mut candidate = Candidate::new(display)
                        .kind("browser_tab")
                        .location()
                        .source_id(SOURCE_ID)
                        .source(&source)
                        .subtitle("browser tab")
                        .bundle_id(&bundle_id)
                        .pid(pid)
                        .payload_json(&payload)
                        .current_location(current);
                    if !url.is_empty() {
                        candidate = candidate.url(url);
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
        candidates.extend(ctx.warm_locations().into_iter().filter(|candidate| {
            candidate
                .pid_value()
                .is_some_and(|pid| failed_pids.contains(&pid))
        }));
    }
    if successful_apps == 0 {
        let count = candidates.len();
        // The current running-app snapshot authoritatively prunes terminated
        // pids, while every still-running failed pid keeps its last-good rows.
        // On first process start there is no last-good key yet; on_start emits
        // the explicitly degraded baseline and retries immediately.
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
            "[chromium] refresh outcome={} count={} elapsed_ms={}",
            outcome, count, elapsed_ms
        ),
    );
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log(
        "warn",
        "[chromium] initial warm catalog degraded outcome=empty_without_last_good candidates=0 retry=immediate_background",
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
        .unwrap_or_default();
    activate_app(ctx, pid).await;
    if url.is_empty() || app_name.is_empty() {
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
          set active tab index of w to (index of t)
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
                "[chromium] tab-select did not confirm (ok={}, out={:?})",
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
    if !CHROMIUM_BUNDLES.contains(&bundle.as_str()) {
        return SourceActionResponse::unhandled();
    }
    let app_name = match app_name_for_pid(&action.context.bundle_id, pid) {
        Some(name) => name,
        None => return SourceActionResponse::unhandled(),
    };
    match action.name.as_str() {
        "tab_select" => {
            let Some(index) = action.index.filter(|n| *n > 0) else {
                return SourceActionResponse::unhandled();
            };
            let script = format!(
                r#"
tell application {app}
  activate
  set tabIndex to {idx}
  repeat with w in windows
    if (count of tabs of w) >= tabIndex then
      set active tab index of w to tabIndex
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
            // Chromium-family bundle gates this claim either way: an OK script
            // is `performed`, a non-OK is `failed` so the host doesn't fall
            // back to a ⌘<digit> keystroke that switches the wrong tab.
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
    make new window
  else
    tell front window to make new tab
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
            // Closing the last tab collapses to closing the window — same as
            // ⌘W natively. Gesture stays "close this thing in this context".
            let script = format!(
                r#"
tell application {app}
  if (count of windows) is 0 then return "missing"
  tell front window to close active tab
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

/// Best-effort app-name lookup for AppleScript `tell application "<name>"`.
/// The host passes bundle id in source-action context but not the localized
/// name; we fall back to a canonical name per bundle so AppleScript can still
/// reach the right app.
fn app_name_for_pid(bundle_id: &Option<String>, _pid: i64) -> Option<String> {
    let bundle = bundle_id.as_deref()?;
    Some(canonical_app_name(bundle).to_string())
}

fn canonical_app_name(bundle_id: &str) -> &'static str {
    match bundle_id {
        "com.google.Chrome" => "Google Chrome",
        "com.google.Chrome.canary" => "Google Chrome Canary",
        "com.google.Chrome.beta" => "Google Chrome Beta",
        "com.google.Chrome.dev" => "Google Chrome Dev",
        "org.chromium.Chromium" => "Chromium",
        "com.brave.Browser" => "Brave Browser",
        "com.brave.Browser.beta" => "Brave Browser Beta",
        "com.brave.Browser.nightly" => "Brave Browser Nightly",
        "com.microsoft.edgemac" => "Microsoft Edge",
        "com.microsoft.edgemac.Beta" => "Microsoft Edge Beta",
        "com.microsoft.edgemac.Dev" => "Microsoft Edge Dev",
        "com.microsoft.edgemac.Canary" => "Microsoft Edge Canary",
        "company.thebrowser.Browser" => "Arc",
        "com.vivaldi.Vivaldi" => "Vivaldi",
        "com.operasoftware.Opera" => "Opera",
        "com.operasoftware.OperaNext" => "Opera Next",
        "com.operasoftware.OperaDeveloper" => "Opera Developer",
        _ => "Chromium",
    }
}

async fn activate_app(ctx: &Context, pid: i64) -> bool {
    ctx.call_host("app.activate", json!({ "pid": pid }))
        .await
        .get("ok")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
}

fn main() {
    run(Chromium);
}

#[cfg(test)]
mod refresh_tests {
    use super::*;

    #[test]
    fn source_name_distinguishes_browser_editions() {
        assert_eq!(
            source_name("com.google.Chrome", "Google Chrome"),
            "chrome.tabs"
        );
        assert_eq!(
            source_name("com.brave.Browser", "Brave Browser"),
            "brave.tabs"
        );
        assert_eq!(
            source_name("com.microsoft.edgemac", "Microsoft Edge"),
            "edge.tabs"
        );
    }

    #[test]
    fn startup_refresh_budget_stays_below_host_initialize_timeout() {
        assert!(STARTUP_REFRESH_BUDGET < Duration::from_secs(15));
    }
}
