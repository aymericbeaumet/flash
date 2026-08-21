use flash_plugin::{
    applescript_quote, run, run_osascript, Candidate, CommandRequest, Context, Event,
    PerformResponse, RefreshGate, RunningApplication,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

const SOURCE_NOTES: &str = "notes.notes";
const POLL_SECONDS: u64 = 60;
const SLOW_REFRESH_MS: u128 = 1_000;
static REFRESH_GATE: LazyLock<RefreshGate> = LazyLock::new(RefreshGate::default);

const LIST_SCRIPT: &str = r#"
if application "Notes" is not running then return ""
tell application "Notes"
  set output to {}
  repeat with acc in accounts
    try
      repeat with n in notes of acc
        set the end of output to ((id of n as text) & tab & (name of n as text))
      end repeat
    end try
  end repeat
  set AppleScript's text item delimiters to linefeed
  return output as text
end tell
"#;

fn select_script(note_id: &str) -> String {
    format!(
        "
tell application \"Notes\"
  activate
  try
    show note id {}
  end try
end tell
",
        applescript_quote(note_id)
    )
}

/// Round-tripped through the host so resolution can re-open the note by id.
#[derive(Serialize, Deserialize)]
struct NotePayload {
    id: String,
    title: String,
}

struct Notes;

flash_plugin::plugin!(Notes);

impl FlashPlugin for Notes {
    async fn on_start(&self, ctx: Context) {
        // Runs after the initialize reply, so a slow Notes listing never
        // delays the handshake. A failed initial listing publishes nothing —
        // the host keeps its last-good catalog — and retries in the
        // background.
        if refresh_candidates(&ctx).await.is_none() {
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
        let is_notes = event.bundle_id.as_deref() == Some("com.apple.Notes");
        if event.name == "core:apps.terminated" && is_notes {
            // Termination is authoritative and needs no AppleScript round trip.
            clear_candidates(&ctx).await;
        } else if (event.name == "core:apps.launched" && is_notes)
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

async fn refresh_candidates(ctx: &Context) -> Option<Vec<Candidate>> {
    REFRESH_GATE
        .run(ctx, |ctx, running| async move {
            if notes_is_running(&running) {
                refresh_candidates_inner(&ctx).await
            } else {
                let started_at = Instant::now();
                ctx.publish(Vec::new());
                log_refresh(&ctx, "empty", 0, started_at);
                Some(Vec::new())
            }
        })
        .await
}

fn notes_is_running(applications: &[RunningApplication]) -> bool {
    applications
        .iter()
        .any(|application| application.bundle_id == "com.apple.Notes")
}

async fn refresh_candidates_inner(ctx: &Context) -> Option<Vec<Candidate>> {
    let started_at = Instant::now();
    let result = run_osascript(ctx, LIST_SCRIPT, Duration::from_secs(30)).await;
    if !result.ok {
        ctx.log("warn", &format!("[notes] list failed: {}", result.stderr));
        log_refresh(ctx, "failed", 0, started_at);
        return None;
    }
    let candidates = candidates_from_output(&result.stdout);
    // A successful empty response is authoritative: Notes is stopped or has no
    // rows. Only a real subprocess failure skips the publish so the host
    // keeps its last-good catalog.
    let count = candidates.len();
    ctx.publish(candidates.clone());
    log_refresh(
        ctx,
        if count == 0 { "empty" } else { "ok" },
        count,
        started_at,
    );
    Some(candidates)
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
    ctx.log_fields("debug", "[notes] warm refresh", fields.clone());
    if elapsed_ms >= SLOW_REFRESH_MS {
        ctx.log_fields("warn", "[notes] warm refresh slow", fields);
    }
}

fn log_degraded_initial(ctx: &Context) {
    ctx.log_fields(
        "warn",
        "[notes] initial warm catalog degraded",
        BTreeMap::from([
            ("outcome".to_string(), "unpublished_failure".to_string()),
            ("candidates".to_string(), "0".to_string()),
            ("retry".to_string(), "immediate_background".to_string()),
        ]),
    );
}

fn candidates_from_output(output: &str) -> Vec<Candidate> {
    let mut candidates = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in output.lines() {
        let line = line.trim();
        let Some((note_id, title)) = line.split_once('\t') else {
            continue;
        };
        let note_id = note_id.trim();
        let title = title.trim();
        if note_id.is_empty() || title.is_empty() || !seen.insert(note_id.to_string()) {
            continue;
        }
        candidates.push(
            Candidate::new(SOURCE_NOTES, title)
                .kind("note")
                .subtitle("Note")
                .payload_json(&NotePayload {
                    id: note_id.to_string(),
                    title: title.to_string(),
                }),
        );
    }
    candidates
}

async fn resolve(ctx: &Context, row: &Candidate) -> PerformResponse {
    let note_id = row
        .payload_as::<NotePayload>()
        .map(|p| p.id)
        .unwrap_or_default();
    if note_id.is_empty() {
        return PerformResponse::unhandled();
    }
    let result = run_osascript(ctx, &select_script(&note_id), Duration::from_secs(10)).await;
    if result.ok {
        PerformResponse::ok()
    } else {
        PerformResponse::fail("note selection failed")
    }
}

async fn invoke(ctx: &Context, cmd: &CommandRequest) -> PerformResponse {
    match cmd.subcommand.as_str() {
        "open" => {
            if ctx.open_app("com.apple.Notes").await {
                PerformResponse::ok()
            } else {
                PerformResponse::fail("host.open com.apple.Notes failed")
            }
        }
        "refresh" => {
            if refresh_candidates(ctx).await.is_some() {
                PerformResponse::ok().message("notes refreshed")
            } else {
                PerformResponse::fail("notes refresh failed")
            }
        }
        other => PerformResponse::fail(format!("unknown subcommand: {other}")),
    }
}

fn main() {
    run(Notes);
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
    fn notes_refresh_only_runs_while_notes_is_open() {
        assert!(notes_is_running(&[RunningApplication {
            bundle_id: "com.apple.Notes".to_string(),
            ..Default::default()
        }]));
        assert!(!notes_is_running(&[RunningApplication {
            bundle_id: "com.apple.TextEdit".to_string(),
            ..Default::default()
        }]));
    }

    #[test]
    fn note_output_rejects_malformed_rows_and_deduplicates_ids() {
        let candidates = candidates_from_output(
            "note-1\tFirst\nmalformed\nnote-2\t Second \nnote-1\tRenamed\n\tMissing ID\n",
        );
        let titles: Vec<&str> = candidates
            .iter()
            .map(|candidate| candidate.title.as_str())
            .collect();
        assert_eq!(titles, ["First", "Second"]);
        assert_eq!(
            candidates[0].payload_as::<NotePayload>().unwrap().id,
            "note-1"
        );
    }
}
