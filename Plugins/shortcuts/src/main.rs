use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant, SystemTime};

use flash_plugin::{
    Candidate, CommandRequest, Context, Event, PerformResponse, RefreshGate, applescript_quote,
    run, run_osascript,
};

const SOURCE_ENTRIES: &str = "shortcuts.entries";
const SHORTCUTS_BUNDLE_ID: &str = "com.apple.shortcuts";
/// Nothing polls. Opening the flashlight, leaving the Shortcuts app and a
/// configuration change relist the shortcuts — but listing launches the
/// faceless Shortcuts Events service, so a trigger first compares the
/// Shortcuts database's size and modification time with the last listing's
/// and skips an unchanged one. When the database cannot be read, a trigger
/// relists once the listing is this old instead.
const FALLBACK_TTL: Duration = Duration::from_secs(300);
/// The Shortcuts library and its write-ahead log, under `$HOME`.
const DATABASE_FILES: [&str; 2] = [
    "Library/Shortcuts/Shortcuts.sqlite",
    "Library/Shortcuts/Shortcuts.sqlite-wal",
];
const SLOW_REFRESH_MS: u128 = 1_000;
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);
static LAST_PUBLISHED: LazyLock<Mutex<Option<Vec<String>>>> = LazyLock::new(|| Mutex::new(None));
static LAST_LISTED: Mutex<Option<Listed>> = Mutex::new(None);
static FOCUSED: Mutex<Option<String>> = Mutex::new(None);

/// Each database file's length and modification time; `None` when unreadable.
type Stamp = [Option<(u64, SystemTime)>; DATABASE_FILES.len()];

/// A successful listing: when it began and the database it read.
#[derive(Clone, Copy)]
struct Listed {
    at: Instant,
    stamp: Stamp,
}

async fn database_stamp() -> Stamp {
    let mut stamp: Stamp = [None; DATABASE_FILES.len()];
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return stamp;
    };
    for (slot, file) in stamp.iter_mut().zip(DATABASE_FILES) {
        *slot = tokio::fs::metadata(home.join(file))
            .await
            .ok()
            .and_then(|metadata| Some((metadata.len(), metadata.modified().ok()?)));
    }
    stamp
}

/// Whether a trigger should relist, given the last listing and the database
/// as it stands at `now`.
fn refresh_due(last: Option<&Listed>, stamp: &Stamp, now: Instant) -> bool {
    let Some(last) = last else {
        return true;
    };
    if stamp.iter().any(Option::is_some) {
        last.stamp != *stamp
    } else {
        now.saturating_duration_since(last.at) >= FALLBACK_TTL
    }
}

/// Whether `event` should relist: the flashlight opening, or focus leaving
/// the Shortcuts app. Tracks the focused app in `focused`.
fn triggers(focused: &mut Option<String>, event: &Event) -> bool {
    match event.name.as_str() {
        "core:session.opened" => true,
        "core:focus.changed" => {
            let previous = std::mem::replace(focused, event.bundle_id.clone());
            previous.as_deref() == Some(SHORTCUTS_BUNDLE_ID) && *focused != previous
        }
        _ => false,
    }
}

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
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if event.name == "core:config.changed" {
            refresh_candidates(&ctx).await;
            return;
        }
        if triggers(
            &mut FOCUSED.lock().unwrap_or_else(|e| e.into_inner()),
            &event,
        ) {
            // Detached, so a listing never holds back the focus events
            // behind it, and skipped while one is already in flight.
            tokio::spawn(async move {
                REFRESH_GATE
                    .try_run(&ctx, |ctx, _running| async move {
                        let stamp = database_stamp().await;
                        let last = *LAST_LISTED.lock().unwrap_or_else(|e| e.into_inner());
                        if refresh_due(last.as_ref(), &stamp, Instant::now()) {
                            list(&ctx, stamp).await;
                        }
                    })
                    .await;
            });
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
            let stamp = database_stamp().await;
            list(&ctx, stamp).await
        })
        .await
}

/// List every shortcut and publish the rows when they changed; `stamp` is
/// the database this listing reads, recorded on success. Run under the gate.
async fn list(ctx: &Context, stamp: Stamp) -> bool {
    let started_at = Instant::now();
    let result = run_osascript(ctx, LIST_SCRIPT, Duration::from_secs(30)).await;
    if !result.ok {
        ctx.log(
            "warn",
            &format!("[shortcuts] list failed: {}", result.stderr.trim()),
        );
        log_refresh(ctx, "failed", 0, started_at);
        return false;
    }
    *LAST_LISTED.lock().unwrap_or_else(|e| e.into_inner()) = Some(Listed {
        at: started_at,
        stamp,
    });

    let names = names_from_output(&result.stdout);
    if replace_if_changed(&mut last_published(), &names) {
        ctx.publish(candidates_from_names(&names));
    }
    log_refresh(
        ctx,
        if names.is_empty() { "empty" } else { "ok" },
        names.len(),
        started_at,
    );
    true
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

    /// Nothing polls: a trigger relists only when the Shortcuts database
    /// changed since the last listing, or — when it cannot be read — once
    /// the listing is `FALLBACK_TTL` old.
    #[test]
    fn an_unchanged_database_skips_the_listing() {
        let now = Instant::now();
        let at = SystemTime::UNIX_EPOCH + Duration::from_secs(100);
        let stamp: Stamp = [Some((10, at)), Some((20, at))];
        assert!(refresh_due(None, &stamp, now), "never listed");
        let listed = Listed { at: now, stamp };
        assert!(
            !refresh_due(Some(&listed), &stamp, now + 2 * FALLBACK_TTL),
            "unchanged, however old"
        );
        let changed: Stamp = [Some((10, at)), Some((24, at))];
        assert!(refresh_due(Some(&listed), &changed, now));

        let unknown: Stamp = [None, None];
        let listed = Listed {
            at: now,
            stamp: unknown,
        };
        assert!(!refresh_due(
            Some(&listed),
            &unknown,
            now + Duration::from_secs(5)
        ));
        assert!(refresh_due(Some(&listed), &unknown, now + FALLBACK_TTL));
    }

    #[test]
    fn opening_the_flashlight_or_leaving_shortcuts_triggers() {
        let mut focused = None;
        let event = |name: &str, bundle_id: Option<&str>| Event {
            name: name.into(),
            bundle_id: bundle_id.map(Into::into),
            ..Event::default()
        };
        assert!(triggers(&mut focused, &event("core:session.opened", None)));
        assert!(!triggers(
            &mut focused,
            &event("core:focus.changed", Some(SHORTCUTS_BUNDLE_ID))
        ));
        assert!(triggers(
            &mut focused,
            &event("core:focus.changed", Some("com.apple.Terminal"))
        ));
        assert!(!triggers(
            &mut focused,
            &event("core:focus.changed", Some("com.apple.Mail"))
        ));
    }

    #[test]
    fn list_script_targets_the_faceless_shortcuts_events_service() {
        assert!(LIST_SCRIPT.contains("tell application \"Shortcuts Events\""));
        assert!(!LIST_SCRIPT.contains("tell application \"Shortcuts\""));
    }
}
