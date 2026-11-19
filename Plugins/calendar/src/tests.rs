//! The plugin against a host played by the tests: a scripted calendar, a
//! clock the test moves, and the deadlines the plugin registers, landed by
//! hand. No test reads a calendar or waits on real time.

use std::collections::BTreeMap;

use flash_plugin::testing::{Harness, WireHarness};
use serde_json::{Value, json};

use super::*;
use crate::agenda::testing::{T0, at};

/// The test's wall clock, in UTC.
#[derive(Clone)]
struct TestClock(Arc<Mutex<f64>>);

impl Clock for TestClock {
    fn now(&self) -> f64 {
        *self.0.lock().unwrap()
    }

    fn utc_offset(&self, _: f64) -> i64 {
        0
    }
}

/// How macOS's prompt goes.
#[derive(Clone, Copy, PartialEq)]
enum Prompt {
    Grants,
    Refuses,
    /// Left open past the caller's wait.
    Unanswered,
}

/// The host, played for the tests.
struct Host {
    harness: Harness,
    clock: TestClock,
    /// What `access` and `list` answer.
    access: &'static str,
    prompt: Prompt,
    events: Vec<Value>,
    truncated: bool,
    /// A failed read's reason.
    failure: Option<&'static str>,
    /// The URL schemes an application is registered for.
    handled: Vec<&'static str>,
    /// Every host call the plugin made, as `(method, params)`.
    calls: Vec<(String, Value)>,
    /// Each `status` notification's segments, in order.
    statuses: Vec<BTreeMap<String, String>>,
    /// The plugin's deadlines as last registered: name to `(seconds,
    /// priority)`.
    deadlines: BTreeMap<String, (f64, String)>,
    logs: Vec<Value>,
}

fn wire_event(title: &str, start: f64, end: f64) -> Value {
    json!({
        "id": format!("{title}@{start}"), "title": title, "start": at(start), "end": at(end),
        "all_day": false, "calendar": "Work", "declined": false, "canceled": false,
    })
}

fn with_link(mut event: Value, link: &str) -> Value {
    event["links"] = json!([link]);
    event
}

impl Host {
    fn new(config: Value) -> (Arc<Calendar>, Self) {
        let clock = TestClock(Arc::new(Mutex::new(T0)));
        let plugin = Arc::new(Calendar::new(Box::new(clock.clone())));
        let host = Self {
            harness: Harness::with_config("calendar", config),
            clock,
            access: "granted",
            prompt: Prompt::Grants,
            events: Vec::new(),
            truncated: false,
            failure: None,
            handled: vec!["https"],
            calls: Vec::new(),
            statuses: Vec::new(),
            deadlines: BTreeMap::new(),
            logs: Vec::new(),
        };
        (plugin, host)
    }

    /// Move the wall clock to `minutes` after 08:00 UTC.
    fn set_time(&self, minutes: f64) {
        *self.clock.0.lock().unwrap() = at(minutes);
    }

    fn answer(&mut self, method: &str, params: &Value) -> Value {
        match (method, params["operation"].as_str()) {
            ("host.calendar_events", Some("list")) => {
                if let Some(reason) = self.failure {
                    return json!({ "ok": false, "error": reason });
                }
                if self.access != "granted" {
                    return json!({ "ok": true, "access": self.access });
                }
                let mut reply = json!({ "ok": true, "access": "granted", "events": self.events });
                if self.truncated {
                    reply["truncated"] = json!(true);
                }
                reply
            }
            ("host.calendar_events", Some("request_access")) => {
                if self.access == "undetermined" {
                    match self.prompt {
                        Prompt::Grants => self.access = "granted",
                        Prompt::Refuses => self.access = "denied",
                        // What the SDK answers a call the host left open.
                        Prompt::Unanswered => {
                            return json!({ "ok": false, "error": "host call timed out" });
                        }
                    }
                }
                json!({ "ok": true, "access": self.access })
            }
            ("host.open", _) => {
                let url = params["url"].as_str().unwrap_or_default();
                let scheme = url.split_once(':').map_or("", |(scheme, _)| scheme);
                if self.handled.contains(&scheme) {
                    json!({ "ok": true, "bundle_id": "com.example.handler" })
                } else if params["if_handled"] == true {
                    json!({ "ok": false, "error": "no application opens the URL" })
                } else {
                    json!({ "ok": false, "error": "open failed" })
                }
            }
            _ => json!({ "ok": false, "error": "not scripted" }),
        }
    }

