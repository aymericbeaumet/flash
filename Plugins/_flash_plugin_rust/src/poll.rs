//! Host-driven cadences and deadlines.
//!
//! A plugin never arms a timer or sleeps to schedule work. It registers a
//! cadence ([`Context::interval`]) or a one-shot deadline ([`Context::after`])
//! with the host, which folds every registration in the app onto one clock
//! and sends `core:poll:<name>` when each is due. Every change republishes
//! the plugin's complete registration set (`poll {registrations}`), so the
//! host's view is always the plugin's whole answer rather than a diff.

use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use serde_json::{Map, Value, json};
use tokio::task::JoinHandle;

use crate::context::Context;

/// Floor on a cadence (`poll.min_every_ms` in `protocol.json`): below it a
/// poll is a busy loop, and the answer is an event.
pub(crate) const MIN_EVERY: Duration = Duration::from_millis(50);
/// Ceiling on a cadence or a deadline (`poll.max_seconds`).
pub(crate) const MAX_SECONDS: u64 = 86_400;
/// Most registrations one plugin may hold at once (`poll.max_registrations`).
pub(crate) const MAX_REGISTRATIONS: usize = 64;
/// Longest registration name the host accepts (`poll.max_name_bytes`); the
/// SDK's own `i<n>`/`d<n>` names stay far below it.
pub(crate) const MAX_NAME_BYTES: usize = 64;

/// How late the host may deliver a wake-up. Slack is what lets unrelated
/// wake-ups across the whole app collapse into one, so ask for the loosest
/// priority whose lateness nobody would notice. The host's fourth, tighter
/// priority (`system`, input-adjacent probes) is core-only.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PollPriority {
    /// 25 ms: a value on screen that the user watches change — a one-second
    /// sampler behind a visible segment, a settle whose refresh redraws one.
    High,
    /// 100 ms: ordinary sampling, settles and refreshes nobody watches tick.
    Normal,
    /// 1 s: background upkeep — remote pulls, retries and backoffs.
    Low,
}

impl PollPriority {
    pub(crate) const ALL: [PollPriority; 3] = [Self::High, Self::Normal, Self::Low];

    pub(crate) const fn wire(self) -> &'static str {
        match self {
            Self::High => "high",
            Self::Normal => "normal",
            Self::Low => "low",
        }
    }
}

type BoxFuture = Pin<Box<dyn Future<Output = ()> + Send>>;
type CadenceFn = Box<dyn FnMut(Context) -> BoxFuture + Send>;
type DeadlineFn = Box<dyn FnOnce(Context) -> BoxFuture + Send>;

#[derive(Clone, Copy, Debug, PartialEq)]
enum Kind {
    Every,
    After,
}

#[derive(Clone, Copy, Debug)]
struct Registration {
    kind: Kind,
    period: Duration,
    priority: PollPriority,
}

/// A cadence's callback outlives a cancel, so `set_period` can re-arm it.
struct Cadence {
    callback: Arc<Mutex<CadenceFn>>,
    running: Arc<AtomicBool>,
}

#[derive(Default)]
struct State {
    /// The set on the wire: what the host currently drives.
    registrations: BTreeMap<String, Registration>,
    cadences: HashMap<String, Cadence>,
    deadlines: HashMap<String, DeadlineFn>,
}

/// Everything this plugin has asked the host to drive.
pub(crate) struct PollRegistry {
    state: Mutex<State>,
    counter: AtomicU64,
}

