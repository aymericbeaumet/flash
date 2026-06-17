use std::process::Stdio;
use std::time::Duration;

use flash_plugin::{run, CommandRequest, CommandResponse, Context};

struct Spotify;

flash_plugin::plugin!(Spotify);

impl FlashPlugin for Spotify {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        let (tail, timeout): (Vec<String>, u64) = match command.subcommand.as_str() {
            "login" => (vec!["authenticate".into()], 300),
            "status" => (vec!["--version".into()], 120),
            "pause" => (vec!["playback".into(), "pause".into()], 120),
            "play" => (vec!["playback".into(), "play".into()], 120),
            "toggle" => (vec!["playback".into(), "play-pause".into()], 120),
            "next" => (vec!["playback".into(), "next".into()], 120),
            "previous" => (vec!["playback".into(), "previous".into()], 120),
            "search" => (vec!["search".into(), command.args.join(" ")], 120),
            "run" => (command.args, 120),
            other => {
                return CommandResponse::error(format!("unknown subcommand: {other}"));
            }
        };
        let argv = spotify(&ctx, &tail);
        run_command(&ctx, &argv, Duration::from_secs(timeout))
            .await
            .into_command()
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

fn spotify(ctx: &Context, tail: &[String]) -> Vec<String> {
    let config = ctx.config_dir().join("spotify-player");
    let cache = ctx.cache_dir().join("spotify-player");
    let _ = std::fs::create_dir_all(&config);
    let _ = std::fs::create_dir_all(&cache);
    let mut argv = vec![
        "spotify_player".to_string(),
        "--config-folder".to_string(),
        config.display().to_string(),
        "--cache-folder".to_string(),
        cache.display().to_string(),
    ];
    argv.extend_from_slice(tail);
    argv
}

fn main() {
    run(Spotify);
}
