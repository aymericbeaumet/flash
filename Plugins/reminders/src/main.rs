use std::collections::BTreeMap;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use flash_plugin::{
    applescript_quote, run, run_command, run_osascript, Candidate, CommandRequest, CommandResponse,
    Context, Event, RefreshGate, ResolveResponse, RunningApplication,
};
use serde::{Deserialize, Serialize};

const SOURCE_ID: &str = "plugin:reminders";
const POLL_SECONDS: u64 = 60;
const SLOW_REFRESH_MS: u128 = 1_000;
const STARTUP_REFRESH_BUDGET: Duration = Duration::from_secs(8);
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
        "
tell application \"Reminders\"
  activate
  try
    show reminder id {}
  end try
end tell
",
        applescript_quote(reminder_id)
    )
}

/// Round-tripped through the host so resolution can re-open the reminder by id.
#[derive(Serialize, Deserialize)]
struct ReminderPayload {
    id: String,
    list: String,
    title: String,
}

struct Reminders;

flash_plugin::plugin!(Reminders);

impl FlashPlugin for Reminders {
    async fn on_start(&self, ctx: Context) {
        let initial_succeeded =
            match tokio::time::timeout(STARTUP_REFRESH_BUDGET, refresh_candidates(&ctx)).await {
                Ok(succeeded) => succeeded,
                Err(_) => {
                    log_startup_timeout(&ctx);
                    false
                }
            };
        if should_publish_degraded_initial(initial_succeeded, ctx.has_locations(SOURCE_ID)) {
            log_degraded_initial(&ctx);
            ctx.set_locations(SOURCE_ID, Vec::new());
        }
        if !initial_succeeded {
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
        let is_reminders = event.bundle_id.as_deref() == Some("com.apple.reminders");
        if event.name == "core:apps.terminated" && is_reminders {
            // Termination is authoritative and needs no AppleScript round trip.
            clear_candidates(&ctx).await;
        } else if (event.name == "core:apps.launched" && is_reminders)
            || event.name == "core:config.changed"
        {
            refresh_candidates(&ctx).await;
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        invoke(&ctx, &command).await
    }

    async fn resolve_candidate(&self, ctx: Context, candidate: Candidate) -> ResolveResponse {
        resolve(&ctx, &candidate).await
    }
}

async fn refresh_candidates(ctx: &Context) -> bool {
    REFRESH_GATE
        .run(ctx, |ctx, running| async move {
            if reminders_is_running(&running) {
                refresh_candidates_inner(&ctx).await
            } else {
                let started_at = Instant::now();
                ctx.set_locations(SOURCE_ID, Vec::new());
                log_refresh(&ctx, "empty", 0, started_at);
                true
            }
        })
        .await
}

fn reminders_is_running(applications: &[RunningApplication]) -> bool {
    applications
        .iter()
        .any(|application| application.bundle_id == "com.apple.reminders")
}

async fn refresh_candidates_inner(ctx: &Context) -> bool {
    let started_at = Instant::now();
    let Some(candidates) = collect_candidates(ctx).await else {
        log_refresh(ctx, "failed", ctx.warm_locations().len(), started_at);
        return false;
    };
    let count = candidates.len();
    ctx.set_locations(SOURCE_ID, candidates);
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
            ctx.set_locations(SOURCE_ID, Vec::new());
        })
        .await;
}

fn log_refresh(ctx: &Context, outcome: &str, count: usize, started_at: Instant) {
    let elapsed_ms = started_at.elapsed().as_millis();
    let fields = BTreeMap::from([
        ("outcome".to_string(), outcome.to_string()),
        ("candidates".to_string(), count.to_string()),
        ("elapsed_ms".to_string(), elapsed_ms.to_string()),
    ]);
    ctx.log_fields("debug", "[reminders] warm refresh", fields.clone());
    if elapsed_ms >= SLOW_REFRESH_MS {
        ctx.log_fields("warn", "[reminders] warm refresh slow", fields);
    }
}

fn log_startup_timeout(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[reminders] initial warm refresh timed out",
        BTreeMap::from([
            (
                "budget_ms".to_string(),
                STARTUP_REFRESH_BUDGET.as_millis().to_string(),
            ),
            (
                "outcome".to_string(),
                "timed_out_background_retry".to_string(),
            ),
        ]),
    );
}

