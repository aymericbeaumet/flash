# Flash and AltTab

[AltTab](https://alt-tab.app) brings "Windows alt-tab on macOS": hold a
modifier, press Tab to walk through every window of every app, release to
switch. It is free GPL-3.0 software for macOS 12 and later, about 16,000
GitHub stars, very active (361 releases since 2018), with a paid AltTab Pro
that adds search, more styles, auto-size and extra shortcuts. It shows each
window as a thumbnail, an app icon or a title, with a full-size preview of
the selected one, and lists minimized windows, hidden apps' windows and
windows on other Spaces with a badge saying where each one is.

Flash's `window switch` covers the list without the hold: every window,
ordered by when you last focused it, with a hint label on every row. You
open it (`:ls`, or any key you map) and pick a row; nothing waits for a
modifier to come up, and Flash binds no Option-Tab, so AltTab keeps it.

| | AltTab | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free; Pro paid | MIT, free |
| Platforms | macOS 12+ | macOS 13+ |
| Permissions | Accessibility; Screen Recording for thumbnails and previews | Accessibility |
| Default chord | Option-Tab, configurable | None; `:ls`, or any key you map |
| Rows | Thumbnails, app icons or titles; a full-size preview | App icon, app name, window title, a badge; no thumbnails |
| Windows listed | Every app, minimized, hidden and other Spaces | Every app, minimized, hidden and other Spaces Flash has seen |
| Picking | Hold and Tab, arrows, the mouse; search in Pro | One hint label key, or Tab and the arrows, then Return |
| Configuration | GUI preferences | TOML, live reload, `flash window switch` CLI |
| Hints, modes, bar | None | Yes |

## Where AltTab is stronger

- **Hold-to-cycle.** Hold a modifier, tap Tab, release to switch. Flash's
  list stays up until you pick a row, so a switch is a key to open it and a
  label to choose.
- **Thumbnails and a live preview.** Flash reads no screen pixels, so its rows
  are an icon and a title; telling two windows of one app apart takes a
  distinct title.
- **Windows on other Spaces from the start.** AltTab lists them the moment
  it runs; Flash lists a window on another Space once it has seen it: you
  focused it, or its Space was active, since Flash started.
- **Mouse support**, styles, multiple shortcuts with their own filters
  (this Space, this app, this screen), a blacklist and per-window actions
  from the switcher, all in a preferences window.
- **Older macOS**, back to 12.

## Where Flash is stronger

- **One key picks any window.** Every row carries a hint label from your
  hint alphabet, so the fifth window is one keystroke, not four Tabs.
- **No Screen Recording permission**, and nothing about your windows leaves
  memory: the list is held in Flash's process and never written to disk.
- **It is part of the same keyboard layer**: the switcher sits next to
  `window focus --direction`, `app previous`, marks, hints and the
  flashlight, all in one file.

## Flash features you might like

- `window focus --direction=left|right|up|down` and `ctrl+w h|j|k|l` in
  NORMAL move between windows by position ([windows](../windows.md)).
- `app previous` / `app next` (`[a` and `]a`) flip between apps;
  `mark set --letter=a` and `mark jump --letter=a` bring one back by letter.
- The flashlight (`:flashlight`, `app switch`) searches running apps, browser
  tabs and more by name.

## Moving from AltTab

| AltTab | Flash |
| --- | --- |
| Hold Option, press Tab | `:ls`, or the key you map to `window switch` |
| Shift-Tab, arrows | The same while the list is up |
| Release Option to switch | Return, or the row's hint label |
| Escape to cancel | The same, or a click |
| Click a thumbnail | Type the row's hint label |
| Search (Pro) | The flashlight: `app switch`, or `:flashlight` |
| Shortcut for this app's windows only | `window next` / `window previous` (`]w` / `[w` in NORMAL) |
| Close, minimize, hide or quit the selected window | Switch to it, then `window close`, `window minimize`, `app quit` |
| Shortcut on Command-Tab | Not available: Command-Tab stays the system's app switcher; use any other chord |

Both run side by side: Flash binds no Option-Tab, so AltTab keeps it. To
open Flash's list from a key:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>w" = ["flash", "window", "switch"]
```

*Checked 2026-10-22 against the AltTab [site](https://alt-tab.app) and
[repository](https://github.com/lwouis/alt-tab-macos).*
