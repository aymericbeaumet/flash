use std::collections::{BTreeMap, HashSet};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use flash_plugin::{
    applescript_quote, run, run_osascript, Candidate, CommandRequest, Context, Event,
    PerformResponse, RefreshGate,
};

const SOURCE_ENTRIES: &str = "shortcuts.entries";
const SHORTCUTS_BUNDLE_ID: &str = "com.apple.shortcuts";
const POLL_SECONDS: u64 = 300;
const SLOW_REFRESH_MS: u128 = 1_000;
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
static LAST_PUBLISHED: LazyLock<Mutex<Option<Vec<String>>>> = LazyLock::new(|| Mutex::new(None));

const LIST_SCRIPT: &str = r#"
tell application "Shortcuts Events"
  set output to name of every shortcut
end tell
set AppleScript's text item delimiters to linefeed
return output as text
"#;

fn run_script(shortcut_name: &str) -> String {
    format!(
        r#"
tell application "Shortcuts Events"
  run shortcut named {}
end tell
"#,
        applescript_quote(shortcut_name)
    )
}

struct Shortcuts;

flash_plugin::plugin!(Shortcuts);

impl FlashPlugin for Shortcuts {
    async fn on_start(&self, ctx: Context) {
        // Shortcuts Events is faceless and may be launched by osascript, so it
        // cannot be gated by the host's regular-application snapshot.
        if !refresh_candidates(&ctx).await {
            log_degraded_initial(&ctx);
            let retry_ctx = ctx.clone();
            tokio::spawn(async move {
                refresh_candidates(&retry_ctx).await;
            });
        }
        drop(
            ctx.interval(Duration::from_secs(POLL_SECONDS), |ctx| async move {
                refresh_candidates(&ctx).await;
            }),
        );
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if event.name == "core:config.changed" {
            refresh_candidates(&ctx).await;
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        invoke(&ctx, &command).await
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        resolve(&ctx, &row).await
    }
}

async fn refresh_candidates(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, _running| async move {
            let started_at = Instant::now();
            let result = run_osascript(&ctx, LIST_SCRIPT, Duration::from_secs(30)).await;
            if !result.ok {
                ctx.log(
                    "warn",
                    &format!("[shortcuts] list failed: {}", result.stderr.trim()),
                );
                log_refresh(&ctx, "failed", 0, started_at);
                return false;
            }

            let names = names_from_output(&result.stdout);
            if replace_if_changed(&mut last_published(), &names) {
                ctx.publish(candidates_from_names(&names));
            }
            log_refresh(
                &ctx,
                if names.is_empty() { "empty" } else { "ok" },
                names.len(),
                started_at,
            );
            true
        })
        .await
}

fn last_published() -> std::sync::MutexGuard<'static, Option<Vec<String>>> {
    LAST_PUBLISHED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn replace_if_changed(last: &mut Option<Vec<String>>, next: &[String]) -> bool {
    if last.as_deref() == Some(next) {
        return false;
    }
    *last = Some(next.to_vec());
    true
}

fn names_from_output(output: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut seen = HashSet::new();
    for line in output.lines() {
        let name = line.trim();
        if !name.is_empty() && seen.insert(name.to_string()) {
            names.push(name.to_string());
        }
    }
    names
}

fn candidates_from_names(names: &[String]) -> Vec<Candidate> {
    names
        .iter()
        .map(|name| {
            Candidate::new(SOURCE_ENTRIES, name)
                .kind("shortcut")
                .subtitle("Shortcut")
                .payload(name)
        })
        .collect()
}

fn log_refresh(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    let elapsed_ms = started_at.elapsed().as_millis();
    let fields = BTreeMap::from([
        ("outcome".to_string(), outcome.to_string()),
        ("rows".to_string(), count.to_string()),
        ("elapsed_ms".to_string(), elapsed_ms.to_string()),
    ]);
    ctx.log_fields("debug", "[shortcuts] refresh", fields.clone());
    if elapsed_ms >= SLOW_REFRESH_MS {
        ctx.log_fields("warn", "[shortcuts] refresh slow", fields);
    }
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[shortcuts] initial catalog degraded",
        BTreeMap::from([
            ("outcome".to_string(), "unpublished_failure".to_string()),
            ("rows".to_string(), "0".to_string()),
            ("retry".to_string(), "immediate_background".to_string()),
        ]),
    );
}

async fn resolve(ctx: &Context, row: &Candidate) -> PerformResponse {
    let Some(name) = row.payload_str().filter(|name| !name.is_empty()) else {
        return PerformResponse::fail("row payload carries no shortcut name");
    };
    let result = run_osascript(ctx, &run_script(name), Duration::from_secs(30)).await;
    if result.ok {
        PerformResponse::ok()
    } else {
        PerformResponse::fail("shortcut run failed")
    }
}

async fn invoke(ctx: &Context, command: &CommandRequest) -> PerformResponse {
    match command.subcommand.as_str() {
        "open" => {
            if ctx.open_app(SHORTCUTS_BUNDLE_ID).await {
                PerformResponse::ok()
            } else {
                PerformResponse::fail("host.open failed")
            }
        }
        "refresh" => {
            if refresh_candidates(ctx).await {
                PerformResponse::ok().message("shortcuts refreshed")
            } else {
                PerformResponse::fail("shortcuts refresh failed")
            }
        }
        other => PerformResponse::fail(format!("unknown subcommand: {other}")),
    }
}

fn main() {
    run(Shortcuts);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn listing_trims_deduplicates_and_preserves_order() {
        assert_eq!(
            names_from_output("Morning\n Work \nMorning\n\nEvening\n"),
            ["Morning", "Work", "Evening"]
        );
    }

    #[test]
    fn candidates_preserve_wire_metadata_and_payload() {
        let rows = candidates_from_names(&["Build & Test".to_string()]);
        let row = &rows[0];
        assert_eq!(row.source, SOURCE_ENTRIES);
        assert_eq!(row.title, "Build & Test");
        assert_eq!(row.meta("kind"), Some("shortcut"));
        assert_eq!(row.meta("subtitle"), Some("Shortcut"));
        assert_eq!(row.payload_str(), Some("Build & Test"));
    }

    #[test]
    fn change_gate_publishes_initial_and_authoritative_empty_once() {
        let mut last = None;
        let first = vec!["Morning".to_string()];
        assert!(replace_if_changed(&mut last, &first));
        assert!(!replace_if_changed(&mut last, &first));
        assert!(replace_if_changed(&mut last, &[]));
        assert!(!replace_if_changed(&mut last, &[]));
    }

    #[test]
    fn run_script_quotes_the_shortcut_name() {
        let script = run_script("Ship \"release\" \\ archive");
        assert!(script.contains("run shortcut named \"Ship \\\"release\\\" \\\\ archive\""));
    }

    #[test]
    fn list_script_targets_the_faceless_shortcuts_events_service() {
        assert!(LIST_SCRIPT.contains("tell application \"Shortcuts Events\""));
        assert!(!LIST_SCRIPT.contains("tell application \"Shortcuts\""));
    }
}
