use std::time::Duration;

use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, string_list, CliResult, Context, Plugin};

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

impl Plugin for Media {
    async fn handle(&self, ctx: Context, method: String, params: Value) -> Value {
        if method != "command.invoke" {
            return json!({ "ok": false, "error": format!("unknown method: {method}") });
        }
        let name = str_field(&params, "subcommand").to_string();
        let result = match name.as_str() {
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
                argv.extend(string_list(&params, "args"));
                ctx.run_cli(&argv, Duration::from_secs(120)).await
            }
            other => {
                return json!({ "ok": false, "error": format!("unknown subcommand: {other}") });
            }
        };
        result.value()
    }
}

async fn osascript(ctx: &Context, source: &str) -> CliResult {
    let argv = vec![
        "/usr/bin/osascript".to_string(),
        "-e".to_string(),
        source.to_string(),
    ];
    ctx.run_cli(&argv, Duration::from_secs(10)).await
}

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
    if post_media_key(key_code) {
        return CliResult {
            ok: true,
            stdout: String::new(),
            stderr: String::new(),
            status: 0,
        };
    }
    applescript_command(ctx, fallback).await
}

async fn get_current(ctx: &Context) -> Value {
    let Some(player) = pick_player(ctx, true).await else {
        return json!({
            "ok": false,
            "stdout": "",
            "stderr": "no supported media app is running",
            "status": 1,
        });
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
    json!({ "ok": true, "stdout": summary, "stderr": "", "status": 0 })
}

async fn status(ctx: &Context) -> Value {
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
    json!({ "ok": true, "stdout": lines.join("\n"), "stderr": "", "status": 0 })
}

fn post_media_key(key_code: i32) -> bool {
    use objc2_app_kit::{NSEvent, NSEventModifierFlags, NSEventType};
    use objc2_core_graphics::{CGEvent, CGEventTapLocation};
    use objc2_foundation::NSPoint;

    // NX_KEYDOWN (0x0A) then NX_KEYUP (0x0B).
    for state in [0x0A, 0x0B] {
        let data1 = ((key_code as isize) << 16) | ((state as isize) << 8);
        let event = NSEvent::otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2(
            NSEventType::SystemDefined,
            NSPoint::new(0.0, 0.0),
            NSEventModifierFlags(0xA00),
            0.0,
            0,
            None,
            8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1,
            -1,
        );
        let Some(event) = event else {
            return false;
        };
        let Some(cg_event) = event.CGEvent() else {
            return false;
        };
        CGEvent::post(CGEventTapLocation::HIDEventTap, Some(&cg_event));
    }
    true
}

fn main() {
    run(Media);
}
