//! The items of an Apple app Flash holds the grant for (`host.notes`,
//! `host.reminders`, `host.contacts`): the app, its framework and the grant
//! stay in the resident, and a plugin holding the capability of the same
//! name reads the access macOS grants Flash, asks for it, lists the items
//! and has one shown in its app through these typed calls.
//!
//! An item crosses the wire as an identifier and the one line its app shows
//! it by ([`AppItem`]): never a note's text, a reminder's notes or a card's
//! phone numbers. Which rows the items make, and in what order, is the
//! plugin's to decide; [`ItemCatalog`](crate::ItemCatalog) keeps them
//! listed.

use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::context::Context;
use crate::grant::{GrantAccess, access_from_response, failure};

/// Every `operation` of the three RPCs (`protocol.json`
/// `app_items.operations`).
#[cfg(test)]
pub(crate) const OPERATIONS: [&str; 4] = ["access", "request_access", "list", "show"];

/// The longest identifier [`Context::show_app_item`] takes, in bytes
/// (`app_items.max_id_bytes`).
pub const MAX_APP_ITEM_ID_BYTES: usize = 1_024;

/// How long a listing waits for its reply: the host gives Notes' script
/// thirty seconds.
const LIST_TIMEOUT: Duration = Duration::from_secs(35);
/// How long a `show` waits: inside the `perform` deadline.
const SHOW_TIMEOUT: Duration = Duration::from_secs(9);

/// An app whose items the host lists, each behind the capability of its
/// name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppItems {
    /// Every note of every account (`host.notes`, capability `notes`).
    Notes,
    /// Every open reminder (`host.reminders`, capability `reminders`).
    Reminders,
    /// Every contact card (`host.contacts`, capability `contacts`).
    Contacts,
}

impl AppItems {
    /// In `protocol.json` order.
    pub const ALL: [Self; 3] = [Self::Notes, Self::Reminders, Self::Contacts];

    /// The host RPC that reads it.
    pub fn method(self) -> &'static str {
        match self {
            Self::Notes => "host.notes",
            Self::Reminders => "host.reminders",
            Self::Contacts => "host.contacts",
        }
    }
}

/// One item (`protocol.json` `app_item`).
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
pub struct AppItem {
    /// Selects the item in its app again ([`Context::show_app_item`]).
    pub id: String,
    /// A note's name, a reminder's title, the name Contacts shows a card by.
    /// The host cuts it to the title quota; it may be empty.
    pub title: String,
    /// A reminder's list: its title.
    #[serde(default)]
    pub list: Option<String>,
    /// The position of a reminder's list among Reminders' lists, from 0;
    /// `None` when Reminders no longer names the list.
    #[serde(default)]
    pub list_index: Option<u64>,
    /// When a reminder was created, in Unix seconds.
    #[serde(default)]
    pub created: Option<f64>,
}

/// What one listing found.
#[derive(Clone, Debug, PartialEq)]
pub enum AppItemListing {
    /// The items, in the app's own order. `truncated`: the host left later
    /// items out of the reply (`app_items.max_items`, `reply_bytes`).
    Items {
        items: Vec<AppItem>,
        truncated: bool,
    },
    /// macOS grants no access: nothing was read.
    NoAccess(GrantAccess),
}

/// A `list` reply; one malformed item refuses them all.
pub(crate) fn listing_from_response(
    mut response: Value,
    method: &str,
) -> Result<AppItemListing, String> {
    let access = access_from_response(&response, method)?;
    if access != GrantAccess::Granted {
        return Ok(AppItemListing::NoAccess(access));
    }
    let truncated = response.get("truncated").and_then(Value::as_bool) == Some(true);
    let items = response
        .get_mut("items")
        .filter(|items| items.is_array())
        .map(Value::take)
        .ok_or_else(|| format!("{method} response missing items"))?;
    let items: Vec<AppItem> = serde_json::from_value(items)
        .map_err(|_| format!("{method} response has a malformed item"))?;
    if items
        .iter()
        .any(|item| item.created.is_some_and(|created| !created.is_finite()))
    {
        return Err(format!("{method} response has a malformed item"));
    }
    Ok(AppItemListing::Items { items, truncated })
}

