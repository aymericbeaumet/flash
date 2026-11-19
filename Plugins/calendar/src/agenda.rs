//! Which event is next, what the values say about it, and when they next
//! change. Pure, so the rules are tested without a calendar: every instant
//! is Unix seconds, and the local time comes from the caller.

use flash_plugin::status::Markup;

use crate::links::MeetingLink;

/// An event that began stays next for its first ten minutes, long enough to
/// join it late; then the next one to start takes over.
pub(crate) const GRACE: f64 = 600.0;

pub(crate) const LOOKAHEAD_HOURS_DEFAULT: u32 = 24;
pub(crate) const LOOKAHEAD_HOURS_MIN: u32 = 1;
pub(crate) const LOOKAHEAD_HOURS_MAX: u32 = 168;

/// `[plugins.calendar]`: which events the next-meeting values and the
/// `calendar` commands count, and how far ahead they look.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Settings {
    /// Calendars to read, by the title Calendar shows; empty reads every
    /// event calendar.
    pub(crate) calendars: Vec<String>,
    /// Count all-day events.
    pub(crate) all_day: bool,
    /// Count events the user declined.
    pub(crate) declined: bool,
    /// How far ahead, in hours, the next event may start.
    pub(crate) lookahead_hours: u32,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            calendars: Vec::new(),
            all_day: false,
            declined: false,
            lookahead_hours: LOOKAHEAD_HOURS_DEFAULT,
        }
    }
}

impl Settings {
    pub(crate) fn lookahead(&self) -> f64 {
        f64::from(self.lookahead_hours) * 3_600.0
    }

    /// Whether `event` counts. A cancelled event never does.
    pub(crate) fn admits(&self, event: &Event) -> bool {
        !event.canceled && (self.all_day || !event.all_day) && (self.declined || !event.declined)
    }
}

/// One occurrence of an event, as the host read it.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Event {
    /// The event's identifier and this occurrence's start: a repeating
    /// event's occurrences share the identifier.
    pub(crate) id: String,
    pub(crate) title: String,
    pub(crate) start: f64,
    pub(crate) end: f64,
    pub(crate) all_day: bool,
    /// The user is an attendee who declined it.
    pub(crate) declined: bool,
    pub(crate) canceled: bool,
    /// The meeting link found in its URL, location or notes.
    pub(crate) link: Option<MeetingLink>,
}

impl Event {
    /// The title on one line, untitled events named as Calendar names them.
    pub(crate) fn display_title(&self) -> String {
        let words: Vec<&str> = self.title.split_whitespace().collect();
        if words.is_empty() {
            "New Event".to_string()
        } else {
            words.join(" ")
        }
    }
}

/// The events of one read, in start order, and how far ahead of now an event
/// may start to be next. A read covers twice the look-ahead, and is read
/// again once one look-ahead has passed, so the values never miss an event
/// that entered the look-ahead since.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Agenda {
    pub(crate) events: Vec<Event>,
    pub(crate) lookahead: f64,
}

impl Agenda {
    pub(crate) fn new(mut events: Vec<Event>, lookahead: f64) -> Self {
        events.sort_by(|a, b| {
            a.start
                .total_cmp(&b.start)
                .then(a.end.total_cmp(&b.end))
                .then_with(|| a.id.cmp(&b.id))
        });
        Self { events, lookahead }
    }
}

/// The plugin's status segments: the next event, as text a status format
/// shows. Every one is empty when no event is next.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Values {
    /// `Standup in 12m`, `Standup now`.
    pub(crate) next: String,
    pub(crate) title: String,
    /// `in 12m`, `in 1h 5m`, `now`.
    pub(crate) until: String,
    /// Whole minutes until it starts, rounded up; `0` once it began.
    pub(crate) minutes: String,
    /// `09:30`, local time.
    pub(crate) start: String,
    pub(crate) end: String,
    /// `1` once it began, empty before.
    pub(crate) ongoing: String,
    /// The meeting link as the event writes it; empty without one.
    pub(crate) link: String,
}

