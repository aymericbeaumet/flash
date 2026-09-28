//! Completing a walk with the session store: which store belongs to which
//! running Firefox, which store window to which AX window, the URLs the strip
//! does not expose, the windows it cannot see, and which window is focused.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use flash_plugin::Context;

use super::strip::{walk, Strip, Tab};
use super::StripPosition;
use crate::session_store::{self, SessionStore, SessionWindow, StoreFile};

/// One tab of a catalog cycle, before it becomes a row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct CatalogTab {
    pub(super) title: String,
    pub(super) url: String,
    pub(super) current: bool,
    pub(super) position: StripPosition,
}

/// Complete one walk with its store. Every AX window's selected tab stays
/// current (the host picks among them with the focused window's document);
/// windows only the store knows are listed after, never current.
pub(super) fn catalog(strip: &Strip, store: Option<&SessionStore>) -> Vec<CatalogTab> {
    let mut tabs = strip.tabs.clone();
    let pairing = store
        .map(|store| pair_windows(strip, store))
        .unwrap_or_default();
    let mut offscreen = Vec::new();
    if let Some(store) = store {
        fill_urls(&mut tabs, store, &pairing);
        apply_store_selection(&mut tabs, store, &pairing.pairs);
        offscreen = offscreen_windows(&strip.tabs, store, &pairing);
    }
    let focused = focused_root(strip, store, &pairing.pairs, offscreen.len());
    let mut tab_counts: BTreeMap<usize, usize> = BTreeMap::new();
    for tab in &tabs {
        *tab_counts.entry(tab.root).or_default() += 1;
    }
    let window_count = tab_counts.len() + offscreen.len();
    let mut seen: BTreeMap<usize, usize> = BTreeMap::new();
    let mut out: Vec<CatalogTab> = tabs
        .iter()
        .map(|tab| {
            let index = seen.entry(tab.root).or_default();
            *index += 1;
            CatalogTab {
                title: tab.title.clone(),
                url: tab.url.clone(),
                current: tab.selected,
                position: StripPosition {
                    index: *index,
                    tab_count: tab_counts[&tab.root],
                    window_count,
                    window_focused: focused == Some(tab.root),
                },
            }
        })
        .collect();
    for window in offscreen {
        for (position, tab) in window.tabs.iter().enumerate() {
            if tab.title.is_empty() && tab.url.is_empty() {
                continue;
            }
            out.push(CatalogTab {
                title: tab.title.clone(),
                url: tab.url.clone(),
                current: false,
                position: StripPosition {
                    index: position + 1,
                    tab_count: window.tabs.len(),
                    window_count,
                    window_focused: false,
                },
            });
        }
    }
    out
}

/// A walk completed with its store's URLs, for finding a tab to select.
pub(super) async fn collect(ctx: &Context, pid: i64) -> Strip {
    let mut strip = walk(ctx, pid).await.unwrap_or_default();
    fill_from_store(pid, &mut strip).await;
    strip
}

/// Give the walk's URL-less tabs their store URLs. The store supplies
/// nothing else, so a strip exposing every tab's URL skips the read.
pub(super) async fn fill_from_store(pid: i64, strip: &mut Strip) {
    if strip.tabs.iter().all(|tab| !tab.url.is_empty()) {
        return;
    }
    let stores = session_store::load().await;
    let assigned = assign_stores(&[(pid, strip.tabs.as_slice())], &stores);
    if let Some(index) = assigned.get(&pid) {
        let store = &stores[*index].store;
        let pairing = pair_windows(strip, store);
        fill_urls(&mut strip.tabs, store, &pairing);
    }
}

fn titles_match(lhs: &str, rhs: &str) -> bool {
    let lhs = lhs.trim();
    !lhs.is_empty() && lhs == rhs.trim()
}

/// How many of the `ax` titles `store` holds, each store title used once.
fn title_overlap<'a>(
    ax: impl IntoIterator<Item = &'a str>,
    store: impl IntoIterator<Item = &'a str>,
) -> usize {
    let mut available: HashMap<&str, usize> = HashMap::new();
    for title in store {
        let title = title.trim();
        if !title.is_empty() {
            *available.entry(title).or_default() += 1;
        }
    }
    ax.into_iter()
        .filter(|title| match available.get_mut(title.trim()) {
            Some(count) if *count > 0 => {
                *count -= 1;
                true
            }
            _ => false,
        })
        .count()
}

