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
| Platforms | macOS 14+ stable; Linux (X11, Wayland) and Windows 10+ beta | macOS 14+ only |
| Permissions | Accessibility; Screen Recording for the `vision`, `contour` and `segment` strategies | Accessibility; Automation per browser when tabs are listed; Screen Recording only for `:screenshot`, which runs Apple's `screencapture` |
| Hints from | `axtree` (default), `vision` (on-device OCR), `contour`, `segment` | Accessibility tree; tmux control mode for terminal panes; a per-app enhancer for VS Code |
| Pointer modes | Hints, grid, recursive grid, bisect, scroll, monitor select, user-defined modes | Hints, keyboard-shaped grid, bisect, pointer mode, screens, warp, saved positions, scroll target |
| Beyond pointing | Hooks, `neru watch` event stream | Persistent NORMAL mode with per-app actions, flashlight search, status bar, widgets, popups, window placement, plugins |
| Configuration | One TOML; CLI; IPC socket with JSON schemas and a Go client | One TOML, live reload, `flash config_check`; `flash <verb>` over an AppleEvent; no socket |
| Maintenance | Weekly releases since 2025-11; 11 open issues | 1.0.0 in October 2026; nightly from `main`; one maintainer |

## Where Neru is stronger

- **It works where Accessibility does not.** OCR, contour and segmentation
  label canvases, games, remote desktops and Electron apps with thin trees.
  Flash offers only the grid there, by design.
- **Three platforms.** The same config follows you to Linux and Windows,
  with the caveat that those builds are beta.
- **A real IPC surface.** A versioned socket protocol, JSON schemas, a Go
  client and an event stream make it easy to build on from skhd,
  Hammerspoon or a shell script. Flash's CLI is an AppleEvent with a JSON
  reply; there is no socket and no event stream outside the browser help.
- **Custom modes are first class.** A mode is a name, an indicator and a key
  table, for example a window layer that calls `yabai`.
- **Monitor select and screen-share hiding** ship as modes and options.
- **A longer public track record** of weekly releases and user reports.

## Where Flash is stronger

- **Accessibility only.** No Screen Recording prompt ever, and nothing in
  the process reads pixels. The [privacy page](../privacy.md) lists every
  prompt and file.
- **A persistent modal layer.** NORMAL stays on across apps; `]t` resolves
  to the next tab in a browser, Finder or tmux because actions come from
  plugin bindings, not raw chords. Neru's modes are transient layers.
- **Terminal hints** on tmux panes, URLs, file paths and status-bar tabs,
  kept warm from tmux's control mode.
- **Everything after the click.** flashlight (apps, tabs, windows, emoji,
  math, currency), the status bar, widgets and PTY popups share one plugin
  set. Neru deliberately stops at pointing.
- **Window placement** and directional focus are built in; Neru moved that
  into a separate tool.
- **Sandboxed plugins** with declared capabilities and a Rust SDK.

## Flash features you might like

- `mouse_target --search` types visible text to pick a target, next to the
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
| Hints (`Primary+Shift+Space`) | `["flash", "mouse_target"]` |
| Grid, recursive grid | `["flash", "mouse_grid"]`; each key zooms into its cell |
| Bisect | `["flash", "mouse_grid", "--bisect"]` |
| Scroll mode | NORMAL's `ctrl+d`/`ctrl+u`, `ctrl+e`/`ctrl+y`, `gg`/`G`; `scroll_target` picks the area |
| Monitor select | `["flash", "mouse_screens"]` |
| `/` filter in hints | `["flash", "mouse_target", "--search"]` |
| `capture_scope = "screen"` | `["flash", "mouse_target", "--scope=screen"]` |
| Menu bar, Dock hints | `mouse_menubar`, `mouse_dock`, `mouse_notifications` |
| `[[hints.app_configs]]` per bundle | `[mode.apps."<bundle id>".normal.mappings]` |
| `neru config reload` | Saving the file; `flash config_check` validates it |
| `neru watch`, hooks | `flash status --json`; no event stream |
| OCR strategies | Nothing. Use the grid. |

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]
"cmd+shift+alt+space" = ["flash", "mouse_grid"]
"cmd+shift+c" = ["flash", "mouse_grid", "--bisect"]

[mode.apps."com.apple.Safari".all.mappings]
"cmd+shift+f" = ["flash", "mouse_target", "--search"]
```

Running both is possible but pointless: both take a hotkey and draw an
overlay. Pick one for pointing; Flash can still provide the bar and widgets.

*Checked 2026-10-14 against the Neru
[README](https://github.com/y3owk1n/neru),
[getting started](https://github.com/y3owk1n/neru/blob/main/docs/guide/getting-started.md)
and [configuration](https://github.com/y3owk1n/neru/blob/main/docs/reference/configuration.md).*
