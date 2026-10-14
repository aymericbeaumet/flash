# Flash and conky

[conky](https://github.com/brndnmtthws/conky) is a "Light-weight system
monitor for X, Wayland, and other things, too", GPL-3 C++ with Lua
configuration, about 8,500 stars and frequent releases (1.25.3 in October
2026). macOS is on its platform list, but the wiki says you "might need to
install XQuartz", there is no Homebrew formula, and reports describe drawing
into the X root window, no transparency and one desktop only. Flash's
widgets exist for the people who left conky behind on Linux.

| | conky on macOS | Flash widgets |
| --- | --- | --- |
| License, price | GPL-3, free | MIT, free |
| Install | Build from source; XQuartz likely | `brew install --cask aymericbeaumet/tap/flash` |
| Definition | Lua config with `${cpu}`-style variables and Lua drawing | `[widgets.<name>]` tables with tmux-format templates |
| Rendering | X11 window, or console, file and HTTP output | Native click-through layers at desktop level |
| Data | Built-in variables for CPU, memory, disks, network, battery, processes, and `${exec}` | Bundled plugins for the same, named sources and `#()` jobs |
| Maintenance | Active, Linux first | 1.0.0, October 2026 |

## Where conky is stronger

- **Hundreds of variables and Lua drawing**: graphs, gauges, images,
  arbitrary Cairo drawing, and years of themes to copy.
- **Linux and BSDs.** On a Linux desktop it is the natural tool; Flash does
  not run there.
- **Non-desktop outputs** (console, file, HTTP) for scripts.

## Where Flash is stronger

- **It works on macOS as a native desktop layer**: below windows, above the
  wallpaper, per display, with the notch and Spaces handled by the system.
- **One install and one file**, no X server.
- **Event-driven values** from plugins on one scheduler that pauses when
  the widget is covered or the display sleeps.
- **The same template feeds the bar.**

## Flash features you might like

- The conky migration table in [widgets](../widgets.md): `${cpu}` to
  `#{flash.plugin.cpu.percent}`, `${mem}` to `#{flash.plugin.memory.*}`,
  `${top name 1}` to `#{flash.plugin.processes.top_cpu}`.
- `#[meter=N]` and `#[spark]` for bars and graphs.
- `[statusbar.sources.<name>]` for any command's output, the `${exec}`
  equivalent.

## Moving from conky

| conky | Flash |
| --- | --- |
| `${cpu cpu0}%` | `#{flash.plugin.cpu.percent}` |
| `${cpubar}` | `#[meter=20]#{flash.plugin.cpu.percent}#[nometer]` |
| `${cpugraph}` | `#[spark]#{flash.plugin.cpu.history}#[nospark]` |
| `${memperc}` | `#{flash.plugin.memory.percent}` |
| `${fs_used_perc /}` | `#{flash.plugin.disks.*}` ([status plugins](../status-plugins.md)) |
| `${battery_percent}` | `#{flash.plugin.power.*}` |
| `${top name 1}` | `#{flash.plugin.processes.top_cpu}` |
| `${exec cmd}` | A named source running `cmd` |
| `${time %H:%M}` | `#{flash.clock.time}` |
| `alignment = 'top_right'` | `anchor = "top_right"` |
| Lua drawing | Not available |

Start from `docs/examples/widgets/system-panel.toml`.

*Checked 2026-10-14 against the conky
[README](https://github.com/brndnmtthws/conky) and
[installation wiki](https://github.com/brndnmtthws/conky/wiki/Installation).*