impl Context {
    /// What macOS answers about Flash's grant for `app`, without asking
    /// (`access`). Requires the capability of the app's name, as every call
    /// here does. Notes also reads [`GrantAccess::Undetermined`] while it is
    /// not running: macOS has nobody to ask about.
    pub async fn app_items_access(&self, app: AppItems) -> Result<GrantAccess, String> {
        let params = json!({ "operation": "access" });
        access_from_response(&self.call_host(app.method(), params).await, app.method())
    }

    /// The same, asking macOS first when Flash never asked
    /// (`request_access`): the answer is then `Granted` or `Denied`, once
    /// the user gave it, or still `Undetermined` when macOS cannot be asked
    /// (Notes is not running). The host shows the prompt only while the
    /// user is using the plugin and answers
    /// [`USER_REQUEST_REQUIRED_ERROR`](crate::USER_REQUEST_REQUIRED_ERROR)
    /// otherwise. A prompt left open longer than `timeout` is the host-call
    /// timeout error.
    pub async fn request_app_items_access(
        &self,
        app: AppItems,
        timeout: Duration,
    ) -> Result<GrantAccess, String> {
        let params = json!({ "operation": "request_access" });
        access_from_response(
            &self.call_host_timeout(app.method(), params, timeout).await,
            app.method(),
        )
    }

    /// Every item of `app`, in the app's own order (`list`). It never asks
    /// macOS: without the grant it answers [`AppItemListing::NoAccess`].
    pub async fn app_items(&self, app: AppItems) -> Result<AppItemListing, String> {
        let params = json!({ "operation": "list" });
        listing_from_response(
            self.call_host_timeout(app.method(), params, LIST_TIMEOUT)
                .await,
            app.method(),
        )
    }

