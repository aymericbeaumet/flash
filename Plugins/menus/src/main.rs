//! `@menus`: the menu-bar commands of the app you are in, as flashlight
//! rows. Picking one presses the menu item.
//!
//! Accessibility stays in the host. This plugin asks its broker for the menu
//! bar of the app that owns it, one snapshot per `@menus` scope, and decides
//! what a row is: which items are listed, under what title, in what order.
//! A row carries the handle the snapshot gave its item, and picking it asks
//! the host to press that handle. Nothing here opens a menu, posts a key or
//! moves the pointer.

mod bar;

use std::collections::BTreeMap;
use std::time::Duration;

use flash_plugin::{
    Candidate, Context, PerformResponse, SearchRequest, SearchResponse, ax_snapshot_roots, run,
};
use serde_json::{Value, json};

use bar::MenuBar;

/// The plugin's one source, live and `per_scope`: the rows do not depend on
/// what is typed after `@menus`, so the host asks once per scope, keeps the
/// rows while the scope lasts and filters them itself.
const SOURCE: &str = "menus.items";
/// The elements one snapshot may read: the broker's own default. A menu bar
/// larger than this is listed as far as the walk went.
const SNAPSHOT_NODES: usize = 3000;
/// Under the `search` deadline, so a menu bar that takes longer is answered
/// as an empty list and a log line instead of a dropped request.
const SNAPSHOT_TIMEOUT: Duration = Duration::from_millis(900);
const PRESS: &str = "AXPress";
/// The host's answer for a handle a later snapshot or a quit app retired.
const STALE_HANDLE: &str = "stale ax handle";

/// The app whose menu bar a snapshot read, and the rows of its items. A row
/// is the whole path to its item, so selecting it presses the item at once.
fn rows(pid: i64, bar: &MenuBar) -> Vec<Candidate> {
    bar.items()
        .into_iter()
        .map(|item| {
            Candidate::new(SOURCE, item.title)
                .pid(pid)
                .payload(item.handle.to_string())
                .finishes_command(true)
        })
        .collect()
}

/// A snapshot reply as `(pid, tree)`. `Ok(None)`: no app but Flash owns the
/// menu bar. `Err` is the host's refusal, or what was wrong with its reply.
fn menu_bar(reply: &Value) -> Result<Option<(i64, MenuBar)>, String> {
    if reply.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(reply
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("invalid host response")
            .to_string());
    }
    let nodes = reply
        .get("nodes")
        .and_then(Value::as_array)
        .ok_or("snapshot without nodes")?;
    let Some(pid) = reply.get("pid").and_then(Value::as_i64) else {
        return Ok(None);
    };
    let bar = MenuBar::from_nodes(nodes, SNAPSHOT_NODES).ok_or("malformed snapshot node")?;
    Ok(Some((pid, bar)))
}

struct Menus;

flash_plugin::plugin!(Menus);

impl FlashPlugin for Menus {
    async fn on_search(&self, ctx: Context, request: SearchRequest) -> SearchResponse {
        if request.source != SOURCE {
            return SearchResponse::default();
        }
        // Only what a row needs: three attributes, read with the children
        // in one round trip per element.
        let walk = json!({
            "root": ax_snapshot_roots::MENU_BAR,
            "follow": [bar::CHILDREN],
            "collect": [bar::ROLE, bar::TITLE, bar::ENABLED],
            "max_nodes": SNAPSHOT_NODES,
        });
        match menu_bar(&ctx.ax_snapshot_timeout(walk, SNAPSHOT_TIMEOUT).await) {
            Ok(Some((pid, bar))) => {
                let rows = rows(pid, &bar);
                ctx.log_fields(
                    "debug",
                    "[menus] walk",
                    BTreeMap::from([
                        ("nodes".to_string(), bar.len().to_string()),
                        ("items".to_string(), rows.len().to_string()),
                    ]),
                );
                SearchResponse::rows(rows)
            }
            Ok(None) => SearchResponse::default(),
            Err(reason) => {
                ctx.log("warn", &format!("[menus] snapshot failed: {reason}"));
                SearchResponse::default()
            }
        }
    }

