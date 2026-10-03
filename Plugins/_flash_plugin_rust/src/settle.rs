//! Trailing debounce with a ceiling, for refreshes keyed to bursty events.

use std::collections::BTreeSet;
use std::future::Future;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::context::Context;
use crate::poll::PollPriority;

/// Coalesces a burst of events into one refresh. The refresh runs once the
/// events have been quiet for `settle`, and at the latest `max_wait` after
/// the burst began, so a source that never goes quiet still refreshes at
/// that bound. It receives every key the burst named — the apps whose
/// windows changed, say — so it can re-read those alone. Between bursts
/// nothing runs: no timer, no task. During a burst the wait is one host
/// deadline ([`Context::after`]) at `priority`, never a sleep: when it lands
/// before the burst settled (later events extended it), it re-arms for the
/// remainder.
///
/// Keep one per refresh in a `static` and call [`schedule`](Self::schedule)
/// from `on_event`. With `settle == max_wait` it is a plain window: the
/// first event opens it and every event inside joins the one refresh.
///
/// ```ignore
/// static AX_BURST: Settle<i64> = Settle::new(
///     Duration::from_millis(300),
///     Duration::from_secs(10),
///     PollPriority::Normal,
/// );
///
/// if event.is_ax_change(&[ax_notifications::TITLE_CHANGED]) {
///     let refresh_ctx = ctx.clone();
///     AX_BURST.schedule(&ctx, pid, move |pids| async move {
///         refresh(&refresh_ctx, pids).await
///     });
/// }
/// ```
pub struct Settle<K> {
    settle: Duration,
    max_wait: Duration,
    priority: PollPriority,
    burst: Mutex<Option<Burst<K>>>,
}

struct Burst<K> {
    first: Instant,
    last: Instant,
    keys: BTreeSet<K>,
}

impl<K> Burst<K> {
    fn due(&self, settle: Duration, max_wait: Duration) -> Instant {
        (self.last + settle).min(self.first + max_wait)
    }
}

