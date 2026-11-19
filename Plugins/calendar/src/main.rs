//! The next meeting: its status values, `calendar join` and `calendar next`.
//!
//! The calendar is the host's: this process is sandboxed and holds no
//! Calendars grant. Under the manifest's `calendar_events` capability it asks
//! Flash for the events of a window (`host.calendar_events`), and Flash
//! tells it when the calendar changed (`core:calendar.changed`). Which event
//! is next, what the values say, when they change and which link joins a
//! meeting are decided here.
//!
//! Events are read only while a status surface shows one of the segments
//! (`core:status.observed`), and for each command. The values change at
//! instants of their own, so the plugin asks the host's clock for exactly
//! the next one; nothing polls.

mod agenda;
mod links;

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use flash_plugin::status::Published;
use flash_plugin::{
    CalendarEvent, CalendarListing, CommandRequest, Context, Deadline, Event, GrantAccess,
    MAX_CALENDARS, PerformAlert, PerformResponse, PollPriority, host_events, run,
};

use agenda::{Agenda, JoinTarget, Settings, Values};

const CALENDARS_SETTING: &str = "calendars";
const ALL_DAY_SETTING: &str = "all_day";
const DECLINED_SETTING: &str = "declined";
const LOOKAHEAD_HOURS_SETTING: &str = "lookahead_hours";

/// A failed read keeps the last events and is tried again this much later.
const RETRY: Duration = Duration::from_secs(300);
/// The longest deadline the host arms (`poll.max_seconds`): a later instant
/// is reached a day at a time.
const MAX_DEADLINE_SECONDS: f64 = 86_400.0;
/// A tick that lands a hair before the instant it was armed for (the host's
/// clock is not the wall clock) is re-armed no sooner than this.
const MIN_DEADLINE_SECONDS: f64 = 0.005;
/// How long a surface's first read waits for the user to answer macOS's
/// prompt. A later answer still reaches the values: the host announces it
/// (`core:calendar.changed`).
const OBSERVED_ASK_TIMEOUT: Duration = Duration::from_secs(60);
/// How long a command waits for that answer: inside the perform deadline.
const COMMAND_ASK_TIMEOUT: Duration = Duration::from_secs(8);
/// The bounds of a perform reply's alert (`quotas.alert_title_bytes`,
/// `quotas.alert_value_bytes`).
const ALERT_TITLE_BYTES: usize = 256;
const ALERT_VALUE_BYTES: usize = 64;

const DENIED_MESSAGE: &str = "Flash may not read your calendars: allow it in System Settings › Privacy & Security › Calendars";
const UNANSWERED_MESSAGE: &str = "Answer macOS's Calendars prompt, then run the command again";
const NO_LINK_MESSAGE: &str = "The event has no meeting link";

/// The wall clock and the local zone, which the tests replace.
trait Clock: Send + Sync {
    /// Unix seconds.
    fn now(&self) -> f64;
    /// The local zone's offset from UTC, in seconds, at `instant`.
    fn utc_offset(&self, instant: f64) -> i64;
}

struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> f64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |elapsed| elapsed.as_secs_f64())
    }

    fn utc_offset(&self, instant: f64) -> i64 {
        let time = instant.floor() as libc::time_t;
        // SAFETY: `localtime_r` writes only into the caller-owned `tm`,
        // which is plain old data; a null return leaves it unused.
        unsafe {
            let mut tm: libc::tm = std::mem::zeroed();
            if libc::localtime_r(&time, &mut tm).is_null() {
                0
            } else {
                tm.tm_gmtoff
            }
        }
    }
}

/// What one read of the calendar found.
#[derive(Debug, PartialEq)]
enum Read {
    Agenda(Agenda),
    /// macOS refused access, or the user did when asked.
    Denied,
    /// macOS's prompt is still open.
    Unanswered,
    Failed(String),
}

#[derive(Default)]
struct State {
    /// The host said which segments are shown at least once.
    started: bool,
    /// A status surface shows a segment: only then are events read.
    observed: bool,
    /// Bumped by every change of `observed`: a read begun before it is
    /// stale.
    generation: u64,
    /// The reads begun, and the latest one adopted: a read that finishes
    /// after a later one is dropped.
    reads: u64,
    adopted: u64,
    /// The events last read while observed; `None`: nothing to show.
    agenda: Option<Agenda>,
    published: Published<Values>,
    /// The next change of a value.
    change: Option<Deadline>,
    /// The next read: one look-ahead after the last, or a retry.
    horizon: Option<Deadline>,
}

