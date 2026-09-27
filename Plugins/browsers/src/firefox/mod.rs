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
//!   parallel with the raise, then verifies in the background. Everything
//!   else re-walks the strip, finds the tab by URL then title, and presses it
//!   through an AX ladder with verification.
//! - `tab_new`, `tab_close` and the tab moves stay unhandled: the manifest's
//!   chords and the core's ⌘W are Firefox's own shortcuts.

mod catalog;
#[cfg(test)]
mod fixtures;
mod select;
mod strip;

use flash_plugin::{ActionRequest, Candidate, Context, PerformResponse};
use serde::{Deserialize, Serialize};

use crate::ax;
use crate::route::{TabRoute, TabTarget};
use crate::session_store;
use crate::{performed, tab_candidate, Browser, TabPayload};
use catalog::{assign_stores, catalog, collect, CatalogTab};
use select::{
    activate_and_find_tab, nth_tab_in_front_window, post_keys, select_tab, spawn_fast_jump_verify,
    tab_key_plan,
};
use strip::{walk, Tab};

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
        app_name: String::new(),
        url: tab.url.clone(),
        strip: Some(tab.position),
    };
    tab_candidate(browser, pid, &tab.title, &tab.url, tab.current, &payload)
}

/// Resolve a flashlight pick. A row at a usable strip position of the
/// focused window takes the key fast path: no AX read on the critical path,
/// then a background verification that corrects through the AX ladder if the
/// strip drifted since emit. Otherwise: re-walk, match by URL then title,
/// and press the tab. The URL comes from the payload — the raw string
/// stashed at emit time — because the host round-trips the row's `url`
/// through Foundation's URL parser, which can percent-encode it away from
/// what a fresh walk reports.
pub async fn resolve(
    ctx: &Context,
    pid: i64,
    row: &Candidate,
    payload: &TabPayload,
) -> PerformResponse {
    let url = if payload.url.is_empty() {
        row.url_value().unwrap_or("")
    } else {
        payload.url.as_str()
    };
    let name = row.title.as_str();
    let route = TabRoute::new(pid, url, name);

    if let Some(position) = payload.strip.filter(|position| position.window_focused) {
        if let Some(plan) = tab_key_plan(position.index, position.tab_count) {
            let (keys_ok, _) = tokio::join!(post_keys(ctx, pid, &plan), ctx.activate(pid));
            if keys_ok {
                spawn_fast_jump_verify(ctx, pid, url, name, plan.len());
                return performed(pid, route);
            }
            ctx.log(
                "debug",
                "[browsers] firefox key plan rejected by host; using AX path",
            );
        }
    }

    let ax = ax::session(pid).lock_owned().await;
    let Some(target) = activate_and_find_tab(ctx, pid, url, name).await else {
        ctx.log(
            "warn",
            &format!(
                "[browsers] firefox resolve target not found pid={pid} title_present={} url_present={}",
                !name.is_empty(),
                !url.is_empty()
            ),
        );
        return PerformResponse::fail("resolve target not found");
    };
    // Reply as soon as the target is in hand: the press lands within a few ms
    // of the spawn, while the settle + verify behind it only gated the host's
    // post-resolve bookkeeping. The owned session guard rides into the task
    // so refreshes stay locked out until the selection settles.
    let task_ctx = ctx.clone();
    tokio::spawn(async move {
        let _ax = ax;
        if select_tab(&task_ctx, pid, &target).await {
            task_ctx.log(
                "debug",
                &format!("[browsers] firefox resolve selected pid={pid}"),
            );
        } else {
            task_ctx.log(
                "warn",
                &format!("[browsers] firefox resolve select did not stick pid={pid}"),
            );
        }
    });
    performed(pid, route)
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

/// `tab_select` (the numbered-tab jump) selects the Nth tab of the focused
/// window: an index past its strip is `unhandled` rather than a jump into
/// another window, and a press that does not stick is an error, so the host
/// never falls back to a ⌘<digit> that could switch the wrong tab. Every
/// other action is `unhandled`: Firefox's own chords (manifest
/// `action_keystrokes`, the core's ⌘W) create, close and move tabs.
pub async fn perform_action(ctx: &Context, pid: i64, action: &ActionRequest) -> PerformResponse {
    if action.name != "tab_select" {
        return PerformResponse::unhandled();
    }
    let Some(index) = action
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
        PerformResponse::ok().target_pid(pid)
    } else {
        PerformResponse::fail("tab press did not stick")
    }
}
