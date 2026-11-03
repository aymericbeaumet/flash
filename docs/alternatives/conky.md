# Flash and conky

[conky](https://github.com/brndnmtthws/conky) is a "Light-weight system
monitor for X, Wayland, and other things, too": over 300 built-in objects,
text, bars and graphs, and Lua with Cairo and Imlib2 for anything else,
drawn on the desktop or printed to a console, a file or HTTP. It is GPL-3
C++, about 8,500 stars, with frequent releases (1.25.4 on 2026-10-14). Its
README now lists macOS beside Linux and the BSDs, but the wiki's macOS build
says you "might need to install XQuartz", there is no Homebrew formula, and
reports describe drawing into the X root window, no transparency and one
desktop only. Flash's [desktop widgets](../widgets.md) exist for the people
who left conky behind on a Linux desktop.

| | conky on macOS | Flash widgets |
| --- | --- | --- |
| License, price | GPL-3, free | MIT, free |
| Install | Build from source; XQuartz likely | `brew install --cask aymericbeaumet/tap/flash` |
| Definition | Lua config with `${cpu}`-style variables and Lua drawing | `[widgets.<name>]` tables with tmux-format templates |
| Rendering | X11 window, or console, file and HTTP output | Native click-through layers at desktop level |
| Data | Built-in variables for CPU, memory, disks, network, battery, processes, and `${exec}` | Bundled plugins and core process values for the same, named sources and `#()` jobs |
| Maintenance | 1.25.4, October 2026; active, Linux first | 1.1.0, October 2026 |

## Where conky is stronger

- **Hundreds of variables and Lua drawing**: graphs, gauges, images,
  arbitrary Cairo drawing, and years of themes to copy.
- **Linux and BSDs.** On a Linux desktop it is the natural tool; Flash does
  not run there.
- **Sensors.** `${hwmon}`, `${acpitemp}` and `${nvidia}` read temperatures
  and fans; macOS keeps them behind the SMC, and Flash reads none.
- **Mouse events and non-desktop outputs** (console, file, HTTP). Flash's
  widgets never take a click.

## Where Flash is stronger

- **It works on macOS as a native desktop layer**: below windows, above the
  wallpaper, per display, with the notch and Spaces handled by the system.
- **One install and one file**, no X server.
- **Event-driven values** from plugins on one scheduler that pauses when
  the widget is covered or the display sleeps.
- **The same template feeds the bar**, and the popups under it.

## Flash features you might like

- The conky migration table in [widgets](../widgets.md#coming-from-conky):
  the `own_window` settings, alignment, colours, `${if_…}` and the common
  variables, line by line.
- `#[meter=N]` and `#[spark]` for bars and graphs.
- `[statusbar.sources.<name>]` for any command's output, the `${execi}`
  equivalent, with `history = N` for `${execgraph}`.
- `[monitors.<name>]` on the same values, for the `${if_match}` that used to
  turn a line red: an alert when the disk fills, not only a colour.

## Coming from conky on a Linux desktop

Most of a `.conkyrc` moves line by line; what changes is the system
underneath it.

- **The window settings disappear.** `own_window_type desktop`,
  `own_window_hints below,sticky,skip_taskbar` and `own_window_argb_visual`
  are how conky asks an X window manager for what a Flash widget always is:
  below every window, on every Space, never in the window switcher, with a
  `#RRGGBBAA` background.
- **`${exec}` scripts that read Linux need new lines.** `/proc`, `/sys`,
  `sensors`, `acpi` and `nvidia-smi` are not there; `sysctl`, `vm_stat`,
  `pmset -g batt`, `ioreg` and `netstat` are the macOS readers, and the
  sysinfo plugin already covers CPU, memory, disks, network and battery.
- **Several configs are several tables.** Each `conky -c` your `.xinitrc`
  started becomes a `[widgets.<name>]` with its own anchor, screen and
  font, and Flash starts with your session through `[app] autostart`.
- **`xinerama_head` is `screen`**: a display number from 1, counted left to
  right, or `"all"`.
- **Lua and Cairo do not come along.** A source script can print status
  markup (colours, meters, sparklines) for what a Lua hook computed.

## Moving from conky

| conky | Flash |
| --- | --- |
| `${cpu cpu0}%` | `#{flash.plugin.sysinfo.cpu_percent}` |
| `${cpubar}` | `#[meter=20]#{flash.plugin.sysinfo.cpu_percent}#[nometer]` |
| `${cpugraph}` | `#[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]` |
| `${memperc}` | `#{flash.plugin.sysinfo.memory_percent}` |
| `${fs_used_perc /}` | `#{flash.plugin.sysinfo.disks_percent}` |
| `${battery_percent}` | `#{flash.plugin.sysinfo.power_percent}` |
| `${uptime_short}`, `${loadavg 1}` | `#{flash.plugin.sysinfo.cpu_uptime}`, `#{flash.plugin.sysinfo.cpu_load}` |
| `${top name 1}` | `#{flash.top_cpu}` |
| `${exec cmd}` | `#(cmd)` |
| `${execi 300 cmd}` | A named source running `cmd` with `interval = 300` |
| `${time %H:%M}` | `%H:%M`, expanded by `strftime` in the template |
| `alignment = 'top_right'` | `anchor = "top_right"` |
| `own_window_type = 'desktop'` | Built in |
| Lua drawing, `${hwmon}` | Not available |

```toml
[widgets.conky]
template = """
#[fg=#EBCB8B,bold]#{host_short}#[default]#[align=right]%H:%M
Uptime #{flash.plugin.sysinfo.cpu_uptime} · load #{flash.plugin.sysinfo.cpu_load}
CPU #[meter=20]#{flash.plugin.sysinfo.cpu_percent}#[nometer] #{flash.plugin.sysinfo.cpu_percent}%%
RAM #[meter=20]#{flash.plugin.sysinfo.memory_percent}#[nometer] #{flash.plugin.sysinfo.memory_percent}%%
Mail #{flash.source.unread}
#{flash.top_cpu}
"""
anchor = "top_right"
screen = "all"
bg = "#2E3440CC"

[statusbar.sources.unread]
command = ["~/bin/unread-mail"]
interval = 300
```

`~/bin/unread-mail` stands for any script of yours that prints a count.
Start from `docs/examples/widgets/system-panel.toml` for a fuller panel.

*Checked 2026-10-23 against the conky
[README](https://github.com/brndnmtthws/conky), its releases and the
[installation wiki](https://github.com/brndnmtthws/conky/wiki/Installation).*
