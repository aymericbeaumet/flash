use std::process::Stdio;
use std::time::Duration;

use flash_plugin::{
    run, Candidate, Context, Event, ResolveResponse, RunningApplication, SourceActionRequest,
    SourceActionResponse,
};
use serde::{Deserialize, Serialize};
use serde_json::json;

const SOURCE_ID: &str = "plugin:chromium";

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
    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            "core:flash.started" | "core:apps.snapshot" => {
                let apps = chromium_apps(&event.running_applications);
                refresh_snapshot(&ctx, apps).await;
            }
            "core:apps.launched" | "core:apps.terminated" | "core:focus.changed" => {
                let apps = chromium_apps(&event.running_applications);
                if !apps.is_empty() {
                    refresh_snapshot(&ctx, apps).await;
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
    repeat with t in tabs of w
      try
        set out to out & (title of t as text) & tab & (URL of t as text) & linefeed
      end try
    end repeat
  end repeat
end tell
return out
"#,
        app = applescript_quote(app_name)
    )
}

async fn refresh_snapshot(ctx: &Context, apps: Vec<(String, String, i64)>) {
    let mut candidates = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for (bundle_id, app_name, pid) in &apps {
        let app_label = if app_name.is_empty() {
            "Browser".to_string()
        } else {
            app_name.clone()
        };
        let source = source_name(bundle_id, &app_label);
        let result = run_osascript(ctx, &list_script(&app_label), Duration::from_secs(10)).await;
        if !result.ok {
            ctx.log(
                "warn",
                &format!(
                    "[chromium] list failed bundle={} stderr={}",
                    bundle_id, result.stderr
                ),
            );
            continue;
        }
        for line in result.stdout.lines() {
            let mut parts = line.splitn(2, '\t');
            let title = parts.next().unwrap_or("").trim();
            let url = parts.next().unwrap_or("").trim();
            if title.is_empty() && url.is_empty() {
                continue;
            }
            let key = format!("{pid}|{title}|{url}");
            if !seen.insert(key) {
                continue;
            }
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
                .source_id(SOURCE_ID)
                .source(&source)
                .subtitle("browser tab")
                .bundle_id(bundle_id)
                .pid(*pid)
                .payload_json(&payload);
            if !url.is_empty() {
                candidate = candidate.url(url);
            }
            candidates.push(candidate);
        }
    }
    ctx.emit_snapshot(SOURCE_ID, candidates);
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
    let _ = run_osascript(ctx, &script, Duration::from_secs(10)).await;
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

#[derive(Default)]
struct CommandOutput {
    ok: bool,
    stdout: String,
    stderr: String,
    _status: i32,
}

async fn activate_app(ctx: &Context, pid: i64) -> bool {
    ctx.call_host("app.activate", json!({ "pid": pid }))
        .await
        .get("ok")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
}

async fn run_osascript(ctx: &Context, script: &str, timeout: Duration) -> CommandOutput {
    run_command(
        ctx,
        &[
            "/usr/bin/osascript".to_string(),
            "-e".to_string(),
            script.to_string(),
        ],
        timeout,
    )
    .await
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

fn applescript_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

fn main() {
    run(Chromium);
}
