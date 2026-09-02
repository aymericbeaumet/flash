use std::path::{Path, PathBuf};
use std::time::Duration;

use flash_plugin::{run, run_command, CommandRequest, Context, PerformResponse};

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);
const LOGIN_TIMEOUT: Duration = Duration::from_secs(300);

#[derive(Debug, PartialEq, Eq)]
struct CommandPlan {
    tail: Vec<String>,
    timeout: Duration,
}

fn command_plan(command: &CommandRequest) -> Result<CommandPlan, String> {
    let tail = match command.subcommand.as_str() {
        "login" => {
            return Ok(CommandPlan {
                tail: vec!["authenticate".to_string()],
                timeout: LOGIN_TIMEOUT,
            });
        }
        "status" => vec!["--version".to_string()],
        "pause" => vec!["playback".to_string(), "pause".to_string()],
        "play" => vec!["playback".to_string(), "play".to_string()],
        "toggle" => vec!["playback".to_string(), "play-pause".to_string()],
        "next" => vec!["playback".to_string(), "next".to_string()],
        "previous" => vec!["playback".to_string(), "previous".to_string()],
        "search" => vec!["search".to_string(), command.args.join(" ")],
        "run" => command.args.clone(),
        other => return Err(format!("unknown subcommand: {other}")),
    };
    Ok(CommandPlan {
        tail,
        timeout: DEFAULT_TIMEOUT,
    })
}

fn spotify_argv(config: &Path, cache: &Path, tail: &[String]) -> Vec<String> {
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

struct Spotify;

flash_plugin::plugin!(Spotify);

impl FlashPlugin for Spotify {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        let plan = match command_plan(&command) {
            Ok(plan) => plan,
            Err(error) => return PerformResponse::fail(error),
        };

        let config = ctx.config_dir().join("spotify-player");
        let cache = ctx.cache_dir().join("spotify-player");
        prepare_directory(&config).await;
        prepare_directory(&cache).await;

        run_command(
            &ctx,
            &spotify_argv(&config, &cache, &plan.tail),
            plan.timeout,
        )
        .await
        .into_perform()
    }
}

async fn prepare_directory(path: &PathBuf) {
    // Match the previous implementation: directory creation is best-effort;
    // spotify_player reports any unusable path through its own stderr.
    let _ = tokio::fs::create_dir_all(path).await;
}

fn main() {
    run(Spotify);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(subcommand: &str, args: &[&str]) -> CommandRequest {
        CommandRequest {
            subcommand: subcommand.to_string(),
            args: args.iter().map(|arg| (*arg).to_string()).collect(),
            ..Default::default()
        }
    }

    #[test]
    fn playback_commands_map_to_exact_spotify_player_argv() {
        let cases = [
            ("status", vec!["--version"]),
            ("pause", vec!["playback", "pause"]),
            ("play", vec!["playback", "play"]),
            ("toggle", vec!["playback", "play-pause"]),
            ("next", vec!["playback", "next"]),
            ("previous", vec!["playback", "previous"]),
        ];
        for (subcommand, expected) in cases {
            let plan = command_plan(&request(subcommand, &[])).unwrap();
            assert_eq!(plan.tail, expected);
            assert_eq!(plan.timeout, DEFAULT_TIMEOUT);
        }
    }

    #[test]
    fn login_uses_the_long_timeout() {
        let plan = command_plan(&request("login", &[])).unwrap();
        assert_eq!(plan.tail, ["authenticate"]);
        assert_eq!(plan.timeout, LOGIN_TIMEOUT);
    }

    #[test]
    fn search_joins_arguments_while_run_forwards_them_verbatim() {
        let search = command_plan(&request("search", &["miles", "davis"])).unwrap();
        assert_eq!(search.tail, ["search", "miles davis"]);

        let run = command_plan(&request("run", &["search", "miles davis"])).unwrap();
        assert_eq!(run.tail, ["search", "miles davis"]);
    }

    #[test]
    fn base_directories_precede_command_arguments() {
        let argv = spotify_argv(
            Path::new("/data/config/spotify-player"),
            Path::new("/data/cache/spotify-player"),
            &["playback".to_string(), "next".to_string()],
        );
        assert_eq!(
            argv,
            [
                "spotify_player",
                "--config-folder",
                "/data/config/spotify-player",
                "--cache-folder",
                "/data/cache/spotify-player",
                "playback",
                "next",
            ]
        );
    }

    #[test]
    fn unknown_subcommand_fails_before_spawning() {
        assert_eq!(
            command_plan(&request("shuffle", &[])).unwrap_err(),
            "unknown subcommand: shuffle"
        );
    }
}
