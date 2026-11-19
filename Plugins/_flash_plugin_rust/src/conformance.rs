//! The frame-level conformance corpus, read from the SDK's side.
//!
//! `conformance/host-frames.ndjson` holds frames the host sends and
//! `conformance/plugin-frames.ndjson` frames a plugin sends; the format and
//! the fixture they describe are in `conformance/README.md`. The host's
//! `PluginSchemaTests` reads the same two files. Here every host frame goes
//! through the SDK's real serve loop and decoders, and the SDK's real
//! encoders must write the plugin frames the corpus shows.

use std::collections::{BTreeMap, BTreeSet};
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use crate::runtime::decode_event;
use crate::status::{Preview, StatusCarousel, StatusSegment, StatusValue};
use crate::testing::{Harness, WireHarness};
use crate::{
    AppleScriptOperation, AudioDirection, Candidate, Context, EvaluateRequest, EvaluateResponse,
    Frame, HintsRequest, HintsResponse, JumpTarget, Perform, PerformResponse, Plugin, PollPriority,
    Priority, QueryAnswer, SearchRequest, SearchResponse, TextGridLine, TextGridRequest,
    TextGridResponse,
};

const HOST_FRAMES: &str = include_str!("../conformance/host-frames.ndjson");
const PLUGIN_FRAMES: &str = include_str!("../conformance/plugin-frames.ndjson");

struct Line {
    name: String,
    accept: bool,
    reply_to: Option<String>,
    reply: Option<String>,
    /// The frame's bytes exactly as the corpus spells them.
    raw: &'static str,
    frame: Value,
}

impl Line {
    fn method(&self) -> Option<&str> {
        self.frame.get("method").and_then(Value::as_str)
    }
}

fn corpus(text: &'static str) -> Vec<Line> {
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let entry: Value = serde_json::from_str(line).expect("a corpus line is JSON");
            let field = |key: &str| entry.get(key).and_then(Value::as_str).map(str::to_string);
            let name = field("name").expect("a corpus line is named");
            let (_, rest) = line
                .split_once(", \"frame\": ")
                .unwrap_or_else(|| panic!("{name}: `frame` comes last"));
            Line {
                accept: match entry["expect"].as_str() {
                    Some("accept") => true,
                    Some("reject") => false,
                    other => panic!("{name}: expect is {other:?}"),
                },
                reply_to: field("reply_to"),
                reply: field("reply"),
                raw: rest.strip_suffix('}').expect("a corpus line is one object"),
                frame: entry["frame"].clone(),
                name,
            }
        })
        .collect()
}

fn named<'a>(lines: &'a [Line], name: &str) -> &'a Line {
    lines
        .iter()
        .find(|line| line.name == name)
        .unwrap_or_else(|| panic!("no corpus line named {name}"))
}

/// The window every spatial request and command context of the corpus names.
fn fixture_window() -> Frame {
    Frame::new(0.0, 25.0, 1440.0, 875.0)
}

/// The rows of the `publish` line; the first is the row `perform.resolve`
/// hands back.
fn fixture_rows() -> Vec<Candidate> {
    vec![
        Candidate::new("example.items", "Example row")
            .url("https://example.com/a")
            .subtitle("First")
            .copy_text("Example row"),
        Candidate::new("example.items", "Open the site").open_url_effect("https://example.com/"),
        Candidate::new("example.tabs", "Open the app").open_app_effect("com.example.app"),
        Candidate::new("example.items", "Insert").insert_text("inserted"),
        Candidate::new("example.items", "Bare"),
    ]
}

/// The row of the `publish.confirm` line, which `perform.resolve.confirmed`
/// hands back once the user answered its question.
fn confirming_row() -> Candidate {
    Candidate::new("example.items", "Restart").confirm("Restart this Mac?")
}

/// The plugin the corpus describes. A handler answers with the reply the
/// corpus names only for the request it shows, so a field the SDK decoded
/// differently surfaces as a different reply.
#[derive(Default)]
struct Fixture {
    /// The handlers that ran, in order.
    handled: Arc<Mutex<Vec<&'static str>>>,
}