    /// Run the plugin until it has nothing left to do, answering its host
    /// calls. Deadlines are recorded, never landed: `fire` does that.
    async fn settle(&mut self) {
        let mut quiet = 0;
        while quiet < 20 {
            for _ in 0..8 {
                tokio::task::yield_now().await;
            }
            let frames = self.harness.drain();
            if frames.is_empty() {
                quiet += 1;
                continue;
            }
            quiet = 0;
            for frame in frames {
                let method = frame["method"].as_str().unwrap_or_default().to_string();
                if let Some(id) = frame["id"].as_u64() {
                    let reply = self.answer(&method, &frame["params"]);
                    self.calls.push((method, frame["params"].clone()));
                    assert!(self.harness.reply_host(id, reply));
                    continue;
                }
                match method.as_str() {
                    "status" => self.statuses.push(
                        frame["params"]["segments"]
                            .as_object()
                            .unwrap()
                            .iter()
                            .map(|(name, value)| {
                                (name.clone(), value.as_str().unwrap().to_string())
                            })
                            .collect(),
                    ),
                    "poll" => {
                        self.deadlines = frame["params"]["registrations"]
                            .as_object()
                            .unwrap()
                            .iter()
                            .map(|(name, entry)| {
                                (
                                    name.clone(),
                                    (
                                        entry["after"].as_f64().expect("a one-shot deadline"),
                                        entry["priority"].as_str().unwrap().to_string(),
                                    ),
                                )
                            })
                            .collect();
                    }
                    "log" => self.logs.push(frame["params"].clone()),
                    other => panic!("unexpected frame: {other}"),
                }
            }
        }
    }

    async fn event(&mut self, plugin: &Arc<Calendar>, name: &str, payload: Value) {
        let event = Event {
            name: name.to_string(),
            segments: payload["segments"].as_array().map(|segments| {
                segments
                    .iter()
                    .map(|segment| segment.as_str().unwrap().to_string())
                    .collect()
            }),
            ..Event::default()
        };
        plugin.on_event(self.harness.context(), event).await;
        self.settle().await;
    }

    async fn observe(&mut self, plugin: &Arc<Calendar>, segments: &[&str]) {
        self.event(
            plugin,
            host_events::STATUS_OBSERVED,
            json!({ "segments": segments }),
        )
        .await;
    }

    async fn calendar_changed(&mut self, plugin: &Arc<Calendar>) {
        self.event(plugin, host_events::CALENDAR_CHANGED, json!({}))
            .await;
    }

    async fn command(&mut self, plugin: &Arc<Calendar>, subcommand: &str, args: &[&str]) -> Value {
        let (plugin, ctx) = (plugin.clone(), self.harness.context());
        let request = CommandRequest {
            command: "calendar".to_string(),
            subcommand: subcommand.to_string(),
            args: args.iter().map(ToString::to_string).collect(),
            ..CommandRequest::default()
        };
        let task = tokio::spawn(async move { plugin.on_command(ctx, request).await });
        self.settle().await;
        serde_json::to_value(task.await.unwrap()).unwrap()
    }

    /// The deadline registered at `priority`: its name and its delay.
    fn deadline(&self, priority: &str) -> Option<(String, f64)> {
        let mut matching = self
            .deadlines
            .iter()
            .filter(|(_, (_, registered))| registered == priority);
        let found = matching
            .next()
            .map(|(name, (after, _))| (name.clone(), *after));
        assert!(matching.next().is_none(), "one {priority} deadline at most");
        found
    }

    fn after(&self, priority: &str) -> Option<f64> {
        self.deadline(priority).map(|(_, after)| after)
    }

    /// The host's tick of the deadline registered at `priority`.
    async fn fire(&mut self, priority: &str) {
        let (name, _) = self.deadline(priority).expect("a deadline to land");
        self.deadlines.remove(&name);
        self.harness
            .deliver_poll_tick(&name)
            .expect("the deadline is pending")
            .await
            .unwrap();
        self.settle().await;
    }

    /// The value of `segment` as last published.
    fn value(&self, segment: &str) -> &str {
        self.statuses
            .last()
            .and_then(|segments| segments.get(segment))
            .map_or("", String::as_str)
    }

    fn lists(&self) -> Vec<&Value> {
        self.calls
            .iter()
            .filter(|(_, params)| params["operation"] == "list")
            .map(|(_, params)| params)
            .collect()
    }

    fn asks(&self) -> usize {
        self.calls
            .iter()
            .filter(|(_, params)| params["operation"] == "request_access")
            .count()
    }

    fn opens(&self) -> Vec<Value> {
        self.calls
            .iter()
            .filter(|(method, _)| method == "host.open")
            .map(|(_, params)| params.clone())
            .collect()
    }
}

