//! Selecting a Firefox tab: Firefox's own tab shortcuts for a known strip
//! position, else an AX press ladder — verified either way.

use std::collections::BTreeMap;
use std::time::Duration;

use flash_plugin::Context;
use serde_json::{json, Value};

use super::catalog::{collect, fill_from_store, focused_root};
use super::strip::{walk, Strip, Tab};
use crate::ax;

/// One synthesized chord of the tab-jump plan (exactly one modifier — the
/// host's `host.post_keys` is chord-only by contract).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Chord {
    key_code: u32,
    modifier: &'static str,
}

/// ANSI keycodes for the digit row 1…9.
const DIGIT_KEYCODES: [u32; 9] = [18, 19, 20, 21, 23, 22, 26, 28, 25];
const KEY_PAGE_UP: u32 = 116;
const KEY_PAGE_DOWN: u32 = 121;
/// Longest ctrl+PgDn/PgUp walk the fast path takes from an anchor; past
/// this the AX press is comparable in latency and steadier visually.
const MAX_TAB_WALK: usize = 12;

/// Keystroke plan that lands on strip position `index` of `tab_count` using
/// Firefox's native bindings: ⌘1…⌘8 select positions directly, ⌘9 selects
/// the LAST tab, and ctrl+PgDn/PgUp step in strip order (layout-independent,
/// never MRU). Deep-middle positions beyond [`MAX_TAB_WALK`] return `None`
/// and fall back to the AX press.
pub(super) fn tab_key_plan(index: usize, tab_count: usize) -> Option<Vec<Chord>> {
    if index == 0 || index > tab_count {
        return None;
    }
    let digit = |position: usize| Chord {
        key_code: DIGIT_KEYCODES[position - 1],
        modifier: "command",
    };
    if index <= 8 {
        return Some(vec![digit(index)]);
    }
    if index == tab_count {
        return Some(vec![digit(9)]);
    }
    let forward = index - 8;
    let backward = tab_count - index;
    if forward.min(backward) > MAX_TAB_WALK {
        return None;
    }
    let (anchor, step, count) = if forward <= backward {
        (digit(8), KEY_PAGE_DOWN, forward)
    } else {
        (digit(9), KEY_PAGE_UP, backward)
    };
    let mut plan = vec![anchor];
    plan.extend((0..count).map(|_| Chord {
        key_code: step,
        modifier: "control",
    }));
    Some(plan)
}

/// Post a chord plan to `pid` through the host. Modifier chords dispatch via
/// the target's key-equivalent path, so Firefox does not need to be
/// frontmost — the jump runs in parallel with `host.activate`.
pub(super) async fn post_keys(ctx: &Context, pid: i64, plan: &[Chord]) -> bool {
    let keys: Vec<Value> = plan
        .iter()
        .map(|chord| json!({"key_code": chord.key_code, "modifiers": [chord.modifier]}))
        .collect();
    ctx.post_keys(json!({"pid": pid, "keys": keys, "interval_ms": 16}))
        .await
}

/// The 1-based `index`th tab of the focused window, or of the front-most
/// window holding tabs (`AXWindows` is front to back) when focus is unknown.
pub(super) fn nth_tab_in_front_window(strip: &Strip, index: usize) -> Option<&Tab> {
    let front = focused_root(strip, None, &BTreeMap::new(), 0)
        .or_else(|| strip.tab_roots().first().copied())?;
    strip
        .tabs
        .iter()
        .filter(|tab| tab.root == front)
        .nth(index.checked_sub(1)?)
}

/// Verify a keystroke jump once the chord chain has landed, and correct
/// through the AX ladder when the strip drifted since the row was emitted.
/// Detached: the pick was already answered.
pub(super) fn spawn_fast_jump_verify(
    ctx: &Context,
    pid: i64,
    url: &str,
    name: &str,
    plan_len: usize,
) {
    let ctx = ctx.clone();
    let url = url.to_string();
    let name = name.to_string();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(120 + 40 * plan_len as u64)).await;
        let _ax = ax::session(pid).lock_owned().await;
        let strip = walk(&ctx, pid).await.unwrap_or_default();
        let corrected = match find_tab(&strip.tabs, &url, &name) {
            Some(hit) if hit.selected => {
                ctx.log(
                    "debug",
                    &format!("[browsers] firefox fast tab jump verified pid={pid}"),
                );
                return;
            }
            Some(hit) => {
                ctx.log(
                    "debug",
                    &format!(
                        "[browsers] firefox fast tab jump missed; correcting via AX pid={pid}"
                    ),
                );
                let target = hit.clone();
                select_tab(&ctx, pid, &target).await
            }
            None => match activate_and_find_tab(&ctx, pid, &url, &name).await {
                Some(target) => select_tab(&ctx, pid, &target).await,
                None => false,
            },
        };
        if !corrected {
            ctx.log(
                "warn",
                &format!("[browsers] firefox fast tab jump could not be corrected pid={pid}"),
            );
        }
    });
}