impl Fixture {
    fn ran(&self, handler: &'static str) {
        self.handled.lock().unwrap().push(handler);
    }

    fn focused(bundle_id: Option<&str>, pid: Option<i64>, window: Option<Frame>) -> bool {
        bundle_id == Some("com.example.app") && pid == Some(512) && window == Some(fixture_window())
    }
}

impl Plugin for Fixture {
    fn evaluate(&self, request: EvaluateRequest) -> EvaluateResponse {
        self.ran("evaluate");
        if request.query == "2+2" {
            return EvaluateResponse::answers(vec![QueryAnswer::copy_text("4", Some("2+2"))]);
        }
        EvaluateResponse::default()
    }

    async fn on_hints(&self, _: Context, request: HintsRequest) -> HintsResponse {
        self.ran("hints");
        if !Self::focused(
            request.bundle_id.as_deref(),
            request.pid,
            request.front_window_frame,
        ) || request.display_scale.is_some_and(|scale| scale != 2.0)
        {
            return HintsResponse::default();
        }
        HintsResponse::targets(vec![
            JumpTarget::new("pane-1", Frame::new(10.0, 20.0, 300.0, 200.0))
                .role("AXButton")
                .label("Build")
                .url("https://example.com/a")
                .context_id("window-1")
                .pid(512)
                .priority(Priority::High),
            JumpTarget::new("pane-2", Frame::new(320.0, 20.0, 300.0, 200.0)),
        ])
        .context_pid(512)
    }

    async fn on_text_grid(&self, _: Context, request: TextGridRequest) -> TextGridResponse {
        self.ran("text_grid");
        if !Self::focused(
            request.bundle_id.as_deref(),
            request.pid,
            request.front_window_frame,
        ) || request.display_scale != Some(2.0)
        {
            return TextGridResponse::default();
        }
        TextGridResponse::new(
            80,
            24,
            vec![
                TextGridLine::text(0, 0, "$ cargo test"),
                TextGridLine::format(23, 0, 80, "#[align=right]main"),
            ],
        )
        .cell(crate::TextGridCell {
            width: 9.0,
            height: 18.0,
            pad_x: 0.0,
            pad_y: 5.5,
        })
    }

    async fn on_search(&self, _: Context, request: SearchRequest) -> SearchResponse {
        self.ran("search");
        if request.source != "example.live" || request.query != "ro" {
            return SearchResponse::default();
        }
        SearchResponse::rows(vec![
            Candidate::new("example.live", "Live row")
                .url("https://example.com/a")
                .subtitle("First"),
            Candidate::new("example.live", "Open the site").open_url_effect("https://example.com/"),
        ])
    }

    async fn perform(&self, ctx: Context, request: Perform) -> PerformResponse {
        self.ran("perform");
        match request {
            Perform::Resolve(row) if row == fixture_rows()[0] || row == confirming_row() => {
                PerformResponse::ok()
            }
            Perform::Resolve(_) => PerformResponse::fail("unexpected row"),
            Perform::Navigate(route) => PerformResponse::ok().navigation_url(route.url),
            Perform::Command(command) => match command.name().as_str() {
                "tab next" => {
                    let focused = command.context.as_ref().is_some_and(|context| {
                        Self::focused(
                            context.bundle_id.as_deref(),
                            context.pid,
                            context.front_window_frame,
                        )
                    });
                    if !focused || command.index() != Some(3) {
                        return PerformResponse::fail("unexpected command");
                    }
                    PerformResponse::ok()
                        .target_pid(512)
                        .navigation_url("https://example.com/a")
                        .message("Done")
                        .alert(crate::PerformAlert::value("volume", "38%").widest_value("100%"))
                }
                "example decline" if command.context.is_none() => PerformResponse::unhandled(),
                "example break" => PerformResponse::fail("example failed"),
                "example repeat" => PerformResponse::ok().message(command.count.to_string()),
                "example confirm" => PerformResponse::ok().message(if command.confirmed {
                    "confirmed"
                } else {
                    "unconfirmed"
                }),
                // Call the host RPC the first argument names and hand back
                // what the SDK made of the host's reply.
                "example call" => {
                    let taken = ctx.call_host(&command.query(), json!({})).await;
                    PerformResponse::ok().message(taken.to_string())
                }
                _ => PerformResponse::fail("unexpected command"),
            },
        }
    }
}