fn manifest() -> Value {
    serde_json::from_str(include_str!("../manifest.json")).unwrap()
}

// -- The manifest ------------------------------------------------------------

/// The manifest declares exactly what the plugin serves.
#[test]
fn the_manifest_declares_the_values_the_commands_the_settings_and_the_capabilities() {
    let manifest = manifest();
    assert_eq!(manifest["status"], json!(agenda::SEGMENTS));
    assert_eq!(
        manifest["commands"],
        json!([
            {
                "command": "calendar", "subcommand": "join",
                "description": "Open the meeting link of the next or current calendar event"
            },
            {
                "command": "calendar", "subcommand": "next",
                "description": "Show the next calendar event"
            }
        ])
    );
    assert_eq!(
        manifest["listen"],
        json!([host_events::STATUS_OBSERVED, host_events::CALENDAR_CHANGED])
    );
    assert_eq!(manifest["capabilities"], json!(["calendar_events", "open"]));
    assert!(manifest.get("sandbox").is_none(), "the default sandbox");
    let settings = &manifest["settings"];
    let defaults = Settings::default();
    assert_eq!(settings[CALENDARS_SETTING]["type"], "string_array");
    assert_eq!(
        settings[CALENDARS_SETTING]["default"],
        json!(defaults.calendars)
    );
    assert_eq!(
        settings[ALL_DAY_SETTING]["default"],
        json!(defaults.all_day)
    );
    assert_eq!(
        settings[DECLINED_SETTING]["default"],
        json!(defaults.declined)
    );
    let hours = &settings[LOOKAHEAD_HOURS_SETTING];
    assert_eq!(hours["type"], "integer");
    assert_eq!(hours["default"], json!(agenda::LOOKAHEAD_HOURS_DEFAULT));
    assert_eq!(hours["min"], json!(agenda::LOOKAHEAD_HOURS_MIN));
    assert_eq!(hours["max"], json!(agenda::LOOKAHEAD_HOURS_MAX));
    assert_eq!(settings.as_object().unwrap().len(), 4);
    // Twice the widest look-ahead is the widest window the host reads.
    assert_eq!(
        2 * i64::from(agenda::LOOKAHEAD_HOURS_MAX) * 3_600,
        flash_plugin::MAX_CALENDAR_WINDOW_SECONDS
    );
}

#[test]
fn the_settings_are_the_ones_the_host_resolved() {
    let read = |config: Value| settings(&Harness::with_config("calendar", config).context());
    assert_eq!(read(json!({})), Settings::default());
    assert_eq!(
        read(json!({
            "calendars": ["Work", "Family"], "all_day": true, "declined": true,
            "lookahead_hours": 8
        })),
        Settings {
            calendars: vec!["Work".into(), "Family".into()],
            all_day: true,
            declined: true,
            lookahead_hours: 8,
        }
    );
    // The host sends none of these; a value it would is still bounded.
    assert_eq!(read(json!({ "lookahead_hours": 0 })).lookahead_hours, 24);
    assert_eq!(read(json!({ "lookahead_hours": 169 })).lookahead_hours, 24);
    assert_eq!(
        read(json!({ "calendars": "Work" })).calendars,
        Vec::<String>::new()
    );

    let titles = |calendars: &[&str]| {
        calendar_titles(&Settings {
            calendars: calendars.iter().map(ToString::to_string).collect(),
            ..Settings::default()
        })
    };
    assert_eq!(titles(&[]), Some(Vec::new()), "every calendar");
    assert_eq!(titles(&["Work", ""]), Some(vec!["Work".to_string()]));
    assert_eq!(titles(&[""]), None, "no calendar, never every one");
    assert_eq!(
        titles(&["A"; 70]).map(|titles| titles.len()),
        Some(MAX_CALENDARS)
    );
}

// -- Reading -----------------------------------------------------------------

/// Starting does not read: only a surface showing a value, or a command,
/// does. A started plugin says it knows no event.
#[tokio::test]
async fn nothing_is_read_until_a_value_is_shown() {
    let (plugin, mut host) = Host::new(json!({}));
    host.access = "undetermined";
    host.observe(&plugin, &[]).await;
    assert_eq!(host.calls, [], "no read, no prompt");
    assert_eq!(
        host.statuses.len(),
        1,
        "the previous run's values are cleared"
    );
    assert!(host.statuses[0].values().all(String::is_empty));
    let mut names = agenda::SEGMENTS;
    names.sort_unstable();
    assert_eq!(
        host.statuses[0]
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>(),
        names
    );
    assert_eq!(host.deadlines, BTreeMap::new());
    // Nor does a change of a calendar nobody shows.
    host.calendar_changed(&plugin).await;
    assert_eq!(host.calls, []);
}

