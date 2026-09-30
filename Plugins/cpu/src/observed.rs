//! Host cadences scoped to status observation.
//!
//! This plugin is status-bound: the host runs it only while a status surface
//! shows one of its segments — except once a command has started it, when it
//! keeps running unobserved. Its cadences therefore follow
//! `core:status.observed` as well: cancelled while none of its segments is
//! shown, re-armed as soon as one is, so an unobserved process never samples.

use std::future::Future;
use std::sync::{Mutex, MutexGuard};
use std::time::Duration;

use flash_plugin::{Context, PollHandle};

#[derive(Default)]
pub(crate) struct ObservedCadences {
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    /// `None` until the host's first report, which arrives right after
    /// initialize: until then the cadences run.
    observed: Option<bool>,
    polls: Vec<(PollHandle, Duration)>,
}

impl ObservedCadences {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// Register a host cadence that ticks only while a segment is observed.
    pub(crate) fn interval<F, Fut>(&self, ctx: &Context, period: Duration, tick: F)
    where
        F: FnMut(Context) -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let handle = ctx.interval(period, tick);
        let mut state = self.lock();
        if state.observed == Some(false) {
            handle.cancel();
        }
        state.polls.push((handle, period));
    }

    /// Whether a surface may show a segment: false only once the host has
    /// reported that none is shown.
    pub(crate) fn observed(&self) -> bool {
        self.lock().observed != Some(false)
    }

    /// Apply the host's observed segment set. True when the cadences were
    /// just re-armed, so the caller refreshes now rather than a period later.
    pub(crate) fn observe(&self, segments: &[String]) -> bool {
        let observed = !segments.is_empty();
        let mut state = self.lock();
        let previous = state.observed.replace(observed);
        if previous == Some(observed) || (previous.is_none() && observed) {
            return false;
        }
        for (handle, period) in &state.polls {
            if observed {
                handle.set_period(*period);
            } else {
                handle.cancel();
            }
        }
        observed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;

    fn segments(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    #[tokio::test]
    async fn cadences_tick_only_while_a_segment_is_observed() {
        let mut harness = Harness::new("observed");
        let ctx = harness.context();
        let cadences = ObservedCadences::default();
        cadences.interval(&ctx, Duration::from_secs(1), |_| async {});
        assert!(cadences.observed(), "unknown until the host reports");
        assert!(
            !cadences.observe(&segments(&["summary"])),
            "armed since registration"
        );
        assert!(!cadences.observe(&[]));
        assert!(!cadences.observe(&[]));
        assert!(!cadences.observed());
        assert!(
            cadences.observe(&segments(&["label"])),
            "re-armed: refresh now"
        );
        assert!(!cadences.observe(&[]));
        cadences.interval(&ctx, Duration::from_secs(15), |_| async {});
        let polls: Vec<String> = harness
            .drain()
            .into_iter()
            .filter(|frame| frame["method"] == "poll")
            .map(|frame| frame["params"]["intervals"].to_string())
            .collect();
        assert_eq!(
            polls,
            [
                r#"{"i0":1.0}"#,
                "{}",
                r#"{"i0":1.0}"#,
                "{}",
                r#"{"i1":15.0}"#,
                "{}",
            ],
            "only transitions reach the host; unobserved registrations stay cancelled"
        );
    }
}