impl State {
    fn cancel(deadline: &mut Option<Deadline>) {
        if let Some(deadline) = deadline.take()
            && deadline.is_pending()
        {
            deadline.cancel();
        }
    }
}

struct Shared {
    state: Mutex<State>,
    clock: Box<dyn Clock>,
}

struct Calendar {
    shared: Arc<Shared>,
}

impl Calendar {
    fn new(clock: Box<dyn Clock>) -> Self {
        Self {
            shared: Arc::new(Shared {
                state: Mutex::new(State::default()),
                clock,
            }),
        }
    }
}

/// `[plugins.calendar]`, as the host resolved it against the manifest.
fn settings(ctx: &Context) -> Settings {
    let defaults = Settings::default();
    Settings {
        calendars: ctx
            .config_json::<Vec<String>>(CALENDARS_SETTING)
            .unwrap_or_default(),
        all_day: ctx
            .config_json::<bool>(ALL_DAY_SETTING)
            .unwrap_or(defaults.all_day),
        declined: ctx
            .config_json::<bool>(DECLINED_SETTING)
            .unwrap_or(defaults.declined),
        lookahead_hours: ctx
            .config_json::<u32>(LOOKAHEAD_HOURS_SETTING)
            .filter(|hours| {
                (agenda::LOOKAHEAD_HOURS_MIN..=agenda::LOOKAHEAD_HOURS_MAX).contains(hours)
            })
            .unwrap_or(defaults.lookahead_hours),
    }
}

/// The titles a read names: the configured ones the host takes. `None` when
/// titles are configured and none is usable, which reads no calendar rather
/// than every one.
fn calendar_titles(settings: &Settings) -> Option<Vec<String>> {
    let titles: Vec<String> = settings
        .calendars
        .iter()
        .filter(|title| !title.is_empty())
        .take(MAX_CALENDARS)
        .cloned()
        .collect();
    (settings.calendars.is_empty() || !titles.is_empty()).then_some(titles)
}

fn event(event: CalendarEvent) -> agenda::Event {
    agenda::Event {
        link: links::find(
            event.url.as_deref(),
            event.location.as_deref(),
            &event.links,
        ),
        id: event.id,
        title: event.title,
        start: event.start,
        end: event.end,
        all_day: event.all_day,
        declined: event.declined,
        canceled: event.canceled,
    }
}

