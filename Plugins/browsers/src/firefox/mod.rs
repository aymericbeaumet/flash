//! Firefox (Gecko) tabs, with no browser add-on. Gecko has no tab scripting
//! dictionary, so:
//!
//! - **Listing** walks each window's tab strip through the host AX broker
//!   ([`strip`]) — the truth for what is on screen — and completes it from
//!   the profile's [session store](crate::session_store) ([`catalog`]): URLs
//!   the strip does not expose, windows the walk cannot see (other Spaces),
//!   and fallback signals for the focused window and a window's selected tab.
//! - **Selecting** ([`select`]) a tab at a known strip position of the
//!   focused window posts Firefox's own tab shortcuts through the host in
//!   parallel with the raise, then confirms it with a walk. Everything else
//!   re-walks the strip, finds the tab by URL (by title only for a tab
//!   without one), and presses it through an AX ladder with verification.
//!   A pick replies once the tab is confirmed selected, never before.
//! - **Stepping** (`tab next`, `tab previous`, `tab first`, `tab last`)
//!   posts Firefox's own tab keys, then walks the strip to name the tab
//!   they landed on, so the host records one movement stop per press even
//!   in a burst the catalog's settle would fold into one listing. Firefox
//!   owns the step itself, so vertical tabs, tab groups and the wrap at
//!   either end behave as they do without Flash.
//! - `tab new`, `tab close` and the tab moves stay unhandled: the manifest's
//!   chords and `defaults`' ⌘W are Firefox's own shortcuts.

mod catalog;
#[cfg(test)]
mod fixtures;
mod select;
mod strip;

use std::time::Duration;

use flash_plugin::{Candidate, CommandRequest, Context, PerformResponse, PollPriority};
use serde::{Deserialize, Serialize};

use crate::ax;
use crate::route::{TabRoute, TabTarget};
use crate::session_store;
use crate::{Browser, TabPayload, performed, tab_candidate};
use catalog::{CatalogTab, assign_stores, catalog, collect};
use select::{
    TabStep, activate_and_find_tab, confirm_fast_jump, nth_tab_in_front_window, post_keys,
    select_tab, selected_tab_in_front_window, step_keys, tab_key_plan,
};
use strip::{Tab, walk};

/// The SDK's `call_host` timeout: the longest one host call on the selection
/// path (the raise, a walk, a press, the key post) waits for its reply. The
/// SDK does not export it, so a test measures it against this value.
const HOST_CALL_TIMEOUT: Duration = Duration::from_secs(5);

/// How long a pick may take to confirm its tab before replying an error:
/// strictly longer than one host call, so a switch that one slow call
/// delays (a raise from another Space) still confirms and is recorded, and
/// shorter than the host's perform deadline (`protocol.json`, 10 s), so the
/// error still reaches it. A pick normally confirms in ~0.3 s (key jump) to
/// ~2 s (the slowest AX path: a walk, a store read, the one activation
/// retry, then three verified presses).
const SELECT_DEADLINE: Duration = HOST_CALL_TIMEOUT.saturating_add(Duration::from_secs(1));

/// A beat for Firefox's own tab key to land before the walk that names
/// where it went. Only the movement stop waits on it: the switch is on
/// screen as soon as the key is posted.
const STEP_SETTLE: Duration = Duration::from_millis(120);

/// Where a row's tab sits, carried in its payload for the key fast path.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StripPosition {
    /// 1-based position in its window's tab strip.
    pub index: usize,
    /// Tabs in that window.
    pub tab_count: usize,
    /// Firefox windows at emit time.
    pub window_count: usize,
    /// Whether that window is the one Firefox's tab shortcuts address:
    /// ⌘1…⌘9 and ctrl+PgDn/PgUp act on it alone, so this gates the fast path.
    pub window_focused: bool,
}

