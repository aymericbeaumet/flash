# Flash and Scoot

[Scoot](https://github.com/mjrusso/scoot) is "a tiny utility app that
provides fast, keyboard-driven control over the mouse pointer": element
mode over the Accessibility tree, a grid over all screens, and a freestyle
mode. It is BSD-3 Swift by Michael Russo, about 530 stars, with v1.3 in
March 2026 after v1.2 in December 2022. It asks for Accessibility only and
makes no network requests.

| | Scoot | Flash |
| --- | --- | --- |
| License, price | BSD-3, free | MIT, free |
| Platforms | macOS (README still names 11 and 12) | macOS 14+ |
| Permissions | Accessibility | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot` |
| Hints from | Accessibility tree of the focused window | Accessibility tree; tmux panes; VS Code enhancer |
| Pointer modes | Element, grid over all screens, freestyle; left/right/middle/double click, drag, scroll; System, Emacs and vi key sets | Hints, search, keyboard-shaped grid, bisect, pointer mode, screens, drag, select, words, path, sticky |
| Beyond pointing | Menu bar icon | NORMAL mode, flashlight, status bar, widgets, popups, window placement, plugins |
| Configuration | Preferences window | One TOML file, live reload, CLI |
| Maintenance | v1.3, March 2026; slow | 1.0.0, October 2026 |

## Where Scoot is stronger

- **Tiny.** One small app with one job, and a preferences window for keys,
  fonts, colours and opacity.
- **Emacs key set** for cursor movement, next to vi and system sets.
- **Older macOS** versions still run it.
- **A single grid across every connected screen** in one view.

## Where Flash is stronger

- **Search, bisect, words and paths** on top of labels and grid.
- **Per-app configuration** and a persistent NORMAL mode.
- **Context menus.** Scoot cannot take the cursor while a context menu is
  open (its README says so); Flash labels menus and menu-bar extras.
- **Terminal hints, flashlight, bar, widgets, popups, plugins.**
- **Scoot turns on `AXEnhancedUserInterface` for every app** to repair thin
  trees (issue #11), which can change how other apps behave; Flash scopes
  enhancements per app through its VS Code enhancer.

## Flash features you might like

- `mouse_pointer` is the freestyle mode: layout `hjkl`, `m` `,` `.` click,
  `v` drag ([commands](../commands.md)).
- `mouse_grid --bisect` halves the screen instead of a fixed grid.
- `mouse_warp --area=window --edge=center` jumps to a window or screen edge.
- `mouse_position --action=save` remembers positions and labels them later.

## Moving from Scoot

| Scoot | Flash |
| --- | --- |
| Element mode | `["flash", "mouse_target"]` |
| Grid mode | `["flash", "mouse_grid"]` |
| Freestyle mode | `["flash", "mouse_pointer"]` |
| Drag | `mouse_target --drag`, `mouse_grid --drag` |
| Right, middle click | `cf` in NORMAL for right-click; `mouse_button --state=toggle --middle` |
| Scroll | NORMAL mode scroll keys |
| vi / Emacs key sets | NORMAL mode keys are vi-like and remappable; no Emacs preset |

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]
"cmd+shift+alt+space" = ["flash", "mouse_grid"]
"cmd+shift+ctrl+space" = ["flash", "mouse_pointer"]
```

*Checked 2026-10-14 against the Scoot
[README](https://github.com/mjrusso/scoot) and release list.*
