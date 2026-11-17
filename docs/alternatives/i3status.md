# Flash and i3status

[i3status](https://github.com/i3/i3status) "Generates status bar to use with
i3bar, dzen2 or xmobar", and its man page adds lemonbar and a terminal: one
small C program that prints a status line every few seconds from built-in
modules (`cpu_usage`, `load`, `memory`, `disk`, `battery`, `wireless`,
`ethernet`, `volume`, `tztime`, `run_watch`, `path_exists`, `read_file`,
`cpu_temperature`), "designed to be very efficient by issuing a very small
number of system calls" rather than spawning shell commands. It is BSD-3,
about 650 stars, 2.15 in August 2024, part of the i3 project. It reads
Linux's `/proc` and `/sys` and the BSDs' sysctls, has no macOS port, and
prints for bars that do not exist there. Flash's [status bar](../statusbar.md)
replaces the pair: the sysinfo plugin covers most modules, in-process and
without a shell, and a short source covers the rest.

| | i3status | Flash |
| --- | --- | --- |
| License, price | BSD-3, free | MIT, free |
| Platforms | Linux and the BSDs | macOS 13+ |
| Data | Built-in modules, read with a few system calls | The sysinfo plugin, read in-process; named sources and `#()` jobs for anything else |
| Output | i3bar JSON, dzen2, xmobar, lemonbar, terminal, plain | Its own bar, desktop widgets, popups |
| Colours | `color_good`, `color_degraded`, `color_bad` with thresholds per module | tmux conditionals in the template; monitors for alerts |
| Configuration | `i3status.conf` with `order +=` and a section per module | One template string in TOML, live reload |
| Maintenance | 2.15, August 2024; stable | 1.1.0, October 2026 |

## Where i3status is stronger

- **A module for each Linux interface.** `wireless` with ESSID, quality and
  bitrate, `run_watch` on a pidfile, `cpu_temperature` from the thermal
  zones, `volume` from ALSA or PulseAudio. Flash's plugin has no Wi-Fi
  details or temperature (macOS keeps temperatures behind the SMC), and
  volume or a VPN check needs a one-line source.
- **Per-module time zones.** `tztime berlin` with its own `timezone`; Flash's
  template formats local time only.
- **One output, many bars.** The same program feeds i3bar, dzen2, xmobar or
  lemonbar. Flash draws only its own surfaces, and has no reader for the
  i3bar streaming protocol yet ([standards](../standards.md)), which matters
  only if you keep an i3status-style generator of your own.
- **Nothing else to it.** A tiny, stable program that does one job.

## Where Flash is stronger

- **The same economy, on a Mac.** CPU, memory, disk, network and battery
  are read in-process by one sandboxed plugin on one clock, only while a
  surface shows them, and paused while the displays sleep.
- **Thresholds that act.** Beyond colouring a value, a
  [monitor](../monitors.md) raises an alert or runs a command when the disk
  passes 90%, from the same value.
- **Detail on demand.** `:sysinfo disks` and the other pagers, or btop in a
  hover popup, for what does not fit on one line.
- **The rest of the bar**: the mode, the focused app, workspaces with
  [tiling](../tiling.md), the next meeting, your own scripts.

## Flash features you might like

- `#{flash.plugin.sysinfo.cpu_history}` drawn as a sparkline, where
  i3status prints the current percentage only.
- `#{flash.top_cpu}` and `#{flash.top_mem}`, tables of the busiest
  processes, in a popup or a widget.
- `time in tokyo` in the flashlight answers inline, for the occasional
  look at another zone.
- `flash status refresh --name=<source>` updates one value on demand.

## Moving from i3status

| i3status | Flash |
| --- | --- |
| `order += "cpu_usage"` | `#{flash.plugin.sysinfo.cpu_percent}` |
| `order += "load"` | `#{flash.plugin.sysinfo.cpu_load}` |
| `order += "memory"` | `#{flash.plugin.sysinfo.memory_percent}` |
| `order += "disk /"` | `#{flash.plugin.sysinfo.disks_percent}`, the startup volume |
| `battery 0` with `%status %percentage` | `#{flash.plugin.sysinfo.power_state}`, `power_percent` |
| `ethernet`, `wireless` with `%ip` | `#{flash.plugin.sysinfo.network_address}` |
| `tztime local` with `format = "%Y-%m-%d %H:%M:%S"` | `%Y-%m-%d %H:%M:%S` in the template |
| `tztime berlin` | A source running `TZ=Europe/Berlin date +%H:%M` |
| `volume master` | A source running `osascript -e 'output volume of (get volume settings)'` |
| `run_watch VPN`, `path_exists VPN` | A source running `pgrep` or `test -e` |
| `read_file` | A source running `cat` |
| `threshold_degraded`, `color_bad` | `#{?#{e\|>=:…,90},#[fg=red],}` before the value |
| `general { interval = 5 }` | `[statusbar] interval = 5` for sources; plugin values arrive as they change |
| `cpu_temperature` | Not available |

```toml
[statusbar]
enabled = true
template = """
#[align=right]#{?#{e|>=:#{flash.plugin.sysinfo.disks_percent},90},#[fg=red],}/ #{flash.plugin.sysinfo.disks_percent}%%#[default]
 | #{flash.plugin.sysinfo.network_address}
 | #{flash.plugin.sysinfo.power_state} #{flash.plugin.sysinfo.power_percent}%%
 | load #{flash.plugin.sysinfo.cpu_load}
 | #{flash.plugin.sysinfo.memory_percent}%%
 | Berlin #{flash.source.berlin}
 | %Y-%m-%d %H:%M:%S
"""

[statusbar.sources.berlin]
command = ["/bin/sh", "-c", "TZ=Europe/Berlin date +%H:%M"]
interval = 60
```

The template's newlines are dropped, so the lines join into one right-hand
lane separated by `|` as i3bar drew it; `%%` is a literal percent sign.

*Checked 2026-10-23 against the i3status [manual](https://i3wm.org/i3status/manpage.html)
and [repository](https://github.com/i3/i3status).*
