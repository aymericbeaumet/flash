use std::time::Duration;

use flash_plugin::{
    applescript_quote, run, Candidate, CommandRequest, CommandResponse, Context, Event, Plugin,
    Request, ResolveResponse, Response,
};
use serde::{Deserialize, Serialize};

const SOURCE_ID: &str = "plugin:contacts";

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

tell application "Contacts"
  if not (running) then return ""
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
tell application \"Contacts\"
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

impl Plugin for Contacts {
    async fn on_start(&self, ctx: Context) {
        emit_candidates(&ctx).await;
    }

    async fn on_event(&self, ctx: Context, event: Event) {
        if matches!(
            event.name.as_str(),
            "flash.started" | "apps.launched" | "config.changed"
        ) {
            emit_candidates(&ctx).await;
        }
    }

    async fn handle(&self, ctx: Context, request: Request) -> Response {
        match request {
            Request::ResolveCandidate(candidate) => {
                resolve_candidate(&ctx, &candidate).await.into()
            }
            Request::Command(cmd) => invoke(&ctx, &cmd).await,
            _ => CommandResponse::error("unsupported request").into(),
        }
    }
}

async fn emit_candidates(ctx: &Context) {
    let result = ctx
        .run_osascript(LIST_SCRIPT, Duration::from_secs(30))
        .await;
    if !result.ok {
        ctx.log(
            "warn",
            &format!("[contacts] list failed: {}", result.stderr),
        );
        return;
    }
    let mut candidates = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for line in result.stdout.lines() {
        let name = line.trim();
        if name.is_empty() || !seen.insert(name.to_string()) {
            continue;
        }
        candidates.push(
            Candidate::new(name)
                .kind("contact")
                .source_id(SOURCE_ID)
                .source("contacts")
                .subtitle("Contact")
                .payload_json(&ContactPayload {
                    contact: name.to_string(),
                }),
        );
    }
    ctx.emit_snapshot(SOURCE_ID, candidates);
}

async fn resolve_candidate(ctx: &Context, candidate: &Candidate) -> ResolveResponse {
    let name = candidate
        .payload_as::<ContactPayload>()
        .map(|p| p.contact)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| candidate.name.clone());
    if name.is_empty() {
        return ResolveResponse::unresolved();
    }
    let result = ctx
        .run_osascript(&select_script(&name), Duration::from_secs(10))
        .await;
    ResolveResponse {
        did_resolve: result.ok,
        target_pid: None,
    }
}

async fn invoke(ctx: &Context, cmd: &CommandRequest) -> Response {
    match cmd.subcommand.as_str() {
        "open" => ctx
            .run_cli(
                &[
                    "/usr/bin/open".into(),
                    "-b".into(),
                    "com.apple.AddressBook".into(),
                ],
                Duration::from_secs(10),
            )
            .await
            .into(),
        "refresh" => {
            emit_candidates(ctx).await;
            CommandResponse::toast("contacts refreshed").into()
        }
        other => CommandResponse::error(format!("unknown subcommand: {other}")).into(),
    }
}

fn main() {
    run(Contacts);
}
