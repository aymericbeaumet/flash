//! Request deadlines. The host names how long it will wait for a request's
//! reply (`deadline_ms` on the envelope). A read-only handler (`search`,
//! `hints`) still running just before then is dropped — its subprocesses and
//! host calls with it — and the request answers `deadline exceeded` while the
//! host still listens, instead of a reply it would discard.

use std::future::Future;
use std::time::Duration;

/// Canonical error (pinned in `protocol.json` as `errors.deadline_exceeded`).
pub(crate) const DEADLINE_EXCEEDED_ERROR: &str = "deadline exceeded";

/// No host deadline is longer: a manifest `timeout_ms` perform override.
const MAX_DEADLINE_MS: u64 = 600_000;

/// The request's deadline, when the envelope names a well-formed one.
pub(crate) fn from_envelope(frame: &serde_json::Value) -> Option<Duration> {
    let ms = frame.get("deadline_ms")?.as_u64()?;
    (1..=MAX_DEADLINE_MS)
        .contains(&ms)
        .then(|| Duration::from_millis(ms))
}

/// How long a handler may run: the deadline less the reply's way back to the
/// host, a tenth of it and at most 50 ms.
pub(crate) fn handler_budget(deadline: Duration) -> Duration {
    deadline - (deadline / 10).min(Duration::from_millis(50))
}

/// Run `handler` within `deadline`'s budget; `None` when it ran out. Without
/// a deadline the handler runs to completion.
pub(crate) async fn within<T>(
    deadline: Option<Duration>,
    handler: impl Future<Output = T>,
) -> Option<T> {
    match deadline {
        Some(deadline) => tokio::time::timeout(handler_budget(deadline), handler)
            .await
            .ok(),
        None => Some(handler.await),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_error_matches_the_shared_protocol_contract() {
        let contract: serde_json::Value =
            serde_json::from_str(include_str!("../protocol.json")).unwrap();
        assert_eq!(
            contract["errors"]["deadline_exceeded"],
            DEADLINE_EXCEEDED_ERROR
        );
    }

    #[test]
    fn envelope_deadlines_are_validated() {
        assert_eq!(
            from_envelope(&json!({"deadline_ms": 500})),
            Some(Duration::from_millis(500))
        );
        assert_eq!(from_envelope(&json!({"deadline_ms": 0})), None);
        assert_eq!(from_envelope(&json!({"deadline_ms": -5})), None);
        assert_eq!(from_envelope(&json!({"deadline_ms": 600_001})), None);
        assert_eq!(from_envelope(&json!({"deadline_ms": "500"})), None);
        assert_eq!(from_envelope(&json!({})), None);
    }

    #[test]
    fn the_budget_leaves_the_reply_time_to_arrive() {
        assert_eq!(
            handler_budget(Duration::from_millis(500)),
            Duration::from_millis(450)
        );
        assert_eq!(
            handler_budget(Duration::from_millis(50)),
            Duration::from_millis(45)
        );
        assert_eq!(
            handler_budget(Duration::from_secs(10)),
            Duration::from_millis(9_950)
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn a_handler_past_its_budget_is_dropped() {
        let slow = within(Some(Duration::from_millis(20)), async {
            tokio::time::sleep(Duration::from_secs(5)).await;
        });
        assert_eq!(slow.await, None);
        let quick = within(Some(Duration::from_millis(100)), async { 7 });
        assert_eq!(quick.await, Some(7));
        assert_eq!(within(None, async { 7 }).await, Some(7));
    }
}
