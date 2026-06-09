use std::time::Duration;

use flash_plugin::{run, CommandResponse, Context, Plugin, Request, Response};

struct Spotify;

impl Plugin for Spotify {
    async fn handle(&self, ctx: Context, request: Request) -> Response {
        let Request::Command(cmd) = request else {
            return CommandResponse::error("unsupported request").into();
        };
        let (tail, timeout): (Vec<String>, u64) = match cmd.subcommand.as_str() {
            "login" => (vec!["authenticate".into()], 300),
            "status" => (vec!["--version".into()], 120),
            "pause" => (vec!["playback".into(), "pause".into()], 120),
            "play" => (vec!["playback".into(), "play".into()], 120),
            "toggle" => (vec!["playback".into(), "play-pause".into()], 120),
            "next" => (vec!["playback".into(), "next".into()], 120),
            "previous" => (vec!["playback".into(), "previous".into()], 120),
            "search" => (vec!["search".into(), cmd.args.join(" ")], 120),
            "run" => (cmd.args, 120),
            other => {
                return CommandResponse::error(format!("unknown subcommand: {other}")).into();
            }
        };
        let argv = spotify(&ctx, &tail);
        ctx.run_cli(&argv, Duration::from_secs(timeout))
            .await
            .into()
    }
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