/// Raise Firefox and locate the `url` / `name` tab. The walk races the raise,
/// and a unique hit needs no store read. `AXWindows` can be empty or partial
/// while Firefox is still activating (coming forward from another Space), so
/// a full miss retries once after the activation settles.
pub(super) async fn activate_and_find_tab(
    ctx: &Context,
    pid: i64,
    url: &str,
    name: &str,
) -> Option<Tab> {
    let (_, strip) = tokio::join!(ctx.activate(pid), walk(ctx, pid));
    let mut strip = strip.unwrap_or_default();
    if let Some(tab) = find_tab_unambiguous(&strip.tabs, url, name) {
        return Some(tab.clone());
    }
    fill_from_store(pid, &mut strip).await;
    if let Some(tab) = find_tab(&strip.tabs, url, name) {
        return Some(tab.clone());
    }
    tokio::time::sleep(Duration::from_millis(250)).await;
    let strip = collect(ctx, pid).await;
    find_tab(&strip.tabs, url, name).cloned()
}

/// Match `url` (primary key), then `name`.
fn find_tab<'a>(tabs: &'a [Tab], url: &str, name: &str) -> Option<&'a Tab> {
    tabs.iter()
        .find(|tab| !url.is_empty() && tab.url == url)
        .or_else(|| {
            tabs.iter()
                .find(|tab| !name.is_empty() && tab.title == name)
        })
}

/// Match against a walk without store URLs: the URL when the strip exposes
/// one, else a title unique across every window. Ambiguity returns `None`
/// so the caller can disambiguate with the store's URLs.
fn find_tab_unambiguous<'a>(tabs: &'a [Tab], url: &str, name: &str) -> Option<&'a Tab> {
    if let Some(hit) = tabs.iter().find(|tab| !url.is_empty() && tab.url == url) {
        return Some(hit);
    }
    let mut hits = tabs
        .iter()
        .filter(|tab| !name.is_empty() && tab.title == name);
    match (hits.next(), hits.next()) {
        (Some(only), None) => Some(only),
        _ => None,
    }
}

/// Select `tab`, escalating through three AX strategies. AXPress leads:
/// Firefox accepts the AXSelectedChildren / AXSelected writes with a success
/// status without moving the visible tab, so leading with them would cost a
/// verify round on every pick. Each strategy the element accepts is verified
/// against a fresh walk — which purges the previous handles broker-side, so
/// the next strategy re-finds the tab in it. A rejected strategy purges
/// nothing (the caller holds the pid's AX session), so the next one reuses
/// the same handles.
pub(super) async fn select_tab(ctx: &Context, pid: i64, tab: &Tab) -> bool {
    raise_tab_window(ctx, tab).await;
    if tab.selected {
        return true;
    }
    let mut current = tab.clone();
    for strategy in ["press", "select_child", "set_selected"] {
        let accepted = match strategy {
            "press" => ctx.ax_perform(current.handle, "AXPress").await,
            "select_child" => match current.parent_handle {
                Some(parent) => ctx.ax_select_child(parent, current.handle).await,
                None => false,
            },
            _ => ctx.ax_set(current.handle, "AXSelected", true).await,
        };
        if !accepted {
            ctx.log(
                "debug",
                &format!("[browsers] firefox select strategy {strategy} rejected"),
            );
            continue;
        }
        tokio::time::sleep(Duration::from_millis(120)).await;
        let strip = walk(ctx, pid).await.unwrap_or_default();
        match strip.tabs.iter().find(|fresh| same_tab(fresh, &current)) {
            Some(fresh) if fresh.selected => {
                raise_tab_window(ctx, fresh).await;
                return true;
            }
            Some(fresh) => {
                current = fresh.clone();
                ctx.log(
                    "debug",
                    &format!(
                        "[browsers] firefox select strategy {strategy} returned ok but tab did not become selected"
                    ),
                );
            }
            None => {
                // A transient empty/partial walk (Firefox still settling after
                // the raise) purged our handles; later strategies will be
                // rejected too.
                ctx.log(
                    "debug",
                    &format!(
                        "[browsers] firefox select strategy {strategy} lost the tab in a {}-tab re-walk",
                        strip.tabs.len()
                    ),
                );
            }
        }
    }
    false
}

async fn raise_tab_window(ctx: &Context, tab: &Tab) {
    if let Some(window) = tab.window_handle {
        ctx.ax_perform(window, "AXRaise").await;
        ctx.ax_set(window, "AXMain", true).await;
        ctx.ax_set(window, "AXFocused", true).await;
    }
}