    async fn on_resolve(&self, ctx: Context, row: Candidate) -> PerformResponse {
        let Some(handle) = row
            .payload_str()
            .and_then(|payload| payload.parse::<u64>().ok())
        else {
            return PerformResponse::fail("unknown menu item");
        };
        let reply = ctx
            .call_host(
                "host.ax_perform",
                json!({ "handle": handle, "action": PRESS }),
            )
            .await;
        if reply.get("ok").and_then(Value::as_bool) == Some(true) {
            let pressed = PerformResponse::ok();
            return match row.pid_value() {
                Some(pid) => pressed.target_pid(pid),
                None => pressed,
            };
        }
        match reply.get("error").and_then(Value::as_str) {
            // The menus were read again since, or the app quit: the item
            // this row named is not the host's to press any more.
            Some(STALE_HANDLE) => PerformResponse::fail("menu item is gone: search @menus again"),
            // The app did not confirm the press. An item that opens a
            // modal dialog answers only once the dialog closes, long after
            // the item ran, so this is no failure to report.
            Some(reason) => {
                ctx.log("warn", &format!("[menus] press unconfirmed: {reason}"));
                PerformResponse::unhandled()
            }
            None => PerformResponse::fail("invalid host response"),
        }
    }
}

fn main() {
    run(Menus);
}

#[cfg(test)]
mod tests {
    use super::bar::testing::Snapshot;
    use super::*;
    use flash_plugin::testing::Harness;

    fn manifest() -> Value {
        serde_json::from_str(include_str!("../manifest.json")).unwrap()
    }

    /// File › New Tab and File › Export › PDF…, behind an Apple menu.
    fn snapshot() -> Snapshot {
        let mut snapshot = Snapshot::bar();
        snapshot
            .bar_item(2, "Apple")
            .bar_item(3, "File")
            .menu(10, 2)
            .menu(20, 3)
            .item(11, 10, "About This Mac")
            .item(21, 20, "New Tab")
            .item(22, 20, "Export")
            .menu(30, 22)
            .item(31, 30, "PDF…");
        snapshot
    }

    fn search(source: &str) -> SearchRequest {
        SearchRequest {
            source: source.to_string(),
            query: String::new(),
        }
    }

    /// Answer the plugin's one snapshot with `reply`: the params it asked
    /// with, then its rows.
    async fn searched(reply: Value) -> (Value, Vec<Candidate>, Vec<Value>) {
        let mut harness = Harness::new("menus");
        let ctx = harness.context();
        let task = tokio::spawn(async move { Menus.on_search(ctx, search(SOURCE)).await });
        let (id, method, params) = harness.next_host_request().await.expect("a host call");
        assert_eq!(method, "host.ax_snapshot");
        assert!(harness.reply_host(id, reply));
        (params, task.await.unwrap().rows, harness.drain())
    }

    /// Answer the press a resolve of `row` asks for with `reply`.
    async fn resolved(row: Candidate, reply: Value) -> (Value, PerformResponse) {
        let mut harness = Harness::new("menus");
        let ctx = harness.context();
        let task = tokio::spawn(async move { Menus.on_resolve(ctx, row).await });
        let (id, method, params) = harness.next_host_request().await.expect("a host call");
        assert_eq!(method, "host.ax_perform");
        assert!(harness.reply_host(id, reply));
        (params, task.await.unwrap())
    }

    fn row(handle: &str) -> Candidate {
        Candidate::new(SOURCE, "File › New Tab")
            .pid(512)
            .payload(handle)
    }

    /// One live source of the shared type, pulled once per scope, behind
    /// the one capability the broker asks for, in the default sandbox.
    #[test]
    fn the_manifest_declares_one_live_source_and_the_accessibility_capability() {
        let manifest = manifest();
        assert_eq!(
            manifest["sources"],
            json!([{ "name": SOURCE, "type": "menus", "priority": "high", "live": "per_scope" }])
        );
        assert_eq!(manifest["capabilities"], json!(["accessibility"]));
        for surface in ["commands", "listen", "status", "hints", "query", "sandbox"] {
            assert!(manifest.get(surface).is_none(), "{surface}");
        }
    }

    #[tokio::test]
    async fn a_search_snapshots_the_menu_bar_and_lists_its_items() {
        let (params, rows, _) =
            searched(json!({ "ok": true, "pid": 512, "nodes": snapshot().nodes() })).await;
        assert_eq!(
            params,
            json!({
                "root": "menu_bar",
                "follow": ["AXChildren"],
                "collect": ["AXRole", "AXTitle", "AXEnabled"],
                "max_nodes": 3000,
            }),
            "no pid: the host names the app"
        );
        assert_eq!(
            rows,
            [
                Candidate::new(SOURCE, "File › New Tab")
                    .pid(512)
                    .payload("21")
                    .finishes_command(true),
                Candidate::new(SOURCE, "File › Export › PDF…")
                    .pid(512)
                    .payload("31")
                    .finishes_command(true),
            ]
        );
        assert!(
            rows.iter()
                .all(|row| row.meta("finishes_command") == Some("1")),
            "Return on a row presses its item"
        );
    }

