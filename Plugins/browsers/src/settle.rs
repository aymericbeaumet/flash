//! Trailing debounce with a ceiling, for refreshes keyed to `core:ax.changed`.
//!
//! The host forwards every AX notification of the focused app — the value
//! change of each keystroke included — without naming it, so a refresh keyed
//! to that event waits for the burst to settle: it runs once the app has been
//! quiet for `settle`, and at the latest `max_wait` after the burst began, so
//! an app that never goes quiet still refreshes at that bound. An idle app
//! costs nothing.

use std::collections::BTreeSet;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub(crate) struct Settle {
    settle: Duration,
    max_wait: Duration,
    burst: Mutex<Option<Burst>>,
}

struct Burst {
    first: Instant,
    last: Instant,
    pids: BTreeSet<i64>,
}

impl Burst {
    fn due(&self, settle: Duration, max_wait: Duration) -> Instant {
        (self.last + settle).min(self.first + max_wait)
    }
}

impl Settle {
    pub(crate) const fn new(settle: Duration, max_wait: Duration) -> Self {
        Self {
            settle,
            max_wait,
            burst: Mutex::new(None),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Option<Burst>> {
        self.burst.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Record an event for `pid` at `now`. True when it began a burst: the
    /// caller then spawns the one task that [`wait`](Self::wait)s for it.
    pub(crate) fn note(&self, pid: i64, now: Instant) -> bool {
        let mut burst = self.lock();
        match burst.as_mut() {
            Some(burst) => {
                burst.last = burst.last.max(now);
                burst.pids.insert(pid);
                false
            }
            None => {
                *burst = Some(Burst {
                    first: now,
                    last: now,
                    pids: BTreeSet::from([pid]),
                });
                true
            }
        }
    }

    /// When the pending burst is due; `None` when nothing is pending.
    pub(crate) fn due(&self) -> Option<Instant> {
        self.lock()
            .as_ref()
            .map(|burst| burst.due(self.settle, self.max_wait))
    }

    /// The pids of a burst due at `now`, ending it; `None` while it is still
    /// settling or when nothing is pending.
    pub(crate) fn take_due(&self, now: Instant) -> Option<BTreeSet<i64>> {
        let mut burst = self.lock();
        if burst.as_ref()?.due(self.settle, self.max_wait) > now {
            return None;
        }
        burst.take().map(|burst| burst.pids)
    }

    /// Sleep until the pending burst settles and return its pids.
    pub(crate) async fn wait(&self) -> Option<BTreeSet<i64>> {
        loop {
            let due = self.due()?;
            tokio::time::sleep_until(tokio::time::Instant::from_std(due)).await;
            if let Some(pids) = self.take_due(Instant::now()) {
                return Some(pids);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn a_never_quiet_app_still_runs_at_the_ceiling() {
        let settle = Settle::new(SETTLE, MAX_WAIT);
        let start = Instant::now();
        assert!(settle.note(7, start));
        for step in 1..=40 {
            assert!(!settle.note(7, start + Duration::from_millis(step * 500)));
        }
        assert_eq!(settle.due(), Some(start + MAX_WAIT));
        assert_eq!(settle.take_due(start + MAX_WAIT), Some(BTreeSet::from([7])));
    }
}