/// Which candidate store (an index into `stores`, newest first) belongs to
/// which running Firefox. A pid takes the store holding most of its
/// on-screen titles, ties going to the newer store. A pid whose walk shows no
/// tab at all (every window on another Space) takes the newest unclaimed
/// store only when it is the sole such pid: nothing else tells the editions'
/// stores apart.
pub(super) fn assign_stores(strips: &[(i64, &[Tab])], stores: &[StoreFile]) -> HashMap<i64, usize> {
    let mut scored = Vec::new();
    for &(pid, tabs) in strips {
        for (index, file) in stores.iter().enumerate() {
            let score = title_overlap(
                tabs.iter().map(|tab| tab.title.as_str()),
                file.store
                    .windows
                    .iter()
                    .flat_map(|window| window.tabs.iter().map(|tab| tab.title.as_str())),
            );
            if score > 0 {
                scored.push((score, index, pid));
            }
        }
    }
    scored.sort_by(|lhs, rhs| {
        rhs.0
            .cmp(&lhs.0)
            .then(lhs.1.cmp(&rhs.1))
            .then(lhs.2.cmp(&rhs.2))
    });
    let mut assigned = HashMap::new();
    let mut claimed = HashSet::new();
    for (_, index, pid) in scored {
        if !assigned.contains_key(&pid) && claimed.insert(index) {
            assigned.insert(pid, index);
        }
    }
    let blank: Vec<i64> = strips
        .iter()
        .filter(|(_, tabs)| tabs.is_empty())
        .map(|(pid, _)| *pid)
        .collect();
    if let [pid] = blank[..] {
        if let Some(index) = (0..stores.len()).find(|index| !claimed.contains(index)) {
            assigned.insert(pid, index);
        }
    }
    assigned
}

/// Which store window is which AX window.
#[derive(Debug, Default)]
struct Pairing {
    /// AX window root → its store window index.
    pairs: BTreeMap<usize, usize>,
    /// AX window root → the store windows it could not tell apart, none of
    /// which it takes.
    tied: BTreeMap<usize, BTreeSet<usize>>,
}

impl Pairing {
    fn tied_with(&self, root: usize, index: usize) -> bool {
        self.tied
            .get(&root)
            .is_some_and(|tied| tied.contains(&index))
    }
}

/// Pair AX windows with store windows. A store write lags the strip by up to
/// ~15 s, so windows pair by title overlap rather than equality, best
/// overlap first; zero overlap never pairs. An overlap tie yields only to
/// evidence of the same window: the store window whose selected tab has the
/// AX window's selected title, then, for the `AXMain` window, the store's
/// selected window. A tie still standing is ambiguous, and the AX window
/// takes none of the tied store windows: a wrong pair would lend it another
/// window's URLs and selection and hide the real one.
fn pair_windows(strip: &Strip, store: &SessionStore) -> Pairing {
    let main = main_root(strip);
    let mut by_root: BTreeMap<usize, Vec<&Tab>> = BTreeMap::new();
    for tab in &strip.tabs {
        by_root.entry(tab.root).or_default().push(tab);
    }
    let mut scored = Vec::new();
    for (&root, tabs) in &by_root {
        let mut selected = tabs.iter().filter(|tab| tab.selected);
        let selected = match (selected.next(), selected.next()) {
            (Some(tab), None) => Some(tab.title.as_str()),
            _ => None,
        };
        for (index, window) in store.windows.iter().enumerate() {
            let overlap = title_overlap(
                tabs.iter().map(|tab| tab.title.as_str()),
                window.tabs.iter().map(|tab| tab.title.as_str()),
            );
            if overlap == 0 {
                continue;
            }
            let same_selection = selected.is_some_and(|title| {
                window
                    .selected
                    .and_then(|index| window.tabs.get(index))
                    .is_some_and(|tab| titles_match(title, &tab.title))
            });
            let focused = main == Some(root) && store.selected_window == Some(index);
            scored.push(((overlap, same_selection, focused), root, index));
        }
    }
    scored.sort_by(|lhs, rhs| {
        rhs.0
            .cmp(&lhs.0)
            .then(lhs.1.cmp(&rhs.1))
            .then(lhs.2.cmp(&rhs.2))
    });
    let mut pairing = Pairing::default();
    let mut used = HashSet::new();
    for &(evidence, root, index) in &scored {
        if pairing.pairs.contains_key(&root)
            || pairing.tied.contains_key(&root)
            || used.contains(&index)
        {
            continue;
        }
        let rivals: BTreeSet<usize> = scored
            .iter()
            .filter(|(other, other_root, other_index)| {
                *other_root == root && *other == evidence && !used.contains(other_index)
            })
            .map(|&(_, _, other_index)| other_index)
            .collect();
        if rivals.len() > 1 {
            pairing.tied.insert(root, rivals);
        } else {
            used.insert(index);
            pairing.pairs.insert(root, index);
        }
    }
    pairing
}