    #[tokio::test]
    async fn a_source_that_is_not_this_one_asks_the_host_nothing() {
        let mut harness = Harness::new("menus");
        let response = Menus
            .on_search(harness.context(), search("menus.other"))
            .await;
        assert_eq!(response.rows, []);
        assert!(harness.drain().is_empty(), "no host call, no log");
    }

    /// No app but Flash owns the menu bar: nothing to list, nothing wrong.
    #[tokio::test]
    async fn no_menu_bar_owner_lists_nothing() {
        let (_, rows, frames) = searched(json!({ "ok": true, "nodes": [] })).await;
        assert_eq!(rows, []);
        assert!(frames.is_empty(), "{frames:?}");
        let (_, rows, _) = searched(json!({ "ok": true, "pid": 512, "nodes": [] })).await;
        assert_eq!(rows, [], "an app without a menu bar");
    }

    #[tokio::test]
    async fn a_refused_or_malformed_snapshot_lists_nothing_and_says_so_in_the_log() {
        for (reply, reason) in [
            (
                json!({ "ok": false, "error": "accessibility snapshot timed out" }),
                "accessibility snapshot timed out",
            ),
            (json!({ "ok": true, "pid": 512 }), "snapshot without nodes"),
            (
                json!({ "ok": true, "pid": 512, "nodes": [{ "handle": 1 }] }),
                "malformed snapshot node",
            ),
        ] {
            let (_, rows, frames) = searched(reply).await;
            assert_eq!(rows, [], "{reason}");
            let logs: Vec<&str> = frames
                .iter()
                .filter(|frame| frame["method"] == "log")
                .filter_map(|frame| frame["params"]["message"].as_str())
                .collect();
            assert_eq!(logs, [format!("[menus] snapshot failed: {reason}")]);
        }
    }

    #[tokio::test]
    async fn picking_a_row_presses_its_handle_and_names_its_app() {
        let (params, response) = resolved(row("21"), json!({ "ok": true })).await;
        assert_eq!(params, json!({ "handle": 21, "action": "AXPress" }));
        assert_eq!(
            serde_json::to_value(response).unwrap(),
            json!({ "ok": true, "target_pid": 512 })
        );
    }

    /// The handle was retired: the row fails in words, and nothing else is
    /// tried. No second press, no key, no pointer.
    #[tokio::test]
    async fn a_stale_handle_fails_and_tries_nothing_else() {
        let mut harness = Harness::new("menus");
        let ctx = harness.context();
        let task = tokio::spawn(async move { Menus.on_resolve(ctx, row("21")).await });
        let (id, _, _) = harness.next_host_request().await.expect("a host call");
        assert!(harness.reply_host(id, json!({ "ok": false, "error": "stale ax handle" })));
        let response = task.await.unwrap();
        assert_eq!(
            response.error_message(),
            Some("menu item is gone: search @menus again")
        );
        assert!(
            harness
                .drain()
                .iter()
                .all(|frame| frame["method"] != "host.ax_perform"
                    && frame["method"] != "host.ax_snapshot"
                    && frame["method"] != "host.post_keys"),
            "one press and nothing after it"
        );
    }

    /// An item that opens a modal dialog is pressed, yet the app answers
    /// the press only when the dialog closes.
    #[tokio::test]
    async fn a_press_the_app_did_not_confirm_is_not_reported_as_a_failure() {
        let (_, response) = resolved(
            row("21"),
            json!({ "ok": false, "error": "ax action failed" }),
        )
        .await;
        assert!(response.is_unhandled());
    }

    #[tokio::test]
    async fn a_row_without_a_handle_presses_nothing() {
        for row in [
            Candidate::new(SOURCE, "File › New Tab"),
            row("File/New Tab"),
            row("-1"),
        ] {
            let mut harness = Harness::new("menus");
            let response = Menus.on_resolve(harness.context(), row).await;
            assert_eq!(response.error_message(), Some("unknown menu item"));
            assert!(harness.drain().is_empty(), "no host call");
        }
    }
}
