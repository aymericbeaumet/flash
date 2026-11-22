//! A menu bar as the host's snapshot describes it, and the items `@menus`
//! lists from it.
//!
//! The snapshot is flat and breadth-first: each node names its parent, and
//! the children of one node keep their menu order. The first node is the
//! app's `AXMenuBar`; its children are the bar items, the Apple menu first.

use std::collections::HashMap;

use serde_json::Value;

pub const ROLE: &str = "AXRole";
pub const TITLE: &str = "AXTitle";
pub const ENABLED: &str = "AXEnabled";
pub const CHILDREN: &str = "AXChildren";

/// The deepest submenu listed, counted from the bar: `File › Export › PDF…`
/// sits at depth 2.
const MAX_DEPTH: usize = 4;
/// The elements the listing visits before it stops: bar items, the Apple
/// menu and the `AXMenu` holding a submenu's items do not count.
const MAX_VISITED: usize = 2500;
/// What joins the titles of a path.
const SEPARATOR: &str = " › ";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Role {
    Menu,
    MenuItem,
    MenuBarItem,
    Other,
}

#[derive(Debug)]
struct Node {
    handle: u64,
    role: Role,
    /// As the element reports it; the listing trims it.
    title: Option<String>,
    /// True when the element does not say.
    enabled: bool,
    children: Vec<usize>,
}

/// One pressable menu item: its path from the bar, and the handle the host
/// presses it by.
#[derive(Debug, PartialEq, Eq)]
pub struct Item {
    pub title: String,
    pub handle: u64,
}

#[derive(Debug)]
pub struct MenuBar {
    nodes: Vec<Node>,
    /// The nodes before this index have every child they own in the
    /// snapshot. A walk that stopped at its node budget read the ones from
    /// here on without reaching their children.
    expanded: usize,
}

impl MenuBar {
    /// The tree of a snapshot's `nodes`, walked with a budget of
    /// `max_nodes`. `None` when a node is not what the protocol describes.
    pub fn from_nodes(values: &[Value], max_nodes: usize) -> Option<Self> {
        let mut nodes = Vec::with_capacity(values.len());
        let mut parents = Vec::with_capacity(values.len());
        let mut index_of = HashMap::with_capacity(values.len());
        for (index, value) in values.iter().enumerate() {
            let handle = value.get("handle")?.as_u64()?;
            let attrs = value.get("attrs")?.as_object()?;
            let attr = |name: &str| attrs.get(name).and_then(Value::as_str);
            let parent = match value.get("parent") {
                None | Some(Value::Null) => None,
                // A child always follows its parent in a breadth-first walk.
                Some(parent) => Some(*index_of.get(&parent.as_u64()?)?),
            };
            index_of.insert(handle, index);
            parents.push(parent);
            nodes.push(Node {
                handle,
                role: match attr(ROLE) {
                    Some("AXMenu") => Role::Menu,
                    Some("AXMenuItem") => Role::MenuItem,
                    Some("AXMenuBarItem") => Role::MenuBarItem,
                    _ => Role::Other,
                },
                title: attr(TITLE).map(str::to_string),
                // A flag arrives as "1" or "0".
                enabled: attr(ENABLED) != Some("0"),
                children: Vec::new(),
            });
        }
        for (index, parent) in parents.iter().enumerate() {
            if let Some(parent) = parent {
                nodes[*parent].children.push(index);
            }
        }
        // A walk that used its whole budget stopped while reading the
        // children of its last node's parent: every node after that parent
        // was read, and none of them expanded.
        let expanded = if values.len() >= max_nodes {
            parents.last().copied().flatten().unwrap_or(0)
        } else {
            nodes.len()
        };
        Some(Self { nodes, expanded })
    }

    /// The elements the snapshot holds.
    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    /// The enabled, titled items that open no submenu, in menu order, each
    /// under the titles that lead to it. The Apple menu, the first bar
    /// item, is skipped: its items belong to the system, not the app.
    pub fn items(&self) -> Vec<Item> {
        let mut listing = Listing {
            bar: self,
            items: Vec::new(),
            visited: 0,
        };
        let bar_items = self.nodes.first().map_or(&[][..], |bar| &bar.children);
        for &bar_item in bar_items.iter().skip(1) {
            let Some(title) = trimmed(self.nodes[bar_item].title.as_deref()) else {
                continue;
            };
            listing.descend(bar_item, &mut vec![title], 1);
        }
        listing.items
    }
}