impl PollRegistry {
    pub(crate) fn new() -> Self {
        Self {
            state: Mutex::new(State::default()),
            counter: AtomicU64::new(0),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Names are host-validated (`[a-z0-9_-]`) and ride inside the tick's
    /// event name. A fresh name per registration (and per deadline arming)
    /// means a tick that raced a cancel can never run a newer callback.
    fn name(&self, prefix: char) -> String {
        format!("{prefix}{}", self.counter.fetch_add(1, Ordering::Relaxed))
    }
}

/// Why a registration was refused before it reached the host, which would
/// otherwise reject the plugin's whole set.
fn refusal(state: &State, name: &str, registration: &Registration) -> Option<String> {
    let max = Duration::from_secs(MAX_SECONDS);
    if registration.period > max {
        return Some(format!("longer than {MAX_SECONDS} s"));
    }
    if registration.kind == Kind::Every && registration.period < MIN_EVERY {
        return Some(format!(
            "a cadence below {} ms is a busy loop",
            MIN_EVERY.as_millis()
        ));
    }
    if !state.registrations.contains_key(name) && state.registrations.len() >= MAX_REGISTRATIONS {
        return Some(format!("more than {MAX_REGISTRATIONS} registrations"));
    }
    None
}

/// The `poll` notification for the current set: every registration with its
/// kind, period in seconds (whole milliseconds, rounded up so a deadline
/// never lands before the instant it was asked for) and priority.
fn frame(state: &State) -> Value {
    let registrations: Map<String, Value> = state
        .registrations
        .iter()
        .map(|(name, registration)| {
            let millis = registration.period.as_nanos().div_ceil(1_000_000);
            let seconds = millis as f64 / 1000.0;
            let key = match registration.kind {
                Kind::Every => "every",
                Kind::After => "after",
            };
            (
                name.clone(),
                json!({ key: seconds, "priority": registration.priority.wire() }),
            )
        })
        .collect();
    json!({ "registrations": registrations })
}

impl Context {
    /// Replace (`Some`) or drop (`None`) one wire registration and republish
    /// the whole set. Emitted under the lock, so concurrent changes reach the
    /// host in the order they were made. False when it was refused.
    fn set_registration(&self, name: &str, registration: Option<Registration>) -> bool {
        let mut state = self.poll.lock();
        match registration {
            Some(registration) => {
                if let Some(reason) = refusal(&state, name, &registration) {
                    drop(state);
                    self.log(
                        "warn",
                        &format!("[plugin] poll registration refused: {reason}"),
                    );
                    return false;
                }
                state.registrations.insert(name.to_string(), registration);
            }
            None => {
                if state.registrations.remove(name).is_none() {
                    return true;
                }
            }
        }
        let frame = frame(&state);
        debug_assert!(crate::wire::valid_poll(&frame), "{frame}");
        self.emit.notify("poll", frame);
        true
    }

    /// Run a background refresh at a fixed cadence, driven by the host.
    ///
    /// This does **not** arm a timer in the plugin. It registers `period`
    /// with the host, which drives every poller in Flash — core watchers
    /// included — from a single clock, and ticks this callback when the
    /// registration is due, at most `priority`'s slack late. The first tick
    /// waits for `period`; callers perform their authoritative initial
    /// refresh in `on_start`. A callback still running when the next tick
    /// arrives makes that tick a no-op rather than queueing it, so one
    /// cadence never overlaps itself.
    ///
    /// Reach for this only when nothing else can tell you the value changed.
    /// An event (`on_event`) is always preferable, and the host exposes one
    /// for every source it can observe. A period outside the protocol's
    /// bounds is refused with a warning and the handle never ticks.
    pub fn interval<F, Fut>(
        &self,
        period: Duration,
        priority: PollPriority,
        mut callback: F,
    ) -> PollHandle
    where
        F: FnMut(Context) -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let name = self.poll.name('i');
        let callback: CadenceFn = Box::new(move |ctx| Box::pin(callback(ctx)));
        self.poll.lock().cadences.insert(
            name.clone(),
            Cadence {
                callback: Arc::new(Mutex::new(callback)),
                running: Arc::new(AtomicBool::new(false)),
            },
        );
        self.set_registration(
            &name,
            Some(Registration {
                kind: Kind::Every,
                period,
                priority,
            }),
        );
        PollHandle {
            name,
            priority,
            ctx: self.clone(),
        }
    }

    /// Run `callback` once, `delay` from now, driven by the host: the
    /// deadline form of [`interval`](Self::interval), for an irregular next
    /// wake-up — a debounce, a retry backoff, an expiry. Nothing sleeps in
    /// the plugin; the host delivers the tick at most `priority`'s slack
    /// late, and holds it while the displays sleep or the session is locked
    /// (one catch-up tick follows). Cancel it with the returned handle;
    /// re-arming means a new `after`.
    pub fn after<F, Fut>(&self, delay: Duration, priority: PollPriority, callback: F) -> Deadline
    where
        F: FnOnce(Context) -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let name = self.poll.name('d');
        let callback: DeadlineFn = Box::new(move |ctx| Box::pin(callback(ctx)));
        self.poll.lock().deadlines.insert(name.clone(), callback);
        let registered = self.set_registration(
            &name,
            Some(Registration {
                kind: Kind::After,
                period: delay,
                priority,
            }),
        );
        if !registered {
            self.poll.lock().deadlines.remove(&name);
        }
        Deadline {
            name,
            ctx: self.clone(),
        }
    }

    /// Resolve `delay` from now, on the host's clock: the awaitable form of
    /// [`after`](Self::after), for a wait inside one piece of work — a retry
    /// backoff, a measurement window, a beat for another app to react.
    /// Dropping the future (a `select!` that took another branch) cancels the
    /// registration. A registration the SDK refuses (logged) resolves at once.
    pub async fn wait(&self, delay: Duration, priority: PollPriority) {
        let (fired, landed) = tokio::sync::oneshot::channel();
        let deadline = self.after(delay, priority, move |_| async move {
            let _ = fired.send(());
        });
        let _cancel_on_drop = CancelOnDrop(deadline);
        let _ = landed.await;
    }