/// `text` within `limit` bytes, cut at a character and marked when cut.
fn fitted(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_string();
    }
    let mut cut = String::new();
    for character in text.chars() {
        if cut.len() + character.len_utf8() + '…'.len_utf8() > limit {
            break;
        }
        cut.push(character);
    }
    cut.push('…');
    cut
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Whether a status surface shows a segment.
    fn is_observed(&self) -> bool {
        self.lock().observed
    }

    /// Read the events from now to twice the look-ahead, so the values stay
    /// complete until the next read. `ask`: when Flash never asked macOS,
    /// ask and wait this long for the answer; only the user's own use of the
    /// plugin passes one.
    async fn read(&self, ctx: &Context, ask: Option<Duration>) -> Read {
        let settings = settings(ctx);
        let Some(calendars) = calendar_titles(&settings) else {
            return Read::Agenda(Agenda::new(Vec::new(), settings.lookahead()));
        };
        let start = self.clock.now().floor() as i64;
        let end = start + 2 * i64::from(settings.lookahead_hours) * 3_600;
        let mut ask = ask;
        loop {
            match ctx.calendar_events(start, end, &calendars).await {
                Ok(CalendarListing::Events { events, truncated }) => {
                    if truncated {
                        ctx.log(
                            "warn",
                            "[calendar] more events than one read holds: later ones are not counted",
                        );
                    }
                    let events = events
                        .into_iter()
                        .map(event)
                        .filter(|event| settings.admits(event))
                        .collect();
                    return Read::Agenda(Agenda::new(events, settings.lookahead()));
                }
                Ok(CalendarListing::NoAccess(GrantAccess::Undetermined)) => {
                    let Some(timeout) = ask.take() else {
                        return Read::Denied;
                    };
                    match ctx.request_calendar_access(timeout).await {
                        // Read again, once: the grant is there now.
                        Ok(GrantAccess::Granted) => {}
                        Ok(_) => return Read::Denied,
                        Err(_) => return Read::Unanswered,
                    }
                }
                Ok(CalendarListing::NoAccess(_)) => return Read::Denied,
                Err(reason) => return Read::Failed(reason),
            }
        }
    }

    /// Number a read that is about to start.
    fn begin_read(&self) -> (u64, u64) {
        let mut state = self.lock();
        state.reads += 1;
        (state.reads, state.generation)
    }

    /// Read in the background and take the result: an event handler never
    /// waits on the host, or on a prompt.
    fn refresh(self: &Arc<Self>, ctx: &Context, ask: Option<Duration>) {
        let (serial, generation) = self.begin_read();
        let (shared, ctx) = (self.clone(), ctx.clone());
        tokio::spawn(async move {
            let read = shared.read(&ctx, ask).await;
            shared.adopt(&ctx, &read, serial, generation);
        });
    }

    /// Show what an observed read found, and plan the next read.
    fn adopt(self: &Arc<Self>, ctx: &Context, read: &Read, serial: u64, generation: u64) {
        let mut state = self.lock();
        if !state.observed || generation != state.generation || serial <= state.adopted {
            return;
        }
        state.adopted = serial;
        match read {
            Read::Agenda(agenda) => {
                // `Low`: the look-ahead moving on brings in events hours
                // away.
                self.arm_read(&mut state, ctx, agenda.lookahead);
                state.agenda = Some(agenda.clone());
                self.evaluate(&mut state, ctx);
            }
            // The answer to a prompt still open is announced by the host
            // (`core:calendar.changed`); access granted later in System
            // Settings is seen by the next command.
            Read::Denied | Read::Unanswered => {
                State::cancel(&mut state.horizon);
                state.agenda = None;
                self.evaluate(&mut state, ctx);
            }
            Read::Failed(_) => {
                // The host logged why; the last events stay.
                ctx.log("warn", "[calendar] read failed");
                self.arm_read(&mut state, ctx, RETRY.as_secs_f64());
            }
        }
    }

    /// Read again in `seconds`, while observed.
    fn arm_read(self: &Arc<Self>, state: &mut State, ctx: &Context, seconds: f64) {
        State::cancel(&mut state.horizon);
        let shared = self.clone();
        let delay = Duration::from_secs_f64(seconds.clamp(1.0, MAX_DEADLINE_SECONDS));
        state.horizon = Some(ctx.after(delay, PollPriority::Low, move |ctx| async move {
            if shared.is_observed() {
                shared.refresh(&ctx, None);
            }
        }));
    }

    /// Publish the values as they are now, when they changed, and ask the
    /// host's clock for the instant they next change.
    fn evaluate(self: &Arc<Self>, state: &mut State, ctx: &Context) {
        State::cancel(&mut state.change);
        let now = self.clock.now();
        let offset = |instant: f64| self.clock.utc_offset(instant);
        let values = state
            .agenda
            .as_ref()
            .and_then(|agenda| agenda::values(agenda, now, &offset))
            .unwrap_or_default();
        if let Some(values) = state.published.update(values) {
            ctx.status(values.segments());
        }
        let Some(change) = state
            .agenda
            .as_ref()
            .and_then(|agenda| agenda::next_change(agenda, now))
        else {
            return;
        };
        let delay = (change - now).clamp(MIN_DEADLINE_SECONDS, MAX_DEADLINE_SECONDS);
        let shared = self.clone();
        // `High`: the countdown is on screen beside the clock.
        state.change = Some(ctx.after(
            Duration::from_secs_f64(delay),
            PollPriority::High,
            move |ctx| async move {
                let mut state = shared.lock();
                if state.observed {
                    shared.evaluate(&mut state, &ctx);
                }
            },
        ));
    }

    /// The surfaces started or stopped showing a segment.
    fn observe(self: &Arc<Self>, ctx: &Context, observed: bool) {
        {
            let mut state = self.lock();
            if !state.started {
                // A restarted plugin knows no event: say so before a surface
                // keeps showing the previous run's meeting.
                state.started = true;
                state.published.reset();
                self.evaluate(&mut state, ctx);
            }
            if observed == state.observed {
                return;
            }
            state.observed = observed;
            state.generation += 1;
            if !observed {
                State::cancel(&mut state.horizon);
                state.agenda = None;
                self.evaluate(&mut state, ctx);
                return;
            }
        }
        // The user put a value on a surface: the one moment, with a
        // command, when macOS may be asked.
        self.refresh(ctx, Some(OBSERVED_ASK_TIMEOUT));
    }

    async fn command(self: &Arc<Self>, ctx: &Context, command: &CommandRequest) -> PerformResponse {
        let name = command.name();
        if !matches!(name.as_str(), "calendar join" | "calendar next") {
            return PerformResponse::fail(format!("unknown command: {name}"));
        }
        if !command.args.is_empty() {
            return PerformResponse::fail(format!("usage: {name}"));
        }
        let (serial, generation) = self.begin_read();
        let read = self.read(ctx, Some(COMMAND_ASK_TIMEOUT)).await;
        // A command's read is the freshest there is: the values take it too.
        self.adopt(ctx, &read, serial, generation);
        let agenda = match read {
            Read::Agenda(agenda) => agenda,
            Read::Denied => return PerformResponse::fail(DENIED_MESSAGE),
            Read::Unanswered => return PerformResponse::fail(UNANSWERED_MESSAGE),
            Read::Failed(reason) => {
                return PerformResponse::fail(format!("Could not read your calendars: {reason}"));
            }
        };
        let now = self.clock.now();
        let no_event = || agenda::no_event_message(settings(ctx).lookahead_hours);
        if name == "calendar next" {
            let offset = |instant: f64| self.clock.utc_offset(instant);
            let Some((title, detail)) = agenda::summary(&agenda, now, &offset) else {
                return PerformResponse::fail(no_event());
            };
            return PerformResponse::ok()
                .message(format!("{title} {detail}"))
                .alert(PerformAlert::value(
                    fitted(&title, ALERT_TITLE_BYTES),
                    fitted(&detail, ALERT_VALUE_BYTES),
                ));
        }
        match agenda::join_target(&agenda, now) {
            JoinTarget::NoEvent => PerformResponse::fail(no_event()),
            // An error is logged: it never names the event.
            JoinTarget::NoLink(_) => PerformResponse::fail(NO_LINK_MESSAGE),
            JoinTarget::Join(event, link) => {
                // The meeting's app when one handles its link, else the link
                // itself.
                let mut opened = None;
                if let Some(app) = &link.app_url
                    && ctx.open_url_if_handled(app).await.is_ok()
                {
                    opened = Some(app.as_str());
                }
                if opened.is_none() {
                    if let Err(reason) = ctx.open_url(&link.url).await {
                        return PerformResponse::fail(format!(
                            "Could not open the meeting link: {reason}"
                        ));
                    }
                    opened = Some(link.url.as_str());
                }
                let scheme = opened
                    .and_then(|url| url.split_once(':'))
                    .map_or("", |(scheme, _)| scheme);
                // The log names the service and the scheme, never the event.
                ctx.log_fields(
                    "info",
                    "[calendar] join",
                    BTreeMap::from([
                        ("service".to_string(), link.service.clone()),
                        ("scheme".to_string(), scheme.to_ascii_lowercase()),
                    ]),
                );
                PerformResponse::ok().message(format!("Joining {}", event.display_title()))
            }
        }
    }
}

flash_plugin::plugin!(Calendar);

impl FlashPlugin for Calendar {
    async fn on_event(&self, ctx: Context, event: Event) {
        match event.name.as_str() {
            host_events::STATUS_OBSERVED => {
                if let Some(segments) = event.segments.as_deref() {
                    self.shared.observe(&ctx, !segments.is_empty());
                }
            }
            // The database changed, or the user answered macOS's prompt:
            // read again, without asking.
            host_events::CALENDAR_CHANGED if self.shared.is_observed() => {
                self.shared.refresh(&ctx, None);
            }
            _ => {}
        }
    }

    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        self.shared.command(&ctx, &command).await
    }
}

fn main() {
    run(Calendar::new(Box::new(SystemClock)));
}

#[cfg(test)]
mod tests;