/// Rows for every running Firefox, in `apps` order: `None` for a pid whose AX
/// walk failed (the caller keeps that pid's previous rows), else its complete
/// catalog.
pub async fn list_tabs(
    ctx: Context,
    apps: Vec<(&'static Browser, i64)>,
) -> Vec<(i64, Option<Vec<Candidate>>)> {
    // The store read (a stat per profile, a decode only when Firefox has
    // rewritten it) overlaps the AX walks.
    let stores = tokio::spawn(session_store::load());
    let walks: Vec<_> = apps
        .iter()
        .map(|&(_, pid)| {
            let ctx = ctx.clone();
            tokio::spawn(async move {
                let session = ax::session(pid);
                let _ax = session.lock().await;
                walk(&ctx, pid).await
            })
        })
        .collect();
    let mut strips = Vec::with_capacity(walks.len());
    for walk in walks {
        strips.push(walk.await.ok().flatten());
    }
    let stores = stores.await.unwrap_or_default();
    let visible: Vec<(i64, &[Tab])> = apps
        .iter()
        .zip(&strips)
        .filter_map(|(&(_, pid), strip)| strip.as_ref().map(|strip| (pid, strip.tabs.as_slice())))
        .collect();
    let assigned = assign_stores(&visible, &stores);
    apps.iter()
        .zip(&strips)
        .map(|(&(browser, pid), strip)| {
            let rows = strip.as_ref().map(|strip| {
                let store = assigned
                    .get(&pid)
                    .map(|index| stores[*index].store.as_ref());
                catalog(strip, store)
                    .iter()
                    .map(|tab| candidate(browser, pid, tab))
                    .collect()
            });
            (pid, rows)
        })
        .collect()
}

fn candidate(browser: &Browser, pid: i64, tab: &CatalogTab) -> Candidate {
    let payload = TabPayload {
        bundle_id: browser.bundle_id.to_string(),
        url: tab.url.clone(),
        title: String::new(),
        strip: Some(tab.position),
        slot: None,
    };
    tab_candidate(browser, pid, &tab.title, &tab.url, tab.current, &payload)
}

/// Resolve a flashlight pick, replying `performed` only once the tab is
/// confirmed selected: the host records the jump in movement history on
/// that reply, so a pick that cannot confirm within [`SELECT_DEADLINE`] is
/// an error (never `unhandled`, which would let a host fallback fire too).
/// The URL comes from the payload — the raw string stashed at emit time —
/// because the host round-trips the row's `url` through Foundation's URL
/// parser, which can percent-encode it away from what a fresh walk reports.
pub async fn resolve(
    ctx: &Context,
    pid: i64,
    row: &Candidate,
    payload: &TabPayload,
) -> PerformResponse {
    resolve_within(ctx, pid, row, payload, SELECT_DEADLINE).await
}

async fn resolve_within(
    ctx: &Context,
    pid: i64,
    row: &Candidate,
    payload: &TabPayload,
    deadline: Duration,
) -> PerformResponse {
    let url = if payload.url.is_empty() {
        row.url_value().unwrap_or("")
    } else {
        payload.url.as_str()
    };
    let name = row.title.as_str();
    // Dropping the selection on timeout also drops its AX session guard and
    // any press it had yet to send.
    let selected = tokio::time::timeout(deadline, select_pick(ctx, pid, url, name, payload.strip))
        .await
        .unwrap_or(Err("tab selection timed out"));
    match selected {
        Ok(()) => performed(pid, TabRoute::new(pid, url, name)),
        Err(error) => {
            ctx.log(
                "warn",
                &format!(
                    "[browsers] firefox resolve failed pid={pid} error={error:?} title_present={} url_present={}",
                    !name.is_empty(),
                    !url.is_empty()
                ),
            );
            PerformResponse::fail(error)
        }
    }
}

/// Select a picked tab. A row at a usable strip position of the focused
/// window takes the key fast path: no AX read before the jump, then a walk
/// that confirms it, correcting through the AX ladder if the strip drifted
/// since emit. Otherwise: re-walk, match, and press the tab.
async fn select_pick(
    ctx: &Context,
    pid: i64,
    url: &str,
    name: &str,
    strip: Option<StripPosition>,
) -> Result<(), &'static str> {
    if let Some(position) = strip.filter(|position| position.window_focused)
        && let Some(plan) = tab_key_plan(position.index, position.tab_count)
    {
        let (keys_ok, _) = tokio::join!(post_keys(ctx, pid, &plan), ctx.activate(pid));
        if keys_ok {
            return if confirm_fast_jump(ctx, pid, url, name, plan.len()).await {
                Ok(())
            } else {
                Err("tab jump did not stick")
            };
        }
        ctx.log(
            "debug",
            "[browsers] firefox key plan rejected by host; using AX path",
        );
    }
    let session = ax::session(pid);
    let _ax = session.lock().await;
    let target = activate_and_find_tab(ctx, pid, url, name)
        .await
        .ok_or("resolve target not found")?;
    if select_tab(ctx, pid, &target).await {
        Ok(())
    } else {
        Err("tab press did not stick")
    }
}