    /// Bring `app` forward on the item `id` names (`show`): an identifier a
    /// listing returned, at most [`MAX_APP_ITEM_ID_BYTES`] long. The host
    /// refuses it without the grant.
    pub async fn show_app_item(&self, app: AppItems, id: &str) -> Result<(), String> {
        let params = json!({ "operation": "show", "id": id });
        let response = self
            .call_host_timeout(app.method(), params, SHOW_TIMEOUT)
            .await;
        if response.get("ok").and_then(Value::as_bool) == Some(true) {
            Ok(())
        } else {
            Err(failure(&response, &format!("{} failed", app.method())))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::Harness;

    fn reminder() -> Value {
        json!({
            "id": "5F8A-R1", "title": "Buy milk", "list": "Inbox", "list_index": 0,
            "created": 1_800_000_000u64,
        })
    }

    #[test]
    fn a_listing_decodes_whole_or_not_at_all() {
        let note = json!({ "id": "x-coredata://4F1C/ICNote/p12", "title": "" });
        let reply = json!({ "ok": true, "access": "granted", "items": [reminder(), note] });
        let AppItemListing::Items { items, truncated } =
            listing_from_response(reply, "host.reminders").unwrap()
        else {
            panic!("a granted listing");
        };
        assert!(!truncated);
        assert_eq!(
            items[0],
            AppItem {
                id: "5F8A-R1".into(),
                title: "Buy milk".into(),
                list: Some("Inbox".into()),
                list_index: Some(0),
                created: Some(1_800_000_000.0),
            }
        );
        assert_eq!(
            items[1],
            AppItem {
                id: "x-coredata://4F1C/ICNote/p12".into(),
                ..AppItem::default()
            }
        );
        assert_eq!(
            listing_from_response(
                json!({ "ok": true, "access": "granted", "items": [], "truncated": true }),
                "host.notes"
            ),
            Ok(AppItemListing::Items {
                items: Vec::new(),
                truncated: true
            })
        );

        let malformed = |change: fn(&mut Value)| {
            let mut item = reminder();
            change(&mut item);
            listing_from_response(
                json!({ "ok": true, "access": "granted", "items": [item] }),
                "host.reminders",
            )
        };
        for change in [
            (|item| item["id"] = json!(7)) as fn(&mut Value),
            |item| {
                item.as_object_mut().unwrap().remove("title");
            },
            |item| item["list"] = json!(["Inbox"]),
            |item| item["list_index"] = json!(-1),
            |item| item["list_index"] = json!("0"),
            |item| item["created"] = json!("1800000000"),
        ] {
            assert_eq!(
                malformed(change),
                Err("host.reminders response has a malformed item".to_string())
            );
        }
        for reply in [
            json!({ "ok": true, "access": "granted" }),
            json!({ "ok": true, "access": "granted", "items": { "id": "a" } }),
        ] {
            assert_eq!(
                listing_from_response(reply, "host.notes"),
                Err("host.notes response missing items".to_string())
            );
        }
    }

    #[test]
    fn a_reply_without_the_grant_is_the_access_alone() {
        for (name, access) in [
            ("denied", GrantAccess::Denied),
            ("undetermined", GrantAccess::Undetermined),
        ] {
            assert_eq!(
                listing_from_response(json!({ "ok": true, "access": name }), "host.contacts"),
                Ok(AppItemListing::NoAccess(access))
            );
        }
        assert_eq!(
            listing_from_response(json!({ "ok": false }), "host.contacts"),
            Err("host.contacts failed".to_string())
        );
    }

    #[tokio::test]
    async fn each_app_is_read_through_its_own_method() {
        for app in AppItems::ALL {
            let mut harness = Harness::new("items");
            let ctx = harness.context();
            let task = tokio::spawn(async move { ctx.app_items(app).await });
            let (id, method, params) = harness.next_host_request().await.unwrap();
            assert_eq!(method, app.method());
            assert_eq!(params, json!({ "operation": "list" }));
            assert!(harness.reply_host(id, json!({ "ok": true, "access": "denied" })));
            assert_eq!(
                task.await.unwrap(),
                Ok(AppItemListing::NoAccess(GrantAccess::Denied))
            );

            let ctx = harness.context();
            let task = tokio::spawn(async move { ctx.show_app_item(app, "5F8A").await });
            let (id, method, params) = harness.next_host_request().await.unwrap();
            assert_eq!(method, app.method());
            assert_eq!(params, json!({ "operation": "show", "id": "5F8A" }));
            let refusal = format!("{} show requires access", app.method());
            assert!(harness.reply_host(id, json!({ "ok": false, "error": refusal })));
            assert_eq!(task.await.unwrap(), Err(refusal));
        }
    }

    #[tokio::test]
    async fn a_prompt_left_open_is_the_timeout_error() {
        let mut harness = Harness::new("items");
        let ctx = harness.context();
        let task = tokio::spawn(async move {
            ctx.request_app_items_access(AppItems::Notes, Duration::from_millis(20))
                .await
        });
        let (_, method, params) = harness.next_host_request().await.unwrap();
        assert_eq!(method, "host.notes");
        assert_eq!(params, json!({ "operation": "request_access" }));
        assert_eq!(
            task.await.unwrap(),
            Err(crate::context::HOST_TIMEOUT_ERROR.to_string())
        );
    }

    #[test]
    fn the_app_items_contract_matches_the_shared_protocol() {
        let contract: Value = serde_json::from_str(include_str!("../protocol.json")).unwrap();
        let items = &contract["app_items"];
        let methods: Vec<&str> = AppItems::ALL.iter().map(|app| app.method()).collect();
        assert_eq!(items["methods"], json!(methods));
        assert_eq!(items["operations"], json!(OPERATIONS));
        assert_eq!(items["max_id_bytes"], MAX_APP_ITEM_ID_BYTES);
        for app in AppItems::ALL {
            let capability = app.method().trim_start_matches("host.");
            assert_eq!(
                contract["methods"]["plugin_to_host_rpcs"][app.method()],
                capability
            );
            assert!(
                contract["capabilities"]
                    .as_array()
                    .unwrap()
                    .contains(&Value::from(capability))
            );
        }
        // Every key of the item shape is one this decoder reads.
        let mut keys: Vec<String> = ["required", "optional"]
            .iter()
            .flat_map(|group| contract["app_item"][group].as_array().unwrap())
            .map(|key| key.as_str().unwrap().to_string())
            .collect();
        keys.sort();
        let mut read: Vec<String> = reminder().as_object().unwrap().keys().cloned().collect();
        read.sort();
        assert_eq!(keys, read);
    }
}