    /// Run the callback a host tick names: a deadline fires once and leaves
    /// the set (the host dropped it too, and ignores it if a later set still
    /// lists it), a cadence runs unless its previous run is still going. A
    /// tick for a cancelled or unknown registration does nothing. The
    /// returned task is the callback's run.
    pub(crate) fn deliver_poll_tick(&self, name: &str) -> Option<JoinHandle<()>> {
        let mut state = self.poll.lock();
        if let Some(callback) = state.deadlines.remove(name) {
            state.registrations.remove(name);
            drop(state);
            return Some(tokio::spawn(callback(self.clone())));
        }
        if !state.registrations.contains_key(name) {
            return None;
        }
        let cadence = state.cadences.get(name)?;
        // The host cannot see that this callback is still running — a tick
        // is a one-way frame — so the skip happens here: running the
        // collector back-to-back to catch up is exactly the pile-up a shared
        // clock exists to prevent.
        if cadence.running.swap(true, Ordering::AcqRel) {
            return None;
        }
        let running = Arc::clone(&cadence.running);
        let callback = Arc::clone(&cadence.callback);
        // Released first: the callback may itself re-period or cancel.
        drop(state);
        let future = (callback.lock().unwrap_or_else(|error| error.into_inner()))(self.clone());
        Some(tokio::spawn(async move {
            future.await;
            running.store(false, Ordering::Release);
        }))
    }
}

/// A live cadence registration. Dropping it changes nothing — the callback
/// keeps running — but it lets a poller whose useful rate varies (a retry
/// backoff, an idle backend) move its own period instead of registering at
/// its fastest rate and discarding most ticks, and lets a poller scoped to
/// an observer stop and resume.
pub struct PollHandle {
    name: String,
    priority: PollPriority,
    ctx: Context,
}

impl PollHandle {
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Re-register at a new period (same priority), effective from the
    /// host's next plan. Also re-arms a cancelled handle.
    pub fn set_period(&self, period: Duration) {
        self.ctx.set_registration(
            &self.name,
            Some(Registration {
                kind: Kind::Every,
                period,
                priority: self.priority,
            }),
        );
    }

    /// Stop the cadence. The callback stays alive for a later `set_period`
    /// but never ticks meanwhile.
    pub fn cancel(&self) {
        self.ctx.set_registration(&self.name, None);
    }
}

/// A pending one-shot deadline. Dropping it leaves the deadline armed.
pub struct Deadline {
    name: String,
    ctx: Context,
}

impl Deadline {
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Whether the deadline is still waiting to fire.
    pub fn is_pending(&self) -> bool {
        self.ctx.poll.lock().deadlines.contains_key(&self.name)
    }

    /// Drop the deadline if it has not fired; its callback never runs.
    pub fn cancel(&self) {
        let removed = self.ctx.poll.lock().deadlines.remove(&self.name).is_some();
        if removed {
            self.ctx.set_registration(&self.name, None);
        }
    }
}

