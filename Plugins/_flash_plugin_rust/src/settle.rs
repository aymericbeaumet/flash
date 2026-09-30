//! Trailing debounce with a ceiling, for refreshes keyed to bursty events.

use std::collections::BTreeSet;
use std::future::Future;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// Coalesces a burst of events into one refresh. The refresh runs once the
/// events have been quiet for `settle`, and at the latest `max_wait` after
/// the burst began, so a source that never goes quiet still refreshes at
/// that bound. It receives every key the burst named — the apps whose
/// windows changed, say — so it can re-read those alone. Between bursts
/// nothing runs: no timer, no task.
///
/// Keep one per refresh in a `static` and call [`schedule`](Self::schedule)
/// from `on_event`:
///
/// ```ignore
/// static AX_BURST: Settle<i64> =
///     Settle::new(Duration::from_millis(300), Duration::from_secs(10));
///
/// if event.is_ax_change(&[ax_notifications::TITLE_CHANGED]) {
///     let ctx = ctx.clone();
///     AX_BURST.schedule(pid, move |pids| async move { refresh(&ctx, pids).await });
/// }
/// ```
pub struct Settle<K> {
    settle: Duration,
    max_wait: Duration,
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
    pub const fn new(settle: Duration, max_wait: Duration) -> Self {
        Self {
            settle,
            max_wait,
            burst: Mutex::new(None),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Option<Burst<K>>> {
        self.burst.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Record an event naming `key` at `now`. True when it began a burst:
    /// the caller then runs the one waiter that [`wait`](Self::wait)s for
    /// it. [`schedule`](Self::schedule) does both.
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

    /// Sleep until the pending burst settles and return its keys; `None`
    /// when nothing is pending.
    pub async fn wait(&self) -> Option<BTreeSet<K>> {
        loop {
            let due = self.due()?;
            tokio::time::sleep_until(tokio::time::Instant::from_std(due)).await;
            if let Some(keys) = self.take_due(Instant::now()) {
                return Some(keys);
            }
        }
    }
}

impl<K: Ord + Send + 'static> Settle<K> {
    /// Record an event naming `key`. The event that begins a burst spawns
    /// the one task that runs `refresh` with the burst's keys once it
    /// settles; later events of the burst only extend it, and their
    /// `refresh` is dropped unrun.
    pub fn schedule<F, Fut>(&'static self, key: K, refresh: F)
    where
        F: FnOnce(BTreeSet<K>) -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        if !self.note(key, Instant::now()) {
            return;
        }
        tokio::spawn(async move {
            if let Some(keys) = self.wait().await {
                refresh(keys).await;
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    const SETTLE: Duration = Duration::from_secs(1);
    const MAX_WAIT: Duration = Duration::from_secs(10);

    #[test]
    fn a_burst_runs_once_it_has_been_quiet() {
        let settle = Settle::new(SETTLE, MAX_WAIT);
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
        let settle = Settle::new(SETTLE, MAX_WAIT);
        let start = Instant::now();
        assert!(settle.note(7, start));
        for step in 1..=40 {
            assert!(!settle.note(7, start + Duration::from_millis(step * 500)));
        }
        assert_eq!(settle.due(), Some(start + MAX_WAIT));
        assert_eq!(settle.take_due(start + MAX_WAIT), Some(BTreeSet::from([7])));
    }

    /// A burst scheduled from several events runs its refresh once, with
    /// every key it named, and the next event begins a fresh burst.
    #[tokio::test]
    async fn a_scheduled_burst_refreshes_once_with_every_key() {
        static BURST: Settle<i64> = Settle::new(Duration::from_millis(20), Duration::from_secs(1));
        let runs = Arc::new(Mutex::new(Vec::new()));
        for pid in [7, 9, 7] {
            let runs = Arc::clone(&runs);
            BURST.schedule(pid, move |pids| async move {
                runs.lock().unwrap().push(pids);
            });
        }
        tokio::time::timeout(Duration::from_secs(2), async {
            while runs.lock().unwrap().is_empty() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("the burst settled");
        tokio::time::sleep(Duration::from_millis(60)).await;
        assert_eq!(*runs.lock().unwrap(), [BTreeSet::from([7, 9])]);
        assert!(BURST.due().is_none(), "the burst ended");
    }
}
