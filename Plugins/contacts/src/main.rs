use std::process::Stdio;
use std::time::Duration;

use flash_plugin::{
    run, Candidate, CommandRequest, CommandResponse, Context, Event, ResolveResponse,
};
use serde::{Deserialize, Serialize};

const SOURCE_ID: &str = "plugin:contacts";
const POLL_SECONDS: u64 = 60;

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

flash_plugin::plugin!(Contacts);

impl FlashPlugin for Contacts {
    async fn on_start(&self, ctx: Context) {
        emit_candidates(&ctx).await;
        let poll_ctx = ctx.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(POLL_SECONDS)).await;
                emit_candidates(&poll_ctx).await;
            }
        });
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

async fn emit_candidates(ctx: &Context) {
    let result = run_osascript(ctx, LIST_SCRIPT, Duration::from_secs(30)).await;
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
                .source("contacts.cards")
                .subtitle("Contact")
                .payload_json(&ContactPayload {
                    contact: name.to_string(),
                }),
        );
    }
    ctx.emit_snapshot(SOURCE_ID, candidates);
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
                "com.apple.AddressBook".into(),
            ],
            Duration::from_secs(10),
        )
        .await
        .into_command(),
        "refresh" => {
            emit_candidates(ctx).await;
            CommandResponse::toast("contacts refreshed")
        }
        other => CommandResponse::error(format!("unknown subcommand: {other}")),
    }
}

#[derive(Default)]
struct CommandOutput {
    ok: bool,
    stdout: String,
    stderr: String,
    _status: i32,
}

impl CommandOutput {
    fn into_command(self) -> CommandResponse {
        CommandResponse {
            ok: self.ok,
            stdout: (!self.stdout.trim().is_empty()).then(|| shorten(&self.stdout)),
            error: (!self.ok && !self.stderr.trim().is_empty()).then(|| shorten(&self.stderr)),
            ..Default::default()
        }
    }
}

async fn run_osascript(ctx: &Context, script: &str, timeout: Duration) -> CommandOutput {
    run_command(
        ctx,
        &[
            "/usr/bin/osascript".to_string(),
            "-e".to_string(),
            script.to_string(),
        ],
        timeout,
    )
    .await
}

async fn run_command(ctx: &Context, argv: &[String], timeout: Duration) -> CommandOutput {
    let Some((program, args)) = argv.split_first() else {
        return CommandOutput {
            ok: false,
            stderr: "empty argv".to_string(),
            _status: -1,
            ..Default::default()
        };
    };
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .current_dir(&ctx.data_dir)
        .env("HOME", ctx.home_dir())
        .env("XDG_CONFIG_HOME", ctx.config_dir())
        .env("XDG_CACHE_HOME", ctx.cache_dir())
        .env("XDG_DATA_HOME", ctx.share_dir())
        .env(
            "PATH",
            format!(
                "{}:{}",
                ctx.bin_dir().display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    match tokio::time::timeout(timeout, command.output()).await {
        Ok(Ok(output)) => CommandOutput {
            ok: output.status.success(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
            _status: output.status.code().unwrap_or(-1),
        },
        Ok(Err(err)) => CommandOutput {
            ok: false,
            stderr: err.to_string(),
            _status: -1,
            ..Default::default()
        },
        Err(_) => CommandOutput {
            ok: false,
            stderr: format!("timed out after {}ms", timeout.as_millis()),
            _status: 124,
            ..Default::default()
        },
    }
}

fn applescript_quote(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

fn shorten(value: &str) -> String {
    const LIMIT: usize = 2000;
    let trimmed = value.trim();
    if trimmed.chars().count() <= LIMIT {
        return trimmed.to_string();
    }
    let head: String = trimmed.chars().take(LIMIT - 3).collect();
    format!("{head}...")
}

fn main() {
    run(Contacts);
}
