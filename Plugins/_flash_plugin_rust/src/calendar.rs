//! The user's calendar (`host.calendar_events`): EventKit and the Calendars
//! grant stay in the resident, and a plugin holding the `calendar_events`
//! capability reads the access macOS grants Flash, asks for it, and lists
//! the events of a bounded window through these typed calls.
//!
//! macOS names Flash in its prompt. The host shows it only while the user
//! is using the plugin (one of its performs is in flight, or a status
//! surface shows one of its segments), so ask from `on_command` or when
//! `core:status.observed` first lists a segment, never from a background
//! refresh. The same capability delivers `core:calendar.changed`
//! ([`host_events::CALENDAR_CHANGED`](crate::host_events::CALENDAR_CHANGED))
//! when the calendar database changes or the user answers the prompt.
//!
//! An event's notes never cross the wire: a [`CalendarEvent`] carries the
//! link-shaped runs the host found in them.

use std::time::Duration;

use serde_json::{Value, json};

use crate::context::Context;

/// Every `operation` of `host.calendar_events` (`protocol.json`
/// `calendar_events.operations`).
#[cfg(test)]
pub(crate) const OPERATIONS: [&str; 3] = ["access", "request_access", "list"];

/// The longest window one [`Context::calendar_events`] reads, in seconds
/// (`calendar_events.max_window_seconds`): fourteen days.
pub const MAX_CALENDAR_WINDOW_SECONDS: i64 = 1_209_600;
/// The most calendar titles one read names (`calendar_events.max_calendars`).
pub const MAX_CALENDARS: usize = 64;
/// What the host answers a [`Context::request_calendar_access`] that would
/// show macOS's prompt while the user is not using the plugin
/// (`errors.user_request_required`).
pub const USER_REQUEST_REQUIRED_ERROR: &str = "requires the user to be using the plugin";

/// How long a read waits for its reply: EventKit opens its database on the
/// first one.
const LIST_TIMEOUT: Duration = Duration::from_secs(8);

/// What macOS answers about Flash's Calendars grant, without asking.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CalendarAccess {
    Granted,
    /// The user refused, a policy did, or the grant is write-only.
    Denied,
    /// Flash never asked.
    Undetermined,
}

impl CalendarAccess {
    /// In `protocol.json` order.
    pub const ALL: [Self; 3] = [Self::Granted, Self::Denied, Self::Undetermined];

    /// The name on the wire.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Granted => "granted",
            Self::Denied => "denied",
            Self::Undetermined => "undetermined",
        }
    }

    fn from_wire(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|access| access.as_str() == name)
    }
}

/// One occurrence of an event (`protocol.json` `calendar_event`).
#[derive(Clone, Debug, PartialEq)]
pub struct CalendarEvent {
    /// The event's identifier and this occurrence's start: a repeating
    /// event's occurrences share the identifier.
    pub id: String,
    pub title: String,
    /// Unix seconds.
    pub start: f64,
    pub end: f64,
    pub all_day: bool,
    /// The title of the calendar it belongs to.
    pub calendar: String,
    /// The user is an attendee who declined it.
    pub declined: bool,
    pub canceled: bool,
    /// The event's URL field.
    pub url: Option<String>,
    pub location: Option<String>,
    /// The link-shaped runs of the event's notes, in order: a scheme, `:/`
    /// and the characters up to the next whitespace, quote or bracket.
    pub links: Vec<String>,
}

/// What one read of the calendar found.
#[derive(Clone, Debug, PartialEq)]
pub enum CalendarListing {
    /// The events of the window, in start order. `truncated`: the host left
    /// later events out of the reply (`calendar_events.max_events`,
    /// `reply_bytes`).
    Events {
        events: Vec<CalendarEvent>,
        truncated: bool,
    },
    /// macOS grants no access: nothing was read.
    NoAccess(CalendarAccess),
}

/// The host's error, or `fallback` for a failure that carries none.
fn failure(response: &Value, fallback: &str) -> String {
    response
        .get("error")
        .and_then(Value::as_str)
        .filter(|error| !error.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

/// The `access` of any successful reply.
pub(crate) fn access_from_response(response: &Value) -> Result<CalendarAccess, String> {
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(failure(response, "host.calendar_events failed"));
    }
    response
        .get("access")
        .and_then(Value::as_str)
        .and_then(CalendarAccess::from_wire)
        .ok_or_else(|| "host.calendar_events response missing access".to_string())
}

fn event_from_value(value: &Value) -> Option<CalendarEvent> {
    let text = |key: &str| Some(value.get(key)?.as_str()?.to_string());
    let optional = |key: &str| match value.get(key) {
        None | Some(Value::Null) => Some(None),
        Some(text) => Some(Some(text.as_str()?.to_string())),
    };
    let flag = |key: &str| value.get(key)?.as_bool();
    let instant = |key: &str| {
        value
            .get(key)?
            .as_f64()
            .filter(|seconds| seconds.is_finite())
    };
    let links = match value.get("links") {
        None | Some(Value::Null) => Vec::new(),
        Some(links) => links
            .as_array()?
            .iter()
            .map(|link| link.as_str().map(str::to_string))
            .collect::<Option<Vec<_>>>()?,
    };
    Some(CalendarEvent {
        id: text("id")?,
        title: text("title")?,
        start: instant("start")?,
        end: instant("end")?,
        all_day: flag("all_day")?,
        calendar: text("calendar")?,
        declined: flag("declined")?,
        canceled: flag("canceled")?,
        url: optional("url")?,
        location: optional("location")?,
        links,
    })
}

/// A `list` reply; one malformed event refuses them all.
pub(crate) fn listing_from_response(response: &Value) -> Result<CalendarListing, String> {
    let access = access_from_response(response)?;
    if access != CalendarAccess::Granted {
        return Ok(CalendarListing::NoAccess(access));
    }
    let events = response
        .get("events")
        .and_then(Value::as_array)
        .ok_or_else(|| "host.calendar_events response missing events".to_string())?
        .iter()
        .map(event_from_value)
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| "host.calendar_events response has a malformed event".to_string())?;
    Ok(CalendarListing::Events {
        events,
        truncated: response.get("truncated").and_then(Value::as_bool) == Some(true),
    })
}