fn should_publish_degraded_initial(initial_succeeded: bool, has_last_good: bool) -> bool {
    !initial_succeeded && !has_last_good
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[reminders] initial warm catalog degraded",
        BTreeMap::from([
            ("outcome".to_string(), "empty_without_last_good".to_string()),
            ("candidates".to_string(), "0".to_string()),
            ("retry".to_string(), "immediate_background".to_string()),
        ]),
    );
}

async fn collect_candidates(ctx: &Context) -> Option<Vec<Candidate>> {
    let result = run_osascript(ctx, LIST_SCRIPT, Duration::from_secs(30)).await;
    if !result.ok {
        ctx.log(
            "warn",
            &format!("[reminders] list failed: {}", result.stderr),
        );
        return None;
    }
    Some(candidates_from_output(&result.stdout))
}

fn candidates_from_output(output: &str) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in output.lines() {
        let line = line.trim();
        let parts: Vec<&str> = line.splitn(3, '\t').collect();
        if parts.len() != 3 {
            continue;
        }
        let rid = parts[0].trim();
        let list_name = parts[1].trim();
        let title = parts[2].trim();
        if rid.is_empty() || title.is_empty() || !seen.insert(rid.to_string()) {
            continue;
        }
        candidates.push(
            Candidate::new(title)
                .kind("reminder")
                .source_id(SOURCE_ID)
                .source("reminders.tasks")
                .subtitle(format!("Reminder — {list_name}"))
                .payload_json(&ReminderPayload {
                    id: rid.to_string(),
                    list: list_name.to_string(),
                    title: title.to_string(),
                }),
        );
    }
    candidates
}

async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let rid = candidate
        .payload_as::<ReminderPayload>()
        .map(|p| p.id)
        .unwrap_or_default();
    if rid.is_empty() {
        return ResolveResponse::unresolved();
    }
    let result = run_osascript(ctx, &select_script(&rid), Duration::from_secs(10)).await;
    ResolveResponse {
        did_resolve: result.ok,
        target_pid: None,
        navigation_url: None,
    }
}

async fn invoke(ctx: &Context, cmd: &CommandRequest) -> CommandResponse {
    match cmd.subcommand.as_str() {
        "open" => run_command(
            ctx,
            &[
                "/usr/bin/open".into(),
                "-b".into(),
                "com.apple.reminders".into(),
            ],
            Duration::from_secs(10),
        )
        .await
        .into_command(),
        "refresh" => {
            if refresh_candidates(ctx).await {
                CommandResponse::toast("reminders refreshed")
            } else {
                CommandResponse::error("reminders refresh failed")
            }
        }
        other => CommandResponse::error(format!("unknown subcommand: {other}")),
    }
}

fn main() {
    run(Reminders);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn successful_empty_output_is_an_authoritative_empty_snapshot() {
        assert!(candidates_from_output("").is_empty());
        assert!(candidates_from_output(" \nmalformed\n").is_empty());
    }

    #[test]
    fn startup_refresh_budget_stays_below_host_initialize_timeout() {
        assert!(STARTUP_REFRESH_BUDGET < Duration::from_secs(15));
    }

    #[test]
    fn reminders_refresh_only_runs_while_reminders_is_open() {
        assert!(reminders_is_running(&[RunningApplication {
            bundle_id: "com.apple.reminders".to_string(),
            ..Default::default()
        }]));
        assert!(!reminders_is_running(&[RunningApplication {
            bundle_id: "com.apple.Notes".to_string(),
            ..Default::default()
        }]));
    }

    #[test]
    fn transient_startup_failure_only_uses_empty_when_no_last_good_exists() {
        assert!(should_publish_degraded_initial(false, false));
        assert!(!should_publish_degraded_initial(false, true));
        assert!(!should_publish_degraded_initial(true, false));
    }

    #[test]
    fn reminder_output_rejects_malformed_rows_and_deduplicates_ids() {
        let candidates = candidates_from_output(
            "rem-1\tInbox\tBuy milk\nmalformed\nrem-2\tWork\t Ship release \nrem-1\tInbox\tDuplicate\n",
        );
        let titles: Vec<&str> = candidates
            .iter()
            .map(|candidate| candidate.title.as_str())
            .collect();
        assert_eq!(titles, ["Buy milk", "Ship release"]);
        assert_eq!(
            candidates[0].payload_as::<ReminderPayload>().unwrap().id,
            "rem-1"
        );
    }
}