#[tokio::test]
async fn the_first_shown_value_reads_twice_the_look_ahead_and_publishes() {
    let (plugin, mut host) = Host::new(json!({ "calendars": ["Work"], "lookahead_hours": 2 }));
    let mut holiday = wire_event("Holiday", 0.0, 1_440.0);
    holiday["all_day"] = json!(true);
    host.events = vec![
        holiday,
        with_link(wire_event("Standup", 30.0, 45.0), "https://zoom.us/j/123"),
    ];
    host.observe(&plugin, &["next"]).await;
    assert_eq!(
        host.lists(),
        [&json!({
            "operation": "list", "start": 1_800_000_000i64, "end": 1_800_014_400i64,
            "calendars": ["Work"]
        })]
    );
    assert_eq!(host.asks(), 0);
    assert_eq!(host.statuses.len(), 2, "cleared, then the event");
    assert_eq!(host.value("next"), "Standup in 30m");
    assert_eq!(host.value("next_title"), "Standup");
    assert_eq!(host.value("next_in"), "in 30m");
    assert_eq!(host.value("next_minutes"), "30");
    assert_eq!(host.value("next_start"), "08:30");
    assert_eq!(host.value("next_end"), "08:45");
    assert_eq!(host.value("next_ongoing"), "");
    assert_eq!(host.value("next_link"), "https://zoom.us/j/123");
    // The countdown's next minute, and the next read one look-ahead on.
    assert_eq!(host.after("high"), Some(60.0));
    assert_eq!(host.after("low"), Some(7_200.0));
    assert_eq!(host.deadlines.len(), 2);

    // A command reads again without asking; an unchanged read is not
    // published twice.
    let next = host.command(&plugin, "next", &[]).await;
    assert_eq!(
        next,
        json!({
            "ok": true, "message": "Standup in 30m · 08:30–08:45 · Zoom",
            "alert": { "title": "Standup", "value": "in 30m · 08:30–08:45 · Zoom" }
        })
    );
    assert_eq!(host.lists().len(), 2);
    assert_eq!(host.asks(), 0);
    assert_eq!(host.statuses.len(), 2);
}

/// The values change at instants of their own, and the host's clock is
/// asked for exactly the next one: no cadence, no read.
#[tokio::test]
async fn the_countdown_follows_the_host_clock_to_the_start_the_grace_and_the_end() {
    let (plugin, mut host) = Host::new(json!({}));
    host.events = vec![wire_event("Standup", 12.0, 42.0)];
    host.set_time(0.5);
    host.observe(&plugin, &["next", "next_minutes"]).await;
    assert_eq!(host.value("next"), "Standup in 12m");
    // 11m30s left reads "12m" until 11m are left, 30 s from now.
    assert_eq!(host.after("high"), Some(30.0));

    host.set_time(1.0);
    host.fire("high").await;
    assert_eq!(host.value("next"), "Standup in 11m");
    assert_eq!(host.value("next_minutes"), "11");
    assert_eq!(host.after("high"), Some(60.0));

    // A tick a hair early changes nothing and is armed again at once.
    host.set_time(1.999);
    let published = host.statuses.len();
    host.fire("high").await;
    assert_eq!(host.statuses.len(), published);
    let after = host.after("high").unwrap();
    assert!((after - 0.06).abs() < 1e-6, "{after}");

    host.set_time(12.0);
    host.fire("high").await;
    assert_eq!(host.value("next"), "Standup now");
    assert_eq!(host.value("next_ongoing"), "1");
    assert_eq!(host.value("next_minutes"), "0");
    // Ten minutes of grace.
    assert_eq!(host.after("high"), Some(600.0));

    host.set_time(22.0);
    host.fire("high").await;
    assert_eq!(host.value("next"), "", "past its grace, nothing is next");
    // Its end changes nothing shown, and is the last instant there is.
    assert_eq!(host.after("high"), Some(1_200.0));
    host.set_time(42.0);
    host.fire("high").await;
    assert_eq!(host.after("high"), None);
    assert_eq!(host.lists().len(), 1, "one read served it all");
}

