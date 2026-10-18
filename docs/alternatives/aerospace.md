# Flash and AeroSpace

[AeroSpace](https://github.com/nikitabobko/AeroSpace) "is an i3-like tiling
window manager for macOS": tree-based tiling, its own emulation of virtual
workspaces, i3-style binding modes, a TOML config and a CLI. It is MIT Swift
for macOS 13+, about 23,000 stars, in public beta (v0.21.3 in July 2026),
needs no SIP change, and is not notarized. Flash does not tile; the two are
complementary, and the overlap is only window placement and keyboard modes.

| | AeroSpace | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 13+ | macOS 14+ |
| Permissions | Accessibility; one private API (`_AXUIElementGetWindow`) | Accessibility; no private APIs |
| Windows | Automatic tiling, tiles and accordion layouts, workspaces, multi-monitor pool | Named positions, proportional frames, placement rules by app and title, directional focus, minimize, native full screen |
| Modes | i3 binding modes in `aerospace.toml` | NORMAL, INSERT, COMMAND, TERMINAL for all input, with per-app actions |
| Hints, bar | None; `exec-on-workspace-change` for bars | Hints in every app, status bar, widgets, popups |
| Configuration | TOML, auto-reload option, CLI | TOML, live reload, CLI |
| Maintenance | Beta, releases every few weeks | 1.0.0, October 2026 |

## Where AeroSpace is stronger

- **It is a window manager.** Automatic tiling, workspaces that survive
  monitor changes, and an i3 vocabulary; Flash only moves the focused
  window where you tell it.
- **Lower macOS floor.**
- **A large user base and a documented stability policy** (no SIP, one
  private API, no ricing).

## Where Flash is stronger

- **Everything that is not tiling**: hints, modes, search, bar, widgets,
  popups, plugins.
- **Public APIs only** and a notarization path.
- **Placement rules without a tiling model**, for people who want a few
  windows pinned and the rest left alone.

## Flash features you might like

- `window_focus --direction=left|right|up|down` and `--direction=next|
  previous|behind` for focus without tiling ([windows](../windows.md)).
- `window_move --position=lefthalf` and proportional frames as quick
  manual layouts.
- `mouse_screens` to jump the pointer to a display.
- A bar segment showing `#{flash.active_app}`, next to an AeroSpace
  workspace source.

## Using both

Keep AeroSpace for tiling and workspaces. Give Flash the hint, mode and bar
keys, and leave AeroSpace's `alt`-based bindings alone. A shell source can
show the focused workspace in Flash's bar:

```toml
[statusbar.sources.workspace]
command = ["aerospace", "list-workspaces", "--focused"]
```

Flash's placement rules and AeroSpace's tiling will fight over the same
window; use one or the other per app.

*Checked 2026-10-14 against the AeroSpace
[README](https://github.com/nikitabobko/AeroSpace) and
[guide](https://nikitabobko.github.io/AeroSpace/guide).*