struct Listing<'a> {
    bar: &'a MenuBar,
    items: Vec<Item>,
    visited: usize,
}

impl<'a> Listing<'a> {
    fn descend(&mut self, parent: usize, path: &mut Vec<&'a str>, depth: usize) {
        if depth > MAX_DEPTH || self.visited >= MAX_VISITED {
            return;
        }
        let bar = self.bar;
        for &child in &bar.nodes[parent].children {
            self.visited += 1;
            if self.visited >= MAX_VISITED {
                return;
            }
            let node = &bar.nodes[child];
            match node.role {
                Role::Menu => self.descend(child, path, depth),
                Role::MenuItem | Role::MenuBarItem => {
                    let Some(title) = trimmed(node.title.as_deref()) else {
                        continue;
                    };
                    let submenus: Vec<usize> = node
                        .children
                        .iter()
                        .copied()
                        .filter(|&menu| bar.nodes[menu].role == Role::Menu)
                        .collect();
                    path.push(title);
                    if submenus.is_empty() {
                        // An item the walk never expanded may open a
                        // submenu: it is not offered as one to press.
                        if node.role == Role::MenuItem && node.enabled && child < bar.expanded {
                            self.items.push(Item {
                                title: path.join(SEPARATOR),
                                handle: node.handle,
                            });
                        }
                    } else {
                        for submenu in submenus {
                            self.descend(submenu, path, depth + 1);
                        }
                    }
                    path.pop();
                }
                Role::Other => {}
            }
        }
    }
}

/// `title` without the spaces around it, `None` when nothing is left.
/// Spaces are the tab and Unicode's space separators, as AppKit trims them;
/// a line break is part of a title.
fn trimmed(title: Option<&str>) -> Option<&str> {
    let title = title?.trim_matches(is_space);
    (!title.is_empty()).then_some(title)
}

