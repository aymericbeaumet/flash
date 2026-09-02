use std::collections::{BTreeMap, HashSet};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use flash_plugin::{
    applescript_quote, run, run_osascript, Candidate, CommandRequest, Context, Event,
    PerformResponse, RefreshGate, RunningApplication,
};
use serde::{Deserialize, Serialize};

const SOURCE_TASKS: &str = "reminders.tasks";
const REMINDERS_BUNDLE_ID: &str = "com.apple.reminders";
const POLL_SECONDS: u64 = 60;
const SLOW_REFRESH_MS: u128 = 1_000;
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);

const LIST_SCRIPT: &str = r#"
if application "Reminders" is not running then return ""
tell application "Reminders"
  set output to {}
  repeat with l in lists
    try
      repeat with r in (reminders of l whose completed is false)
        set the end of output to ((id of r as text) & tab & (name of l as text) & tab & (name of r as text))
      end repeat
    end try
  end repeat
  set AppleScript's text item delimiters to linefeed
  return output as text
end tell
"#;

fn select_script(reminder_id: &str) -> String {
    format!(
        r#"
tell application "Reminders"
  activate
  try
    show reminder id {}
  end try
end tell
"#,
        applescript_quote(reminder_id)
    )
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
struct ReminderPayload {
    id: String,
    list: String,
    title: String,
}

struct Reminders;

flash_plugin::plugin!(Reminders);

impl FlashPlugin for Reminders {
    async fn on_start(&self, ctx: Context) {
        // Runs after initialize, so AppleScript never delays the handshake.
        // Transient failure emits nothing and leaves the host's last-good
        // catalog intact; retry once immediately, then on the normal cadence.
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
        let is_reminders = event.bundle_id.as_deref() == Some(REMINDERS_BUNDLE_ID);
        if event.name == "core:apps.terminated" && is_reminders {
            // Termination is authoritative and needs no AppleScript round trip.
            clear_candidates(&ctx).await;
        } else if (event.name == "core:apps.launched" && is_reminders)
            || event.name == "core:config.changed"
        {
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
        .run(ctx, |ctx, running| async move {
            if reminders_is_running(&running) {
                refresh_candidates_inner(&ctx).await
            } else {
                let started_at = Instant::now();
                ctx.publish(Vec::new());
                log_refresh(&ctx, "empty", 0, started_at);
                true
            }
        })
        .await
}

fn reminders_is_running(applications: &[RunningApplication]) -> bool {
    applications
        .iter()
        .any(|application| application.bundle_id == REMINDERS_BUNDLE_ID)
}

async fn refresh_candidates_inner(ctx: &Context) -> bool {
    let started_at = Instant::now();
    let result = run_osascript(ctx, LIST_SCRIPT, Duration::from_secs(30)).await;
    if !result.ok {
        ctx.log(
            "warn",
            &format!("[reminders] list failed: {}", result.stderr.trim()),
        );
        log_refresh(ctx, "failed", 0, started_at);
        return false;
    }

    let candidates = candidates_from_output(&result.stdout);
    let count = candidates.len();
    // A successful empty listing is authoritative. Only subprocess failure
    // skips publication and therefore preserves the host's last-good rows.
    ctx.publish(candidates);
    log_refresh(
        ctx,
        if count == 0 { "empty" } else { "ok" },
        count,
        started_at,
    );
    true
}

async fn clear_candidates(ctx: &Context) {
    REFRESH_GATE
        .run(ctx, |ctx, _running| async move {
            ctx.publish(Vec::new());
        })
        .await;
}

fn log_refresh(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    let elapsed_ms = started_at.elapsed().as_millis();
    let fields = BTreeMap::from([
        ("outcome".to_string(), outcome.to_string()),
        ("rows".to_string(), count.to_string()),
        ("elapsed_ms".to_string(), elapsed_ms.to_string()),
    ]);
    ctx.log_fields("debug", "[reminders] refresh", fields.clone());
    if elapsed_ms >= SLOW_REFRESH_MS {
        ctx.log_fields("warn", "[reminders] refresh slow", fields);
    }
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[reminders] initial catalog degraded",
        BTreeMap::from([
            ("outcome".to_string(), "unpublished_failure".to_string()),
            ("rows".to_string(), "0".to_string()),
            ("retry".to_string(), "immediate_background".to_string()),
        ]),
    );
}

fn candidates_from_output(output: &str) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    let mut seen = HashSet::new();
    for line in output.lines() {
        let parts: Vec<&str> = line.trim().splitn(3, '\t').collect();
        if parts.len() != 3 {
            continue;
        }
        let reminder_id = parts[0].trim();
        let list = parts[1].trim();
        let title = parts[2].trim();
        if reminder_id.is_empty() || title.is_empty() || !seen.insert(reminder_id.to_string()) {
            continue;
        }
        candidates.push(
            Candidate::new(SOURCE_TASKS, title)
                .kind("reminder")
                .subtitle(format!("Reminder — {list}"))
                .payload_json(&ReminderPayload {
                    id: reminder_id.to_string(),
                    list: list.to_string(),
                    title: title.to_string(),
                }),
        );
    }
    candidates
}

async fn resolve(ctx: &Context, row: &Candidate) -> PerformResponse {
    let Some(payload) = row
        .payload_as::<ReminderPayload>()
        .filter(|payload| !payload.id.is_empty())
    else {
        return PerformResponse::fail("row payload carries no reminder id");
    };
    let result = run_osascript(ctx, &select_script(&payload.id), Duration::from_secs(10)).await;
    if result.ok {
        PerformResponse::ok()
    } else {
        PerformResponse::fail("reminder selection failed")
    }
}

async fn invoke(ctx: &Context, command: &CommandRequest) -> PerformResponse {
    match command.subcommand.as_str() {
        "open" => {
            if ctx.open_app(REMINDERS_BUNDLE_ID).await {
                PerformResponse::ok()
            } else {
                PerformResponse::fail("host.open failed")
            }
        }
        "refresh" => {
            if refresh_candidates(ctx).await {
                PerformResponse::ok().message("reminders refreshed")
            } else {
                PerformResponse::fail("reminders refresh failed")
            }
        }
        other => PerformResponse::fail(format!("unknown subcommand: {other}")),
    }
}

fn main() {
    run(Reminders);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn successful_empty_output_is_authoritative() {
        assert!(candidates_from_output("").is_empty());
        assert!(candidates_from_output(" \nmalformed\n").is_empty());
    }

    #[test]
    fn listing_preserves_order_trims_fields_and_deduplicates_ids() {
        let candidates = candidates_from_output(
            "rem-1\tInbox\tBuy milk\nmalformed\nrem-2\t Work \t Ship release \nrem-1\tInbox\tDuplicate\n\tMissing\tID\n",
        );
        let titles: Vec<&str> = candidates
            .iter()
            .map(|candidate| candidate.title.as_str())
            .collect();
        assert_eq!(titles, ["Buy milk", "Ship release"]);

        let first = &candidates[0];
        assert_eq!(first.source, SOURCE_TASKS);
        assert_eq!(first.meta("kind"), Some("reminder"));
        assert_eq!(first.meta("subtitle"), Some("Reminder — Inbox"));
        assert_eq!(
            first.payload_as::<ReminderPayload>(),
            Some(ReminderPayload {
                id: "rem-1".to_string(),
                list: "Inbox".to_string(),
                title: "Buy milk".to_string(),
            })
        );
    }

    #[test]
    fn running_app_gate_matches_only_reminders() {
        assert!(reminders_is_running(&[RunningApplication {
            bundle_id: REMINDERS_BUNDLE_ID.to_string(),
            ..Default::default()
        }]));
        assert!(!reminders_is_running(&[RunningApplication {
            bundle_id: "com.apple.Notes".to_string(),
            ..Default::default()
        }]));
    }

    #[test]
    fn selection_script_quotes_the_identifier() {
        let script = select_script("x\"y\\z");
        assert!(script.contains("show reminder id \"x\\\"y\\\\z\""));
    }
}
