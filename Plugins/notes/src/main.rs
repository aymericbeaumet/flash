use std::time::Duration;

use flash_plugin::{
    applescript_quote, run, sleep, spawn_background, Candidate, CommandRequest, CommandResponse,
    Context, Event, ResolveResponse,
};
use serde::{Deserialize, Serialize};

const SOURCE_ID: &str = "plugin:notes";
const POLL_SECONDS: u64 = 60;

const LIST_SCRIPT: &str = r#"
tell application "Notes"
  if not (running) then return ""
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
        emit_candidates(&ctx).await;
        start_poll(ctx);
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if matches!(
            event.name.as_str(),
            "core:flash.started" | "core:apps.launched" | "core:config.changed"
        ) {
            emit_candidates(&ctx).await;
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        invoke(&ctx, &command).await
    }

    async fn resolve_candidate(&self, ctx: Context, candidate: Candidate) -> ResolveResponse {
        resolve(&ctx, &candidate).await
    }
}

fn start_poll(ctx: Context) {
    spawn_background(async move {
        loop {
            sleep(Duration::from_secs(POLL_SECONDS)).await;
            emit_candidates(&ctx).await;
        }
    });
}

async fn emit_candidates(ctx: &Context) {
    let result = ctx
        .run_osascript(LIST_SCRIPT, Duration::from_secs(30))
        .await;
    if !result.ok {
        ctx.log("warn", &format!("[notes] list failed: {}", result.stderr));
        return;
    }
    let mut candidates = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in result.stdout.lines() {
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
            Candidate::new(title)
                .kind("note")
                .source_id(SOURCE_ID)
                .source("notes.notes")
                .subtitle("Note")
                .payload_json(&NotePayload {
                    id: note_id.to_string(),
                    title: title.to_string(),
                }),
        );
    }
    ctx.emit_snapshot(SOURCE_ID, candidates);
}

async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let note_id = candidate
        .payload_as::<NotePayload>()
        .map(|p| p.id)
        .unwrap_or_default();
    if note_id.is_empty() {
        return ResolveResponse::unresolved();
    }
    let result = ctx
        .run_osascript(&select_script(&note_id), Duration::from_secs(10))
        .await;
    ResolveResponse {
        did_resolve: result.ok,
        target_pid: None,
    }
}

async fn invoke(ctx: &Context, cmd: &CommandRequest) -> CommandResponse {
    match cmd.subcommand.as_str() {
        "open" => ctx
            .run_cli(
                &[
                    "/usr/bin/open".into(),
                    "-b".into(),
                    "com.apple.Notes".into(),
                ],
                Duration::from_secs(10),
            )
            .await
            .into_command(),
        "refresh" => {
            emit_candidates(ctx).await;
            CommandResponse::toast("notes refreshed")
        }
        other => CommandResponse::error(format!("unknown subcommand: {other}")),
    }
}

fn main() {
    run(Notes);
}
