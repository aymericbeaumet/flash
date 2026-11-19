//! Signals to other processes (`host.process_signal`): `kill(2)` stays in
//! the resident, and a plugin holding the `process_signal` capability asks
//! for one signal to one pid.
//!
//! The host honours a signal only inside a `perform` the user confirmed (a
//! command or a row that declares `confirm`), one signal per confirmed
//! perform, and refuses it anywhere else. It never signals itself, launchd
//! or a process group. A plugin cannot grant itself that consent.

use serde_json::{Value, json};

use crate::context::Context;

/// One signal of `host.process_signal` (`protocol.json`
/// `process_signals.signals`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProcessSignal {
    /// SIGTERM: ask the process to quit.
    Term,
}

impl ProcessSignal {
    /// In `protocol.json` order.
    pub const ALL: [Self; 1] = [Self::Term];

    /// The name on the wire.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Term => "term",
        }
    }
}

/// What a host reply states: sent, or the host's reason.
pub(crate) fn result_from_response(response: &Value) -> Result<(), String> {
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(());
    }
    Err(response
        .get("error")
        .and_then(Value::as_str)
        .filter(|error| !error.is_empty())
        .unwrap_or("host.process_signal failed")
        .to_string())
}

impl Context {
    /// Ask the host to signal one process (`host.process_signal`). Requires
    /// the `process_signal` capability. `Err` is the host's reason: the
    /// kernel's (`No such process`, `Operation not permitted`), a pid the
    /// host never signals, or, outside a perform the user confirmed,
    /// [`CONFIRMATION_REQUIRED_ERROR`](crate::CONFIRMATION_REQUIRED_ERROR).
    /// Call it from the `on_command` or `on_resolve` of a command or row
    /// that declares `confirm`, once, and nowhere else.
    pub async fn signal_process(&self, pid: i64, signal: ProcessSignal) -> Result<(), String> {
        let params = json!({ "pid": pid, "signal": signal.as_str() });
        result_from_response(&self.call_host("host.process_signal", params).await)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Harness;

    #[test]
    fn a_reply_is_sent_or_the_hosts_reason() {
        assert_eq!(result_from_response(&json!({ "ok": true })), Ok(()));
        assert_eq!(
            result_from_response(&json!({ "ok": false, "error": "No such process" })),
            Err("No such process".to_string())
        );
        assert_eq!(
            result_from_response(
                &json!({ "ok": false, "error": crate::CONFIRMATION_REQUIRED_ERROR })
            ),
            Err(crate::CONFIRMATION_REQUIRED_ERROR.to_string())
        );
        assert_eq!(
            result_from_response(&json!({ "ok": false })),
            Err("host.process_signal failed".to_string())
        );
    }

    #[tokio::test]
    async fn a_signal_is_one_request_naming_the_pid_and_the_signal() {
        let mut harness = Harness::new("processes");
        let ctx = harness.context();
        let task = tokio::spawn(async move { ctx.signal_process(4242, ProcessSignal::Term).await });
        let (id, method, params) = harness.next_host_request().await.unwrap();
        assert_eq!(method, "host.process_signal");
        assert_eq!(params, json!({ "pid": 4242, "signal": "term" }));
        assert!(harness.reply_host(id, json!({ "ok": true })));
        assert_eq!(task.await.unwrap(), Ok(()));
    }

    #[test]
    fn the_signals_match_the_shared_protocol() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let signals: Vec<&str> = ProcessSignal::ALL.iter().map(|s| s.as_str()).collect();
        assert_eq!(contract["process_signals"]["signals"], json!(signals));
        assert_eq!(contract["process_signals"]["min_pid"], 2);
        assert_eq!(
            contract["methods"]["plugin_to_host_rpcs"]["host.process_signal"],
            "process_signal"
        );
        assert!(
            contract["capabilities"]
                .as_array()
                .unwrap()
                .contains(&Value::from("process_signal"))
        );
    }
}