/// A host request reaches its handler exactly when the corpus accepts it,
/// and the whole reply frame is the plugin frame the line names. A rejected
/// request is answered with a failure, or — an id the SDK cannot answer —
/// with nothing at all.
#[tokio::test]
async fn the_sdk_answers_each_host_request_as_the_corpus_says() {
    let plugin_frames = corpus(PLUGIN_FRAMES);
    let host_frames = corpus(HOST_FRAMES);
    let requests = host_frames
        .iter()
        .filter(|line| line.method().is_some_and(|method| method != "event"));
    for line in requests {
        let method = line.method().unwrap();
        let fixture = Fixture::default();
        let handled = fixture.handled.clone();
        let mut wire = WireHarness::new(fixture);
        wire.send_raw(format!("{}\n", line.raw).as_bytes()).await;
        match &line.reply {
            Some(reply) => {
                let expected = named(&plugin_frames, reply);
                assert!(expected.accept, "{}: {reply} is a frame", line.name);
                if let Some(answered) = &expected.reply_to {
                    assert_eq!(answered, method, "{}: {reply}", line.name);
                }
                assert_eq!(wire.recv().await, expected.frame, "{}", line.name);
                if !line.accept {
                    assert_eq!(expected.frame["result"]["ok"], false, "{}", line.name);
                }
            }
            None => {
                assert!(
                    !line.accept,
                    "{}: an accepted request names its reply",
                    line.name
                );
                wire.send(json!({ "id": 77, "method": "ping", "params": {} }))
                    .await;
                assert_eq!(
                    wire.recv().await,
                    json!({ "id": 77, "result": { "ok": true } }),
                    "{}: nothing answers it",
                    line.name
                );
            }
        }
        let expected: &[&str] = match method {
            "evaluate" if line.accept => &["evaluate"],
            "hints" if line.accept => &["hints"],
            "text_grid" if line.accept => &["text_grid"],
            "search" if line.accept => &["search"],
            "perform" if line.accept => &["perform"],
            _ => &[],
        };
        assert_eq!(*handled.lock().unwrap(), expected, "{}", line.name);
    }

    let answered: BTreeSet<&str> = host_frames
        .iter()
        .filter(|line| line.accept && line.reply.is_some())
        .filter_map(Line::method)
        .collect();
    let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
    for method in contract["methods"]["host_to_plugin"]
        .as_object()
        .unwrap()
        .keys()
        .filter(|method| *method != "event")
    {
        assert!(answered.contains(method.as_str()), "{method} has no line");
    }
}

#[test]
fn the_sdk_decodes_each_host_event_as_the_corpus_says() {
    let host_frames = corpus(HOST_FRAMES);
    let params = |line: &Line| {
        line.frame
            .get("params")
            .cloned()
            .unwrap_or_else(|| json!({}))
    };
    for line in host_frames
        .iter()
        .filter(|line| line.method() == Some("event"))
    {
        let decoded = decode_event(params(line));
        assert_eq!(decoded.is_ok(), line.accept, "{}", line.name);
        if let Ok(inbound) = decoded {
            assert_eq!(
                json!(inbound.event.name),
                line.frame["params"]["name"],
                "{}",
                line.name
            );
        }
    }

    let decoded = |name: &str| {
        decode_event(params(named(&host_frames, name)))
            .unwrap_or_else(|error| panic!("{name}: {error}"))
    };
    let apps: Vec<(String, i64, String)> = decoded("event.apps-changed")
        .running_applications
        .into_iter()
        .map(|app| (app.bundle_id, app.pid, app.localized_name))
        .collect();
    assert_eq!(
        apps,
        [
            ("com.example.app".to_string(), 512, "Example".to_string()),
            ("com.example.other".to_string(), 640, "Other".to_string()),
        ]
    );
    let focus = decoded("event.focus-changed").event;
    assert_eq!(
        (focus.bundle_id.as_deref(), focus.pid),
        (Some("com.example.app"), Some(512))
    );
    let change = decoded("event.ax-changed").event;
    assert_eq!(
        (change.pid, change.notification.as_deref()),
        (Some(512), Some("AXValueChanged"))
    );
    assert_eq!(
        decoded("event.status-observed").event.segments,
        Some(vec!["summary".to_string(), "feed".to_string()])
    );
}

