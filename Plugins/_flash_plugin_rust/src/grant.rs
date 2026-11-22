//! A macOS privacy grant Flash holds on a plugin's behalf: Calendars,
//! Reminders, Contacts, Automation of Notes. The plugin never holds one; it
//! reads what macOS answers about Flash's through the host RPC of the data
//! it reaches ([`Context::calendar_access`](crate::Context::calendar_access),
//! [`Context::app_items_access`](crate::Context::app_items_access)), and
//! may have the host ask.
//!
//! macOS names Flash in its prompt. The host shows it only while the user
//! is using the plugin: one of its performs or searches is in flight, or a
//! status surface shows one of its segments. Ask from `on_command`, from
//! `on_search`, or when `core:status.observed` first lists a segment, never
//! from a background refresh.

use serde_json::Value;

/// What the host answers a request that would show macOS's prompt while the
/// user is not using the plugin (`errors.user_request_required`).
pub const USER_REQUEST_REQUIRED_ERROR: &str = "requires the user to be using the plugin";

/// What macOS answers about one of Flash's grants, without asking.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrantAccess {
    Granted,
    /// The user refused, a policy did, or the grant is too narrow to read.
    Denied,
    /// Flash never asked.
    Undetermined,
}

impl GrantAccess {
    /// In `protocol.json` order.
    pub const ALL: [Self; 3] = [Self::Granted, Self::Denied, Self::Undetermined];

    /// The name on the wire.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Granted => "granted",
            Self::Denied => "denied",
            Self::Undetermined => "undetermined",
        }
    }

    fn from_wire(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|access| access.as_str() == name)
    }
}

/// The host's error, or `fallback` for a failure that carries none.
pub(crate) fn failure(response: &Value, fallback: &str) -> String {
    response
        .get("error")
        .and_then(Value::as_str)
        .filter(|error| !error.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

/// The `access` of any successful reply of `method`.
pub(crate) fn access_from_response(response: &Value, method: &str) -> Result<GrantAccess, String> {
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(failure(response, &format!("{method} failed")));
    }
    response
        .get("access")
        .and_then(Value::as_str)
        .and_then(GrantAccess::from_wire)
        .ok_or_else(|| format!("{method} response missing access"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_reply_names_the_access_or_fails_whole() {
        for access in GrantAccess::ALL {
            assert_eq!(
                access_from_response(&json!({ "ok": true, "access": access.as_str() }), "host.x"),
                Ok(access)
            );
        }
        for reply in [
            json!({ "ok": true }),
            json!({ "ok": true, "access": "limited" }),
            json!({ "ok": true, "access": true }),
        ] {
            assert_eq!(
                access_from_response(&reply, "host.x"),
                Err("host.x response missing access".to_string()),
                "{reply}"
            );
        }
        assert_eq!(
            access_from_response(
                &json!({ "ok": false, "error": USER_REQUEST_REQUIRED_ERROR }),
                "host.x"
            ),
            Err(USER_REQUEST_REQUIRED_ERROR.to_string())
        );
        assert_eq!(
            access_from_response(&json!({ "ok": false }), "host.x"),
            Err("host.x failed".to_string())
        );
    }

    #[test]
    fn the_grant_contract_matches_the_shared_protocol() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let access: Vec<&str> = GrantAccess::ALL.iter().map(|a| a.as_str()).collect();
        for section in ["calendar_events", "app_items"] {
            assert_eq!(contract[section]["access"], json!(access), "{section}");
        }
        assert_eq!(
            contract["errors"]["user_request_required"],
            USER_REQUEST_REQUIRED_ERROR
        );
    }
}