impl<K: Ord> Settle<K> {
    pub const fn new(settle: Duration, max_wait: Duration, priority: PollPriority) -> Self {
        Self {
            settle,
            max_wait,
            priority,
            burst: Mutex::new(None),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Option<Burst<K>>> {
        self.burst.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Record an event naming `key` at `now`. True when it began a burst:
    /// the caller then arms the one deadline that ends it.
    /// [`schedule`](Self::schedule) does both.
    pub fn note(&self, key: K, now: Instant) -> bool {
        let mut burst = self.lock();
        match burst.as_mut() {
            Some(burst) => {
                burst.last = burst.last.max(now);
                burst.keys.insert(key);
                false
            }
            None => {
                *burst = Some(Burst {
                    first: now,
                    last: now,
                    keys: BTreeSet::from([key]),
                });
                true
            }
        }
    }

    /// When the pending burst is due; `None` when nothing is pending.
    pub fn due(&self) -> Option<Instant> {
        self.lock()
            .as_ref()
            .map(|burst| burst.due(self.settle, self.max_wait))
    }

    /// The keys of a burst due at `now`, ending it; `None` while it is
    /// still settling or when nothing is pending.
    pub fn take_due(&self, now: Instant) -> Option<BTreeSet<K>> {
        let mut burst = self.lock();
        if burst.as_ref()?.due(self.settle, self.max_wait) > now {
            return None;
        }
        burst.take().map(|burst| burst.keys)
    }
}

impl<K: Ord + Send + 'static> Settle<K> {
    /// Record an event naming `key`. The event that begins a burst arms the
    /// one host deadline that runs `refresh` with the burst's keys once it
    /// settles; later events of the burst only extend it, and their
    /// `refresh` is dropped unrun.
    pub fn schedule<F, Fut>(&'static self, ctx: &Context, key: K, refresh: F)
    where
        F: FnOnce(BTreeSet<K>) -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        if self.note(key, Instant::now()) {
            self.arm(ctx, refresh);
        }
    }

    /// Wait on the host for the burst's current due time; a deadline that
    /// lands while later events have pushed it out waits for the rest.
    fn arm<F, Fut>(&'static self, ctx: &Context, refresh: F)
    where
        F: FnOnce(BTreeSet<K>) -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let Some(due) = self.due() else {
            return;
        };
        let delay = due.saturating_duration_since(Instant::now());
        ctx.after(delay, self.priority, move |ctx| async move {
            match self.take_due(Instant::now()) {
                Some(keys) => refresh(keys).await,
                None => self.arm(&ctx, refresh),
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Harness;
    use std::sync::Arc;

    const SETTLE: Duration = Duration::from_secs(1);
    const MAX_WAIT: Duration = Duration::from_secs(10);

    #[test]
    fn a_burst_runs_once_it_has_been_quiet() {
        let settle = Settle::new(SETTLE, MAX_WAIT, PollPriority::Normal);
        let start = Instant::now();
        assert!(settle.note(7, start));
        assert!(!settle.note(7, start + Duration::from_millis(400)));
        assert!(!settle.note(9, start + Duration::from_millis(600)));
        let quiet = start + Duration::from_millis(1_600);
        assert_eq!(settle.due(), Some(quiet));
        assert!(settle.take_due(quiet - Duration::from_millis(1)).is_none());
        assert_eq!(settle.take_due(quiet), Some(BTreeSet::from([7, 9])));
        assert!(settle.due().is_none(), "the burst ended");
        assert!(settle.note(7, quiet), "the next event begins a new burst");
    }

    #[test]
    fn a_never_quiet_source_still_runs_at_the_ceiling() {
        let settle = Settle::new(SETTLE, MAX_WAIT, PollPriority::Normal);
        let start = Instant::now();
        assert!(settle.note(7, start));
        for step in 1..=40 {
            assert!(!settle.note(7, start + Duration::from_millis(step * 500)));
        }
        assert_eq!(settle.due(), Some(start + MAX_WAIT));
        assert_eq!(settle.take_due(start + MAX_WAIT), Some(BTreeSet::from([7])));
    }

    /// A burst scheduled from several events arms one host deadline and
    /// runs its refresh once, with every key it named; a deadline that lands
    /// while the burst is still settling waits for the rest on a fresh one.
    #[tokio::test]
    async fn a_scheduled_burst_waits_on_the_host_and_refreshes_once() {
        static BURST: Settle<i64> = Settle::new(
            Duration::from_millis(40),
            Duration::from_secs(1),
            PollPriority::High,
        );
        let mut harness = Harness::new("settle");
        let ctx = harness.context();
        let runs = Arc::new(Mutex::new(Vec::new()));
        for pid in [7, 9, 7] {
            let runs = Arc::clone(&runs);
            BURST.schedule(&ctx, pid, move |pids| async move {
                runs.lock().unwrap().push(pids);
            });
        }
        let deadlines = registrations(&mut harness);
        assert_eq!(deadlines.len(), 1, "one deadline per burst: {deadlines:?}");
        let (name, entry) = deadlines.into_iter().next().unwrap();
        assert_eq!(entry["priority"], "high");
        assert!(entry["after"].as_f64().unwrap() <= 0.04);

        // A tick that lands before the burst settled re-arms for the rest.
        assert!(!BURST.note(9, Instant::now() + Duration::from_millis(500)));
        harness.deliver_poll_tick(&name).unwrap().await.unwrap();
        assert!(runs.lock().unwrap().is_empty());
        let rearmed = registrations(&mut harness);
        assert_eq!(rearmed.len(), 1);
        let (name, entry) = rearmed.into_iter().next().unwrap();
        assert!(entry["after"].as_f64().unwrap() > 0.4);

        // Once due, the refresh runs with every key.
        tokio::time::sleep(Duration::from_millis(560)).await;
        harness.deliver_poll_tick(&name).unwrap().await.unwrap();
        assert_eq!(*runs.lock().unwrap(), [BTreeSet::from([7, 9])]);
        assert!(BURST.due().is_none(), "the burst ended");
    }

    fn registrations(harness: &mut Harness) -> serde_json::Map<String, serde_json::Value> {
        harness.drain_poll_registrations().unwrap_or_default()
    }
}
