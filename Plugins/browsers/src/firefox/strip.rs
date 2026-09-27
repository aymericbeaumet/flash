//! One Accessibility walk of a Firefox process: its windows, front to back,
//! with the one Firefox's key equivalents address (`AXMain`), and every
//! window's tab strip.

use std::collections::{BTreeSet, HashSet};

use flash_plugin::Context;

use crate::ax::{self, AxNode};

const MAX_NODES: u64 = 3_000;

/// Attributes the broker reads for every visited node. Which node is a tab,
/// and what its title and URL are, is decided here, not in the host.
const COLLECT: &[&str] = &[
    "AXRole",
    "AXSubrole",
    "AXRoleDescription",
    "AXTitle",
    "AXDescription",
    "AXValue",
    "AXURL",
    "AXDocument",
    "AXSelected",
    "AXMain",
];

/// One tab-strip entry.
#[derive(Clone, Debug, Default)]
pub(super) struct Tab {
    pub(super) handle: u64,
    pub(super) parent_handle: Option<u64>,
    /// `AXWindows` index of the window holding the tab.
    pub(super) root: usize,
    pub(super) window_handle: Option<u64>,
    pub(super) title: String,
    pub(super) url: String,
    pub(super) selected: bool,
}

#[derive(Clone, Debug, Default)]
pub(super) struct AxWindow {
    pub(super) handle: Option<u64>,
    pub(super) title: String,
    /// `AXMain`: the window Firefox's key equivalents address.
    pub(super) main: bool,
}

/// Windows by `AXWindows` index (front to back), and the tabs of every
/// window in strip order.
#[derive(Clone, Debug, Default)]
pub(super) struct Strip {
    pub(super) windows: Vec<AxWindow>,
    pub(super) tabs: Vec<Tab>,
}

/// `None` when the broker refuses the walk: a failed walk, not an empty one.
pub(super) async fn walk(ctx: &Context, pid: i64) -> Option<Strip> {
    let nodes = ax::snapshot(ctx, pid, COLLECT, MAX_NODES, &["AXWebArea"]).await?;
    Some(Strip::from_nodes(&nodes))
}

impl Strip {
    fn from_nodes(nodes: &[AxNode]) -> Self {
        let mut windows: Vec<AxWindow> = Vec::new();
        for node in nodes {
            if node.parent.is_none() && node.attr("AXRole") == Some("AXWindow") {
                if node.root >= windows.len() {
                    windows.resize(node.root + 1, AxWindow::default());
                }
                windows[node.root] = AxWindow {
                    handle: Some(node.handle),
                    title: node.attr("AXTitle").unwrap_or("").to_string(),
                    main: node.flag("AXMain"),
                };
            }
        }
        let mut tabs = Vec::new();
        let mut seen = HashSet::new();
        for node in nodes {
            if !is_tab(node) || !seen.insert((node.root, node.handle)) {
                continue;
            }
            let window = windows.get(node.root);
            let fallback = window.map(|window| window.title.as_str()).unwrap_or("");
            let Some(title) = tab_title(node, fallback) else {
                continue;
            };
            tabs.push(Tab {
                handle: node.handle,
                parent_handle: node.parent,
                root: node.root,
                window_handle: window.and_then(|window| window.handle),
                title,
                url: tab_url(node),
                selected: node.flag("AXSelected"),
            });
        }
        let mut strip = Self { windows, tabs };
        strip.apply_window_title_selection();
        strip
    }

    /// Firefox reports `AXSelected` unreliably; a window's title is its
    /// selected tab's, so a unique title match overrides the flags.
    fn apply_window_title_selection(&mut self) {
        for (root, window) in self.windows.iter().enumerate() {
            let window_title = window.title.trim();
            if window_title.is_empty() {
                continue;
            }
            let mut matches = self
                .tabs
                .iter()
                .enumerate()
                .filter(|(_, tab)| {
                    tab.root == root && title_matches_window(&tab.title, window_title)
                })
                .map(|(index, _)| index);
            let (Some(selected), None) = (matches.next(), matches.next()) else {
                continue;
            };
            for (index, tab) in self.tabs.iter_mut().enumerate() {
                if tab.root == root {
                    tab.selected = index == selected;
                }
            }
        }
    }

    /// Window roots holding tabs, front to back.
    pub(super) fn tab_roots(&self) -> BTreeSet<usize> {
        self.tabs.iter().map(|tab| tab.root).collect()
    }
}