/// The manifest's `status` names, in the order [`Values::segments`] lists
/// them.
pub(crate) const SEGMENTS: [&str; 8] = [
    "next",
    "next_title",
    "next_in",
    "next_minutes",
    "next_start",
    "next_end",
    "next_ongoing",
    "next_link",
];

impl Values {
    /// Each segment with its value.
    pub(crate) fn segments(&self) -> [(&'static str, &str); 8] {
        let values = [
            &self.next,
            &self.title,
            &self.until,
            &self.minutes,
            &self.start,
            &self.end,
            &self.ongoing,
            &self.link,
        ];
        std::array::from_fn(|index| (SEGMENTS[index], values[index].as_str()))
    }
}

/// What `calendar join` opens.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum JoinTarget<'a> {
    Join(&'a Event, &'a MeetingLink),
    /// The event it would join has no link.
    NoLink(&'a Event),
    NoEvent,
}

/// The event the values show at `now`: the latest to begin of those that
/// began within [`GRACE`] and have not ended, else the first to begin within
/// the look-ahead. At equal starts one with a meeting link comes first.
pub(crate) fn shown(agenda: &Agenda, now: f64) -> Option<&Event> {
    let begun = agenda
        .events
        .iter()
        .filter(|event| event.start <= now && now < event.end && now < event.start + GRACE)
        .min_by(|a, b| precedes(a, b, true));
    if begun.is_some() {
        return begun;
    }
    let horizon = now + agenda.lookahead;
    agenda
        .events
        .iter()
        .filter(|event| event.start > now && event.start <= horizon)
        .min_by(|a, b| precedes(a, b, false))
}

fn precedes(lhs: &Event, rhs: &Event, latest_first: bool) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    if lhs.start != rhs.start {
        let order = lhs.start.total_cmp(&rhs.start);
        return if latest_first { order.reverse() } else { order };
    }
    match (lhs.link.is_some(), rhs.link.is_some()) {
        (true, false) => return Ordering::Less,
        (false, true) => return Ordering::Greater,
        _ => {}
    }
    lhs.end
        .total_cmp(&rhs.end)
        .then_with(|| lhs.title.cmp(&rhs.title))
        .then_with(|| lhs.id.cmp(&rhs.id))
}

/// Every segment at `now`; `None` when no event is next, so each value is
/// empty. `utc_offset` is the local zone's offset, in seconds, at an
/// instant.
pub(crate) fn values(agenda: &Agenda, now: f64, utc_offset: &dyn Fn(f64) -> i64) -> Option<Values> {
    let event = shown(agenda, now)?;
    let ongoing = event.start <= now;
    let minutes = if ongoing {
        0
    } else {
        minutes_until(event.start, now)
    };
    let until = if ongoing {
        "now".to_string()
    } else {
        format!("in {}", duration(minutes))
    };
    // `#` doubled: a title is text, never a style or a link.
    let title = Markup::text(event.display_title()).into_string();
    Some(Values {
        next: format!("{title} {until}"),
        title,
        until,
        minutes: minutes.to_string(),
        start: clock(event.start, utc_offset),
        end: clock(event.end, utc_offset),
        ongoing: if ongoing { "1" } else { "" }.to_string(),
        link: event
            .link
            .as_ref()
            .map(|link| Markup::text(&link.url).into_string())
            .unwrap_or_default(),
    })
}

/// The first instant after `now` at which a value may change: the next
/// minute of the countdown, or an event starting, ending, leaving its grace
/// or entering the look-ahead. `None` when nothing will.
pub(crate) fn next_change(agenda: &Agenda, now: f64) -> Option<f64> {
    let mut instants: Vec<f64> = Vec::with_capacity(agenda.events.len() * 4 + 1);
    for event in &agenda.events {
        instants.extend([
            event.start - agenda.lookahead,
            event.start,
            event.start + GRACE,
            event.end,
        ]);
    }
    if let Some(event) = shown(agenda, now)
        && event.start > now
    {
        // The countdown shows `ceil(remaining / 60)`: it drops a minute each
        // time the remaining time reaches a whole minute.
        let remaining = (minutes_until(event.start, now) - 1) as f64 * 60.0;
        instants.push(event.start - remaining);
    }
    instants
        .into_iter()
        .filter(|instant| *instant > now)
        .min_by(f64::total_cmp)
}

