//! The output volume, the audio devices and what the media apps are playing.
//!
//! CoreAudio and the players' scripting stay in the host: this plugin asks
//! for them through `host.audio_devices` and `host.applescript`, and owns the
//! commands, the device matching and the wording. Play, pause and skip are
//! Flash's function-row keys (`key system --key=media_play`).

mod report;

use std::time::Duration;

use flash_plugin::{
    AppleScriptOperation, AudioDirection, CommandRequest, Context, MAX_VOLUME_TICKS, PerformAlert,
    PerformResponse, run,
};

use report::{NowPlaying, Player};

/// How long one player gets to answer. Every player is asked at once and the
/// host counts its own queueing in this, so `media status` answers inside
/// the `perform` deadline even while an Automation prompt waits.
const NOW_PLAYING_TIMEOUT: Duration = Duration::from_secs(8);

/// What a media command asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Command {
    VolumeUp,
    VolumeDown,
    VolumeMute,
    /// List the devices of a direction.
    Devices(AudioDirection),
    /// Make the device whose name or UID is the text the direction's default.
    Select(AudioDirection, String),
    Status,
}

/// The command a request names. Only `audio input` and `audio output` take
/// an argument, `--device`, which the manifest declares as a string: the
/// host holds every invocation to that and hands the name over whole,
/// `Studio Speakers` included.
fn parse(request: &CommandRequest) -> Result<Command, String> {
    let name = request.name();
    let devices = |direction| match request.value("device").map(str::trim) {
        None => Ok(Command::Devices(direction)),
        Some("") => Err(format!("usage: {name} [--device=<name or UID>]")),
        Some(device) => Ok(Command::Select(direction, device.to_string())),
    };
    match name.as_str() {
        "audio input" => devices(AudioDirection::Input),
        "audio output" => devices(AudioDirection::Output),
        "volume up" => Ok(Command::VolumeUp),
        "volume down" => Ok(Command::VolumeDown),
        "volume mute" => Ok(Command::VolumeMute),
        "media status" => Ok(Command::Status),
        _ => Err(format!("unknown command: {name}")),
    }
}

struct Media;

flash_plugin::plugin!(Media);

impl FlashPlugin for Media {
    async fn on_command(&self, ctx: Context, request: CommandRequest) -> PerformResponse {
        let command = match parse(&request) {
            Ok(command) => command,
            Err(usage) => return PerformResponse::fail(usage),
        };
        match perform(&ctx, command, request.count).await {
            Ok(response) => response,
            Err(error) => PerformResponse::fail(error),
        }
    }
}

/// Run `command`. A NORMAL count steps the volume that many ticks; the other
/// commands run once.
async fn perform(ctx: &Context, command: Command, count: u32) -> Result<PerformResponse, String> {
    match command {
        Command::VolumeUp | Command::VolumeDown => {
            let ticks = count.clamp(1, MAX_VOLUME_TICKS) as i32;
            let ticks = if command == Command::VolumeUp {
                ticks
            } else {
                -ticks
            };
            let percent = ctx.step_output_volume(ticks).await?;
            // The alert is the feedback of a change, shown wherever it ran;
            // the line is what `flash volume up` prints.
            Ok(PerformResponse::ok()
                .message(report::volume_line(percent))
                .alert(PerformAlert::value("volume", format!("{percent}%")).widest_value("100%")))
        }
        Command::VolumeMute => {
            ctx.toggle_output_mute().await?;
            Ok(PerformResponse::ok())
        }
        Command::Devices(direction) => {
            let devices = ctx.audio_devices(direction).await?;
            Ok(PerformResponse::ok().message(report::devices(&devices, direction)))
        }
        Command::Select(direction, query) => {
            let devices = ctx.audio_devices(direction).await?;
            let device = report::device_matching(&query, &devices)?;
            ctx.select_audio_device(direction, &device.uid).await?;
            Ok(PerformResponse::ok().message(format!(
                "{} device: {}",
                direction.as_str(),
                device.name
            )))
        }
        Command::Status => Ok(PerformResponse::ok().message(status(ctx).await)),
    }
}

/// What every running player plays, then the volume. A player that does not
/// answer is listed as `unknown`; one that is not running is never asked.
async fn status(ctx: &Context) -> String {
    let running = ctx.running_applications();
    let players = report::running_players(running.iter().map(|app| app.bundle_id.as_str()));
    let asked: Vec<_> = players
        .iter()
        .map(|player| tokio::spawn(now_playing(ctx.clone(), *player)))
        .collect();
    let mut answers = Vec::with_capacity(players.len());
    for (player, answer) in players.into_iter().zip(asked) {
        answers.push((player, answer.await.ok().flatten()));
    }
    report::status(&answers, ctx.output_volume().await.ok())
}

