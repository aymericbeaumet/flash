use std::process::Stdio;
use std::time::Duration;

use flash_plugin::{run, CommandRequest, CommandResponse, Context};

const SETTLE_DELAY_SECONDS: &str = "0.20";
const WINDOW_PICKER_DELAY_SECONDS: &str = "0.12";

struct Screenshot;

flash_plugin::plugin!(Screenshot);

impl FlashPlugin for Screenshot {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        let Some(shortcut) = Shortcut::for_subcommand(&command.subcommand) else {
            return CommandResponse::error(format!("unknown subcommand: {}", command.subcommand));
        };
        run_osascript(&ctx, &shortcut.script(), Duration::from_secs(5))
            .await
            .into_command()
    }
}

#[derive(Clone, Copy)]
struct Shortcut {
    key_code: u8,
    control: bool,
    then_space: bool,
}

impl Shortcut {
    fn for_subcommand(subcommand: &str) -> Option<Self> {
        match subcommand {
            "" | "options" => Some(Self::new(23, false, false)),
            "screen" => Some(Self::new(20, false, false)),
            "selection" => Some(Self::new(21, false, false)),
            "window" => Some(Self::new(21, false, true)),
            "screen_clipboard" => Some(Self::new(20, true, false)),
            "selection_clipboard" => Some(Self::new(21, true, false)),
            "window_clipboard" => Some(Self::new(21, true, true)),
            _ => None,
        }
    }

    fn new(key_code: u8, control: bool, then_space: bool) -> Self {
        Self {
            key_code,
            control,
            then_space,
        }
    }

    fn script(self) -> String {
        let modifiers = if self.control {
            "command down, control down, shift down"
        } else {
            "command down, shift down"
        };
        let mut script = format!(
            "delay {SETTLE_DELAY_SECONDS}\n\
             tell application \"System Events\" to key code {} using {{{modifiers}}}",
            self.key_code
        );
        if self.then_space {
            script.push_str(&format!(
                "\ndelay {WINDOW_PICKER_DELAY_SECONDS}\n\
                 tell application \"System Events\" to key code 49"
            ));
        }
        script
    }
}

#[derive(Debug, Default)]
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
    run(Screenshot);
}