/// The host arms no deadline longer than a day: a later instant is reached
/// a day at a time, and the calendar is read again a day on at the latest.
#[tokio::test]
async fn a_far_instant_is_reached_within_the_hosts_bound() {
    let (plugin, mut host) = Host::new(json!({ "lookahead_hours": 24 }));
    // Read at the edge of the window, 47 hours ahead: it enters the
    // look-ahead in 23 hours.
    host.events = vec![wire_event("Offsite", 47.0 * 60.0, 48.0 * 60.0)];
    host.observe(&plugin, &["next"]).await;
    assert_eq!(host.value("next"), "");
    assert_eq!(host.after("high"), Some(23.0 * 3_600.0));
    assert_eq!(host.after("low"), Some(86_400.0));

    let (plugin, mut host) = Host::new(json!({ "lookahead_hours": 168 }));
    host.events = vec![wire_event(
        "Offsite",
        250.0 * 60.0 * 60.0,
        251.0 * 60.0 * 60.0,
    )];
    host.observe(&plugin, &["next"]).await;
    assert_eq!(host.value("next"), "");
    assert_eq!(host.after("high"), Some(86_400.0), "82 hours, a day first");
    assert_eq!(host.after("low"), Some(86_400.0));
}

// -- Asking ------------------------------------------------------------------