fn is_space(character: char) -> bool {
    matches!(
        character,
        '\t' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

#[cfg(test)]
pub mod testing {
    use serde_json::{Map, Value, json};

    /// A snapshot under construction: nodes in the order the test adds
    /// them, which a test keeps breadth-first as the host's walk is.
    #[derive(Default)]
    pub struct Snapshot {
        nodes: Vec<Value>,
    }

    impl Snapshot {
        /// One with its `AXMenuBar`, handle 1.
        pub fn bar() -> Self {
            let mut snapshot = Self::default();
            snapshot.add(1, None, "AXMenuBar", None, None);
            snapshot
        }

        pub fn add(
            &mut self,
            handle: u64,
            parent: Option<u64>,
            role: &str,
            title: Option<&str>,
            enabled: Option<bool>,
        ) -> &mut Self {
            let mut attrs = Map::new();
            attrs.insert(super::ROLE.into(), role.into());
            if let Some(title) = title {
                attrs.insert(super::TITLE.into(), title.into());
            }
            if let Some(enabled) = enabled {
                attrs.insert(
                    super::ENABLED.into(),
                    if enabled { "1" } else { "0" }.into(),
                );
            }
            let mut node = json!({ "handle": handle, "root": 0, "attrs": attrs });
            if let Some(parent) = parent {
                node["parent"] = parent.into();
            }
            self.nodes.push(node);
            self
        }

        /// A bar item under the bar.
        pub fn bar_item(&mut self, handle: u64, title: &str) -> &mut Self {
            self.add(handle, Some(1), "AXMenuBarItem", Some(title), Some(true))
        }

        /// The `AXMenu` an item or a bar item opens.
        pub fn menu(&mut self, handle: u64, parent: u64) -> &mut Self {
            self.add(handle, Some(parent), "AXMenu", None, Some(true))
        }

        /// An enabled item.
        pub fn item(&mut self, handle: u64, parent: u64, title: &str) -> &mut Self {
            self.add(handle, Some(parent), "AXMenuItem", Some(title), Some(true))
        }

        pub fn nodes(&self) -> Vec<Value> {
            self.nodes.clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::Snapshot;
    use super::*;

    fn titles(snapshot: &Snapshot) -> Vec<String> {
        listed(snapshot, usize::MAX)
            .into_iter()
            .map(|item| item.title)
            .collect()
    }

    fn listed(snapshot: &Snapshot, max_nodes: usize) -> Vec<Item> {
        MenuBar::from_nodes(&snapshot.nodes(), max_nodes)
            .expect("a well-formed snapshot")
            .items()
    }

    /// Apple, File (New Tab, a disabled item, a blank one, Export with a
    /// submenu, a separator) and View, which opens nothing.
    fn app() -> Snapshot {
        let mut snapshot = Snapshot::bar();
        snapshot
            .bar_item(2, "Apple")
            .bar_item(3, "File")
            .bar_item(4, "View")
            .menu(10, 2)
            .menu(20, 3)
            .item(11, 10, "About This Mac")
            .item(21, 20, "New Tab")
            .add(22, Some(20), "AXMenuItem", Some("Close All"), Some(false))
            .item(23, 20, "   ")
            .item(24, 20, " Export ")
            .add(25, Some(20), "AXUnknown", None, None)
            .menu(30, 24)
            .item(31, 30, "PDF…")
            .item(32, 30, "PNG…");
        snapshot
    }

    #[test]
    fn enabled_titled_leaves_are_listed_under_their_path() {
        assert_eq!(
            listed(&app(), usize::MAX),
            [
                Item {
                    title: "File › New Tab".into(),
                    handle: 21
                },
                Item {
                    title: "File › Export › PDF…".into(),
                    handle: 31
                },
                Item {
                    title: "File › Export › PNG…".into(),
                    handle: 32
                },
            ],
            "the Apple menu is skipped, disabled and blank items are left out, and a bar \
             item without a menu is no item"
        );
    }

    /// The snapshot is breadth-first; the list is the menus' own order, a
    /// submenu's items where the item that opens it sits.
    #[test]
    fn the_listing_follows_menu_order_not_snapshot_order() {
        let mut snapshot = Snapshot::bar();
        snapshot
            .bar_item(2, "Apple")
            .bar_item(3, "File")
            .bar_item(4, "Edit")
            .menu(20, 3)
            .menu(40, 4)
            .item(21, 20, "Open Recent")
            .item(22, 20, "Close")
            .item(41, 40, "Undo")
            .menu(30, 21)
            .item(31, 30, "notes.txt");
        assert_eq!(
            titles(&snapshot),
            [
                "File › Open Recent › notes.txt",
                "File › Close",
                "Edit › Undo"
            ]
        );
    }

    #[test]
    fn an_item_that_does_not_say_is_enabled() {
        let mut snapshot = Snapshot::bar();
        snapshot
            .bar_item(2, "Apple")
            .bar_item(3, "File")
            .menu(20, 3)
            .add(21, Some(20), "AXMenuItem", Some("Print…"), None);
        assert_eq!(titles(&snapshot), ["File › Print…"]);
    }

    #[test]
    fn titles_lose_the_spaces_around_them_and_nothing_else() {
        let mut snapshot = Snapshot::bar();
        snapshot
            .bar_item(2, "Apple")
            .bar_item(3, "\u{00A0}File\t")
            .bar_item(4, " \u{3000}")
            .menu(20, 3)
            .menu(40, 4)
            .item(21, 20, "\u{2009}Save As…  ")
            .item(22, 20, "\n")
            .item(41, 40, "Hidden");
        assert_eq!(
            titles(&snapshot),
            ["File › Save As…", "File › \n"],
            "a bar item with a blank title lists nothing, and a line break is no space"
        );
    }

    #[test]
    fn depth_is_bounded() {
        let mut snapshot = Snapshot::bar();
        snapshot
            .bar_item(2, "Apple")
            .bar_item(3, "Deep")
            .menu(100, 3);
        // Level n: a menu holding the item that opens level n + 1, and a leaf.
        for level in 0..8u64 {
            let menu = 100 + level * 10;
            snapshot
                .item(menu + 1, menu, &format!("Level {level}"))
                .item(menu + 2, menu, &format!("Leaf {level}"))
                .menu(menu + 10, menu + 1);
        }
        let titles = titles(&snapshot);
        assert!(titles.contains(&"Deep › Leaf 0".to_string()), "{titles:?}");
        assert!(
            titles.contains(&"Deep › Level 0 › Level 1 › Level 2 › Leaf 3".to_string()),
            "{titles:?}"
        );
        assert!(
            !titles.iter().any(|title| title.ends_with("Leaf 4")),
            "{titles:?}"
        );
    }

    #[test]
    fn the_listing_stops_at_its_visit_bound() {
        let mut snapshot = Snapshot::bar();
        snapshot
            .bar_item(2, "Apple")
            .bar_item(3, "History")
            .bar_item(4, "Help")
            .menu(10, 3)
            .menu(11, 4);
        for index in 0..3000u64 {
            snapshot.item(1000 + index, 10, &format!("Page {index}"));
        }
        snapshot.item(9000, 11, "Search");
        let titles = titles(&snapshot);
        // The menu is the first element visited, and the bound is exclusive.
        assert_eq!(titles.len(), MAX_VISITED - 2);
        assert_eq!(titles.first().map(String::as_str), Some("History › Page 0"));
        assert!(
            !titles.contains(&"Help › Search".to_string()),
            "nothing after the bound"
        );
    }

    /// A walk that ran out of budget read its last nodes without their
    /// children. Such an item may open a submenu, so it is not offered.
    #[test]
    fn an_item_a_truncated_walk_did_not_expand_is_not_listed() {
        let mut snapshot = Snapshot::bar();
        snapshot
            .bar_item(2, "Apple")
            .bar_item(3, "File")
            .menu(10, 2)
            .menu(20, 3)
            .item(11, 10, "About This Mac")
            .item(21, 20, "New Tab")
            .item(22, 20, "Open Recent")
            .item(23, 20, "Close");
        // Whole: nine nodes under a budget of ten.
        assert_eq!(
            listed(&snapshot, 10)
                .iter()
                .map(|item| item.title.as_str())
                .collect::<Vec<_>>(),
            ["File › New Tab", "File › Open Recent", "File › Close"]
        );
        // Cut at nine: the walk stopped inside File's menu, whose items it
        // read without expanding. Open Recent may hold a submenu.
        assert_eq!(listed(&snapshot, 9), []);
        // Cut after the first submenu level was read whole.
        snapshot.menu(30, 22).item(31, 30, "notes.txt");
        assert_eq!(
            listed(&snapshot, 11)
                .iter()
                .map(|item| item.title.as_str())
                .collect::<Vec<_>>(),
            ["File › New Tab", "File › Close"],
            "the items read before the last node's parent were expanded; notes.txt was not"
        );
    }

    #[test]
    fn a_snapshot_without_nodes_lists_nothing() {
        let bar = MenuBar::from_nodes(&[], 3000).expect("an empty tree");
        assert_eq!(bar.len(), 0);
        assert_eq!(bar.items(), []);
    }

    #[test]
    fn a_node_the_protocol_does_not_describe_refuses_the_snapshot() {
        use serde_json::json;
        let bar = json!({ "handle": 1, "root": 0, "attrs": {} });
        for node in [
            json!({ "root": 0, "attrs": {} }),
            json!({ "handle": "2", "root": 0, "attrs": {} }),
            json!({ "handle": 2, "root": 0 }),
            json!({ "handle": 2, "root": 0, "attrs": {}, "parent": 7 }),
            json!({ "handle": 2, "root": 0, "attrs": {}, "parent": "1" }),
        ] {
            assert!(
                MenuBar::from_nodes(&[bar.clone(), node.clone()], 3000).is_none(),
                "{node}"
            );
        }
        assert!(
            MenuBar::from_nodes(
                &[
                    bar,
                    json!({ "handle": 2, "root": 0, "attrs": {}, "parent": 1 })
                ],
                3000
            )
            .is_some()
        );
    }
}