/// A host reply the corpus accepts reaches the caller as written; one it
/// rejects reaches it as the invalid-response sentinel.
#[tokio::test]
async fn the_sdk_takes_each_host_reply_as_the_corpus_says() {
    let host_frames = corpus(HOST_FRAMES);
    for line in host_frames.iter().filter(|line| line.method().is_none()) {
        let method = line.reply_to.as_deref().unwrap_or("host.teleport");
        let mut wire = WireHarness::new(Fixture::default());
        wire.send(json!({ "id": 6, "method": "perform", "params": {
            "kind": "command", "command": "example", "subcommand": "call", "args": [method]
        }}))
        .await;
        assert_eq!(
            wire.recv().await,
            json!({ "id": 1, "method": method, "params": {} }),
            "{}",
            line.name
        );
        wire.send_raw(format!("{}\n", line.raw).as_bytes()).await;
        let reply = wire.recv_response(6).await;
        let taken: Value = serde_json::from_str(reply["message"].as_str().unwrap_or_default())
            .unwrap_or_else(|_| panic!("{}: {reply}", line.name));
        let expected = if line.accept {
            line.frame["result"].clone()
        } else {
            json!({ "ok": false, "error": "invalid host response" })
        };
        assert_eq!(taken, expected, "{}", line.name);
    }
}

/// The frames `emit` writes through a fresh `example` context.
fn notifications(emit: impl FnOnce(&Context)) -> Vec<Value> {
    let mut harness = Harness::new("example");
    emit(&harness.context());
    harness.drain()
}

fn notification(emit: impl FnOnce(&Context)) -> Value {
    let mut frames = notifications(emit);
    assert_eq!(frames.len(), 1, "{frames:?}");
    frames.remove(0)
}

/// The request frame a host RPC wrapper writes; the call itself is dropped
/// unanswered.
async fn request<F, Fut>(call: F) -> Value
where
    F: FnOnce(Context) -> Fut,
    Fut: Future + Send + 'static,
    Fut::Output: Send + 'static,
{
    let mut harness = Harness::new("example");
    let task = tokio::spawn(call(harness.context()));
    let frame = harness
        .next_frame()
        .await
        .expect("the wrapper writes its request");
    task.abort();
    frame
}

async fn script(operation: AppleScriptOperation) -> Value {
    request(move |ctx| async move { ctx.applescript(&operation, Duration::from_secs(5)).await })
        .await
}

