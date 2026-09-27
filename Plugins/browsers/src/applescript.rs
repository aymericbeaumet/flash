//! Tab scripting for the browsers with an AppleScript tab dictionary:
//! Chromium-family browsers and Safari. The two dialects differ only in the
//! phrases below; every script skeleton is shared.

use flash_plugin::applescript_quote;

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

/// One row of [`Dialect::list_script`]'s output.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListedTab {
    pub title: String,
    pub url: String,
    /// The front window's current tab.
    pub current: bool,
}

/// Parse `title<TAB>url<TAB>current` lines. Rows with neither a title nor a
/// URL are dropped, and identical (title, URL) rows collapse to the first.
pub fn parse_tab_list(stdout: &str) -> Vec<ListedTab> {
    let mut seen = std::collections::HashSet::new();
    let mut tabs = Vec::new();
    for line in stdout.lines() {
        let mut parts = line.splitn(3, '\t');
        let title = parts.next().unwrap_or("").trim();
        let url = parts.next().unwrap_or("").trim();
        let current = parts.next().is_some_and(|value| value.trim() == "1");
        if (title.is_empty() && url.is_empty()) || !seen.insert((title, url)) {
            continue;
        }
        tabs.push(ListedTab {
            title: title.to_string(),
            url: url.to_string(),
            current,
        });
    }
    tabs
}

impl Dialect {
    pub fn list_script(&self, app: &str) -> String {
        format!(
            r#"
set out to ""
tell application {app}
  repeat with w in windows
    set activeIndex to 0
    try
      set activeIndex to {active_index}
    end try
    repeat with t in tabs of w
      try
        set isCurrent to "0"
        try
          if ((index of w as integer) is 1) and ((index of t as integer) is activeIndex) then set isCurrent to "1"
        end try
        set out to out & ({title} of t as text) & tab & (URL of t as text) & tab & isCurrent & linefeed
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

    /// Activate the browser and select the first tab whose URL (or title)
    /// equals `target`, raising its window. Prints `ok` or `missing`.
    pub fn select_script(&self, app: &str, target: &TabTarget) -> String {
        let (property, value) = match target {
            TabTarget::Url(url) => ("URL", url),
            TabTarget::Title(title) => (self.title, title),
        };
        format!(
            r#"
tell application {app}
  activate
  set targetValue to {value}
  repeat with w in windows
    repeat with t in tabs of w
      try
        if ({property} of t as text) is targetValue then
          {select_tab}
          set index of w to 1
          return "ok"
        end if
      end try
    end repeat
  end repeat
end tell
return "missing"
"#,
            app = applescript_quote(app),
            value = applescript_quote(value),
            select_tab = self.select_tab,
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
        );
        assert!(by_url.contains(r#"set targetValue to "https://example.com/\"q\"""#));
        assert!(by_url.contains("if (URL of t as text) is targetValue then"));
        let by_title = SAFARI.select_script("Safari", &TabTarget::Title("Inbox".into()));
        assert!(by_title.contains("if (name of t as text) is targetValue then"));
        assert!(by_title.contains("set current tab of w to t"));
        let chromium_title = CHROMIUM.select_script("Arc", &TabTarget::Title("Inbox".into()));
        assert!(chromium_title.contains("if (title of t as text) is targetValue then"));
    }

    #[test]
    fn tab_lists_drop_blank_rows_and_collapse_duplicates() {
        let tabs = parse_tab_list(
            "Inbox\thttps://mail.example/\t1\n\
             \t\t0\n\
             Inbox\thttps://mail.example/\t0\n\
             \thttps://blank.example/\t0\n\
             Docs\thttps://docs.example/\n",
        );
        assert_eq!(
            tabs,
            [
                ListedTab {
                    title: "Inbox".into(),
                    url: "https://mail.example/".into(),
                    current: true,
                },
                ListedTab {
                    title: String::new(),
                    url: "https://blank.example/".into(),
                    current: false,
                },
                ListedTab {
                    title: "Docs".into(),
                    url: "https://docs.example/".into(),
                    current: false,
                },
            ]
        );
    }
}