/// A tab is an `AXTab`, or a radio button / button whose subrole or role
/// description marks a tab-strip entry.
fn is_tab(node: &AxNode) -> bool {
    let role = node.attr("AXRole").unwrap_or("");
    if role == "AXTab" {
        return true;
    }
    let subrole = node.attr("AXSubrole").unwrap_or("");
    let role_description = node.attr("AXRoleDescription").unwrap_or("").to_lowercase();
    let is_tab_button = subrole == "AXTabButton"
        || role_description == "tab"
        || role_description.contains("tab button");
    matches!(role, "AXRadioButton" | "AXButton") && is_tab_button
}

fn tab_title(node: &AxNode, fallback: &str) -> Option<String> {
    let raw = node
        .attr("AXTitle")
        .or_else(|| node.attr("AXDescription"))
        .or_else(|| node.attr("AXValue"))
        .unwrap_or(fallback);
    let trimmed = raw.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

fn tab_url(node: &AxNode) -> String {
    node.attr("AXURL")
        .or_else(|| node.attr("AXDocument"))
        .unwrap_or("")
        .trim()
        .to_string()
}

fn title_matches_window(tab_title: &str, window_title: &str) -> bool {
    let tab = tab_title.trim();
    let window = window_title.trim();
    if tab.is_empty() || window.is_empty() {
        return false;
    }
    window == tab
        || [" — Mozilla Firefox", " - Mozilla Firefox"]
            .iter()
            .any(|suffix| {
                window
                    .strip_suffix(suffix)
                    .is_some_and(|title| title.trim() == tab)
            })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(handle: u64, parent: Option<u64>, root: usize, attrs: &[(&str, &str)]) -> AxNode {
        AxNode {
            handle,
            parent,
            root,
            attrs: attrs
                .iter()
                .map(|(key, value)| (key.to_string(), value.to_string()))
                .collect(),
        }
    }

    #[test]
    fn walk_keeps_distinct_tabs_with_identical_titles_and_urls() {
        let nodes: Vec<_> = [1, 2, 2]
            .into_iter()
            .map(|handle| {
                node(
                    handle,
                    None,
                    0,
                    &[
                        ("AXRole", "AXTab"),
                        ("AXTitle", "Same"),
                        ("AXURL", "https://example.com/same"),
                    ],
                )
            })
            .collect();
        let strip = Strip::from_nodes(&nodes);
        assert_eq!(
            strip.tabs.iter().map(|tab| tab.handle).collect::<Vec<_>>(),
            [1, 2]
        );
    }

    #[test]
    fn walk_reads_windows_tab_buttons_and_the_main_flag() {
        let tab_button = [("AXRole", "AXRadioButton"), ("AXSubrole", "AXTabButton")];
        let nodes = [
            node(
                1,
                None,
                0,
                &[
                    ("AXRole", "AXWindow"),
                    ("AXTitle", "Docs — Mozilla Firefox"),
                    ("AXMain", "0"),
                ],
            ),
            node(
                2,
                Some(1),
                0,
                &[
                    tab_button[0],
                    tab_button[1],
                    ("AXTitle", "Inbox"),
                    ("AXSelected", "1"),
                ],
            ),
            node(
                3,
                Some(1),
                0,
                &[
                    ("AXRole", "AXRadioButton"),
                    ("AXRoleDescription", "Tab"),
                    ("AXTitle", "Docs"),
                ],
            ),
            // Not a tab: a plain button.
            node(
                4,
                Some(1),
                0,
                &[("AXRole", "AXButton"), ("AXTitle", "Reload")],
            ),
            node(
                5,
                None,
                1,
                &[("AXRole", "AXWindow"), ("AXTitle", "Mail"), ("AXMain", "1")],
            ),
            // No title of its own: the window's.
            node(6, Some(5), 1, &[("AXRole", "AXTab")]),
        ];
        let strip = Strip::from_nodes(&nodes);
        assert_eq!(
            strip
                .tabs
                .iter()
                .map(|tab| (
                    tab.root,
                    tab.title.as_str(),
                    tab.selected,
                    tab.window_handle
                ))
                .collect::<Vec<_>>(),
            // The window title names Docs as selected, overriding AXSelected.
            [
                (0, "Inbox", false, Some(1)),
                (0, "Docs", true, Some(1)),
                (1, "Mail", true, Some(5))
            ]
        );
        assert_eq!(
            strip
                .windows
                .iter()
                .map(|window| window.main)
                .collect::<Vec<_>>(),
            [false, true]
        );
    }
}