/// Give URL-less tabs the store's URL, each store tab used once: from the
/// paired store window first (the same strip position when its title
/// matches, else that window's first unused same-title tab), then from any
/// store window by exact title except those its window tied between.
fn fill_urls(tabs: &mut [Tab], store: &SessionStore, pairing: &Pairing) {
    let mut used: HashSet<(usize, usize)> = HashSet::new();
    let mut positions: BTreeMap<usize, usize> = BTreeMap::new();
    let mut unpaired = Vec::new();
    for (tab_index, tab) in tabs.iter_mut().enumerate() {
        let position = positions.entry(tab.root).or_default();
        let here = *position;
        *position += 1;
        if !tab.url.is_empty() || tab.title.is_empty() {
            continue;
        }
        let Some(&window_index) = pairing.pairs.get(&tab.root) else {
            unpaired.push(tab_index);
            continue;
        };
        let window = &store.windows[window_index];
        let usable = |index: usize| {
            !used.contains(&(window_index, index))
                && !window.tabs[index].url.is_empty()
                && titles_match(&tab.title, &window.tabs[index].title)
        };
        let hit = (here < window.tabs.len() && usable(here))
            .then_some(here)
            .or_else(|| (0..window.tabs.len()).find(|index| usable(*index)));
        match hit {
            Some(index) => {
                tab.url = window.tabs[index].url.clone();
                used.insert((window_index, index));
            }
            None => unpaired.push(tab_index),
        }
    }
    for tab_index in unpaired {
        let tab = &mut tabs[tab_index];
        let hit = store
            .windows
            .iter()
            .enumerate()
            .filter(|(window_index, _)| !pairing.tied_with(tab.root, *window_index))
            .find_map(|(window_index, window)| {
                window.tabs.iter().enumerate().find_map(|(index, session)| {
                    (!used.contains(&(window_index, index))
                        && !session.url.is_empty()
                        && titles_match(&tab.title, &session.title))
                    .then_some((window_index, index))
                })
            });
        if let Some((window_index, index)) = hit {
            tab.url = store.windows[window_index].tabs[index].url.clone();
            used.insert((window_index, index));
        }
    }
}

/// A paired window whose AX flags leave no single selected tab takes the
/// store's selected tab, when exactly one of its tabs carries that title.
fn apply_store_selection(tabs: &mut [Tab], store: &SessionStore, pairs: &BTreeMap<usize, usize>) {
    for (&root, &window_index) in pairs {
        let selected = tabs
            .iter()
            .filter(|tab| tab.root == root && tab.selected)
            .count();
        if selected == 1 {
            continue;
        }
        let window = &store.windows[window_index];
        let Some(session) = window.selected.and_then(|index| window.tabs.get(index)) else {
            continue;
        };
        let mut hits = tabs
            .iter()
            .enumerate()
            .filter(|(_, tab)| tab.root == root && titles_match(&tab.title, &session.title))
            .map(|(index, _)| index);
        let (Some(hit), None) = (hits.next(), hits.next()) else {
            continue;
        };
        for (index, tab) in tabs.iter_mut().enumerate() {
            if tab.root == root {
                tab.selected = index == hit;
            }
        }
    }
}

