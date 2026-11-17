//! Typed browser operations. The resident owns every AppleScript template.
use crate::route::TabTarget;
use flash_plugin::AppleScriptOperation;
use serde::{Deserialize, Serialize};

pub struct Dialect {
    scripts_tab_moves: bool,
}
pub const CHROMIUM: Dialect = Dialect {
    scripts_tab_moves: false,
};
pub const SAFARI: Dialect = Dialect {
    scripts_tab_moves: true,
};

/// Where a listed tab sat: its window's 1-based index (front to back) and
/// its 1-based position in that window's tabs. The one identity two open
/// tabs with the same title and URL do not share.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TabSlot {
    pub window: usize,
    pub tab: usize,
}

/// What a select script requires of a tab: every field given, equal and
/// case-sensitive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TabIdentity<'a> {
    url: Option<&'a str>,
    title: Option<&'a str>,
}

impl<'a> TabIdentity<'a> {
    /// A listed tab: its URL and title together (an empty title included),
    /// or its title alone when it exposes no URL.
    pub fn listed(url: &'a str, title: &'a str) -> Self {
        Self {
            url: (!url.is_empty()).then_some(url),
            title: Some(title),
        }
    }

    /// A route's target alone: a URL route outlives title changes.
    pub fn route(target: &'a TabTarget) -> Self {
        match target {
            TabTarget::Url(url) => Self {
                url: Some(url),
                title: None,
            },
            TabTarget::Title(title) => Self {
                url: None,
                title: Some(title),
            },
        }
    }
}

/// One row of [`Dialect::list_operation`]'s output.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListedTab {
    pub slot: TabSlot,
    pub title: String,
    pub url: String,
    /// The front window's current tab.
    pub current: bool,
}

/// Parse `window<TAB>tab<TAB>current<TAB>url<TAB>title` lines, the title last
/// so a tab character inside it survives. Every open tab is its own row,
/// identified by its slot: a browser is read once per cycle, so identical
/// title and URL pairs are distinct tabs. Rows with neither a title nor a
/// URL, and lines without a valid slot, are dropped. The title is kept as the
/// browser reports it, surrounding whitespace included: it is the identity a
/// select script compares verbatim, and rows trim it only for display.
pub fn parse_tab_list(stdout: &str) -> Vec<ListedTab> {
    stdout
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(5, '\t');
            let index = |part: Option<&str>| {
                part.and_then(|value| value.trim().parse::<usize>().ok())
                    .filter(|value| *value > 0)
            };
            let slot = TabSlot {
                window: index(parts.next())?,
                tab: index(parts.next())?,
            };
            let current = parts.next().is_some_and(|value| value.trim() == "1");
            let url = parts.next().unwrap_or("").trim();
            let title = parts.next().unwrap_or("").trim_end_matches(['\r', '\n']);
            if title.trim().is_empty() && url.is_empty() {
                return None;
            }
            Some(ListedTab {
                slot,
                title: title.to_string(),
                url: url.to_string(),
                current,
            })
        })
        .collect()
}

impl Dialect {
    pub fn list_operation(&self, bundle_id: &str) -> AppleScriptOperation {
        AppleScriptOperation::BrowserTabs {
            bundle_id: bundle_id.to_string(),
        }
    }
    pub fn select_operation(
        &self,
        bundle_id: &str,
        identity: TabIdentity,
        slot: Option<TabSlot>,
    ) -> AppleScriptOperation {
        AppleScriptOperation::BrowserSelect {
            bundle_id: bundle_id.to_string(),
            url: identity.url.map(str::to_string),
            title: identity.title.map(str::to_string),
            window: slot.map(|slot| slot.window),
            tab: slot.map(|slot| slot.tab),
        }
    }
    pub fn tab_select_operation(&self, bundle_id: &str, index: i64) -> AppleScriptOperation {
        AppleScriptOperation::BrowserTabIndex {
            bundle_id: bundle_id.to_string(),
            index,
        }
    }
    pub fn tab_move_operation(
        &self,
        bundle_id: &str,
        forward: bool,
    ) -> Option<AppleScriptOperation> {
        self.scripts_tab_moves
            .then(|| AppleScriptOperation::BrowserTabMove {
                bundle_id: bundle_id.to_string(),
                forward,
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn listed_titles_keep_the_browsers_whitespace() {
        let tabs = parse_tab_list("1\t1\t1\thttps://mail.example/\t  Inbox \n1\t2\t0\t\t   \n");
        assert_eq!(tabs.len(), 1, "a blank title without a URL is no row");
        assert_eq!(tabs[0].title, "  Inbox ");
    }

    #[test]
    fn tab_lists_keep_identical_tabs_apart_by_their_slot() {
        let tab = |window, index, title: &str, url: &str, current| ListedTab {
            slot: TabSlot { window, tab: index },
            title: title.into(),
            url: url.into(),
            current,
        };
        let tabs = parse_tab_list(
            "1\t1\t0\thttps://mail.example/\tInbox\n\
             1\t2\t0\t\t\n\
             1\t3\t1\thttps://mail.example/\tInbox\n\
             2\t1\t0\thttps://blank.example/\t\n\
             2\t2\t0\thttps://docs.example/\tDocs\twith a tab\n\
             x\t1\t0\thttps://malformed.example/\tMalformed\n",
        );
        assert_eq!(
            tabs,
            [
                // Two open tabs with one title and URL are two rows, and the
                // current flag stays on the one that is current.
                tab(1, 1, "Inbox", "https://mail.example/", false),
                tab(1, 3, "Inbox", "https://mail.example/", true),
                tab(2, 1, "", "https://blank.example/", false),
                tab(2, 2, "Docs\twith a tab", "https://docs.example/", false),
            ]
        );
    }
}
