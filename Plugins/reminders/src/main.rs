use std::time::Duration;

use flash_plugin::{
    applescript_quote, run, sleep, spawn_background, Candidate, CommandRequest, CommandResponse,
    Context, Event, ResolveResponse,
};
use serde::{Deserialize, Serialize};

const SOURCE_ID: &str = "plugin:reminders";
const POLL_SECONDS: u64 = 60;

const LIST_SCRIPT: &str = r#"
tell application "Reminders"
  if not (running) then return ""
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
        ctx.log(
            "warn",
            &format!("[reminders] list failed: {}", result.stderr),
        );
        return;
    }
    let mut candidates = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in result.stdout.lines() {
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
    ctx.emit_snapshot(SOURCE_ID, candidates);
}

async fn resolve(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let rid = candidate
        .payload_as::<ReminderPayload>()
        .map(|p| p.id)
        .unwrap_or_default();
    if rid.is_empty() {
        return ResolveResponse::unresolved();
    }
    let result = ctx
        .run_osascript(&select_script(&rid), Duration::from_secs(10))
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
                    "com.apple.reminders".into(),
                ],
                Duration::from_secs(10),
            )
            .await
            .into_command(),
        "refresh" => {
            emit_candidates(ctx).await;
            CommandResponse::toast("reminders refreshed")
        }
        other => CommandResponse::error(format!("unknown subcommand: {other}")),
    }
}

fn main() {
    run(Reminders);
}