/// Putting a value on a surface is the user's own use: the first read asks
/// macOS when Flash never did, once.
#[tokio::test]
async fn the_first_shown_value_asks_once_then_reads() {
    let (plugin, mut host) = Host::new(json!({}));
    host.access = "undetermined";
    host.events = vec![wire_event("Standup", 30.0, 45.0)];
    host.observe(&plugin, &["next"]).await;
    assert_eq!(
        host.calls
            .iter()
            .map(|(_, params)| params["operation"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["list", "request_access", "list"]
    );
    assert_eq!(host.value("next"), "Standup in 30m");
    host.command(&plugin, "next", &[]).await;
    assert_eq!(host.asks(), 1);
}

#[tokio::test]
async fn a_refused_calendar_stays_empty_and_quiet() {
    let (plugin, mut host) = Host::new(json!({}));
    host.access = "undetermined";
    host.prompt = Prompt::Refuses;
    host.events = vec![wire_event("Standup", 30.0, 45.0)];
    host.observe(&plugin, &["next"]).await;
    assert_eq!(host.asks(), 1);
    assert_eq!(host.statuses.len(), 1, "nothing but the clearing");
    assert_eq!(host.deadlines, BTreeMap::new(), "nothing is planned");
    assert_eq!(
        host.command(&plugin, "join", &[]).await,
        json!({ "ok": false, "error": DENIED_MESSAGE })
    );
    // Refused once, never asked again.
    assert_eq!(host.asks(), 1);
    assert!(
        DENIED_MESSAGE.len() <= ALERT_TITLE_BYTES,
        "it fits the alert"
    );
}

/// A refresh nobody asked for never raises the prompt: a calendar change,
/// or the look-ahead moving on.
#[tokio::test]
async fn a_background_read_never_asks() {
    let (plugin, mut host) = Host::new(json!({}));
    host.access = "undetermined";
    host.prompt = Prompt::Unanswered;
    host.observe(&plugin, &["next"]).await;
    assert_eq!(host.asks(), 1, "the surface's own read asked");
    assert_eq!(host.value("next"), "");

    host.calendar_changed(&plugin).await;
    assert_eq!(host.asks(), 1);
    assert_eq!(host.lists().len(), 2);

    // The user answers the prompt later: the host announces it, and the
    // values follow without another request.
    host.access = "granted";
    host.events = vec![wire_event("Standup", 30.0, 45.0)];
    host.calendar_changed(&plugin).await;
    assert_eq!(host.asks(), 1);
    assert_eq!(host.value("next"), "Standup in 30m");
}

#[tokio::test]
async fn a_command_says_when_the_prompt_is_still_open() {
    let (plugin, mut host) = Host::new(json!({}));
    host.access = "undetermined";
    host.prompt = Prompt::Unanswered;
    assert_eq!(
        host.command(&plugin, "next", &[]).await,
        json!({ "ok": false, "error": UNANSWERED_MESSAGE })
    );
    assert_eq!(host.asks(), 1);
    assert!(
        COMMAND_ASK_TIMEOUT < Duration::from_secs(10),
        "inside the perform deadline"
    );
}

// -- Changes -----------------------------------------------------------------

#[tokio::test]
async fn a_calendar_change_is_read_while_a_value_is_shown() {
    let (plugin, mut host) = Host::new(json!({}));
    host.events = vec![wire_event("Standup", 30.0, 45.0)];
    host.observe(&plugin, &["next"]).await;
    host.events = vec![
        wire_event("Review", 20.0, 50.0),
        wire_event("Standup", 30.0, 45.0),
    ];
    host.calendar_changed(&plugin).await;
    assert_eq!(host.lists().len(), 2);
    assert_eq!(host.value("next"), "Review in 20m");

    // Not shown, a change reads nothing, and the values are cleared for the
    // next surface.
    host.observe(&plugin, &[]).await;
    assert_eq!(host.value("next"), "");
    assert_eq!(host.deadlines, BTreeMap::new(), "nothing stays armed");
    host.calendar_changed(&plugin).await;
    assert_eq!(host.lists().len(), 2);

    // Shown again, it reads afresh.
    host.observe(&plugin, &["next_title"]).await;
    assert_eq!(host.lists().len(), 3);
    assert_eq!(host.value("next_title"), "Review");
}

/// The look-ahead moving on brings in events hours away: the calendar is
/// read again once one look-ahead has passed.
#[tokio::test]
async fn the_calendar_is_read_again_once_a_look_ahead_has_passed() {
    let (plugin, mut host) = Host::new(json!({ "lookahead_hours": 1 }));
    host.observe(&plugin, &["next"]).await;
    assert_eq!(host.after("low"), Some(3_600.0));
    host.set_time(60.0);
    host.events = vec![wire_event("Review", 90.0, 120.0)];
    host.fire("low").await;
    assert_eq!(host.lists().len(), 2);
    assert_eq!(host.lists()[1]["start"], json!(1_800_003_600i64));
    assert_eq!(host.value("next"), "Review in 30m");
    assert_eq!(host.asks(), 0);
}

#[tokio::test]
async fn a_failed_read_keeps_the_last_events_and_is_tried_again() {
    let (plugin, mut host) = Host::new(json!({}));
    host.events = vec![wire_event("Standup", 30.0, 45.0)];
    host.observe(&plugin, &["next"]).await;
    host.failure = Some("boom");
    host.calendar_changed(&plugin).await;
    assert_eq!(host.value("next"), "Standup in 30m");
    assert_eq!(host.after("low"), Some(300.0));
    assert_eq!(host.after("high"), Some(60.0));
    assert_eq!(
        host.logs.last().map(|log| (&log["level"], &log["message"])),
        Some((&json!("warn"), &json!("[calendar] read failed")))
    );
    assert_eq!(
        host.command(&plugin, "next", &[]).await,
        json!({ "ok": false, "error": "Could not read your calendars: boom" })
    );

    host.failure = None;
    host.events = vec![wire_event("Review", 20.0, 50.0)];
    host.fire("low").await;
    assert_eq!(host.value("next"), "Review in 20m");
}

/// A read that finishes after the surface went, or after a later read,
/// shows nothing.
#[tokio::test]
async fn a_stale_read_is_dropped() {
    let (plugin, mut host) = Host::new(json!({}));
    host.observe(&plugin, &["next"]).await;
    let shared = plugin.shared.clone();
    let ctx = host.harness.context();
    let stale = Read::Agenda(Agenda::new(
        vec![event(CalendarEvent {
            id: "E".into(),
            title: "Old".into(),
            start: at(5.0),
            end: at(10.0),
            all_day: false,
            calendar: "Work".into(),
            declined: false,
            canceled: false,
            url: None,
            location: None,
            links: Vec::new(),
        })],
        86_400.0,
    ));
    // Begun first, finished last.
    let (first, generation) = shared.begin_read();
    host.calendar_changed(&plugin).await;
    shared.adopt(&ctx, &stale, first, generation);
    host.settle().await;
    assert_eq!(host.value("next"), "");

    // Begun while shown, finished once the surface went and came back.
    let (serial, generation) = shared.begin_read();
    host.observe(&plugin, &[]).await;
    host.observe(&plugin, &["next"]).await;
    shared.adopt(&ctx, &stale, serial, generation);
    host.settle().await;
    assert_eq!(host.value("next"), "");
    // The same read, in time, is shown.
    let (serial, generation) = shared.begin_read();
    shared.adopt(&ctx, &stale, serial, generation);
    host.settle().await;
    assert_eq!(host.value("next"), "Old in 5m");
}

#[tokio::test]
async fn a_cut_read_is_logged_and_still_shown() {
    let (plugin, mut host) = Host::new(json!({}));
    host.events = vec![wire_event("Standup", 30.0, 45.0)];
    host.truncated = true;
    host.observe(&plugin, &["next"]).await;
    assert_eq!(host.value("next"), "Standup in 30m");
    assert_eq!(host.logs.len(), 1);
    assert_eq!(host.logs[0]["level"], "warn");
}

/// Titles are configured and none is usable: no calendar is read, never
/// every one.
#[tokio::test]
async fn unusable_calendar_titles_read_no_calendar() {
    let (plugin, mut host) = Host::new(json!({ "calendars": [""] }));
    host.events = vec![wire_event("Standup", 30.0, 45.0)];
    host.observe(&plugin, &["next"]).await;
    assert_eq!(host.calls, []);
    assert_eq!(host.value("next"), "");
    assert_eq!(
        host.command(&plugin, "next", &[]).await,
        json!({ "ok": false, "error": "No event in the next 24 hours" })
    );
}

// -- Commands ----------------------------------------------------------------

#[tokio::test]
async fn next_answers_from_a_fresh_read_and_the_values_take_it() {
    let (plugin, mut host) = Host::new(json!({}));
    host.observe(&plugin, &["next"]).await;
    host.events = vec![with_link(
        wire_event("  Weekly\n sync ", 12.0, 42.0),
        "https://meet.google.com/abc-defg-hij",
    )];
    assert_eq!(
        host.command(&plugin, "next", &[]).await,
        json!({
            "ok": true,
            "message": "Weekly sync in 12m · 08:12–08:42 · Google Meet",
            "alert": { "title": "Weekly sync", "value": "in 12m · 08:12–08:42 · Google Meet" }
        })
    );
    assert_eq!(host.value("next"), "Weekly sync in 12m");

    // Not shown anywhere, the command still answers, and publishes nothing.
    let (plugin, mut host) = Host::new(json!({ "lookahead_hours": 1 }));
    host.events = vec![wire_event("Standup", 12.0, 42.0)];
    assert_eq!(
        host.command(&plugin, "next", &[]).await["message"],
        "Standup in 12m · 08:12–08:42"
    );
    assert_eq!(host.statuses, []);
    assert_eq!(host.deadlines, BTreeMap::new());
    host.events = Vec::new();
    assert_eq!(
        host.command(&plugin, "next", &[]).await,
        json!({ "ok": false, "error": "No event in the next hour" })
    );
}

/// The alert's lines are bounded by the host: a long title or meeting host
/// is cut there, and the command's output keeps it whole.
#[tokio::test]
async fn the_alert_fits_the_hosts_bounds() {
    let (plugin, mut host) = Host::new(json!({}));
    let title = "é".repeat(200);
    let mut event = wire_event(&title, 12.0, 42.0);
    event["url"] = json!("https://rooms.a-rather-long-company-name.example.com/standup");
    host.events = vec![event];
    let reply = host.command(&plugin, "next", &[]).await;
    assert_eq!(reply["ok"], true);
    let detail = "in 12m · 08:12–08:42 · rooms.a-rather-long-company-name.example.com";
    assert_eq!(reply["message"], format!("{title} {detail}"));
    let alert_title = reply["alert"]["title"].as_str().unwrap();
    assert_eq!(alert_title, format!("{}…", "é".repeat(126)));
    assert!(alert_title.len() <= ALERT_TITLE_BYTES);
    let value = reply["alert"]["value"].as_str().unwrap();
    assert!(
        value.starts_with("in 12m · 08:12–08:42 · rooms.a-rather-long-"),
        "{value}"
    );
    assert!(value.ends_with('…'), "{value}");
    assert!(value.len() <= ALERT_VALUE_BYTES, "{}", value.len());
    assert!(value.len() > ALERT_VALUE_BYTES - 4, "{}", value.len());
    assert_eq!(fitted("short", 64), "short");
}

#[tokio::test]
async fn join_opens_the_meeting_in_its_app_when_one_handles_it() {
    let (plugin, mut host) = Host::new(json!({}));
    host.events = vec![with_link(
        wire_event("Standup", 2.0, 15.0),
        "https://zoom.us/j/123",
    )];
    host.handled = vec!["https", "zoommtg"];
    assert_eq!(
        host.command(&plugin, "join", &[]).await,
        json!({ "ok": true, "message": "Joining Standup" })
    );
    let app = "zoommtg://zoom.us/join?action=join&confno=123";
    assert_eq!(host.opens(), [json!({ "url": app, "if_handled": true })]);
    let log = host.logs.last().unwrap();
    assert_eq!(log["message"], "[calendar] join");
    assert_eq!(
        log["fields"],
        json!({ "service": "Zoom", "scheme": "zoommtg" })
    );

    // Without the app, the link itself.
    host.handled = vec!["https"];
    host.calls.clear();
    assert_eq!(
        host.command(&plugin, "join", &[]).await["message"],
        "Joining Standup"
    );
    assert_eq!(
        host.opens(),
        [
            json!({ "url": app, "if_handled": true }),
            json!({ "url": "https://zoom.us/j/123" })
        ]
    );
    assert_eq!(
        host.logs.last().unwrap()["fields"],
        json!({ "service": "Zoom", "scheme": "https" })
    );
    // The log never names the event.
    assert!(
        host.logs
            .iter()
            .all(|log| !log.to_string().contains("Standup"))
    );
}

#[tokio::test]
async fn join_says_why_nothing_opened() {
    let (plugin, mut host) = Host::new(json!({}));
    host.events = vec![wire_event("Lunch", 30.0, 90.0)];
    assert_eq!(
        host.command(&plugin, "join", &[]).await,
        json!({ "ok": false, "error": NO_LINK_MESSAGE })
    );
    host.events = Vec::new();
    assert_eq!(
        host.command(&plugin, "join", &[]).await,
        json!({ "ok": false, "error": "No event in the next 24 hours" })
    );
    assert_eq!(host.opens(), Vec::<Value>::new());
    // Nothing opens the link.
    host.events = vec![with_link(
        wire_event("Standup", 2.0, 15.0),
        "https://meet.google.com/abc-defg-hij",
    )];
    host.handled = Vec::new();
    assert_eq!(
        host.command(&plugin, "join", &[]).await,
        json!({ "ok": false, "error": "Could not open the meeting link: open failed" })
    );
    assert_eq!(
        host.opens(),
        [json!({ "url": "https://meet.google.com/abc-defg-hij" })]
    );
}

/// The two commands declare no argument, so the host hands them none; a
/// word the plugin does not serve reads nothing.
#[tokio::test]
async fn an_unknown_command_reads_nothing() {
    let (plugin, mut host) = Host::new(json!({}));
    assert_eq!(
        host.command(&plugin, "agenda", &[]).await,
        json!({ "ok": false, "error": "unknown command: calendar agenda" })
    );
    assert_eq!(host.calls, [], "nothing was read");
}

// -- Over the wire -----------------------------------------------------------

/// Through the generated routing: an observed segment is read and
/// published, a calendar change is read again, and a command is answered.
#[tokio::test]
async fn events_and_commands_reach_their_handlers() {
    /// The next frame that is not a `poll` or a `log`.
    async fn next(wire: &mut WireHarness) -> Value {
        loop {
            let frame = wire.recv().await;
            if frame["method"] != "poll" && frame["method"] != "log" {
                return frame;
            }
        }
    }
    async fn list(wire: &mut WireHarness, events: Value) {
        let call = next(wire).await;
        assert_eq!(call["method"], "host.calendar_events", "{call}");
        assert_eq!(call["params"]["operation"], "list");
        wire.send(json!({ "id": call["id"], "result": {
            "ok": true, "access": "granted", "events": events
        }}))
        .await;
    }

    let clock = TestClock(Arc::new(Mutex::new(T0)));
    let mut wire = WireHarness::new(Calendar::new(Box::new(clock)));
    wire.send(json!({ "id": 1, "method": "initialize", "params": { "protocol_version": 1 } }))
        .await;
    assert_eq!(wire.recv_response(1).await["ok"], true);

    wire.send(json!({ "method": "event", "params": {
        "name": "core:status.observed", "payload": { "segments": ["next"] }
    }}))
    .await;
    let cleared = next(&mut wire).await;
    assert_eq!(cleared["method"], "status");
    assert_eq!(cleared["params"]["segments"]["next"], "");
    list(&mut wire, json!([wire_event("Standup", 12.0, 42.0)])).await;
    let status = next(&mut wire).await;
    assert_eq!(status["method"], "status", "{status}");
    assert_eq!(status["params"]["segments"]["next"], "Standup in 12m");

    wire.send(json!({ "method": "event", "params": {
        "name": "core:calendar.changed", "payload": {}
    }}))
    .await;
    list(&mut wire, json!([wire_event("Review", 5.0, 30.0)])).await;
    assert_eq!(
        next(&mut wire).await["params"]["segments"]["next"],
        "Review in 5m"
    );

    wire.send(json!({ "id": 2, "method": "perform", "params": {
        "kind": "command", "command": "calendar", "subcommand": "next", "args": []
    }}))
    .await;
    list(&mut wire, json!([wire_event("Review", 5.0, 30.0)])).await;
    assert_eq!(
        wire.recv_response(2).await,
        json!({
            "ok": true, "message": "Review in 5m · 08:05–08:30",
            "alert": { "title": "Review", "value": "in 5m · 08:05–08:30" }
        })
    );
    wire.close_stdin().await;
    wire.finished().await;
}