/// Restore a `flash-browser` route: re-walk, match, press, and confirm.
pub async fn restore(ctx: &Context, route: &TabRoute) -> PerformResponse {
    let pid = route.pid;
    let (url, title) = match &route.target {
        TabTarget::Url(url) => (url.as_str(), ""),
        TabTarget::Title(title) => ("", title.as_str()),
    };
    let session = ax::session(pid);
    let _ax = session.lock().await;
    let Some(target) = activate_and_find_tab(ctx, pid, url, title).await else {
        ctx.log(
            "warn",
            &format!("[browsers] firefox restore target not found pid={pid}"),
        );
        return PerformResponse::fail("restore target not found");
    };
    if select_tab(ctx, pid, &target).await {
        performed(pid, Some(route.clone()))
    } else {
        ctx.log(
            "warn",
            &format!("[browsers] firefox restore target press failed pid={pid}"),
        );
        PerformResponse::fail("restore target press failed")
    }
}

/// `tab select` (the numbered-tab jump) selects the Nth tab of the focused
/// window: an index past its strip is `unhandled` rather than a jump into
/// another window, and a press that does not stick is an error, so the host
/// never falls back to a ⌘<digit> that could switch the wrong tab. `tab
/// next`, `tab previous`, `tab first` and `tab last` post Firefox's own tab
/// keys ([`step_keys`]) and then walk the strip to name the tab they landed
/// on, so the host records every step as a movement stop however fast they
/// come, where the catalog of a burst would show only the last. The step
/// itself stays Firefox's: no element of the strip is chosen here and none
/// is pressed, so vertical tabs, tab groups and the wrap at either end work
/// as they do without Flash. A key the host refuses is `unhandled`, leaving
/// the switch to the manifest's chord; a strip that cannot be read after it
/// is performed without a route, and the catalog records the stop once its
/// own burst settles. Every other command is `unhandled`: Firefox's own
/// chords (manifest `bindings`, `defaults`' ⌘W) create, close and move tabs.
pub async fn perform_command(ctx: &Context, pid: i64, command: &CommandRequest) -> PerformResponse {
    if command.command != "tab" {
        return PerformResponse::unhandled();
    }
    if command.subcommand == "select" {
        return select_command(ctx, pid, command).await;
    }
    let Some(step) = TabStep::parse(&command.subcommand) else {
        return PerformResponse::unhandled();
    };
    if !post_keys(ctx, pid, &step_keys(step)).await {
        ctx.log(
            "debug",
            &format!("[browsers] firefox tab step keys refused pid={pid} step={step:?}"),
        );
        return PerformResponse::unhandled();
    }
    // Firefox has switched already; this read only names the stop, so a
    // strip it cannot see costs the route, never the step.
    ctx.wait(STEP_SETTLE, PollPriority::High).await;
    let session = ax::session(pid);
    let _ax = session.lock().await;
    let strip = collect(ctx, pid).await;
    match selected_tab_in_front_window(&strip) {
        Some(tab) => performed(pid, TabRoute::new(pid, &tab.url, &tab.title)),
        None => PerformResponse::ok().target_pid(pid),
    }
}

