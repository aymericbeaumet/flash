//! Tab scripting for the browsers with an AppleScript tab dictionary:
//! Chromium-family browsers and Safari. The two dialects differ only in the
//! phrases below; every script skeleton is shared.

use flash_plugin::applescript_quote;
use serde::{Deserialize, Serialize};

use crate::route::TabTarget;

pub struct Dialect {
    /// Expression yielding the index of window `w`'s current tab.
    active_index: &'static str,
    /// Tab property carrying the page title.
    title: &'static str,
    /// Make tab `t` the current tab of window `w`.
    select_tab: &'static str,
    /// Make tab number `tabIndex` the current tab of window `w`.
    select_nth: &'static str,
    /// Create a window when none exists.
    new_window: &'static str,
    /// Create and focus a tab, inside `tell front window`.
    new_tab: &'static str,
    /// The front window's current tab, as a `close` target.
    current_tab: &'static str,
    /// Whether scripting can reorder tabs. Chromium's `move` recreates the
    /// moved tab as a blank one, so its moves use the native
    /// ctrl+shift+pageup/pagedown chords instead (`action_keystrokes`).
    scripts_tab_moves: bool,
}

pub const CHROMIUM: Dialect = Dialect {
    active_index: "active tab index of w",
    title: "title",
    select_tab: "set active tab index of w to (index of t)",
    select_nth: "set active tab index of w to tabIndex",
    new_window: "make new window",
    new_tab: "make new tab",
    current_tab: "active tab",
    scripts_tab_moves: false,
};

