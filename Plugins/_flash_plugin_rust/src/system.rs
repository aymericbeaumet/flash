//! The host's machine and session actions (`host.system_action`): the lock
//! chord, IOKit power management and the System Events and Finder scripts
//! stay in the resident, and a plugin holding the `system_actions` capability
//! asks for one by name.
//!
//! An action nothing undoes is [destructive](SystemAction::is_destructive):
//! the host honours it only inside a `perform` the user confirmed (a command
//! or a row that declares `confirm`), one action per confirmed perform, and
//! refuses it anywhere else. A plugin cannot grant itself that consent.

use std::time::Duration;

use serde_json::{Value, json};

use crate::context::Context;

/// How long [`Context::system_action`] waits for the host: inside the
/// `perform` deadline, so a command still answers when macOS takes its time
/// (a full Trash, an Automation prompt left open).
const WAIT: Duration = Duration::from_secs(8);

/// The refusal of a destructive action asked outside a confirmed perform
/// (`protocol.json` `errors.confirmation_required`).
pub const CONFIRMATION_REQUIRED_ERROR: &str = "requires a perform the user confirmed";

/// One action of `host.system_action` (`protocol.json`
/// `system_actions.actions`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SystemAction {
    LockScreen,
    Sleep,
    DisplaySleep,
    Screensaver,
    ToggleAppearance,
    Restart,
    Shutdown,
    Logout,
    EmptyTrash,
}

impl SystemAction {
    /// In `protocol.json` order.
    pub const ALL: [Self; 9] = [
        Self::LockScreen,
        Self::Sleep,
        Self::DisplaySleep,
        Self::Screensaver,
        Self::ToggleAppearance,
        Self::Restart,
        Self::Shutdown,
        Self::Logout,
        Self::EmptyTrash,
    ];

    /// The name on the wire.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::LockScreen => "lock_screen",
            Self::Sleep => "sleep",
            Self::DisplaySleep => "display_sleep",
            Self::Screensaver => "screensaver",
            Self::ToggleAppearance => "toggle_appearance",
            Self::Restart => "restart",
            Self::Shutdown => "shutdown",
            Self::Logout => "logout",
            Self::EmptyTrash => "empty_trash",
        }
    }

    /// Whether nothing undoes it: the host then needs a perform the user
    /// confirmed (`system_actions.destructive`).
    pub fn is_destructive(self) -> bool {
        matches!(
            self,
            Self::Restart | Self::Shutdown | Self::Logout | Self::EmptyTrash
        )
    }
}

/// How a system action the host accepted stands when the call returns.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SystemActionOutcome {
    /// The host asked macOS for it and macOS took the request.
    Done,
    /// The host has not answered within the wait and is still at it: Finder
    /// emptying a full Trash, or an Automation prompt nobody answered yet.
    Pending,
}

/// The outcome a host reply states: done, or the host's reason.
pub(crate) fn outcome_from_response(response: &Value) -> Result<SystemActionOutcome, String> {
    if response.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(SystemActionOutcome::Done);
    }
    let error = response
        .get("error")
        .and_then(Value::as_str)
        .filter(|error| !error.is_empty())
        .unwrap_or("host.system_action failed");
    if error == crate::context::HOST_TIMEOUT_ERROR {
        return Ok(SystemActionOutcome::Pending);
    }
    Err(error.to_string())
}

impl Context {
    /// Ask the host for one system action (`host.system_action`). Requires
    /// the `system_actions` capability. `Err` is the host's reason: a
    /// mechanism that failed, or, for a destructive action asked outside a
    /// perform the user confirmed, [`CONFIRMATION_REQUIRED_ERROR`]. Call a
    /// destructive action from the `on_command` or `on_resolve` of a command
    /// or row that declares `confirm`, and nowhere else.
    pub async fn system_action(&self, action: SystemAction) -> Result<SystemActionOutcome, String> {
        let params = json!({ "action": action.as_str() });
        outcome_from_response(
            &self
                .call_host_timeout("host.system_action", params, WAIT)
                .await,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Harness;

    #[test]
    fn a_reply_is_done_pending_or_the_hosts_reason() {
        assert_eq!(
            outcome_from_response(&json!({ "ok": true })),
            Ok(SystemActionOutcome::Done)
        );
        assert_eq!(
            outcome_from_response(&json!({ "ok": false, "error": "host call timed out" })),
            Ok(SystemActionOutcome::Pending)
        );
        assert_eq!(
            outcome_from_response(&json!({ "ok": false, "error": CONFIRMATION_REQUIRED_ERROR })),
            Err(CONFIRMATION_REQUIRED_ERROR.to_string())
        );
        assert_eq!(
            outcome_from_response(&json!({ "ok": false, "error": "power management unavailable" })),
            Err("power management unavailable".to_string())
        );
        assert_eq!(
            outcome_from_response(&json!({ "ok": false })),
            Err("host.system_action failed".to_string())
        );
    }

    #[tokio::test]
    async fn an_action_is_one_request_naming_it() {
        let mut harness = Harness::new("system");
        for action in SystemAction::ALL {
            let ctx = harness.context();
            let task = tokio::spawn(async move { ctx.system_action(action).await });
            let (id, method, params) = harness.next_host_request().await.unwrap();
            assert_eq!(method, "host.system_action");
            assert_eq!(params, json!({ "action": action.as_str() }));
            assert!(harness.reply_host(id, json!({ "ok": true })));
            assert_eq!(task.await.unwrap(), Ok(SystemActionOutcome::Done));
        }
    }

    #[test]
    fn the_actions_match_the_shared_protocol() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let actions: Vec<&str> = SystemAction::ALL.iter().map(|a| a.as_str()).collect();
        assert_eq!(contract["system_actions"]["actions"], json!(actions));
        let destructive: Vec<&str> = SystemAction::ALL
            .iter()
            .filter(|action| action.is_destructive())
            .map(|action| action.as_str())
            .collect();
        assert_eq!(
            contract["system_actions"]["destructive"],
            json!(destructive)
        );
        assert_eq!(
            contract["errors"]["confirmation_required"],
            CONFIRMATION_REQUIRED_ERROR
        );
        assert_eq!(
            contract["methods"]["plugin_to_host_rpcs"]["host.system_action"],
            "system_actions"
        );
        assert!(
            contract["capabilities"]
                .as_array()
                .unwrap()
                .contains(&Value::from("system_actions"))
        );
        assert!(
            WAIT.as_millis() < contract["deadlines_ms"]["perform"].as_u64().unwrap() as u128,
            "a command answers inside its perform deadline"
        );
    }
}
