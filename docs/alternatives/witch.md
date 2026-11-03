# Flash and Witch

[Witch](https://manytricks.com/witch/) from Many Tricks promises "⌘-Tab
Everything": switchers for apps, for windows and for tabs, as many as you
care to define, each with its own hot key, sort order and layout, on screen,
in the menu bar or both. Witch is closed source, $14 for a licence that is
valid forever with at least a year of updates ($8 to upgrade), with a free
trial. Version 4.7 shipped on 2 December 2025 with a rounder panel for
macOS 26 and better tab support in Chrome and Edge; it runs on macOS 10.13
High Sierra or newer.

Flash's [window switcher](../windows.md#switch-to-any-window) is one list,
not a switcher builder: every window of every app, most recently used first,
with a hint label on each row. Apps and tabs are searched in the flashlight
instead.

| | Witch | Flash |
| --- | --- | --- |
| License, price | Closed; $14 once, $8 upgrade, free trial | MIT, free |
| Platforms | macOS 10.13+ | macOS 13+ |
| Permissions | Accessibility (for its `witchdaemon` helper); Screen Recording only for its screenshot key | Accessibility; Automation per browser to list its tabs |
| Switchers | Apps, windows and tabs; several at once, each with its own hot key, sort order, orientation and tab handling | One window list (`window switch`); running apps (`app switch`) and tabs (`@tabs`) in the flashlight |
| Picking | Hold Option, press Tab; arrows or `K`/`J`; `0`–`9` for the first ten windows; `S` to search | One hint label per row; Tab and the arrows, then Return; `@windows` to search by title |
| In-panel actions | Hide, minimize, close, quit, zoom, reveal in Finder, preview, reopen | None: switch first, then `window close`, `window minimize`, `app quit` |
| Placement | On screen, in the menu bar, or both | On screen, on the display you are looking at |
| Configuration | A System Settings pane with ignore lists | One TOML file, live reload, `flash config check` |
| Maintenance | 4.7, December 2025 | 1.1.0, October 2026 |

## Where Witch is stronger

- **Switchers you design.** One for this app's windows sorted by name,
  another for every tab across apps, a vertical one on Control-Tab, one in
  the menu bar: Witch lets you build each and give it a key. Flash has one
  window list with a fixed order (most recently used) and no filters by app,
  Space or display.
- **Hold-to-cycle.** Hold Option, tap Tab, let go. Flash's list stays up
  until you pick a row; it does not switch on a modifier release.
- **Acting from the panel.** `H` hides an app, `M` minimizes, `W` closes,
  `Q` quits, `Z` zooms, `F` shows the file in Finder, `P` previews the
  window, all without leaving the switcher. Flash switches first and acts
  after, and has no command to hide an app.
- **Tabs as rows.** Witch lists the standard tabs of any app that exposes
  them next to their windows, and drills into them from its menu-bar
  switcher. Flash lists browser tabs (Safari, Chrome, Firefox) and tmux
  windows in the flashlight, not in the window list.
- **Spring-loading** opens an app's windows or tabs after a pause on it.
- **Windows on other Spaces from the start.** Flash lists one once it has
  seen it since it started: you focused it, or its Space was active.
- **Runs back to macOS 10.13.**

## Where Flash is stronger

- **A label per window.** Every row has a hint label, so any window in the
  list is one or two keystrokes away, where Witch's digits stop at the
  tenth and the arrows walk the rest.
- **Free and open source.** The list is read through Accessibility on a
  background queue as windows open, close and get retitled, kept in memory,
  and drawn within a frame of the key.
- **Switching is one part of a keyboard layer.** The same file holds
  directional focus (`ctrl+w h`), app marks, hints on every control, the
  flashlight and the bar, so the switcher is never the only way to a window.

## Flash features you might like

- `window last` (`ctrl+w p` in NORMAL) flips between the two most recent
  windows without opening a list, and the switcher itself opens on the
  previous window, so Return alone does the same.
- `window next` and `window previous` (`]w` and `[w`) cycle the focused
  app's windows, as a per-app Witch switcher would.
- `mode flashlight --query=@tabs` searches Safari, Chrome and Firefox tabs
  together, and `@windows` searches every window by title and app name
  ([flashlight](../flashlight.md)).
- `m{x}` saves the focused app as mark `x` and `'{x}` brings it back,
  relaunching it if it quit ([marks](../marks.md)).

## Moving from Witch

| Witch | Flash |
| --- | --- |
| Option-Tab, hold and Tab | `window switch` (`:ls`) on a key you choose; the list waits for a label or Return |
| Arrows, `K`/`J`, Page Up/Down | Tab, Shift-Tab and the arrows |
| `0`–`9` for window #0 to #9 | The row's hint label |
| `S`, search by typing | `mode flashlight --query=@windows` |
| A tab switcher | `mode flashlight --query=@tabs`; in a browser, `gt`, `gT` and `g1`–`g9` in NORMAL |
| An app switcher | `app switch` for running apps; `app previous` and `app next` (`[a`, `]a`) |
| A switcher for the front app's windows | `window next` / `window previous` (`]w` / `[w`) |
| `M`, `W`, `Q` on the selected window | Switch to it, then `window minimize`, `window close`, `app quit` |
| `H` to hide an app | Not a Flash command |
| `Z` to zoom | Switch, then `window move --position=maximized` or `window fullscreen` |
| `P` preview, spring-loading, menu-bar switcher | Not available: Flash reads no window pixels and draws no menu-bar item for this |
| Disable hot keys in some apps | `[mode.apps."<bundle id>"]` tables; a mapping set to `false` there is off in that app |

```toml
[mode.normal.mappings]
"<leader>w" = ["flash", "window", "switch"]
"<leader>/" = ["flash", "mode", "flashlight", "--query=@windows"]
"<leader>t" = ["flash", "mode", "flashlight", "--query=@tabs"]

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"cmd+ctrl+w" = ["flash", "window", "switch"]
```

## Using both

They coexist well. Flash maps no Option-Tab, Control-Tab or
Command-Backtick, so Witch keeps its hot keys, and Witch's in-panel actions
and tab drilling stay available. A common split is Witch for hold-to-cycle
and its per-app and tab switchers, Flash's labelled list for a jump straight
to a window you can see in your head. Avoid binding the same chord in both:
`flash resident doctor` lists every hotkey macOS refused Flash because
another app already holds it.

*Checked 2026-10-23 against Witch's [product page](https://manytricks.com/witch/),
[help](https://manytricks.com/witch/help/) and
[release notes](https://manytricks.com/witch/releasenotes/), and its
[Homebrew cask](https://formulae.brew.sh/cask/witch).*
