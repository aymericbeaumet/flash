# Flash and SketchyBar

[SketchyBar](https://github.com/FelixKratz/SketchyBar) is "A highly
customizable macOS status bar replacement" for "people that like playing
with shell scripts": items are added with `sketchybar --add` commands in a
`sketchybarrc`, fed by plugin scripts, and can subscribe to events or poll.
It is GPL-3 C, about 12,500 stars, with v2.24.1 in October 2026. It is the
reference bar on macOS, and it does more as a bar than Flash does.

| | SketchyBar | Flash's bar |
| --- | --- | --- |
| License, price | GPL-3, free | MIT, free |
| Definition | Shell commands per item; Lua (SbarLua) or C helpers for speed | One tmux-format template string with `#[...]` styles and `#{...}` values |
| Data | Scripts you write, events (`front_app_switched`, `space_change`, `volume_change`, ...) or `update_freq` polling | Bundled plugins (CPU, memory, disks, network, battery, processes, media, tmux, quotas) and named shell sources or `#()` jobs |
| Popups | Popup menus of items | Terminal popups: a real PTY running any command, hover or click |
| Widgets | Items on the bar only | Desktop widgets from the same templates |
| Per display, notch | `display=main|all`, `notch_width` and offsets | `monitor`, `#[align=notch]` |
| Permissions | Screen capture for menu-bar aliases | None beyond Flash's Accessibility |
| Integration | AeroSpace and yabai hooks, `sketchybar --trigger` | Status values from the same plugins as hints and search; mode pill |
| Maintenance | v2.24.1, October 2026; active | 1.0.0, October 2026 |

## Where SketchyBar is stronger

- **Arbitrary layout and drawing.** Backgrounds, borders, icons, graphs,
  animations, bracketing, popup menus, and anything a script can compute.
  Flash's bar is a text line with meters and sparklines.
- **Menu-bar aliases** can mirror native menu-bar extras into the bar.
- **A large ecosystem** of configurations, themes and helpers, and the
  SbarLua API for low-latency event handlers.
- **Events from tiling window managers** are first-class; many AeroSpace
  and yabai setups are built around it.

## Where Flash is stronger

- **No scripts to maintain for the common values.** CPU, memory, disk,
  network, battery and top processes come from plugins that sample on one
  scheduler and pause when the display sleeps; the tips page of SketchyBar
  itself asks users to reduce polling and compile helpers for performance.
- **Terminal popups.** Hovering a segment opens btop, newsboat or calcurse
  in a real terminal, instead of a menu of items.
- **Widgets from the same template language**, drawn on the desktop.
- **One file for bar, hints, modes and widgets**, and the bar shows the
  current mode.
- **No screen capture permission.**

## Flash features you might like

- The tmux format language: `#[fg=yellow]CPU #[meter=20]#{flash.plugin.cpu.percent}`
  with conditionals and `#()` jobs ([status format](../status-format.md)).
- `[popup.<name>]` tables and the hover markers that open them
  ([popups](../popups.md)).
- `[widgets.<name>]` for a conky-style panel ([widgets](../widgets.md)).
- The [example bar](../examples/statusbar/README.md) with feed, quotas and
  system metrics.

## Moving from SketchyBar

| SketchyBar | Flash |
| --- | --- |
| `sketchybar --add item cpu right` + `plugins/cpu.sh` | `#{flash.plugin.cpu.percent}` in the template |
| `update_freq=2` | The plugin's own cadence; `[plugin.<id>]` keys |
| `--subscribe front_app_switched` | `#{flash.active_app}` updates on focus events |
| Popup menu | `[popup.<name>]` with a command, opened from `#[popup=<name>]` |
| `display=all` | `monitor` in `[statusbar]` |
| `notch_width` | `#[align=notch]` |
| AeroSpace workspace item | Keep SketchyBar, or a shell source running `aerospace list-workspaces --focused` |
| Aliases of native extras | Not available; Flash hides the native bar and offers `mouse_menubar` to reach extras |

```toml
[statusbar]
enabled = true
template = "#[fg=yellow]CPU #[fg=default]#{flash.plugin.cpu.percent} #[fg=yellow]MEM #[fg=default]#{flash.plugin.memory.percent} #[align=right]#{flash.clock.time}"
```

Running both bars on one display makes no sense; Flash users who want
SketchyBar's drawing keep SketchyBar and leave `[statusbar]` disabled, and
still get hints and modes.

*Checked 2026-10-14 against the SketchyBar
[README](https://github.com/FelixKratz/SketchyBar),
[events](https://felixkratz.github.io/SketchyBar/config/events) and
[tricks](https://felixkratz.github.io/SketchyBar/config/tricks) pages.*