/// Cancels a [`Context::wait`] deadline its future no longer awaits; a
/// no-op once it fired.
struct CancelOnDrop(Deadline);

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.cancel();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::context::test_context_with_rx;
    use crate::emit::OutboundFrame;
    use tokio::sync::mpsc::Receiver;

    fn polls(rx: &mut Receiver<OutboundFrame>) -> Vec<Value> {
        let mut frames = Vec::new();
        while let Ok(frame) = rx.try_recv() {
            let value: Value = serde_json::from_slice(&frame.payload).unwrap();
            if value["method"] == "poll" {
                frames.push(value["params"]["registrations"].clone());
            }
        }
        frames
    }

    #[tokio::test]
    async fn every_registration_names_its_kind_period_and_priority() {
        let (ctx, mut rx) = test_context_with_rx();
        let cadence = ctx.interval(Duration::from_secs(1), PollPriority::High, |_| async {});
        let deadline = ctx.after(
            Duration::from_micros(300_001),
            PollPriority::Low,
            |_| async {},
        );
        assert_eq!(
            polls(&mut rx),
            [
                json!({ "i0": { "every": 1.0, "priority": "high" } }),
                // Rounded up to whole milliseconds: never early.
                json!({
                    "i0": { "every": 1.0, "priority": "high" },
                    "d1": { "after": 0.301, "priority": "low" },
                }),
            ]
        );
        cadence.set_period(Duration::from_secs(5));
        cadence.cancel();
        deadline.cancel();
        assert_eq!(
            polls(&mut rx),
            [
                json!({
                    "i0": { "every": 5.0, "priority": "high" },
                    "d1": { "after": 0.301, "priority": "low" },
                }),
                json!({ "d1": { "after": 0.301, "priority": "low" } }),
                json!({}),
            ],
            "a re-period keeps its priority; cancels republish the remaining set"
        );
        assert!(!deadline.is_pending());
    }

    #[tokio::test]
    async fn a_deadline_runs_once_and_leaves_the_set() {
        let (ctx, mut rx) = test_context_with_rx();
        let (tx, mut ran) = tokio::sync::mpsc::unbounded_channel();
        let deadline = ctx.after(Duration::ZERO, PollPriority::Normal, move |_| async move {
            tx.send(()).unwrap();
        });
        assert_eq!(
            polls(&mut rx),
            [json!({ "d0": { "after": 0.0, "priority": "normal" } })]
        );
        assert!(deadline.is_pending());
        ctx.deliver_poll_tick("d0")
            .expect("the deadline runs")
            .await
            .unwrap();
        assert!(ran.try_recv().is_ok());
        assert!(!deadline.is_pending());
        // The host dropped it as it fired: no republish, and a duplicate
        // tick (a later set raced it) runs nothing.
        assert!(polls(&mut rx).is_empty());
        assert!(ctx.deliver_poll_tick("d0").is_none());
        deadline.cancel();
        assert!(
            polls(&mut rx).is_empty(),
            "cancelling a fired deadline is a no-op"
        );
    }

    #[tokio::test]
    async fn a_cancelled_deadline_never_runs() {
        let (ctx, mut rx) = test_context_with_rx();
        let deadline = ctx.after(Duration::from_secs(1), PollPriority::Low, |_| async {
            panic!("a cancelled deadline ran");
        });
        deadline.cancel();
        assert_eq!(polls(&mut rx).last(), Some(&json!({})));
        assert!(ctx.deliver_poll_tick(deadline.name()).is_none());
    }

    #[tokio::test]
    async fn a_wait_resolves_on_its_tick_and_cancels_when_dropped() {
        let (ctx, mut rx) = test_context_with_rx();
        let waiter = {
            let ctx = ctx.clone();
            tokio::spawn(async move { ctx.wait(Duration::from_secs(5), PollPriority::Low).await })
        };
        tokio::task::yield_now().await;
        assert_eq!(
            polls(&mut rx),
            [json!({ "d0": { "after": 5.0, "priority": "low" } })]
        );
        assert!(
            !waiter.is_finished(),
            "nothing sleeps: only the tick resolves it"
        );
        ctx.deliver_poll_tick("d0").unwrap().await.unwrap();
        tokio::time::timeout(Duration::from_secs(2), waiter)
            .await
            .expect("the tick resolves the wait")
            .unwrap();
        assert!(
            polls(&mut rx).is_empty(),
            "a fired deadline needs no cancel"
        );

        // A wait abandoned before its tick (a select that took another
        // branch) releases its registration.
        let abandoned = ctx.wait(Duration::from_secs(5), PollPriority::Normal);
        tokio::select! {
            () = abandoned => panic!("resolved without a tick"),
            () = tokio::task::yield_now() => {}
        }
        assert_eq!(
            polls(&mut rx),
            [
                json!({ "d1": { "after": 5.0, "priority": "normal" } }),
                json!({})
            ]
        );
    }

    #[tokio::test]
    async fn out_of_bound_registrations_are_refused_before_the_host_sees_them() {
        let (ctx, mut rx) = test_context_with_rx();
        let busy = ctx.interval(Duration::from_millis(10), PollPriority::High, |_| async {});
        let far = ctx.after(
            Duration::from_secs(MAX_SECONDS + 1),
            PollPriority::Low,
            |_| async {},
        );
        assert!(!far.is_pending());
        assert!(ctx.deliver_poll_tick(busy.name()).is_none());
        let mut frames = polls(&mut rx);
        for _ in 0..MAX_REGISTRATIONS {
            ctx.interval(Duration::from_secs(1), PollPriority::Low, |_| async {});
            frames.extend(polls(&mut rx));
        }
        let over = ctx.interval(Duration::from_secs(1), PollPriority::Low, |_| async {});
        assert!(ctx.deliver_poll_tick(over.name()).is_none());
        frames.extend(polls(&mut rx));
        assert_eq!(
            frames.len(),
            MAX_REGISTRATIONS,
            "only accepted sets reach the host"
        );
        assert_eq!(
            frames.last().unwrap().as_object().unwrap().len(),
            MAX_REGISTRATIONS
        );
        assert!(
            frames
                .iter()
                .all(|set| crate::wire::valid_poll(&json!({ "registrations": set })))
        );
    }
}