/// Store windows no on-screen window paired with — on another Space, or
/// past the node budget — listed from the store alone. A title shared with
/// the screen ("New Tab") is no evidence a store window is on screen: its
/// holder may have its own store window. But a store window an AX window
/// tied between may be that very window, so it is listed only when it holds
/// a title nowhere on screen: a duplicated "New Tab" beats hiding a real
/// window, and a wholly visible one is not listed twice.
fn offscreen_windows<'a>(
    tabs: &[Tab],
    store: &'a SessionStore,
    pairing: &Pairing,
) -> Vec<&'a SessionWindow> {
    let paired: HashSet<usize> = pairing.pairs.values().copied().collect();
    let tied: HashSet<usize> = pairing.tied.values().flatten().copied().collect();
    let visible: HashSet<&str> = tabs.iter().map(|tab| tab.title.trim()).collect();
    let holds_unseen_title = |window: &SessionWindow| {
        window.tabs.iter().any(|tab| {
            let title = tab.title.trim();
            !title.is_empty() && !visible.contains(title)
        })
    };
    store
        .windows
        .iter()
        .enumerate()
        .filter(|(index, window)| {
            !paired.contains(index)
                && !window.tabs.is_empty()
                && (!tied.contains(index) || holds_unseen_title(window))
        })
        .map(|(_, window)| window)
        .collect()
}

/// The window Firefox's tab shortcuts address, when the evidence agrees: the
/// one window reporting `AXMain`; else the only window; else the front of
/// `AXWindows` when the store names it the selected window. `None` otherwise
/// — the fast path then stays off rather than jump in the wrong window.
pub(super) fn focused_root(
    strip: &Strip,
    store: Option<&SessionStore>,
    pairs: &BTreeMap<usize, usize>,
    offscreen_windows: usize,
) -> Option<usize> {
    match strip.windows.iter().filter(|window| window.main).count() {
        0 => {}
        1 => return main_root(strip),
        _ => return None,
    }
    let roots = strip.tab_roots();
    if roots.len() == 1 && offscreen_windows == 0 {
        return roots.first().copied();
    }
    let front = *roots.first()?;
    let selected = store?.selected_window?;
    (pairs.get(&front) == Some(&selected)).then_some(front)
}