/// What `calendar join` opens at `now`: the shown event's link once it began
/// or begins within [`GRACE`]; else that of the latest event in progress
/// that has one, for rejoining a meeting; else the shown event's, however
/// far ahead.
pub(crate) fn join_target(agenda: &Agenda, now: f64) -> JoinTarget<'_> {
    let shown = shown(agenda, now);
    if let Some(event) = shown
        && let Some(link) = &event.link
        && event.start <= now + GRACE
    {
        return JoinTarget::Join(event, link);
    }
    let in_progress = || {
        agenda
            .events
            .iter()
            .filter(|event| event.start <= now && now < event.end)
    };
    if let Some(event) = in_progress()
        .filter(|event| event.link.is_some())
        .min_by(|a, b| precedes(a, b, true))
        && let Some(link) = &event.link
    {
        return JoinTarget::Join(event, link);
    }
    if let Some(event) = shown {
        return match &event.link {
            Some(link) => JoinTarget::Join(event, link),
            None => JoinTarget::NoLink(event),
        };
    }
    match in_progress().min_by(|a, b| precedes(a, b, true)) {
        Some(event) => JoinTarget::NoLink(event),
        None => JoinTarget::NoEvent,
    }
}

/// `calendar next`: the shown event's title, and when it is, its times and
/// its meeting service on one line (`in 12m · 09:30–10:00 · Zoom`).
pub(crate) fn summary(
    agenda: &Agenda,
    now: f64,
    utc_offset: &dyn Fn(f64) -> i64,
) -> Option<(String, String)> {
    let event = shown(agenda, now)?;
    let until = if event.start <= now {
        "now".to_string()
    } else {
        format!("in {}", duration(minutes_until(event.start, now)))
    };
    let mut parts = vec![
        until,
        format!(
            "{}–{}",
            clock(event.start, utc_offset),
            clock(event.end, utc_offset)
        ),
    ];
    if let Some(link) = &event.link {
        parts.push(link.service.clone());
    }
    Some((event.display_title(), parts.join(" · ")))
}

/// Whole minutes from `now` until `instant`, rounded up: `1` in the last
/// minute before it.
pub(crate) fn minutes_until(instant: f64, now: f64) -> i64 {
    (((instant - now) / 60.0).ceil() as i64).max(1)
}

/// `12m`, `1h 5m`, `2h`, `1d 3h`.
pub(crate) fn duration(minutes: i64) -> String {
    let hours = minutes / 60;
    if hours == 0 {
        return format!("{minutes}m");
    }
    if hours >= 24 {
        let days = hours / 24;
        return if hours % 24 == 0 {
            format!("{days}d")
        } else {
            format!("{days}d {}h", hours % 24)
        };
    }
    if minutes % 60 == 0 {
        format!("{hours}h")
    } else {
        format!("{hours}h {}m", minutes % 60)
    }
}

/// `HH:mm` in the local zone, from the zone's offset at that instant.
pub(crate) fn clock(instant: f64, utc_offset: &dyn Fn(f64) -> i64) -> String {
    let local = instant.floor() as i64 + utc_offset(instant);
    let seconds = local.rem_euclid(86_400);
    format!("{:02}:{:02}", seconds / 3_600, seconds % 3_600 / 60)
}

/// Why there is nothing to show within `lookahead_hours`.
pub(crate) fn no_event_message(lookahead_hours: u32) -> String {
    if lookahead_hours == 1 {
        "No event in the next hour".to_string()
    } else {
        format!("No event in the next {lookahead_hours} hours")
    }
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;

    /// 2027-01-15 08:00:00 UTC.
    pub(crate) const T0: f64 = 1_800_000_000.0;

    /// `minutes` after 08:00 UTC.
    pub(crate) fn at(minutes: f64) -> f64 {
        T0 + minutes * 60.0
    }

    pub(crate) fn utc(_: f64) -> i64 {
        0
    }

    pub(crate) fn event(title: &str, start: f64, end: f64) -> Event {
        Event {
            id: format!("{title}@{start}"),
            title: title.to_string(),
            start: at(start),
            end: at(end),
            all_day: false,
            declined: false,
            canceled: false,
            link: None,
        }
    }

    pub(crate) fn linked(title: &str, start: f64, end: f64, link: MeetingLink) -> Event {
        Event {
            link: Some(link),
            ..event(title, start, end)
        }
    }

    pub(crate) fn agenda(events: impl IntoIterator<Item = Event>) -> Agenda {
        Agenda::new(events.into_iter().collect(), 86_400.0)
    }
}