/// Every frame the SDK's own encoders write for the fixture, under the name
/// of the corpus line it must equal.
async fn emitted(plugin_frames: &[Line]) -> Vec<(&'static str, Value)> {
    let safari = || "com.apple.Safari".to_string();
    let fields = |key: &str, value: &str| BTreeMap::from([(key.to_string(), value.to_string())]);
    let params = |name: &str| named(plugin_frames, name).frame["params"].clone();
    let registered = notifications(|ctx| {
        ctx.interval(Duration::from_secs(30), PollPriority::Normal, |_| async {})
            .cancel();
    });
    let traced = crate::trace::scope(Some("k3f9".to_string()), async {
        notification(|ctx| ctx.log_fields("debug", "[plugin] hints served", fields("targets", "2")))
    })
    .await;
    vec![
        ("publish", notification(|ctx| ctx.publish(fixture_rows()))),
        ("publish.empty", notification(|ctx| ctx.publish(Vec::new()))),
        (
            "publish.source",
            notification(|ctx| {
                ctx.publish_source("example.tabs", vec![Candidate::new("example.tabs", "Tab")])
            }),
        ),
        (
            "publish.priority",
            notification(|ctx| {
                ctx.publish(vec![
                    Candidate::new("example.items", "Bare").priority(Priority::Important),
                ])
            }),
        ),
        (
            "publish.confirm",
            notification(|ctx| ctx.publish(vec![confirming_row()])),
        ),
        (
            "status",
            notification(|ctx| {
                let feed = StatusCarousel::new(
                    [StatusValue::text("First"), StatusValue::text("Second")],
                    Duration::from_secs(30),
                )
                .with_prefix("News ");
                ctx.status([
                    ("summary", StatusSegment::from("CPU 12%")),
                    ("feed", StatusSegment::from(feed)),
                ])
            }),
        ),
        (
            "status.preview",
            notification(|ctx| {
                let value = StatusValue::text("CPU").with_preview(Preview::from_markup("body"));
                ctx.status([("summary", value)])
            }),
        ),
        (
            "status.clear",
            notification(|ctx| ctx.status([("summary", "")])),
        ),
        (
            "status.carousel-no-lines",
            notification(|ctx| {
                ctx.status([("feed", StatusCarousel::new([], Duration::from_secs(30)))])
            }),
        ),
        ("poll", registered[0].clone()),
        ("poll.clear", registered[1].clone()),
        (
            "poll.deadline",
            notification(|ctx| {
                ctx.after(Duration::from_millis(250), PollPriority::Low, |_| async {});
            }),
        ),
        (
            "log",
            notification(|ctx| ctx.log_fields("info", "[plugin] refreshed", fields("rows", "12"))),
        ),
        (
            "log.without-fields",
            notification(|ctx| ctx.log("warn", "[plugin] refresh failed")),
        ),
        ("log.trace", traced),
        (
            "host.ping",
            request(|ctx| async move { ctx.ping_host().await }).await,
        ),
        (
            "host.fetch",
            request(|ctx| async move { ctx.fetch("https://api.example.com/v1/items").await }).await,
        ),
        (
            "host.wifi_info",
            request(|ctx| async move { ctx.wifi_ssid(false).await }).await,
        ),
        (
            "host.applescript.browser-tabs",
            script(AppleScriptOperation::BrowserTabs {
                bundle_id: safari(),
            })
            .await,
        ),
        (
            "host.applescript.browser-select",
            script(AppleScriptOperation::BrowserSelect {
                bundle_id: safari(),
                url: Some("https://example.com/a".to_string()),
                title: None,
                window: None,
                tab: None,
            })
            .await,
        ),
        (
            "host.applescript.browser-select.by-position",
            script(AppleScriptOperation::BrowserSelect {
                bundle_id: safari(),
                url: None,
                title: Some("Example".to_string()),
                window: Some(1),
                tab: Some(3),
            })
            .await,
        ),
        (
            "host.applescript.browser-tab-index",
            script(AppleScriptOperation::BrowserTabIndex {
                bundle_id: safari(),
                index: 3,
            })
            .await,
        ),
        (
            "host.applescript.browser-tab-move",
            script(AppleScriptOperation::BrowserTabMove {
                bundle_id: safari(),
                forward: true,
            })
            .await,
        ),
        (
            "host.applescript.shortcuts-list",
            script(AppleScriptOperation::ShortcutsList).await,
        ),
        (
            "host.applescript.shortcut-run",
            script(AppleScriptOperation::ShortcutRun {
                name: "Focus".to_string(),
            })
            .await,
        ),
        (
            "host.applescript.chat-submit",
            script(AppleScriptOperation::ChatSubmit {
                bundle_id: safari(),
            })
            .await,
        ),
        (
            "host.applescript.now-playing",
            script(AppleScriptOperation::NowPlaying {
                bundle_id: "com.apple.Music".to_string(),
                artist: true,
            })
            .await,
        ),
        (
            "host.audio_devices.list",
            request(|ctx| async move { ctx.audio_devices(AudioDirection::Output).await }).await,
        ),
        (
            "host.audio_devices.select",
            request(|ctx| async move {
                ctx.select_audio_device(AudioDirection::Input, "usb-1")
                    .await
            })
            .await,
        ),
        (
            "host.audio_devices.step-volume",
            request(|ctx| async move { ctx.step_output_volume(2).await }).await,
        ),
        (
            "host.audio_devices.toggle-mute",
            request(|ctx| async move { ctx.toggle_output_mute().await }).await,
        ),
        (
            "host.audio_devices.volume",
            request(|ctx| async move { ctx.output_volume().await }).await,
        ),
        (
            "host.normal_mode_target",
            request(|ctx| async move { ctx.normal_mode_target().await }).await,
        ),
        (
            "host.activate",
            request(|ctx| async move { ctx.activate(512).await }).await,
        ),
        (
            "host.open.url",
            request(|ctx| async move { ctx.open_url("https://example.com/a").await }).await,
        ),
        (
            "host.open.app",
            request(|ctx| async move { ctx.open_app("com.example.app").await }).await,
        ),
        // These two wrappers take their params as written; the corpus line
        // supplies them.
        ("host.post_keys", {
            let keys = params("host.post_keys");
            request(|ctx| async move { ctx.post_keys(keys).await }).await
        }),
        ("host.ax_snapshot", {
            let walk = params("host.ax_snapshot");
            request(|ctx| async move { ctx.ax_snapshot(walk).await }).await
        }),
        (
            "host.ax_perform",
            request(|ctx| async move { ctx.ax_perform(7, "AXPress").await }).await,
        ),
        (
            "host.ax_set",
            request(|ctx| async move { ctx.ax_set(7, "AXSelected", true).await }).await,
        ),
        (
            "host.ax_select_child",
            request(|ctx| async move { ctx.ax_select_child(7, 9).await }).await,
        ),
    ]
}