fn same_tab(tab: &Tab, target: &Tab) -> bool {
    if !target.url.is_empty() && !tab.url.is_empty() {
        return tab.url == target.url;
    }
    !target.title.is_empty() && tab.title == target.title
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::firefox::fixtures::{strip, tab};

    #[test]
    fn tab_select_index_stays_inside_the_front_window() {
        let mut tabs = strip(
            2,
            vec![
                tab(0, "Front 1", ""),
                tab(0, "Front 2", ""),
                tab(1, "Back 1", ""),
                tab(1, "Back 2", ""),
                tab(1, "Back 3", ""),
            ],
        );
        assert_eq!(nth_tab_in_front_window(&tabs, 2).unwrap().title, "Front 2");
        // The front window has 2 tabs: index 3 must not spill into the next.
        assert!(nth_tab_in_front_window(&tabs, 3).is_none());
        assert!(nth_tab_in_front_window(&tabs, 0).is_none());
        assert!(nth_tab_in_front_window(&Strip::default(), 1).is_none());
        // The main window wins over AXWindows order.
        tabs.windows[1].main = true;
        assert_eq!(nth_tab_in_front_window(&tabs, 3).unwrap().title, "Back 3");
    }

    #[test]
    fn find_tab_prefers_url_then_title() {
        let tabs = [
            tab(0, "Inbox", "https://mail.example.com/"),
            tab(0, "Inbox", "https://other.example.com/"),
            tab(0, "Docs", ""),
        ];
        assert_eq!(
            find_tab(&tabs, "https://other.example.com/", "Inbox")
                .unwrap()
                .url,
            "https://other.example.com/"
        );
        assert_eq!(find_tab(&tabs, "", "Docs").unwrap().title, "Docs");
        // A stale URL (the tab navigated away) still lands on the title.
        assert_eq!(
            find_tab(&tabs, "https://gone.example.com/", "Docs")
                .unwrap()
                .title,
            "Docs"
        );
        assert!(find_tab(&tabs, "https://gone.example.com/", "Nope").is_none());
        assert!(find_tab(&tabs, "", "").is_none());
    }

    #[test]
    fn find_tab_unambiguous_requires_a_unique_title_hit() {
        let unique = [tab(0, "Docs", ""), tab(0, "Inbox", "")];
        assert_eq!(
            find_tab_unambiguous(&unique, "https://gone.example.com/", "Docs")
                .unwrap()
                .title,
            "Docs"
        );
        // Same-titled tabs without URLs are ambiguous: the caller must
        // disambiguate with the store's URLs instead of taking the first.
        let dup = [tab(0, "Inbox", ""), tab(1, "Inbox", "")];
        assert!(find_tab_unambiguous(&dup, "", "Inbox").is_none());
        let with_urls = [
            tab(0, "Inbox", "https://a.example.com/"),
            tab(0, "Inbox", "https://b.example.com/"),
        ];
        assert_eq!(
            find_tab_unambiguous(&with_urls, "https://b.example.com/", "Inbox")
                .unwrap()
                .url,
            "https://b.example.com/"
        );
    }

    #[test]
    fn tab_key_plan_uses_direct_anchors() {
        let command = |key_code| Chord {
            key_code,
            modifier: "command",
        };
        // ⌘1…⌘8 are direct positions.
        assert_eq!(tab_key_plan(3, 26), Some(vec![command(20)]));
        // ⌘9 is "last tab", whatever the count.
        assert_eq!(tab_key_plan(26, 26), Some(vec![command(25)]));
        // Small strips: the last tab is still within the digit row.
        assert_eq!(tab_key_plan(5, 5), Some(vec![command(23)]));
    }

    #[test]
    fn tab_key_plan_walks_from_the_nearest_anchor() {
        // 10 of 26: ⌘8 then 2 × ctrl+PgDn.
        let plan = tab_key_plan(10, 26).unwrap();
        assert_eq!((plan[0].key_code, plan[0].modifier), (28, "command"));
        assert_eq!(plan.len(), 3);
        assert!(plan[1..]
            .iter()
            .all(|chord| chord.key_code == KEY_PAGE_DOWN && chord.modifier == "control"));
        // 24 of 26: ⌘9 then 2 × ctrl+PgUp.
        let plan = tab_key_plan(24, 26).unwrap();
        assert_eq!(plan[0].key_code, 25);
        assert_eq!(plan.len(), 3);
        assert!(plan[1..]
            .iter()
            .all(|chord| chord.key_code == KEY_PAGE_UP && chord.modifier == "control"));
    }

    #[test]
    fn tab_key_plan_rejects_deep_middles_and_stale_indexes() {
        // 40 of 80: both walks exceed MAX_TAB_WALK → AX path.
        assert_eq!(tab_key_plan(40, 80), None);
        assert_eq!(tab_key_plan(9, 8), None);
        assert_eq!(tab_key_plan(0, 8), None);
    }
}
