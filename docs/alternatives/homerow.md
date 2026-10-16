# Flash and Homerow

[Homerow](https://www.homerow.app) is "Keyboard shortcuts for your entire
Mac": Accessibility-based labels and a scroll mode, sold for a one-time
$49.99 covering all your personal Macs, with a free trial that reminds you
every 50 activations. It began as the commercial successor of Vimac by Dexter
Leng and now belongs to Neil Chudleigh. Version 1.5.3 shipped in March 2026;
updates are irregular (1.4.0 in February 2025, 1.4.1 in October 2025).

| | Homerow | Flash |
| --- | --- | --- |
| License, price | Closed; $49.99 one-time | MIT, free |
| Platforms | macOS 13+ | macOS 14+ |
| Permissions | Accessibility | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot` |
| Hints from | Accessibility tree | Accessibility tree; tmux panes; VS Code enhancer |
| Pointer modes | Labels, search and labels together, labels-only, scroll mode, click chain, Mission Control | Hints, search, grid, bisect, pointer mode, drag, select, words, path, sticky |
| Beyond pointing | Caps Lock to Hyper remap, sound effects | NORMAL mode, flashlight, status bar, widgets, popups, window placement, plugins |
| Configuration | Settings window, "Ignored Apps" | One TOML file, live reload, CLI |
| Maintenance | 1.5.3, March 2026; 156 open issues on the tracker | 1.0.0, October 2026; one maintainer |

## Where Homerow is stronger

- **Polish.** A settings window, a tutor that shows which properties of an
  element are searchable, sound effects, and a product that has been in
  daily use by many people for years.
- **Search and labels in one view** with a fast/exhaustive switch, tuned
  over a long time on the apps people actually use.
- **Click chains** (several clicks in one activation) and **Mission Control**
  support arrived in recent releases.
- **Lower macOS floor** (13 against Flash's 14).
- **Nothing to configure.** Install, grant Accessibility, done.

## Where Flash is stronger

- **Free and open.** No trial reminders, no licence, and the source is there
  when an app misbehaves.
- **Configured in a file.** Every binding is in `flash.toml`, lives in your
  dotfiles, reloads on save and is validated by `flash config_check`. Homerow
  has no file, CLI or scripting surface.
- **A persistent NORMAL mode** instead of a hold-to-activate hint mode, with
  actions that resolve per app.
- **Grid and pointer modes** for apps with no Accessibility tree. Homerow
  has no grid, so a canvas app is a dead end.
- **Terminal, bar, widgets, popups, search, plugins.** Homerow stops at the
  click.
- **Documented privacy.** Homerow's tracker has an open request to opt out of
  analytics calls (#98). Flash has no analytics, and its
  [privacy page](../privacy.md) lists every network destination.

## Flash features you might like

- `mouse_target --search` for the search-first feel, `mouse_target` for
  labels only, in the same hotkey table.
- `mouse_target --multi` and `--sticky` are the click chain.
- `scroll_target` chooses the scroll area, then NORMAL's `ctrl+d`/`ctrl+u`
  scroll it ([normal mode](../normal-mode.md)).
- `mouse_dock`, `mouse_menubar` and `mouse_notifications` label surfaces
  outside the focused window.

## Moving from Homerow

| Homerow | Flash |
| --- | --- |
| Hint shortcut | `["flash", "mouse_target"]` on the key of your choice |
| Labels only | `mouse_target` (labels are the default) |
| Search | `["flash", "mouse_target", "--search"]` |
| Scroll mode | NORMAL mode scroll keys, `scroll_target` to pick the area |
| Shift-Return right-click | In NORMAL, `cf` right-clicks a hint; from a hotkey, `mouse_bigram --secondary` |
| Cmd-click, double-click | `df` double-clicks in NORMAL; modifiers are held as you type the label |
| Ignored Apps | `[mode.apps."<bundle id>"]` tables, or leave the app unmapped |
| Caps Lock to Hyper | Keep Karabiner-Elements; Flash does not remap hardware keys |
| Mission Control hints | Not available |

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]
"cmd+shift+alt+space" = ["flash", "mouse_target", "--search"]
```

Both apps take the Accessibility grant and a hotkey; running them together
only costs a second overlay. Keep Homerow for its tutor while you learn what
each app exposes, if you like.

*Checked 2026-10-14 against
[homerow.app](https://www.homerow.app), its
[changelog](https://www.homerow.app/changelog) and the
[issue tracker](https://github.com/nchudleigh/homerow).*