/// The SDK writes the notifications and host requests the corpus accepts,
/// one at least for every method the contract lists.
#[tokio::test]
async fn the_sdk_writes_the_plugin_frames_the_corpus_shows() {
    let plugin_frames = corpus(PLUGIN_FRAMES);
    let mut written = BTreeSet::new();
    for (name, frame) in emitted(&plugin_frames).await {
        let line = named(&plugin_frames, name);
        assert!(line.accept, "{name}: the SDK writes only valid frames");
        assert_eq!(frame, line.frame, "{name}");
        written.insert(
            line.method()
                .expect("a notification or a request")
                .to_string(),
        );
    }
    let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
    let listed: BTreeSet<String> = ["plugin_to_host_notifications", "plugin_to_host_rpcs"]
        .iter()
        .flat_map(|group| contract["methods"][group].as_object().unwrap().keys())
        .cloned()
        .collect();
    assert_eq!(written, listed);
}

/// The SDK's own checks of what it is about to write — a `poll` set, a
/// `hints`, `text_grid` or `perform` reply — take and refuse the frames the
/// corpus says the host does.
#[test]
fn the_sdk_validators_agree_with_the_corpus() {
    for line in corpus(PLUGIN_FRAMES) {
        let keys: BTreeSet<&str> = line
            .frame
            .as_object()
            .map(|frame| frame.keys().map(String::as_str).collect())
            .unwrap_or_default();
        if line.method() == Some("poll") && keys == BTreeSet::from(["method", "params"]) {
            assert_eq!(
                crate::wire::valid_poll(&line.frame["params"]),
                line.accept,
                "{}",
                line.name
            );
        }
        if let Some(method @ ("hints" | "text_grid" | "perform")) = line.reply_to.as_deref() {
            assert_eq!(
                crate::wire::valid_result(method, &line.frame["result"]),
                line.accept,
                "{}",
                line.name
            );
        }
    }
}