impl Context {
    /// What macOS answers about Flash's Calendars grant, without asking
    /// (`host.calendar_events` `access`). Requires the `calendar_events`
    /// capability, as every call here does.
    pub async fn calendar_access(&self) -> Result<CalendarAccess, String> {
        let params = json!({ "operation": "access" });
        access_from_response(&self.call_host("host.calendar_events", params).await)
    }

    /// The same, asking macOS first when Flash never asked
    /// (`request_access`): the answer is then `Granted` or `Denied`, once
    /// the user gave it. The host shows the prompt only while the user is
    /// using the plugin and answers [`USER_REQUEST_REQUIRED_ERROR`]
    /// otherwise. A prompt left open longer than `timeout` is the host-call
    /// timeout error; the host sends `core:calendar.changed` when the user
    /// answers, so read again then.
    pub async fn request_calendar_access(
        &self,
        timeout: Duration,
    ) -> Result<CalendarAccess, String> {
        let params = json!({ "operation": "request_access" });
        access_from_response(
            &self
                .call_host_timeout("host.calendar_events", params, timeout)
                .await,
        )
    }

    /// The occurrences overlapping `start..end`, both whole Unix seconds at
    /// most [`MAX_CALENDAR_WINDOW_SECONDS`] apart, in the calendars titled
    /// `calendars` (at most [`MAX_CALENDARS`]; none reads every event
    /// calendar), in start order (`list`). It never asks macOS: without the
    /// grant it answers [`CalendarListing::NoAccess`].
    pub async fn calendar_events(
        &self,
        start: i64,
        end: i64,
        calendars: &[String],
    ) -> Result<CalendarListing, String> {
        let mut params = json!({ "operation": "list", "start": start, "end": end });
        if !calendars.is_empty() {
            params["calendars"] = json!(calendars);
        }
        listing_from_response(
            &self
                .call_host_timeout("host.calendar_events", params, LIST_TIMEOUT)
                .await,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Harness;

    fn standup() -> Value {
        json!({
            "id": "E1@1800000720", "title": "Standup", "start": 1_800_000_720u64,
            "end": 1_800_002_520u64, "all_day": false, "calendar": "Work",
            "declined": false, "canceled": false, "url": "https://example.com/standup",
            "location": "Room 4", "links": ["https://zoom.us/j/123?pwd=abc"],
        })
    }

    #[test]
    fn a_listing_decodes_whole_or_not_at_all() {
        let bare = json!({
            "id": "E2", "title": "Lunch", "start": 1_800_007_200.5, "end": 1_800_010_800u64,
            "all_day": true, "calendar": "Home", "declined": true, "canceled": true,
        });
        let reply = json!({ "ok": true, "access": "granted", "events": [standup(), bare] });
        let CalendarListing::Events { events, truncated } = listing_from_response(&reply).unwrap()
        else {
            panic!("a granted listing");
        };
        assert!(!truncated);
        assert_eq!(
            events[0],
            CalendarEvent {
                id: "E1@1800000720".into(),
                title: "Standup".into(),
                start: 1_800_000_720.0,
                end: 1_800_002_520.0,
                all_day: false,
                calendar: "Work".into(),
                declined: false,
                canceled: false,
                url: Some("https://example.com/standup".into()),
                location: Some("Room 4".into()),
                links: vec!["https://zoom.us/j/123?pwd=abc".into()],
            }
        );
        assert_eq!(events[1].start, 1_800_007_200.5);
        assert!(events[1].all_day && events[1].declined && events[1].canceled);
        assert_eq!(
            (&events[1].url, &events[1].location, events[1].links.len()),
            (&None, &None, 0)
        );
        assert_eq!(
            listing_from_response(
                &json!({ "ok": true, "access": "granted", "events": [], "truncated": true })
            ),
            Ok(CalendarListing::Events {
                events: Vec::new(),
                truncated: true
            })
        );

        let malformed = |change: fn(&mut Value)| {
            let mut event = standup();
            change(&mut event);
            listing_from_response(&json!({ "ok": true, "access": "granted", "events": [event] }))
        };
        for change in [
            (|event| event["id"] = json!(7)) as fn(&mut Value),
            |event| {
                event.as_object_mut().unwrap().remove("title");
            },
            |event| event["start"] = json!("1800000720"),
            |event| event["all_day"] = json!(0),
            |event| event["url"] = json!(["https://example.com/"]),
            |event| event["links"] = json!("https://zoom.us/j/1"),
            |event| event["links"] = json!([1]),
        ] {
            assert_eq!(
                malformed(change),
                Err("host.calendar_events response has a malformed event".to_string())
            );
        }
        assert_eq!(
            listing_from_response(&json!({ "ok": true, "access": "granted" })),
            Err("host.calendar_events response missing events".to_string())
        );
    }

    #[test]
    fn a_reply_without_the_grant_is_the_access_alone() {
        for (name, access) in [
            ("denied", CalendarAccess::Denied),
            ("undetermined", CalendarAccess::Undetermined),
        ] {
            let reply = json!({ "ok": true, "access": name });
            assert_eq!(access_from_response(&reply), Ok(access));
            assert_eq!(
                listing_from_response(&reply),
                Ok(CalendarListing::NoAccess(access))
            );
        }
        assert_eq!(
            access_from_response(&json!({ "ok": true, "access": "granted" })),
            Ok(CalendarAccess::Granted)
        );
        for reply in [
            json!({ "ok": true }),
            json!({ "ok": true, "access": "limited" }),
            json!({ "ok": true, "access": true }),
        ] {
            assert_eq!(
                access_from_response(&reply),
                Err("host.calendar_events response missing access".to_string()),
                "{reply}"
            );
        }
        assert_eq!(
            access_from_response(&json!({ "ok": false, "error": USER_REQUEST_REQUIRED_ERROR })),
            Err(USER_REQUEST_REQUIRED_ERROR.to_string())
        );
        assert_eq!(
            listing_from_response(&json!({ "ok": false })),
            Err("host.calendar_events failed".to_string())
        );
    }

    #[tokio::test]
    async fn a_read_names_its_window_and_its_calendars() {
        let mut harness = Harness::new("calendar");
        for (calendars, sent) in [
            (
                Vec::new(),
                json!({ "operation": "list", "start": 10, "end": 70 }),
            ),
            (
                vec!["Work".to_string(), "Family".to_string()],
                json!({
                    "operation": "list", "start": 10, "end": 70, "calendars": ["Work", "Family"]
                }),
            ),
        ] {
            let ctx = harness.context();
            let task = tokio::spawn(async move { ctx.calendar_events(10, 70, &calendars).await });
            let (id, method, params) = harness.next_host_request().await.unwrap();
            assert_eq!(method, "host.calendar_events");
            assert_eq!(params, sent);
            assert!(harness.reply_host(id, json!({ "ok": true, "access": "denied" })));
            assert_eq!(
                task.await.unwrap(),
                Ok(CalendarListing::NoAccess(CalendarAccess::Denied))
            );
        }
    }

    #[tokio::test]
    async fn a_prompt_left_open_is_the_timeout_error() {
        let mut harness = Harness::new("calendar");
        let ctx = harness.context();
        let task =
            tokio::spawn(
                async move { ctx.request_calendar_access(Duration::from_millis(20)).await },
            );
        let (_, method, params) = harness.next_host_request().await.unwrap();
        assert_eq!(method, "host.calendar_events");
        assert_eq!(params, json!({ "operation": "request_access" }));
        assert_eq!(
            task.await.unwrap(),
            Err(crate::context::HOST_TIMEOUT_ERROR.to_string())
        );
    }

    #[test]
    fn the_calendar_contract_matches_the_shared_protocol() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let calendar = &contract["calendar_events"];
        assert_eq!(calendar["operations"], json!(OPERATIONS));
        let access: Vec<&str> = CalendarAccess::ALL.iter().map(|a| a.as_str()).collect();
        assert_eq!(calendar["access"], json!(access));
        assert_eq!(calendar["max_window_seconds"], MAX_CALENDAR_WINDOW_SECONDS);
        assert_eq!(calendar["max_calendars"], MAX_CALENDARS);
        assert_eq!(
            contract["errors"]["user_request_required"],
            USER_REQUEST_REQUIRED_ERROR
        );
        assert_eq!(
            contract["methods"]["plugin_to_host_rpcs"]["host.calendar_events"],
            "calendar_events"
        );
        assert!(
            contract["capabilities"]
                .as_array()
                .unwrap()
                .contains(&Value::from("calendar_events"))
        );
        // Every key of the event shape is one this decoder reads.
        let mut keys: Vec<String> = ["required", "optional"]
            .iter()
            .flat_map(|group| contract["calendar_event"][group].as_array().unwrap())
            .map(|key| key.as_str().unwrap().to_string())
            .collect();
        keys.sort();
        let mut read: Vec<String> = standup().as_object().unwrap().keys().cloned().collect();
        read.sort();
        assert_eq!(keys, read);
    }
}
