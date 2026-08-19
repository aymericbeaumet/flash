use std::collections::BTreeMap;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use flash_plugin::{
    applescript_quote, run, run_osascript, Candidate, CommandRequest, CommandResponse, Context,
    Event, RefreshGate, ResolveResponse, RunningApplication,
};
use serde::{Deserialize, Serialize};

const SOURCE_ID: &str = "plugin:contacts";
const POLL_SECONDS: u64 = 60;
const SLOW_REFRESH_MS: u128 = 1_000;
const STARTUP_REFRESH_BUDGET: Duration = Duration::from_secs(8);
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);

const LIST_SCRIPT: &str = r#"
on safeName(p)
  try
    set n to name of p
    if n is missing value then return ""
    return n
  on error
    return ""
  end try
end safeName

if application "/System/Applications/Contacts.app" is not running then return ""
tell application "/System/Applications/Contacts.app"
  set acc to {}
  repeat with p in people
    set n to my safeName(p)
    if n is not "" then set end of acc to n
  end repeat
  set AppleScript's text item delimiters to linefeed
  return acc as text
end tell
"#;

fn select_script(name: &str) -> String {
    format!(
        "
tell application \"/System/Applications/Contacts.app\"
  activate
  set candidates to every person whose name is {}
  if (count of candidates) > 0 then
    set the selection to (item 1 of candidates)
  end if
end tell
",
        applescript_quote(name)
    )
}

/// Round-tripped through the host so resolution can re-select the right person
/// even after the candidate list refreshes.
#[derive(Serialize, Deserialize)]
struct ContactPayload {
    contact: String,
}

struct Contacts;

flash_plugin::plugin!(Contacts);

impl FlashPlugin for Contacts {
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
        let is_contacts = event.bundle_id.as_deref() == Some("com.apple.AddressBook");
        if event.name == "core:apps.terminated" && is_contacts {
            // Termination is authoritative and needs no AppleScript round trip.
            clear_candidates(&ctx).await;
        } else if (event.name == "core:apps.launched" && is_contacts)
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
            if contacts_is_running(&running) {
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

fn contacts_is_running(applications: &[RunningApplication]) -> bool {
    applications
        .iter()
        .any(|application| application.bundle_id == "com.apple.AddressBook")
}

async fn refresh_candidates_inner(ctx: &Context) -> bool {
    let started_at = Instant::now();
    let Some(candidates) = collect_candidates(ctx).await else {
        log_refresh(ctx, "failed", ctx.warm_locations().len(), started_at);
        return false;
    };
    // A successful empty response is authoritative: Contacts is stopped or the
    // address book has no rows. Only a real subprocess failure preserves the
    // previous warm snapshot.
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
    ctx.log_fields("debug", "[contacts] warm refresh", fields.clone());
    if elapsed_ms >= SLOW_REFRESH_MS {
        ctx.log_fields("warn", "[contacts] warm refresh slow", fields);
    }
}

fn log_startup_timeout(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[contacts] initial warm refresh timed out",
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
        "[contacts] initial warm catalog degraded",
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
            &format!("[contacts] list failed: {}", result.stderr),
        );
        return None;
    }
    Some(candidates_from_output(&result.stdout))
}

fn candidates_from_output(output: &str) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in output.lines() {
        let name = line.trim();
        if name.is_empty() || !seen.insert(name.to_string()) {
            continue;
        }
        candidates.push(
            Candidate::new(name)
                .kind("contact")
                .source_id(SOURCE_ID)
                .source("contacts.cards")
                .subtitle("Contact")
                .payload_json(&ContactPayload {
                    contact: name.to_string(),
                }),
        );
    }
    candidates
}

async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let name = candidate
        .payload_as::<ContactPayload>()
        .map(|p| p.contact)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| candidate.title.clone());
    if name.is_empty() {
        return ResolveResponse::unresolved();
    }
    let result = run_osascript(ctx, &select_script(&name), Duration::from_secs(10)).await;
    ResolveResponse {
        ok: result.ok,
        target_pid: None,
        navigation_url: None,
    }
}

async fn invoke(ctx: &Context, cmd: &CommandRequest) -> CommandResponse {
    match cmd.subcommand.as_str() {
        "open" => {
            if ctx.open_app("com.apple.AddressBook").await {
                CommandResponse::ok()
            } else {
                CommandResponse::error("host.open com.apple.AddressBook failed")
            }
        }
        "refresh" => {
            if refresh_candidates(ctx).await {
                CommandResponse::toast("contacts refreshed")
            } else {
                CommandResponse::error("contacts refresh failed")
            }
        }
        other => CommandResponse::error(format!("unknown subcommand: {other}")),
    }
}

fn main() {
    run(Contacts);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn successful_empty_output_is_an_authoritative_empty_snapshot() {
        assert!(candidates_from_output("").is_empty());
        assert!(candidates_from_output(" \n\t\n").is_empty());
    }

    #[test]
    fn startup_refresh_budget_stays_below_host_initialize_timeout() {
        assert!(STARTUP_REFRESH_BUDGET < Duration::from_secs(15));
    }

    #[test]
    fn transient_startup_failure_only_uses_empty_when_no_last_good_exists() {
        assert!(should_publish_degraded_initial(false, false));
        assert!(!should_publish_degraded_initial(false, true));
        assert!(!should_publish_degraded_initial(true, false));
    }

    #[test]
    fn contact_output_trims_and_deduplicates_names() {
        let candidates = candidates_from_output("Ada Lovelace\n Grace Hopper \nAda Lovelace\n");
        let titles: Vec<&str> = candidates
            .iter()
            .map(|candidate| candidate.title.as_str())
            .collect();
        assert_eq!(titles, ["Ada Lovelace", "Grace Hopper"]);
    }

    #[test]
    fn contacts_refresh_is_gated_by_the_host_running_app_snapshot() {
        assert!(!contacts_is_running(&[]));
        assert!(contacts_is_running(&[RunningApplication {
            bundle_id: "com.apple.AddressBook".to_string(),
            pid: 42,
            localized_name: "Contacts".to_string(),
        }]));
    }

    #[test]
    fn contacts_scripts_use_the_canonical_system_application() {
        assert!(LIST_SCRIPT.contains("tell application \"/System/Applications/Contacts.app\""));
        assert!(
            select_script("Ada").contains("tell application \"/System/Applications/Contacts.app\"")
        );
    }
}
