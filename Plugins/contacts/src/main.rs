use std::collections::BTreeMap;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use flash_plugin::{
    applescript_quote, run, run_osascript, Candidate, CommandRequest, Context, Event,
    PerformResponse, RefreshGate, RunningApplication,
};
use serde::{Deserialize, Serialize};

const SOURCE_CARDS: &str = "contacts.cards";
const POLL_SECONDS: u64 = 60;
const SLOW_REFRESH_MS: u128 = 1_000;
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
        // Runs after the initialize reply, so a slow Contacts listing never
        // delays the handshake. A failed initial listing publishes nothing —
        // the host keeps its last-good catalog — and retries in the
        // background.
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
            if contacts_is_running(&running) {
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

fn contacts_is_running(applications: &[RunningApplication]) -> bool {
    applications
        .iter()
        .any(|application| application.bundle_id == "com.apple.AddressBook")
}

async fn refresh_candidates_inner(ctx: &Context) -> bool {
    let started_at = Instant::now();
    let Some(candidates) = collect_candidates(ctx).await else {
        log_refresh(ctx, "failed", 0, started_at);
        return false;
    };
    // A successful empty response is authoritative: Contacts is stopped or the
    // address book has no rows. Only a real subprocess failure skips the
    // publish so the host keeps its last-good catalog.
    let count = candidates.len();
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
        ("candidates".to_string(), count.to_string()),
        ("elapsed_ms".to_string(), elapsed_ms.to_string()),
    ]);
    ctx.log_fields("debug", "[contacts] warm refresh", fields.clone());
    if elapsed_ms >= SLOW_REFRESH_MS {
        ctx.log_fields("warn", "[contacts] warm refresh slow", fields);
    }
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[contacts] initial warm catalog degraded",
        BTreeMap::from([
            ("outcome".to_string(), "unpublished_failure".to_string()),
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
            Candidate::new(SOURCE_CARDS, name)
                .kind("contact")
                .subtitle("Contact")
                .payload_json(&ContactPayload {
                    contact: name.to_string(),
                }),
        );
    }
    candidates
}

async fn resolve(ctx: &Context, row: &Candidate) -> PerformResponse {
    let name = row
        .payload_as::<ContactPayload>()
        .map(|p| p.contact)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| row.title.clone());
    if name.is_empty() {
        return PerformResponse::unhandled();
    }
    let result = run_osascript(ctx, &select_script(&name), Duration::from_secs(10)).await;
    if result.ok {
        PerformResponse::ok()
    } else {
        PerformResponse::fail("contact selection failed")
    }
}

async fn invoke(ctx: &Context, cmd: &CommandRequest) -> PerformResponse {
    match cmd.subcommand.as_str() {
        "open" => {
            if ctx.open_app("com.apple.AddressBook").await {
                PerformResponse::ok()
            } else {
                PerformResponse::fail("host.open com.apple.AddressBook failed")
            }
        }
        "refresh" => {
            if refresh_candidates(ctx).await {
                PerformResponse::ok().message("contacts refreshed")
            } else {
                PerformResponse::fail("contacts refresh failed")
            }
        }
        other => PerformResponse::fail(format!("unknown subcommand: {other}")),
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
