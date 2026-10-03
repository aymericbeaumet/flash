//! The host names each user interaction with a short trace id and sends it on
//! the requests it causes (`trace` on the request envelope). The runtime runs
//! each request's handler inside that id, and every `log` notification the
//! handler emits carries it back, so the host log shows one interaction end
//! to end across processes.

tokio::task_local! {
    static TRACE: Option<String>;
}

/// The trace id of the request the current task serves, if any. Tasks the
/// handler spawns itself start outside it.
pub(crate) fn current() -> Option<String> {
    TRACE.try_with(Clone::clone).ok().flatten()
}

/// Run `future` as the handler of a request carrying `trace`.
pub(crate) async fn scope<F: std::future::Future>(trace: Option<String>, future: F) -> F::Output {
    TRACE.scope(trace, future).await
}

/// A well-formed id, `^[0-9a-z]{1,16}$` as `protocol.json` pins it and the
/// host mints them; anything else is ignored.
pub(crate) fn from_envelope(frame: &serde_json::Value) -> Option<String> {
    let id = frame.get("trace")?.as_str()?;
    let valid = (1..=16).contains(&id.len())
        && id
            .bytes()
            .all(|byte| byte.is_ascii_digit() || byte.is_ascii_lowercase());
    valid.then(|| id.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn the_id_pattern_matches_the_shared_protocol_contract() {
        let contract: serde_json::Value =
            serde_json::from_str(include_str!("../protocol.json")).unwrap();
        assert_eq!(contract["trace"]["pattern"], "^[0-9a-z]{1,16}$");
    }

    #[test]
    fn envelope_trace_ids_are_validated() {
        assert_eq!(
            from_envelope(&json!({"trace": "k3f9"})).as_deref(),
            Some("k3f9")
        );
        assert_eq!(from_envelope(&json!({"trace": "K3F9"})), None);
        assert_eq!(from_envelope(&json!({"trace": "a".repeat(17)})), None);
        assert_eq!(from_envelope(&json!({"trace": 7})), None);
        assert_eq!(from_envelope(&json!({})), None);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn handlers_run_inside_their_trace() {
        assert_eq!(current(), None);
        let seen = scope(Some("k3f9".to_owned()), async { current() }).await;
        assert_eq!(seen.as_deref(), Some("k3f9"));
        assert_eq!(current(), None);
    }
}
