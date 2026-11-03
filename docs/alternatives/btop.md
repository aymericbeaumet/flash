# Flash and btop

[btop](https://github.com/aristocratos/btop) is a "Resource monitor that
shows usage and stats for processor, memory, disks, network and processes":
a terminal dashboard with graphs, a process tree, filters and signals. It is
Apache-2.0 C++, free, about 35,000 stars, with v1.4.7 in May 2026 adding
Apple silicon GPU figures through IOReport. Flash does not compete with it:
Flash's own README shows btop running in a popup under the bar's CPU
segment. [htop](htop.md) and [Activity Monitor](activity-monitor.md) have
pages of their own.

| | btop | Flash |
| --- | --- | --- |
| License, price | Apache-2.0, free | MIT, free |
| Platforms | Linux, macOS, FreeBSD, NetBSD, OpenBSD | macOS 13+ |
| Permissions | None; extra privileges for CPU power figures | Accessibility; nothing more for the system figures, which a sandboxed plugin reads |
| Metrics | CPU per core with frequency, temperature and (with privileges) power, Apple silicon GPU, memory, disks with I/O, network, battery, every process | CPU and GPU use, load, memory, disk space and I/O, default-route network, battery and its health, top processes, any command's output |
| History | Live graphs while it runs, nothing stored | 20-sample charts per plugin; a named source keeps up to 512 numbers |
| Alerts | None | `[monitors.<name>]` warning and error thresholds; Flash's centred alert, and a macOS notification with `notify = true` |
| Processes | Tree, sort, filter, signals, per-process detail | `#{flash.top_cpu}`, `#{flash.top_mem}`, `@processes` with a confirmed SIGTERM |
| Surfaces | A terminal | Flash's own bar, desktop widgets, popups, including btop itself |
| Keyboard | Full keyboard and mouse; optional vim keys | Hints, mappings, `mode terminal --name=btop` |
| Configuration | `btop.conf`, themes, layout presets | One TOML file, live reload, `flash config check` |
| Maintenance | v1.4.7, May 2026; active | 1.1.0, October 2026 |

## Where btop is stronger

- **It is the dashboard.** Per-core graphs, temperatures, GPU, disks and
  network on one screen, a process tree you can sort, filter and signal.
  Flash's rule is to show a maintained tool like this, not rebuild it, so
  there is no Flash equivalent and there will not be one.
- **CPU temperature**, which Flash does not read.
- **Themes and layout presets**, and it runs on Linux and the BSDs too.

## Where Flash is stronger

- **Always on screen.** A few figures in the bar or a desktop widget without
  a terminal window open.
- **Alerts.** btop shows a full disk when you look; a Flash monitor tells you
  when it crosses the threshold.
- **btop one key away.** A persistent popup keeps btop running, so hovering
  the CPU segment or pressing a mapped key shows it at once.

## Flash features you might like

- `[popup.btop]` with `persistent = true`, and the hover marker
  `#[popup=btop]` around the system labels ([popups](../popups.md)).
- `mode terminal --name=btop` to open it centred from NORMAL.
- The [example bar](../examples/statusbar/README.md), which wires the CPU,
  memory, disk, network and battery labels to popups.

## Moving from btop

Nothing moves; btop moves into a popup.

| btop | Flash |
| --- | --- |
| A terminal tab running btop | `[popup.btop]`, `persistent = true` |
| Glancing at btop | The bar or a widget: `#{p-3:flash.plugin.sysinfo.cpu_label}` and the other labels |
| Watching for a full disk or a runaway process | The built-in monitors, or `[monitors.<name>]` |
| `vim_keys = true` | Stays in `btop.conf`; the popup is a real terminal |

```toml
[popup.btop]
command = ["btop"]
size = "90%x85%"
persistent = true

[statusbar]
enabled = true
template = "#[align=right]#[popup=btop]#[label]CPU#[default] #{p-3:flash.plugin.sysinfo.cpu_label} #[label]MEM#[default] #{p-3:flash.plugin.sysinfo.memory_label}#[nopopup] %H:%M"

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>b" = ["flash", "mode", "terminal", "--name=btop"]
```

## Using both

btop and Flash do different jobs, so the question is only where btop runs.
Kept in a persistent popup, it starts once and keeps its history, sort and
filter between showings, and the popup's terminal gives it every key: btop's
own shortcuts, `vim_keys` and Escape included, work as in any terminal
while it is shown, and Command-W hides it with btop still running
([TERMINAL](../terminal-mode.md)). Flash's bar and
monitors read their figures from the sandboxed system plugin, not from
btop, so closing btop changes nothing in the bar; each samples on its own
clock.

*Checked 2026-10-20 against the btop
[README](https://github.com/aristocratos/btop) and
[changelog](https://github.com/aristocratos/btop/blob/main/CHANGELOG.md),
and its version on 2026-10-23 against the
[releases](https://github.com/aristocratos/btop/releases).*
