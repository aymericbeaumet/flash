use std::time::Duration;

use flash_plugin::{
    run, run_command, run_osascript, CommandOutput, CommandRequest, CommandResponse, Context,
};

// NSSystemDefined media key codes (IOKit IOHIDUsageTables.h, NX_KEYTYPE_*).
// Posting these as system-defined events lets macOS route the command to
// whichever app owns media playback — the same path as the keyboard's
// F8/F9/F10 keys.
const NX_KEYTYPE_PLAY: i32 = 16;
const NX_KEYTYPE_NEXT: i32 = 17;
const NX_KEYTYPE_PREVIOUS: i32 = 18;

const VOLUME_STEP: i32 = 10;

struct Player {
    name: &'static str,
    has_artist: bool,
}

// AppleScript fallback targets — used for now-playing/status queries and
// when the media-key post path is unavailable.
const PLAYERS: &[Player] = &[
    Player {
        name: "Spotify",
        has_artist: true,
    },
    Player {
        name: "Music",
        has_artist: true,
    },
    Player {
        name: "TV",
        has_artist: false,
    },
    Player {
        name: "Podcasts",
        has_artist: false,
    },
];

struct Media;

flash_plugin::plugin!(Media);

impl FlashPlugin for Media {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        let result: CliResult = match command.subcommand.as_str() {
            "play" => media_action(&ctx, NX_KEYTYPE_PLAY, "play").await,
            "pause" => media_action(&ctx, NX_KEYTYPE_PLAY, "pause").await,
            "toggle" => media_action(&ctx, NX_KEYTYPE_PLAY, "playpause").await,
            "next" => media_action(&ctx, NX_KEYTYPE_NEXT, "next track").await,
            "previous" => media_action(&ctx, NX_KEYTYPE_PREVIOUS, "previous track").await,
            "volumeup" => {
                osascript(
                    &ctx,
                    &format!(
                        "set volume output volume ((output volume of (get volume settings)) + {VOLUME_STEP})"
                    ),
                )
                .await
            }
            "volumedown" => {
                osascript(
                    &ctx,
                    &format!(
                        "set volume output volume (((output volume of (get volume settings)) - {VOLUME_STEP}) max 0)"
                    ),
                )
                .await
            }
            "mute" => {
                osascript(
                    &ctx,
                    "set volume output muted (not output muted of (get volume settings))",
                )
                .await
            }
            "get" => return get_current(&ctx).await,
            "status" => return status(&ctx).await,
            "run" => {
                let mut argv = vec!["/usr/bin/osascript".to_string()];
                argv.extend_from_slice(&command.args);
                run_command(&ctx, &argv, Duration::from_secs(120)).await
            }
            other => {
                return CommandResponse::error(format!("unknown subcommand: {other}"));
            }
        };
        result.into_command()
    }
}

async fn osascript(ctx: &Context, source: &str) -> CliResult {
    run_osascript(ctx, source, Duration::from_secs(10)).await
}

type CliResult = CommandOutput;

async fn app_running(ctx: &Context, app: &str) -> bool {
    let result = osascript(
        ctx,
        &format!("tell application \"System Events\" to (name of processes) contains \"{app}\""),
    )
    .await;
    result.ok && result.stdout.trim().eq_ignore_ascii_case("true")
}

async fn app_state(ctx: &Context, app: &str) -> Option<String> {
    if !app_running(ctx, app).await {
        return None;
    }
    let result = osascript(
        ctx,
        &format!("tell application \"{app}\" to player state as text"),
    )
    .await;
    if !result.ok {
        return None;
    }
    let state = result.stdout.trim().to_lowercase();
    if state.is_empty() {
        None
    } else {
        Some(state)
    }
}

async fn pick_player(ctx: &Context, prefer_playing: bool) -> Option<&'static Player> {
    let mut running = Vec::new();
    for player in PLAYERS {
        if app_running(ctx, player.name).await {
            running.push(player);
        }
    }
    if prefer_playing {
        for player in &running {
            if app_state(ctx, player.name).await.as_deref() == Some("playing") {
                return Some(player);
            }
        }
    }
    running.first().copied()
}

async fn applescript_command(ctx: &Context, command: &str) -> CliResult {
    let Some(player) = pick_player(ctx, true).await else {
        return CliResult {
            ok: false,
            stdout: String::new(),
            stderr: "no supported media app is running".into(),
            status: 1,
        };
    };
    let mut result = osascript(
        ctx,
        &format!("tell application \"{}\" to {command}", player.name),
    )
    .await;
    if result.ok && result.stdout.trim().is_empty() {
        result.stdout = format!("{}: {command}", player.name);
    }
    result
}

async fn media_action(ctx: &Context, key_code: i32, fallback: &str) -> CliResult {
    // The host posts the NX_SYSTEM_DEFINED event (`host.post_media_key`), so
    // this plugin needs no WindowServer/IOHID mach allowances of its own.
    let response = ctx
        .call_host(
            "host.post_media_key",
            serde_json::json!({ "key_code": key_code }),
        )
        .await;
    if response.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
        return CliResult {
            ok: true,
            stdout: String::new(),
            stderr: String::new(),
            status: 0,
        };
    }
    applescript_command(ctx, fallback).await
}

async fn get_current(ctx: &Context) -> CommandResponse {
    let Some(player) = pick_player(ctx, true).await else {
        return CommandResponse::error("no supported media app is running");
    };
    let state = app_state(ctx, player.name)
        .await
        .unwrap_or_else(|| "unknown".into());
    let mut fields = vec!["name of current track as text"];
    if player.has_artist {
        fields.push("artist of current track as text");
    }
    let script = format!(
        "tell application \"{}\"\n  try\n    return {}\n  on error\n    return \"\"\n  end try\nend tell",
        player.name,
        fields.join(" & \" — \" & ")
    );
    let result = osascript(ctx, &script).await;
    let track = if result.ok {
        result.stdout.trim().to_string()
    } else {
        String::new()
    };
    let mut summary = format!("{} [{state}]", player.name);
    if !track.is_empty() {
        summary = format!("{summary}: {track}");
    }
    CommandResponse::toast(summary)
}

async fn status(ctx: &Context) -> CommandResponse {
    let mut lines = Vec::new();
    for player in PLAYERS {
        let state = if app_running(ctx, player.name).await {
            app_state(ctx, player.name)
                .await
                .unwrap_or_else(|| "unknown".into())
        } else {
            "not running".into()
        };
        lines.push(format!("{}: {state}", player.name));
    }
    let vol = osascript(ctx, "output volume of (get volume settings)").await;
    let muted = osascript(ctx, "output muted of (get volume settings)").await;
    if vol.ok {
        let muted_flag = muted.ok && muted.stdout.trim().eq_ignore_ascii_case("true");
        lines.push(format!(
            "volume: {}%{}",
            vol.stdout.trim(),
            if muted_flag { " (muted)" } else { "" }
        ));
    }
    CommandResponse::toast(lines.join("\n"))
}

fn main() {
    run(Media);
}