#[cfg(test)]
mod tests {
    use super::testing::*;
    use super::*;
    use crate::links::testing::{meet, zoom};

    fn title(event: Option<&Event>) -> Option<&str> {
        event.map(|event| event.title.as_str())
    }

    fn values_at(agenda: &Agenda, minutes: f64) -> Option<Values> {
        values(agenda, at(minutes), &utc)
    }

    // -- Which event is next -------------------------------------------------

    #[test]
    fn the_first_event_to_start_within_the_look_ahead_is_next() {
        let agenda = agenda([
            event("Review", 120.0, 150.0),
            event("Standup", 30.0, 45.0),
            event("Later", 30.0 * 60.0, 30.0 * 60.0 + 30.0),
        ]);
        assert_eq!(title(shown(&agenda, at(0.0))), Some("Standup"));
        assert_eq!(title(shown(&agenda, at(50.0))), Some("Review"));
        // Past the day's events, the next one is more than 24 hours away.
        assert_eq!(shown(&agenda, at(151.0)), None);
        assert_eq!(title(shown(&agenda, at(6.0 * 60.0))), Some("Later"));
        assert_eq!(shown(&testing::agenda([]), at(0.0)), None);
    }

    /// MeetingBar's rule: a meeting that began stays next for ten minutes,
    /// long enough to join late, then the next one takes over.
    #[test]
    fn an_event_that_began_stays_next_for_its_first_ten_minutes() {
        let agenda = agenda([event("Standup", 0.0, 60.0), event("Review", 90.0, 120.0)]);
        assert_eq!(title(shown(&agenda, at(9.9))), Some("Standup"));
        assert_eq!(title(shown(&agenda, at(10.0))), Some("Review"));
        // A short meeting that ended is never next.
        let short = testing::agenda([event("Ping", 0.0, 5.0)]);
        assert_eq!(title(shown(&short, at(4.0))), Some("Ping"));
        assert_eq!(shown(&short, at(5.0)), None);
    }

    #[test]
    fn the_latest_to_begin_wins_and_a_link_breaks_a_tie() {
        let agenda = agenda([event("Focus", 0.0, 480.0), event("Standup", 5.0, 20.0)]);
        assert_eq!(title(shown(&agenda, at(6.0))), Some("Standup"));
        let tie = testing::agenda([
            event("Hold", 30.0, 60.0),
            linked("Call", 30.0, 60.0, zoom()),
        ]);
        assert_eq!(title(shown(&tie, at(0.0))), Some("Call"));
        assert_eq!(title(shown(&tie, at(35.0))), Some("Call"));
    }

    #[test]
    fn settings_drop_cancelled_and_by_default_all_day_and_declined_events() {
        let normal = event("Standup", 0.0, 15.0);
        let all_day = Event {
            all_day: true,
            ..event("Holiday", 0.0, 1_440.0)
        };
        let declined = Event {
            declined: true,
            ..event("Optional", 0.0, 30.0)
        };
        let canceled = Event {
            canceled: true,
            ..event("Gone", 0.0, 30.0)
        };
        let events = [normal, all_day, declined, canceled];
        let admitted = |settings: &Settings| -> Vec<&str> {
            events
                .iter()
                .filter(|event| settings.admits(event))
                .map(|event| event.title.as_str())
                .collect()
        };
        let mut settings = Settings::default();
        assert_eq!(admitted(&settings), ["Standup"]);
        settings.all_day = true;
        settings.declined = true;
        assert_eq!(admitted(&settings), ["Standup", "Holiday", "Optional"]);
        assert_eq!(settings.lookahead(), 86_400.0);
    }