async fn now_playing(ctx: Context, player: Player) -> Option<NowPlaying> {
    let operation = AppleScriptOperation::NowPlaying {
        bundle_id: player.bundle_id.to_string(),
        artist: player.has_artist,
    };
    ctx.applescript(&operation, NOW_PLAYING_TIMEOUT)
        .await
        .ok()
        .and_then(|output| NowPlaying::parse(&output))
}

fn main() {
    run(Media);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::RunningApplication;
    use flash_plugin::testing::Harness;
    use serde_json::{Value, json};

    fn request(words: &str, args: &[&str]) -> CommandRequest {
        let (command, subcommand) = words.split_once(' ').unwrap();
        CommandRequest {
            command: command.to_string(),
            subcommand: subcommand.to_string(),
            args: args.iter().map(ToString::to_string).collect(),
            ..CommandRequest::default()
        }
    }

    /// Run `request` against a host that answers each call with the next of
    /// `replies`; the calls it made, then its reply.
    async fn run_command(
        harness: &mut Harness,
        request: CommandRequest,
        replies: &[Value],
    ) -> (Vec<(String, Value)>, Value) {
        let ctx = harness.context();
        let task = tokio::spawn(async move { Media.on_command(ctx, request).await });
        let mut calls = Vec::new();
        for reply in replies {
            let (id, method, params) = harness.next_host_request().await.expect("a host call");
            calls.push((method, params));
            assert!(harness.reply_host(id, reply.clone()));
        }
        let response = serde_json::to_value(task.await.unwrap()).unwrap();
        let unanswered: Vec<Value> = harness
            .drain()
            .into_iter()
            .filter(|frame| frame.get("id").is_some())
            .collect();
        assert_eq!(unanswered, Vec::<Value>::new(), "a call nobody answered");
        (calls, response)
    }

    fn audio(params: Value) -> (String, Value) {
        ("host.audio_devices".to_string(), params)
    }

    fn outputs() -> Value {
        json!({ "ok": true, "devices": [
            { "uid": "usb-1", "name": "USB Audio", "default": true },
            { "uid": "usb-2", "name": "USB Audio", "default": false },
            { "uid": "speakers", "name": "Studio Speakers", "default": false },
        ] })
    }

    #[test]
    fn commands_parse_their_words_and_the_one_argument() {
        let cases = [
            ("volume up", vec![], Command::VolumeUp),
            ("volume down", vec![], Command::VolumeDown),
            ("volume mute", vec![], Command::VolumeMute),
            ("media status", vec![], Command::Status),
            (
                "audio input",
                vec![],
                Command::Devices(AudioDirection::Input),
            ),
            (
                "audio output",
                vec![],
                Command::Devices(AudioDirection::Output),
            ),
            (
                "audio output",
                vec!["--device=speakers"],
                Command::Select(AudioDirection::Output, "speakers".to_string()),
            ),
            // The host hands a name over as one argument, whatever words
            // it holds.
            (
                "audio input",
                vec!["--device=Studio Microphone"],
                Command::Select(AudioDirection::Input, "Studio Microphone".to_string()),
            ),
        ];
        for (words, args, command) in cases {
            assert_eq!(
                parse(&request(words, &args)),
                Ok(command),
                "{words} {args:?}"
            );
        }
    }

    /// The host holds `--device` to its declaration; a blank name still
    /// selects nothing here, and an unknown pair names no command.
    #[test]
    fn a_blank_device_and_unknown_words_are_refused() {
        let cases = [
            (
                "audio output",
                vec!["--device="],
                "usage: audio output [--device=<name or UID>]",
            ),
            (
                "audio input",
                vec!["--device= "],
                "usage: audio input [--device=<name or UID>]",
            ),
            (
                "media volumedown",
                vec![],
                "unknown command: media volumedown",
            ),
            ("media toggle", vec![], "unknown command: media toggle"),
        ];
        for (words, args, usage) in cases {
            assert_eq!(
                parse(&request(words, &args)),
                Err(usage.to_string()),
                "{words} {args:?}"
            );
        }
    }

    /// The manifest declares what `parse` reads: `--device` on the two
    /// `audio` commands and no argument anywhere else.
    #[test]
    fn the_manifest_declares_the_device_the_commands_read() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        for command in manifest["commands"].as_array().unwrap() {
            let args = &command["args"];
            if command["command"] == "audio" {
                assert_eq!(args.as_array().map(Vec::len), Some(1), "{command}");
                assert_eq!(args[0]["name"], "device");
                assert_eq!(args[0]["type"], "string");
                assert_eq!(args[0].get("required"), None, "without it, the list");
            } else {
                assert_eq!(args, &Value::Null, "{command}");
            }
        }
    }

    #[tokio::test]
    async fn a_refused_command_reaches_no_device() {
        let mut harness = Harness::new("media");
        let (calls, response) =
            run_command(&mut harness, request("audio output", &["--device="]), &[]).await;
        assert_eq!(calls, []);
        assert_eq!(
            response,
            json!({ "ok": false, "error": "usage: audio output [--device=<name or UID>]" })
        );
    }

    #[tokio::test]
    async fn a_volume_step_shows_the_percent_and_follows_the_count() {
        let mut harness = Harness::new("media");
        let (calls, response) = run_command(
            &mut harness,
            request("volume up", &[]),
            &[json!({ "ok": true, "percent": 56 })],
        )
        .await;
        assert_eq!(
            calls,
            [audio(json!({ "operation": "step_volume", "ticks": 1 }))]
        );
        assert_eq!(
            response,
            json!({ "ok": true, "message": "volume 56%", "alert": {
                "title": "volume", "value": "56%", "widest_value": "100%"
            } })
        );

        // `3` then the key is one step of three ticks, and one alert.
        let down = CommandRequest {
            count: 3,
            ..request("volume down", &[])
        };
        let (calls, response) =
            run_command(&mut harness, down, &[json!({ "ok": true, "percent": 38 })]).await;
        assert_eq!(
            calls,
            [audio(json!({ "operation": "step_volume", "ticks": -3 }))]
        );
        assert_eq!(response["message"], "volume 38%");
        assert_eq!(response["alert"]["value"], "38%");

        // The whole scale at most.
        let far = CommandRequest {
            count: 40,
            ..request("volume up", &[])
        };
        let (calls, _) =
            run_command(&mut harness, far, &[json!({ "ok": true, "percent": 100 })]).await;
        assert_eq!(
            calls,
            [audio(json!({ "operation": "step_volume", "ticks": 16 }))]
        );
    }

    #[tokio::test]
    async fn a_mute_toggle_shows_nothing_and_ignores_the_count() {
        let mut harness = Harness::new("media");
        let mute = CommandRequest {
            count: 4,
            ..request("volume mute", &[])
        };
        let (calls, response) =
            run_command(&mut harness, mute, &[json!({ "ok": true, "muted": true })]).await;
        assert_eq!(calls, [audio(json!({ "operation": "toggle_mute" }))]);
        assert_eq!(response, json!({ "ok": true }));
    }

    #[tokio::test]
    async fn a_host_failure_is_the_commands_error() {
        let mut harness = Harness::new("media");
        let unsupported =
            json!({ "ok": false, "error": "audio device does not support output volume" });
        let (_, response) =
            run_command(&mut harness, request("volume up", &[]), &[unsupported]).await;
        assert_eq!(
            response,
            json!({ "ok": false, "error": "audio device does not support output volume" })
        );
        let denied = json!({ "ok": false, "error": "missing audio_devices capability" });
        let (_, response) = run_command(&mut harness, request("audio input", &[]), &[denied]).await;
        assert_eq!(response["error"], "missing audio_devices capability");
    }

    #[tokio::test]
    async fn devices_list_and_select_by_uid_or_unique_name() {
        let mut harness = Harness::new("media");
        let list = audio(json!({ "operation": "list", "direction": "output" }));
        let (calls, response) =
            run_command(&mut harness, request("audio output", &[]), &[outputs()]).await;
        assert_eq!(calls, std::slice::from_ref(&list));
        assert_eq!(
            response,
            json!({ "ok": true, "message":
                "* USB Audio [usb-1]\n  USB Audio [usb-2]\n  Studio Speakers [speakers]" })
        );

        let (calls, response) = run_command(
            &mut harness,
            request("audio input", &[]),
            &[json!({ "ok": true, "devices": [] })],
        )
        .await;
        assert_eq!(
            calls,
            [audio(json!({ "operation": "list", "direction": "input" }))]
        );
        assert_eq!(response["message"], "no audio input devices");

        for (query, uid, name) in [
            ("Studio Speakers", "speakers", "Studio Speakers"),
            ("usb-2", "usb-2", "USB Audio"),
        ] {
            let select = request("audio output", &[&format!("--device={query}")]);
            let (calls, response) =
                run_command(&mut harness, select, &[outputs(), json!({ "ok": true })]).await;
            assert_eq!(
                calls,
                [
                    list.clone(),
                    audio(json!({ "operation": "select", "direction": "output", "uid": uid })),
                ]
            );
            assert_eq!(
                response,
                json!({ "ok": true, "message": format!("output device: {name}") })
            );
        }
    }

    #[tokio::test]
    async fn a_failed_match_selects_nothing() {
        let mut harness = Harness::new("media");
        for (query, error) in [
            (
                "USB Audio",
                "audio device name is ambiguous, use its UID: USB Audio",
            ),
            ("missing", "audio device not found: missing"),
        ] {
            let select = request("audio output", &[&format!("--device={query}")]);
            let (calls, response) = run_command(&mut harness, select, &[outputs()]).await;
            assert_eq!(calls.len(), 1, "the list alone");
            assert_eq!(response, json!({ "ok": false, "error": error }));
        }
        // The host refusing the selection is the command's failure.
        let select = request("audio output", &["--device=speakers"]);
        let gone = json!({ "ok": false, "error": "audio device unavailable: speakers" });
        let (_, response) = run_command(&mut harness, select, &[outputs(), gone]).await;
        assert_eq!(response["error"], "audio device unavailable: speakers");
    }

    fn app(bundle_id: &str) -> RunningApplication {
        RunningApplication {
            bundle_id: bundle_id.to_string(),
            pid: 1,
            localized_name: String::new(),
        }
    }

    /// Answer the status command's host calls, whatever order the players
    /// are asked in: each player by `answer`, then the volume.
    async fn run_status(
        harness: &mut Harness,
        calls: usize,
        answer: impl Fn(&Value) -> Value,
    ) -> (Vec<Value>, Value) {
        let ctx = harness.context();
        let task =
            tokio::spawn(async move { Media.on_command(ctx, request("media status", &[])).await });
        let mut asked = Vec::new();
        for _ in 0..calls {
            let (id, method, params) = harness.next_host_request().await.expect("a host call");
            let reply = if method == "host.applescript" {
                asked.push(params.clone());
                answer(&params)
            } else {
                assert_eq!(
                    (method.as_str(), &params),
                    ("host.audio_devices", &json!({ "operation": "volume" }))
                );
                json!({ "ok": true, "percent": 31, "muted": true })
            };
            assert!(harness.reply_host(id, reply));
        }
        (asked, serde_json::to_value(task.await.unwrap()).unwrap())
    }

    /// Only a running player is asked, so `media status` never launches one.
    #[tokio::test]
    async fn status_asks_only_the_running_players_and_reports_the_volume() {
        let mut harness = Harness::new("media");
        harness.set_running_applications(vec![
            app("com.apple.Music"),
            app("com.spotify.client"),
            app("com.apple.Safari"),
        ]);
        let (mut asked, response) = run_status(&mut harness, 3, |params| {
            if params["bundle_id"] == "com.spotify.client" {
                json!({ "ok": true, "result": "playing\nOne More Time — Daft Punk" })
            } else {
                json!({ "ok": true, "result": "paused" })
            }
        })
        .await;
        assert_eq!(
            response,
            json!({ "ok": true, "message":
                "Spotify [playing]: One More Time — Daft Punk\nMusic [paused]\nvolume 31% (muted)" })
        );
        asked.sort_by_key(|params| params["bundle_id"].as_str().map(str::to_string));
        assert_eq!(
            asked,
            [
                json!({ "operation": "now_playing", "bundle_id": "com.apple.Music",
                    "artist": true, "timeout_ms": 8000 }),
                json!({ "operation": "now_playing", "bundle_id": "com.spotify.client",
                    "artist": true, "timeout_ms": 8000 }),
            ]
        );
    }

    #[tokio::test]
    async fn a_player_that_does_not_answer_is_unknown() {
        let mut harness = Harness::new("media");
        harness.set_running_applications(vec![app("com.apple.TV"), app("com.apple.podcasts")]);
        let (asked, response) = run_status(&mut harness, 3, |params| {
            if params["bundle_id"] == "com.apple.TV" {
                json!({ "ok": false, "error": "execution error: not authorized (-1743)",
                    "status": 1 })
            } else {
                // It quit since it was listed: the template answers nothing.
                json!({ "ok": true, "result": "" })
            }
        })
        .await;
        assert_eq!(
            response["message"],
            "TV [unknown]\nPodcasts [unknown]\nvolume 31% (muted)"
        );
        assert!(asked.iter().all(|params| params["artist"] == false));
    }

    #[tokio::test]
    async fn status_without_a_player_asks_no_app() {
        let mut harness = Harness::new("media");
        harness.set_running_applications(vec![app("com.apple.Safari")]);
        let (asked, response) = run_status(&mut harness, 1, |_| unreachable!()).await;
        assert_eq!(asked, Vec::<Value>::new());
        assert_eq!(
            response["message"],
            "no media app is running\nvolume 31% (muted)"
        );
    }

    /// The players the plugin may ask are exactly the manifest's Apple
    /// Events targets.
    #[test]
    fn the_players_are_the_manifests_apple_events_targets() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        let players: Vec<&str> = report::PLAYERS.iter().map(|p| p.bundle_id).collect();
        assert_eq!(manifest["apple_events_targets"], json!(players));
    }
}