pub const SAFARI: Dialect = Dialect {
    active_index: "index of current tab of w",
    title: "name",
    select_tab: "set current tab of w to t",
    select_nth: "set current tab of w to tab tabIndex of w",
    new_window: "make new document",
    new_tab: "set current tab to (make new tab)",
    current_tab: "current tab",
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

/// One row of [`Dialect::list_script`]'s output.
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
/// URL, and lines without a valid slot, are dropped.
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
            let title = parts.next().unwrap_or("").trim();
            if title.is_empty() && url.is_empty() {
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
    /// Every tab of every window, numbered by the loops rather than read back
    /// through `index of`: one fewer Apple Event per window and per tab.
    pub fn list_script(&self, app: &str) -> String {
        format!(
            r#"
set out to ""
-- Inside the tell block `tab` names the browser's tab class, which coerces to
-- the word "tab": take the separator from outside it.
set sep to character id 9
tell application {app}
  set windowIndex to 0
  repeat with w in windows
    set windowIndex to windowIndex + 1
    set activeIndex to 0
    try
      set activeIndex to {active_index}
    end try
    set tabIndex to 0
    repeat with t in tabs of w
      set tabIndex to tabIndex + 1
      try
        set isCurrent to "0"
        if windowIndex is 1 and tabIndex is activeIndex then set isCurrent to "1"
        set out to out & (windowIndex as text) & sep & (tabIndex as text) & sep & isCurrent & sep & (URL of t as text) & sep & ({title} of t as text) & linefeed
      end try
    end repeat
  end repeat
end tell
return out
"#,
            app = applescript_quote(app),
            active_index = self.active_index,
            title = self.title,
        )
    }

    /// Activate the browser and select the tab whose URL (or title) equals
    /// `target`, raising its window: the tab at `slot` when it still matches
    /// (so a pick lands on the listed one of several identical tabs), else
    /// the first match. Prints `ok` or `missing`.
    pub fn select_script(&self, app: &str, target: &TabTarget, slot: Option<TabSlot>) -> String {
        let (property, value) = match target {
            TabTarget::Url(url) => ("URL", url),
            TabTarget::Title(title) => (self.title, title),
        };
        let select = format!(
            r#"if ({property} of t as text) is targetValue then
          {select_tab}
          set index of w to 1
          return "ok"
        end if"#,
            select_tab = self.select_tab,
        );
        let listed = slot.map_or_else(String::new, |slot| {
            format!(
                r#"
  try
    set w to window {window}
    set t to tab {tab} of w
    {select}
  end try"#,
                window = slot.window,
                tab = slot.tab,
            )
        });
        format!(
            r#"
tell application {app}
  activate
  set targetValue to {value}{listed}
  repeat with w in windows
    repeat with t in tabs of w
      try
        {select}
      end try
    end repeat
  end repeat
end tell
return "missing"
"#,
            app = applescript_quote(app),
            value = applescript_quote(value),
        )
    }

    /// `tab_select` walks windows front to back so `tab_select 5` can land on
    /// the second window's first tab if window 1 only had four tabs.
    pub fn tab_select_script(&self, app: &str, index: i64) -> String {
        format!(
            r#"
tell application {app}
  activate
  set tabIndex to {index}
  repeat with w in windows
    if (count of tabs of w) >= tabIndex then
      {select_nth}
      set index of w to 1
      return "ok"
    end if
    set tabIndex to tabIndex - (count of tabs of w)
  end repeat
end tell
return "missing"
"#,
            app = applescript_quote(app),
            select_nth = self.select_nth,
        )
    }

    pub fn tab_new_script(&self, app: &str) -> String {
        format!(
            r#"
tell application {app}
  activate
  if (count of windows) is 0 then
    {new_window}
  else
    tell front window to {new_tab}
  end if
  return "ok"
end tell
"#,
            app = applescript_quote(app),
            new_window = self.new_window,
            new_tab = self.new_tab,
        )
    }

    /// Move the front window's current tab one place toward the end
    /// (`forward`) or the start, by moving its neighbour across it: the moved
    /// tab keeps its page and stays current. `None` when this dialect cannot
    /// reorder tabs by script. At either end the move is a confirmed no-op.
    pub fn tab_move_script(&self, app: &str, forward: bool) -> Option<String> {
        if !self.scripts_tab_moves {
            return None;
        }
        let swap = if forward {
            "if i < n then move tab (i + 1) of w to before tab i of w"
        } else {
            "if i > 1 then move tab (i - 1) of w to after tab i of w"
        };
        Some(format!(
            r#"
tell application {app}
  if (count of windows) is 0 then return "missing"
  set w to front window
  set i to {active_index}
  set n to count of tabs of w
  {swap}
  return "ok"
end tell
"#,
            app = applescript_quote(app),
            active_index = self.active_index,
        ))
    }

    /// Closing the last tab collapses to closing the window — same as ⌘W
    /// natively. The gesture stays "close this thing in this context".
    pub fn tab_close_script(&self, app: &str) -> String {
        format!(
            r#"
tell application {app}
  if (count of windows) is 0 then return "missing"
  tell front window to close {current_tab}
  return "ok"
end tell
"#,
            app = applescript_quote(app),
            current_tab = self.current_tab,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safari_moves_tabs_by_script_and_chromium_leaves_it_to_the_chord() {
        let forward = SAFARI.tab_move_script("Safari", true).unwrap();
        assert!(forward.contains("set i to index of current tab of w"));
        assert!(forward.contains("if i < n then move tab (i + 1) of w to before tab i of w"));
        let backward = SAFARI.tab_move_script("Safari", false).unwrap();
        assert!(backward.contains("if i > 1 then move tab (i - 1) of w to after tab i of w"));
        assert!(CHROMIUM.tab_move_script("Google Chrome", true).is_none());
        assert!(CHROMIUM.tab_move_script("Google Chrome", false).is_none());
    }

    #[test]
    fn select_scripts_match_by_url_or_by_the_dialect_title_property() {
        let by_url = CHROMIUM.select_script(
            "Google Chrome",
            &TabTarget::Url("https://example.com/\"q\"".into()),
            None,
        );
        assert!(by_url.contains(r#"set targetValue to "https://example.com/\"q\"""#));
        assert!(by_url.contains("if (URL of t as text) is targetValue then"));
        let by_title = SAFARI.select_script("Safari", &TabTarget::Title("Inbox".into()), None);
        assert!(by_title.contains("if (name of t as text) is targetValue then"));
        assert!(by_title.contains("set current tab of w to t"));
        let chromium_title = CHROMIUM.select_script("Arc", &TabTarget::Title("Inbox".into()), None);
        assert!(chromium_title.contains("if (title of t as text) is targetValue then"));
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

    #[test]
    fn the_list_script_numbers_every_tab_by_window_and_position() {
        let script = SAFARI.list_script("Safari");
        // The separator is bound before `tell`, where `tab` is still the
        // tab character and not the browser's tab class.
        let sep = script.find("set sep to character id 9").unwrap();
        assert!(sep < script.find("tell application").unwrap());
        assert!(script.contains("set windowIndex to windowIndex + 1"));
        assert!(script.contains("set tabIndex to tabIndex + 1"));
        assert!(script.contains("if windowIndex is 1 and tabIndex is activeIndex"));
        assert!(script.contains(
            "(windowIndex as text) & sep & (tabIndex as text) & sep & isCurrent & sep & (URL of t as text) & sep & (name of t as text) & linefeed"
        ));
    }

    #[test]
    fn a_select_script_tries_the_listed_slot_before_the_first_match() {
        let target = TabTarget::Url("https://mail.example/".into());
        let slotted = CHROMIUM.select_script(
            "Google Chrome",
            &target,
            Some(TabSlot { window: 2, tab: 3 }),
        );
        let slot = slotted.find("set w to window 2").unwrap();
        let scan = slotted.find("repeat with w in windows").unwrap();
        assert!(slot < scan);
        assert!(slotted.contains("set t to tab 3 of w"));
        let unslotted = CHROMIUM.select_script("Google Chrome", &target, None);
        assert!(!unslotted.contains("set w to window"));
        assert!(unslotted.contains("repeat with w in windows"));
    }
}
