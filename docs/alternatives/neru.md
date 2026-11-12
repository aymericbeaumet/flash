# Flash and Neru

[Neru](https://github.com/y3owk1n/neru) describes itself as "Hints, grids and
vim keys for your whole desktop. Free, open source, one binary, one TOML
file." It is MIT-licensed Go, stable on macOS 14+, with Linux and Windows
builds in daily beta, and it ships roughly weekly (v1.58.0 on 2026-10-12,
about 810 stars). It is the closest open-source relative of Flash and the
better choice for several people.

| | Neru | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 14+ stable; Linux (X11, Wayland) and Windows 10+ beta | macOS 13+ only |
| Permissions | Accessibility; Screen Recording for the `vision`, `contour` and `segment` strategies | Accessibility; Automation per browser when tabs are listed; Screen Recording only for `:screenshot screen`, which runs Apple's `screencapture` |
| Hints from | `axtree` (default), `vision` (on-device OCR), `contour`, `segment` | Accessibility tree; tmux control mode for terminal panes |
| Pointer modes | Hints, grid, recursive grid, bisect, scroll, monitor select, user-defined modes | Hints, keyboard-shaped grid, bisect, pointer mode, monitor select, warp, saved positions, scroll target; user-defined layers |
| Beyond pointing | Hooks, `neru watch` event stream | Persistent NORMAL mode with per-app actions, flashlight search, status bar, widgets, popups, window placement, plugins; `flash events watch` event stream |
| Configuration | One TOML; CLI; IPC socket with JSON schemas and a Go client | One TOML, live reload, `flash config check`; `flash <topic> <action>` over a versioned IPC socket with JSON Schemas; no client library beyond the CLI |
| Maintenance | Weekly releases since 2025-11; 11 open issues | 1.0.0 in October 2026; nightly from `main`; one maintainer |

## Where Neru is stronger

- **It works where Accessibility does not.** OCR, contour and segmentation
  label canvases, games, remote desktops and Electron apps with thin trees.
  Flash offers only the grid there, by design.
- **Three platforms.** The same config follows you to Linux and Windows,
  with the caveat that those builds are beta.
- **A client library.** Both have a versioned socket protocol with JSON
  schemas and an event stream; Neru also ships a Go client. Flash's client is
  its CLI: `flash --json` replies and `flash events watch` NDJSON from skhd,
  Hammerspoon or a shell script, and the [protocol](../ipc-protocol.md) for
  programs that speak the socket themselves.
- **A longer public track record** of weekly releases and user reports.

## Where Flash is stronger

- **Accessibility only.** No Screen Recording prompt ever, and nothing in
  the process reads pixels. The [privacy page](../privacy.md) lists every
  prompt and file.
- **A persistent modal layer.** NORMAL stays on across apps; `]t` resolves
  to the next tab in a browser, Finder or tmux because actions come from
  plugin bindings, not raw chords. Neru's modes are transient layers; Flash
  has those too, as [layers](../layers.md) that take counts and
  sequences and return to the mode they were entered from.
- **Terminal hints** on tmux panes, URLs, file paths and status-bar tabs,
  kept warm from tmux's control mode.
- **Everything after the click.** flashlight (apps, tabs, emoji,
  math, currency), the status bar, widgets and PTY popups share one plugin
  set. Neru deliberately stops at pointing.
- **Window placement** and directional focus are built in; Neru moved that
  into a separate tool.
- **Sandboxed plugins** with declared capabilities and a Rust SDK.
- **Lower macOS floor** (13 against Neru's 14).

## Flash features you might like

- `gm` is monitor select: each display shows its number, and the pointer and
  keyboard focus go to the one you type. `2gm` goes to display 2 without
  labels, `--direction=next` steps without labels, and `--to=last` lands
  where the pointer last left that display
  ([pick a display](../mouse-grid.md#pick-a-display)).
- `[app] hide_from_capture` keeps every Flash window, the bar, popups and
  widgets included, out of the captures that still honour the request, as
  `hide_overlay_in_screen_share` does for Neru's overlays. On macOS 15 and
  later most recording and call apps ignore it in both tools
  ([screen capture](../privacy.md#screen-capture)).
- `mouse target --search` types visible text to pick a target, next to the
  labels you already know from `/` in Neru.
- `--words`, `--path`, `--sticky` and `--multi` for text selection and
  batch clicks ([commands](../commands.md)).
- `:help` opens a browser page that checks permissions, mappings and plugins
  for this Mac ([browser help](../help.md)).
- Latency is logged per activation, with a benchmark script
  ([performance](../performance.md)).

## Moving from Neru

| Neru | Flash |
| --- | --- |
| Hints (`Primary+Shift+Space`) | `["flash", "mouse", "target"]` |
| Grid, recursive grid | `["flash", "mouse", "grid"]`; each key zooms into its cell |
| Bisect | `["flash", "mouse", "grid", "--bisect"]` |
| Scroll mode | NORMAL's `ctrl+e`/`ctrl+y`, and in a page `ctrl+d`/`ctrl+u` and `gg`/`G` (in a list or a text field they move the selection or the caret); `scroll target` picks the area |
| Monitor select (`monitor_select`) | NORMAL `gm`, or `["flash", "mouse", "screens", "--focus"]`; Flash numbers displays left to right, then top to bottom |
| `neru action move_monitor [--previous]` | `["flash", "mouse", "screens", "--direction=next"]` (or `previous`) |
| `hide_overlay_in_screen_share = true` | `[app] hide_from_capture = true`, a config key rather than a runtime toggle |
| `/` filter in hints | `["flash", "mouse", "target", "--search"]` |
| `capture_scope = "screen"` | `["flash", "mouse", "target", "--scope=screen"]` |
| Menu bar, Dock hints | `mouse menubar`, `mouse dock`, `mouse notifications` |
| `[[hints.app_configs]]` per bundle | `[mode.apps."<bundle id>".normal.mappings]` |
| A custom mode (a name, an indicator, a key table) | A `[mode.layers.<name>]` table with a `label`, entered by `["flash", "mode", "layer", "--name=<name>"]`; Escape leaves it ([layers](../layers.md)) |
| `neru config reload` | Saving the file; `flash config check` validates it |
| `neru watch`, hooks | `flash events watch` (`--name=<glob,...>`, NDJSON); `[monitors.<name>]` with `event` and `run` for hooks |
| OCR strategies | Nothing. Use the grid. |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; layers need them
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"cmd+shift+space" = ["flash", "mouse", "target"]
"cmd+shift+alt+space" = ["flash", "mouse", "grid"]
"cmd+shift+c" = ["flash", "mouse", "grid", "--bisect"]
"cmd+shift+w" = ["flash", "mode", "layer", "--name=window"]

[mode.apps."com.apple.Safari".all.mappings]
"cmd+shift+f" = ["flash", "mouse", "target", "--search"]

# A Neru custom mode that drives yabai, as a layer
[mode.layers.window]
label = "WINDOW"

[mode.layers.window.mappings]
"h" = ["yabai", "-m", "window", "--focus", "west"]
"l" = ["yabai", "-m", "window", "--focus", "east"]
```

Running both is possible but pointless: both take a hotkey and draw an
overlay. Pick one for pointing; Flash can still provide the bar and widgets.

*Checked 2026-10-14 against the Neru
[README](https://github.com/y3owk1n/neru),
[getting started](https://github.com/y3owk1n/neru/blob/main/docs/guide/getting-started.md)
and [configuration](https://github.com/y3owk1n/neru/blob/main/docs/reference/configuration.md);
monitor select and screen-share hiding on 2026-10-23 against its
[configuration](https://github.com/y3owk1n/neru/blob/main/docs/reference/configuration.md#monitor_select)
and [CLI](https://github.com/y3owk1n/neru/blob/main/docs/reference/cli.md) reference.*