async fn select_command(ctx: &Context, pid: i64, command: &CommandRequest) -> PerformResponse {
    let Some(index) = command
        .index()
        .and_then(|index| usize::try_from(index).ok())
        .filter(|index| *index > 0)
    else {
        return PerformResponse::unhandled();
    };
    let session = ax::session(pid);
    let _ax = session.lock().await;
    let (_, strip) = tokio::join!(ctx.activate(pid), collect(ctx, pid));
    let Some(target) = nth_tab_in_front_window(&strip, index).cloned() else {
        return PerformResponse::unhandled();
    };
    if select_tab(ctx, pid, &target).await {
        performed(pid, TabRoute::new(pid, &target.url, &target.title))
    } else {
        PerformResponse::fail("tab press did not stick")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fixtures::{ax_reply, serve_host};
    use flash_plugin::CommandContext;
    use flash_plugin::testing::Harness;
    use serde_json::{Value, json};

    /// A pick of tab "B" (2 of 3) in the focused window, with or without its
    /// strip position.
    fn pick(pid: i64, strip: bool) -> (Candidate, TabPayload) {
        let payload = TabPayload {
            bundle_id: "org.mozilla.firefox".into(),
            url: "https://b.example/".into(),
            title: String::new(),
            strip: strip.then_some(StripPosition {
                index: 2,
                tab_count: 3,
                window_count: 1,
                window_focused: true,
            }),
            slot: None,
        };
        let row = Candidate::new("firefox.tabs", "B")
            .pid(pid)
            .url("https://b.example/")
            .payload_json(&payload);
        (row, payload)
    }

    /// The strip after a pick: "B" selected or not.
    fn landed(selected: bool) -> Value {
        ax_reply(&[
            ("A", "https://a.example/", !selected),
            ("B", "https://b.example/", selected),
            ("C", "https://c.example/", false),
        ])
    }

    /// A `tab <subcommand>` step from the host, with Firefox focused.
    fn step_command(pid: i64, subcommand: &str) -> CommandRequest {
        CommandRequest {
            command: "tab".into(),
            subcommand: subcommand.into(),
            args: vec![],
            context: Some(CommandContext {
                bundle_id: Some("org.mozilla.firefox".into()),
                pid: Some(pid),
                front_window_frame: None,
            }),
        }
    }

    async fn step_against(
        pid: i64,
        subcommand: &str,
        snapshot: Value,
        keys_ok: bool,
    ) -> (PerformResponse, Vec<String>) {
        let mut harness = Harness::new("browsers");
        let ctx = harness.context();
        let command = step_command(pid, subcommand);
        let task = tokio::spawn(async move { perform_command(&ctx, pid, &command).await });
        serve_host(&mut harness, task, |method| match method {
            "host.ax_snapshot" => snapshot.clone(),
            "host.post_keys" => json!({"ok": keys_ok}),
            _ => json!({"ok": true}),
        })
        .await
    }

    fn route_target(response: &PerformResponse) -> TabTarget {
        let wire = serde_json::to_value(response).unwrap();
        TabRoute::parse(wire["navigation_url"].as_str().unwrap())
            .unwrap()
            .target
    }

    /// `]t` posts Firefox's own key, then reads the strip to name where the
    /// browser landed, so the host records a stop per press. Nothing in the
    /// strip is pressed: the sidebar's own controls stay untouched.
    #[tokio::test]
    async fn a_step_posts_the_browsers_key_and_names_where_it_landed() {
        let (response, methods) = step_against(62_010, "next", landed(true), true).await;
        assert!(response.is_ok(), "{methods:?}");
        assert_eq!(methods, ["host.post_keys", "host.ax_snapshot"]);
        assert!(
            !methods.iter().any(|method| method == "host.ax_perform"),
            "a step must press no element: {methods:?}"
        );
        assert_eq!(
            route_target(&response),
            TabTarget::Url("https://b.example/".into())
        );
    }

    /// A key the host refuses leaves the switch to the manifest's chord.
    #[tokio::test]
    async fn a_step_the_host_refuses_is_unhandled() {
        let (response, methods) = step_against(62_014, "next", landed(true), false).await;
        assert!(response.is_unhandled(), "{methods:?}");
        assert_eq!(methods, ["host.post_keys"]);
    }

    /// The step still happened when the strip cannot be read, so it is
    /// performed without a route and the catalog records the stop instead.
    #[tokio::test]
    async fn a_step_whose_strip_cannot_be_read_keeps_the_switch() {
        let (response, methods) = step_against(62_015, "next", json!({"ok": false}), true).await;
        assert!(response.is_ok(), "{methods:?}");
        let wire = serde_json::to_value(&response).unwrap();
        assert_eq!(wire["target_pid"], json!(62_015));
        assert!(wire.get("navigation_url").is_none(), "{wire}");
    }

    async fn resolve_against(
        pid: i64,
        strip: bool,
        mut snapshot: impl FnMut() -> Value,
    ) -> (PerformResponse, Vec<String>) {
        let mut harness = Harness::new("browsers");
        let ctx = harness.context();
        let (row, payload) = pick(pid, strip);
        let task = tokio::spawn(async move { resolve(&ctx, pid, &row, &payload).await });
        serve_host(&mut harness, task, |method| match method {
            "host.ax_snapshot" => snapshot(),
            _ => json!({"ok": true}),
        })
        .await
    }

    #[tokio::test]
    async fn a_key_jump_replies_only_once_the_walk_confirms_the_tab() {
        let pid = 62_001;
        let (response, methods) = resolve_against(pid, true, || landed(true)).await;
        assert!(response.is_ok());
        assert!(
            methods
                .iter()
                .take(2)
                .any(|method| method == "host.post_keys")
        );
        assert!(
            methods.iter().any(|method| method == "host.ax_snapshot"),
            "replied before verifying: {methods:?}"
        );
        let wire = serde_json::to_value(&response).unwrap();
        assert_eq!(wire["target_pid"], json!(pid));
        assert_eq!(
            TabRoute::parse(wire["navigation_url"].as_str().unwrap())
                .unwrap()
                .target,
            TabTarget::Url("https://b.example/".into())
        );
    }

    #[tokio::test]
    async fn a_key_jump_that_cannot_be_confirmed_or_corrected_fails() {
        let (response, methods) = resolve_against(62_002, true, || landed(false)).await;
        assert!(!response.is_ok(), "{methods:?}");
        assert!(!response.is_unhandled());
        // The correction pressed the tab before giving up.
        assert!(methods.iter().any(|method| method == "host.ax_perform"));
    }

    #[tokio::test]
    async fn a_pick_that_cannot_confirm_in_time_fails() {
        // Nobody answers the host calls.
        let harness = Harness::new("browsers");
        let ctx = harness.context();
        let (row, payload) = pick(62_005, true);
        let started = std::time::Instant::now();
        let response =
            resolve_within(&ctx, 62_005, &row, &payload, Duration::from_millis(50)).await;
        assert!(!response.is_ok() && !response.is_unhandled());
        assert_eq!(response.error_message(), Some("tab selection timed out"));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[tokio::test(start_paused = true)]
    async fn the_selection_deadline_outlasts_a_host_call_within_the_perform_timeout() {
        // Nobody answers: the call returns at the SDK's host-call timeout,
        // which paused time reaches at once.
        let harness = Harness::new("browsers");
        let ctx = harness.context();
        let started = tokio::time::Instant::now();
        assert!(!ctx.activate(62_006).await);
        let host_call = started.elapsed();
        assert!(
            host_call >= HOST_CALL_TIMEOUT
                && host_call < HOST_CALL_TIMEOUT + Duration::from_millis(10),
            "the SDK's host-call timeout is {host_call:?}, not {HOST_CALL_TIMEOUT:?}"
        );
        let protocol: Value =
            serde_json::from_str(include_str!("../../../_flash_plugin_rust/protocol.json"))
                .unwrap();
        let perform = Duration::from_millis(protocol["deadlines_ms"]["perform"].as_u64().unwrap());
        assert!(
            host_call < SELECT_DEADLINE,
            "{host_call:?} vs {SELECT_DEADLINE:?}"
        );
        assert!(
            SELECT_DEADLINE < perform,
            "{SELECT_DEADLINE:?} vs {perform:?}"
        );
    }

    #[tokio::test]
    async fn an_ax_press_that_never_sticks_fails() {
        let (response, methods) = resolve_against(62_003, false, || landed(false)).await;
        assert!(!response.is_ok(), "{methods:?}");
        assert!(!response.is_unhandled());
    }

    #[tokio::test]
    async fn an_ax_press_replies_once_the_tab_is_selected() {
        let mut walks = 0;
        let (response, methods) = resolve_against(62_004, false, || {
            walks += 1;
            // Unselected when found, selected after the press.
            landed(walks > 1)
        })
        .await;
        assert!(response.is_ok(), "{methods:?}");
        let press = methods
            .iter()
            .position(|method| method == "host.ax_perform")
            .expect("the tab was pressed before the reply");
        let confirm = methods
            .iter()
            .rposition(|method| method == "host.ax_snapshot")
            .unwrap();
        assert!(press < confirm, "{methods:?}");
    }
}