/// The one window reporting `AXMain`, when it holds tabs.
fn main_root(strip: &Strip) -> Option<usize> {
    let mut mains = strip
        .windows
        .iter()
        .enumerate()
        .filter(|(_, window)| window.main)
        .map(|(root, _)| root);
    match (mains.next(), mains.next()) {
        (Some(root), None) => strip.tab_roots().contains(&root).then_some(root),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::firefox::fixtures::{strip, tab};
    use crate::session_store::SessionTab;

    fn selected(mut tab: Tab) -> Tab {
        tab.selected = true;
        tab
    }

    fn session_window(tabs: &[(&str, &str)], selected: Option<usize>) -> SessionWindow {
        SessionWindow {
            tabs: tabs
                .iter()
                .map(|(title, url)| SessionTab {
                    title: title.to_string(),
                    url: url.to_string(),
                })
                .collect(),
            selected,
        }
    }

    fn positions(rows: &[CatalogTab]) -> Vec<(usize, usize, bool)> {
        rows.iter()
            .map(|row| {
                (
                    row.position.index,
                    row.position.tab_count,
                    row.position.window_focused,
                )
            })
            .collect()
    }

    #[test]
    fn positions_are_per_window_and_focus_follows_the_main_window() {
        let mut two = strip(
            2,
            vec![
                tab(0, "One", ""),
                tab(0, "Two", ""),
                tab(0, "Three", ""),
                tab(1, "Alpha", ""),
                tab(1, "Beta", ""),
            ],
        );
        two.windows[1].main = true;
        let rows = catalog(&two, None);
        assert_eq!(
            positions(&rows),
            [
                (1, 3, false),
                (2, 3, false),
                (3, 3, false),
                (1, 2, true),
                (2, 2, true)
            ]
        );
        assert!(rows.iter().all(|row| row.position.window_count == 2));
    }

    #[test]
    fn focus_needs_agreeing_evidence() {
        // One window: focused, with or without AXMain...
        let one = strip(1, vec![tab(0, "Only", "")]);
        assert_eq!(focused_root(&one, None, &BTreeMap::new(), 0), Some(0));
        // ...unless the store holds windows the walk cannot see.
        assert_eq!(focused_root(&one, None, &BTreeMap::new(), 1), None);
        // Two windows without AXMain: unknown...
        let two = strip(2, vec![tab(0, "Front", ""), tab(1, "Back", "")]);
        assert_eq!(focused_root(&two, None, &BTreeMap::new(), 0), None);
        // ...unless the store's selected window is the front one.
        let store = SessionStore {
            windows: vec![
                session_window(&[("Back", "")], None),
                session_window(&[("Front", "")], None),
            ],
            selected_window: Some(1),
        };
        let pairs = pair_windows(&two, &store).pairs;
        assert_eq!(pairs, BTreeMap::from([(0, 1), (1, 0)]));
        assert_eq!(focused_root(&two, Some(&store), &pairs, 0), Some(0));
        let back_selected = SessionStore {
            selected_window: Some(0),
            ..store
        };
        assert_eq!(focused_root(&two, Some(&back_selected), &pairs, 0), None);
        // A main window without tabs (a Library window) focuses no tab.
        let mut library = strip(3, vec![tab(0, "Front", ""), tab(1, "Back", "")]);
        library.windows[2].main = true;
        assert_eq!(focused_root(&library, None, &BTreeMap::new(), 0), None);
    }

    #[test]
    fn every_window_keeps_its_selected_tab_current_for_host_disambiguation() {
        let two = strip(
            2,
            vec![selected(tab(0, "Front", "")), selected(tab(1, "Back", ""))],
        );
        let rows = catalog(&two, None);
        assert!(rows
            .iter()
            .all(|row| row.current && !row.position.window_focused));
    }

    #[test]
    fn store_urls_fill_by_window_and_position_before_title() {
        let mut tabs = vec![
            tab(0, "Inbox", ""),
            tab(0, "Inbox", ""),
            tab(1, "Inbox", ""),
            tab(1, "Docs", "https://docs.example/ax"),
            tab(1, "Elsewhere", ""),
        ];
        let store = SessionStore {
            windows: vec![
                session_window(
                    &[
                        ("Inbox", "https://mail.example/b"),
                        ("Docs", "https://docs.example/store"),
                    ],
                    None,
                ),
                session_window(
                    &[
                        ("Inbox", "https://mail.example/a1"),
                        ("Inbox", "https://mail.example/a2"),
                    ],
                    None,
                ),
                session_window(&[("Elsewhere", "https://else.example/")], None),
            ],
            selected_window: None,
        };
        let pairing = pair_windows(&strip(2, tabs.clone()), &store);
        assert_eq!(pairing.pairs, BTreeMap::from([(0, 1), (1, 0)]));
        fill_urls(&mut tabs, &store, &pairing);
        assert_eq!(
            tabs.iter().map(|tab| tab.url.as_str()).collect::<Vec<_>>(),
            [
                "https://mail.example/a1",
                "https://mail.example/a2",
                "https://mail.example/b",
                // The strip's own URL wins.
                "https://docs.example/ax",
                // Not in the paired window: any window, by title.
                "https://else.example/",
            ]
        );
    }

    #[test]
    fn the_store_breaks_ambiguous_ax_selection_only() {
        let store = SessionStore {
            windows: vec![session_window(&[("A", ""), ("B", ""), ("C", "")], Some(1))],
            selected_window: Some(0),
        };
        // No AX flag at all: the store's selected tab.
        let mut none = vec![tab(0, "A", ""), tab(0, "B", ""), tab(0, "C", "")];
        let pairs = pair_windows(&strip(1, none.clone()), &store).pairs;
        apply_store_selection(&mut none, &store, &pairs);
        assert_eq!(
            none.iter().map(|tab| tab.selected).collect::<Vec<_>>(),
            [false, true, false]
        );
        // One AX flag: kept, even against a stale store.
        let mut one = vec![tab(0, "A", ""), tab(0, "B", ""), selected(tab(0, "C", ""))];
        apply_store_selection(&mut one, &store, &pairs);
        assert_eq!(
            one.iter().map(|tab| tab.selected).collect::<Vec<_>>(),
            [false, false, true]
        );
    }

    #[test]
    fn windows_only_the_store_knows_are_listed_after_the_strip() {
        let on_screen = strip(1, vec![selected(tab(0, "Docs", ""))]);
        let store = SessionStore {
            windows: vec![
                session_window(&[("Docs", "https://docs.example/")], Some(0)),
                // Another Space: listed, never current or focused.
                session_window(
                    &[
                        ("Mail", "https://mail.example/"),
                        ("", ""),
                        ("News", "https://news.example/"),
                    ],
                    Some(0),
                ),
                // Another unseen window with a same-titled tab: its own row.
                session_window(&[("Docs", "https://docs.example/other")], None),
            ],
            // Last focused: the window on another Space.
            selected_window: Some(1),
        };
        let rows = catalog(&on_screen, Some(&store));
        assert_eq!(
            rows.iter()
                .map(|row| (row.title.as_str(), row.url.as_str(), row.current))
                .collect::<Vec<_>>(),
            [
                ("Docs", "https://docs.example/", true),
                ("Mail", "https://mail.example/", false),
                ("News", "https://news.example/", false),
                ("Docs", "https://docs.example/other", false),
            ]
        );
        // Strip positions of the unseen window count its blank tab; the one
        // AX window is not assumed focused while the store names another.
        assert_eq!(
            positions(&rows),
            [(1, 1, false), (1, 3, false), (3, 3, false), (1, 1, false)]
        );
        assert!(rows.iter().all(|row| row.position.window_count == 3));
        // With the walk seeing nothing, the store is the whole catalog.
        let blank = catalog(&Strip::default(), Some(&store));
        assert_eq!(blank.len(), 4);
    }

    fn listed(rows: &[CatalogTab]) -> Vec<(&str, &str, bool)> {
        rows.iter()
            .map(|row| (row.title.as_str(), row.url.as_str(), row.current))
            .collect()
    }

    #[test]
    fn a_window_on_another_space_survives_sharing_a_title_with_the_screen() {
        let on_screen = strip(1, vec![selected(tab(0, "New Tab", "")), tab(0, "Docs", "")]);
        let store = SessionStore {
            windows: vec![
                // Another Space: its "New Tab" is not the on-screen one.
                session_window(
                    &[
                        ("New Tab", "about:newtab"),
                        ("Mail", "https://mail.example/"),
                    ],
                    Some(1),
                ),
                session_window(
                    &[
                        ("New Tab", "about:newtab"),
                        ("Docs", "https://docs.example/"),
                    ],
                    Some(0),
                ),
            ],
            selected_window: Some(1),
        };
        assert_eq!(
            listed(&catalog(&on_screen, Some(&store))),
            [
                ("New Tab", "about:newtab", true),
                ("Docs", "https://docs.example/", false),
                ("New Tab", "about:newtab", false),
                ("Mail", "https://mail.example/", false),
            ]
        );
    }

    #[test]
    fn a_title_tie_pairs_the_window_showing_the_same_selected_tab() {
        // One on-screen "New Tab" matches both store windows by one title:
        // only its own store window has "New Tab" selected.
        let on_screen = strip(1, vec![selected(tab(0, "New Tab", ""))]);
        let store = SessionStore {
            windows: vec![
                session_window(
                    &[
                        ("New Tab", "about:newtab"),
                        ("Mail", "https://mail.example/"),
                    ],
                    Some(1),
                ),
                session_window(&[("New Tab", "about:newtab")], Some(0)),
            ],
            selected_window: Some(1),
        };
        assert_eq!(
            pair_windows(&on_screen, &store).pairs,
            BTreeMap::from([(0, 1)])
        );
        let rows = catalog(&on_screen, Some(&store));
        assert_eq!(
            listed(&rows),
            [
                ("New Tab", "about:newtab", true),
                ("New Tab", "about:newtab", false),
                ("Mail", "https://mail.example/", false),
            ]
        );
        // The store's focused window is the paired one: the fast path stays on.
        assert!(rows[0].position.window_focused);
        assert!(rows.iter().all(|row| row.position.window_count == 2));
    }

    #[test]
    fn a_lagging_store_window_still_pairs_with_its_focused_window() {
        // The focused window is down to one "New Tab"; its store window
        // still lists the "Docs" tab closed since the last write. Another
        // Space holds a one-tab "New Tab" window of its own.
        let mut on_screen = strip(1, vec![selected(tab(0, "New Tab", ""))]);
        on_screen.windows[0].main = true;
        let store = SessionStore {
            windows: vec![
                session_window(&[("New Tab", "about:home")], Some(0)),
                session_window(
                    &[
                        ("New Tab", "about:newtab"),
                        ("Docs", "https://docs.example/"),
                    ],
                    Some(0),
                ),
            ],
            selected_window: Some(1),
        };
        let rows = catalog(&on_screen, Some(&store));
        assert_eq!(
            listed(&rows),
            [
                ("New Tab", "about:newtab", true),
                ("New Tab", "about:home", false),
            ]
        );
        assert!(rows[0].position.window_focused);
    }

    #[test]
    fn an_undecidable_tie_pairs_neither_store_window() {
        // Both store windows show a selected "New Tab" and nothing names the
        // focused window: the on-screen "New Tab" could be either.
        let on_screen = strip(1, vec![selected(tab(0, "New Tab", ""))]);
        let store = SessionStore {
            windows: vec![
                session_window(
                    &[
                        ("New Tab", "about:newtab"),
                        ("Mail", "https://mail.example/"),
                    ],
                    Some(0),
                ),
                session_window(&[("New Tab", "about:home")], Some(0)),
            ],
            selected_window: None,
        };
        let pairing = pair_windows(&on_screen, &store);
        assert!(pairing.pairs.is_empty());
        assert_eq!(pairing.tied[&0], BTreeSet::from([0, 1]));
        let rows = catalog(&on_screen, Some(&store));
        assert_eq!(
            listed(&rows),
            [
                // Neither candidate lends it a URL.
                ("New Tab", "", true),
                // "Mail" is nowhere on screen: listed, "New Tab" and all.
                ("New Tab", "about:newtab", false),
                ("Mail", "https://mail.example/", false),
                // Wholly visible: not listed again.
            ]
        );
    }

    #[test]
    fn stores_go_to_the_firefox_whose_strip_they_hold() {
        let file = |modified_ms, titles: &[&str]| StoreFile {
            modified_ms,
            store: std::sync::Arc::new(SessionStore {
                windows: vec![session_window(
                    &titles.iter().map(|title| (*title, "")).collect::<Vec<_>>(),
                    None,
                )],
                selected_window: None,
            }),
        };
        // Newest first, as `session_store::load` returns them.
        let stores = [
            file(3, &["Release", "Shared"]),
            file(2, &["Dev", "Dev 2", "Shared"]),
            file(1, &["Shared"]),
        ];
        let release = [tab(0, "Release", ""), tab(0, "Shared", "")];
        let dev = [tab(0, "Dev", ""), tab(0, "Dev 2", "")];
        let nothing: &[Tab] = &[];
        assert_eq!(
            assign_stores(&[(10, &release[..]), (11, &dev[..])], &stores),
            HashMap::from([(10, 0), (11, 1)])
        );
        // A tie goes to the newer store.
        let shared = [tab(0, "Shared", "")];
        assert_eq!(
            assign_stores(&[(10, &shared[..])], &stores),
            HashMap::from([(10, 0)])
        );
        // A walk that sees nothing takes the newest unclaimed store, but only
        // as the sole such Firefox.
        assert_eq!(
            assign_stores(&[(10, &release[..]), (12, nothing)], &stores),
            HashMap::from([(10, 0), (12, 1)])
        );
        assert_eq!(
            assign_stores(&[(12, nothing), (13, nothing)], &stores),
            HashMap::new()
        );
        // Nothing in common: no store.
        let private = [tab(0, "Private", "")];
        assert_eq!(
            assign_stores(&[(10, &private[..])], &stores),
            HashMap::new()
        );
    }
}
