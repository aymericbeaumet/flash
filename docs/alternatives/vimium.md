# Flash and Vimium

[Vimium](https://github.com/philc/vimium) is "a browser extension that
provides keyboard-based navigation and control of the web in the spirit of
the Vim editor", MIT-licensed, for Chrome, Edge and Firefox. Version 2.4.2
shipped in March 2026; it has about 27,000 stars. Flash's hints are
Vimium's idea applied to every app, and Flash's default NORMAL keys follow
Vimium's where they fit.

| | Vimium | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Where it works | Inside web pages of the browser it is installed in | Every macOS app, including browsers, through Accessibility |
| Hints from | The DOM | The Accessibility tree |
| Modes | Vim-like keys per page, insert mode, visual mode | Persistent NORMAL, INSERT, VISUAL in text fields, COMMAND, HOLD and TERMINAL across apps |
| Search | Vomnibar over URLs, bookmarks, history and tabs | flashlight over apps, tabs, tmux, emoji, plugin data, history and bookmarks by source |
| Configuration | Options page with `map` syntax | One TOML file |
| Permissions | Extension permissions (all URLs, tabs, history) | Accessibility; Automation per browser for tab lists |

## Where Vimium is stronger

- **The DOM is richer than the Accessibility tree.** Vimium can hint
  anything with a click handler, filter links by text, open in background
  tabs, and run on pages where the browser's Accessibility output is thin.
- **It is faster at what it does**: an in-page script beats an
  out-of-process Accessibility walk.
- **Visual mode, caret mode, find with regex**, bookmark and history search
  in the vomnibar.
- **No OS permissions** and nothing resident.
- **Chrome and Firefox on any OS.**

## Where Flash is stronger

- **Every app, not one.** The same `f` works in Safari, Finder, Slack, Xcode
  and a terminal. Vimium cannot run on `chrome://` pages, the Web Store,
  view-source tabs or the browser's new tab page.
- **Safari without an extension.** Flash reads Safari, Chrome and Firefox
  through AX web areas, and lists Firefox tabs without an add-on.
- **The mode persists across apps.** Switching from the browser to a
  terminal keeps NORMAL on; `]t` becomes the next tmux window.
- **Everything beyond the page**: windows, bar, widgets, popups, plugins.

## Flash features you might like

- The default NORMAL keys: `f` hints, `gg`/`G`, `ctrl+d`/`ctrl+u`, `[t`/`]t`,
  `x`/`X` close and reopen tabs, `/` opens Find
  ([normal mode](../normal-mode.md)).
- `mouse target --scope=screen` labels Picture-in-Picture players and other
  apps' windows too.
- `:flashlight @history rust` or `!fh rust` search browser history
  by bang ([flashlight](../flashlight.md)).

## Moving from Vimium

| Vimium | Flash |
| --- | --- |
| `f` / `F` link hints | `f` in NORMAL; open in a new tab by holding ⌘ while typing the label |
| `<a-f>` open several links | `alt+f`: the labels come back after each click until Escape; hold ⌘ on each label for a new tab |
| `j` / `k` scroll | Same in a page (`ctrl+e` / `ctrl+y` too); `ctrl+d` / `ctrl+u` half a page, `ctrl+f` / `ctrl+b` a page. With a text field or a list focused they move its caret or selection, and `ctrl+e` / `ctrl+y` still scroll |
| `gg` / `G` | Same |
| `J` / `K` tabs | Same, and `gt` / `gT`, `[t` / `]t`; `<<` / `>>` move the tab |
| `x` / `X` tabs | Same |
| `/` find | Same, with `n` / `N` for the matches; NORMAL stays, so press `i` to type the query |
| `i` insert mode | `i` (and `a`, `o`, their capitals) enters INSERT until `mode normal` |
| `o` / `t` vomnibar | `t` opens a new tab; `:flashlight` searches |
| `map` syntax | `[mode.normal.mappings]` in `flash.toml` |

Keep Vimium for in-page power (text-filtered hints, visual mode). Flash
swallows every key NORMAL does not map, a key set to `false` included, so
Vimium's keys reach the page in INSERT only: `i` hands the keys to the page,
and a `mode normal` chord takes them back.

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
```

*Checked 2026-10-14 against the Vimium
[README](https://github.com/philc/vimium), changelog and
[FAQ](https://github.com/philc/vimium/wiki/FAQ).*