    // -- Values --------------------------------------------------------------

    #[test]
    fn values_count_down_in_whole_minutes_rounded_up() {
        let agenda = agenda([linked("Standup", 12.0, 42.0, meet())]);
        let values = values_at(&agenda, 0.5).unwrap();
        assert_eq!(
            values.segments(),
            [
                ("next", "Standup in 12m"),
                ("next_title", "Standup"),
                ("next_in", "in 12m"),
                ("next_minutes", "12"),
                ("next_start", "08:12"),
                ("next_end", "08:42"),
                ("next_ongoing", ""),
                ("next_link", "https://meet.google.com/abc-defg-hij"),
            ]
        );
        assert_eq!(values_at(&agenda, 11.5).unwrap().next, "Standup in 1m");
        assert_eq!(values_at(&agenda, 0.0).unwrap().minutes, "12");
    }

    #[test]
    fn an_event_in_progress_is_now() {
        let values = values_at(&agenda([event("Standup", 0.0, 15.0)]), 3.0).unwrap();
        assert_eq!(values.next, "Standup now");
        assert_eq!(values.until, "now");
        assert_eq!(values.minutes, "0");
        assert_eq!(values.ongoing, "1");
        assert_eq!(values.link, "");
    }

    #[test]
    fn nothing_next_leaves_every_value_empty() {
        assert_eq!(values_at(&agenda([]), 0.0), None);
        assert_eq!(values_at(&agenda([event("Done", -60.0, -30.0)]), 0.0), None);
        assert!(
            Values::default()
                .segments()
                .iter()
                .all(|(_, value)| value.is_empty())
        );
    }

    /// A title from someone else's invitation is text: never a style, a link
    /// or a click range, and always one line. So is a link's fragment.
    #[test]
    fn a_title_is_text_on_one_line() {
        let agenda = agenda([event("#[range=user|x]1:1\n  #2", 5.0, 10.0)]);
        let values = values_at(&agenda, 0.0).unwrap();
        assert_eq!(values.title, "##[range=user|x]1:1 ##2");
        assert_eq!(values.next, "##[range=user|x]1:1 ##2 in 5m");
        assert_eq!(
            Markup::raw(values.next).plain(),
            "#[range=user|x]1:1 #2 in 5m"
        );
        assert_eq!(event("  ", 0.0, 1.0).display_title(), "New Event");
        let facetime = MeetingLink {
            service: "FaceTime".into(),
            url: "https://facetime.apple.com/join#v=1&p=AbC".into(),
            app_url: None,
        };
        let linked = testing::agenda([linked("Call", 5.0, 10.0, facetime)]);
        let link = values_at(&linked, 0.0).unwrap().link;
        assert_eq!(link, "https://facetime.apple.com/join##v=1&p=AbC");
        assert_eq!(
            Markup::raw(link).plain(),
            "https://facetime.apple.com/join#v=1&p=AbC"
        );
    }

    #[test]
    fn durations_and_clocks() {
        assert_eq!(duration(1), "1m");
        assert_eq!(duration(59), "59m");
        assert_eq!(duration(60), "1h");
        assert_eq!(duration(65), "1h 5m");
        assert_eq!(duration(24 * 60), "1d");
        assert_eq!(duration(27 * 60 + 30), "1d 3h");
        assert_eq!(clock(T0, &utc), "08:00");
        assert_eq!(clock(T0, &|_| 3_600), "09:00");
        // 2026-07-01 23:30 UTC is 01:30 the next day in Paris, in summer
        // time.
        assert_eq!(clock(1_782_948_600.0, &|_| 7_200), "01:30");
        // West of Greenwich, before the day began there.
        assert_eq!(clock(T0, &|_| -10 * 3_600), "22:00");
        assert_eq!(clock(T0 + 59.9, &utc), "08:00");
        assert_eq!(no_event_message(24), "No event in the next 24 hours");
        assert_eq!(no_event_message(1), "No event in the next hour");
    }

    // -- When values change --------------------------------------------------

    /// The values are read at the instant they change, never on a cadence:
    /// the countdown's next minute, then the start, the end of the grace,
    /// the end.
    #[test]
    fn the_next_change_is_the_countdowns_next_minute_or_an_event_boundary() {
        let agenda = agenda([event("Standup", 12.0, 42.0)]);
        // 08:00:30: 11m30s left reads "12m" until 11m left, at 08:01:00.
        assert_eq!(next_change(&agenda, at(0.5)), Some(at(1.0)));
        assert_eq!(next_change(&agenda, at(1.0)), Some(at(2.0)));
        assert_eq!(next_change(&agenda, at(11.2)), Some(at(12.0)));
        assert_eq!(next_change(&agenda, at(12.0)), Some(at(22.0)));
        assert_eq!(next_change(&agenda, at(22.0)), Some(at(42.0)));
        assert_eq!(next_change(&agenda, at(42.0)), None);
        assert_eq!(next_change(&testing::agenda([]), at(0.0)), None);
        // Nothing next: the next change is an event entering the look-ahead.
        let far = testing::agenda([event("Later", 30.0 * 60.0, 31.0 * 60.0)]);
        assert_eq!(next_change(&far, at(0.0)), Some(at(6.0 * 60.0)));
        assert_eq!(values_at(&far, 6.0 * 60.0).unwrap().next, "Later in 1d");
    }

    // -- Joining -------------------------------------------------------------

    #[test]
    fn join_opens_the_event_about_to_start_or_just_started() {
        let agenda = agenda([
            linked("Standup", 0.0, 30.0, zoom()),
            linked("Review", 45.0, 60.0, meet()),
        ]);
        let (standup, review) = (&agenda.events[0], &agenda.events[1]);
        let (zoom, meet) = (zoom(), meet());
        assert_eq!(
            join_target(&agenda, at(-5.0)),
            JoinTarget::Join(standup, &zoom)
        );
        assert_eq!(
            join_target(&agenda, at(5.0)),
            JoinTarget::Join(standup, &zoom)
        );
        // Twenty minutes in, Review is next but forty minutes away: join
        // rejoins the meeting in progress.
        assert_eq!(
            join_target(&agenda, at(20.0)),
            JoinTarget::Join(standup, &zoom)
        );
        // Ten minutes before Review, it is the one to join.
        assert_eq!(
            join_target(&agenda, at(35.0)),
            JoinTarget::Join(review, &meet)
        );
    }

    #[test]
    fn join_falls_back_to_the_next_events_link_and_says_what_is_missing() {
        let later = agenda([linked("Review", 120.0, 150.0, meet())]);
        assert_eq!(
            join_target(&later, at(0.0)),
            JoinTarget::Join(&later.events[0], &meet())
        );
        let lunch = agenda([event("Lunch", 30.0, 90.0)]);
        assert_eq!(
            join_target(&lunch, at(0.0)),
            JoinTarget::NoLink(&lunch.events[0])
        );
        assert_eq!(
            join_target(&lunch, at(60.0)),
            JoinTarget::NoLink(&lunch.events[0])
        );
        assert_eq!(join_target(&agenda([]), at(0.0)), JoinTarget::NoEvent);
    }

    #[test]
    fn next_summarizes_the_shown_event() {
        let agenda = agenda([linked("Standup", 12.0, 42.0, zoom())]);
        assert_eq!(
            summary(&agenda, at(0.0), &utc),
            Some((
                "Standup".to_string(),
                "in 12m · 08:12–08:42 · Zoom".to_string()
            ))
        );
        assert_eq!(
            summary(&agenda, at(13.0), &utc).map(|(_, detail)| detail),
            Some("now · 08:12–08:42 · Zoom".to_string())
        );
        let plain = testing::agenda([event("Lunch", 30.0, 90.0)]);
        assert_eq!(
            summary(&plain, at(0.0), &utc).map(|(_, detail)| detail),
            Some("in 30m · 08:30–09:30".to_string())
        );
        assert_eq!(summary(&testing::agenda([]), at(0.0), &utc), None);
    }
}
