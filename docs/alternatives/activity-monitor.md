# Flash and Activity Monitor

Activity Monitor is the process and resource monitor every Mac already has,
in Applications › Utilities. Apple's guide describes it as the way to see
"how much energy your Mac uses", watch CPU activity "in the Activity Monitor
window or as a live graph in the Dock", monitor memory, and force quit what
stopped responding. Its window has CPU, Memory, Energy, Disk and Network
tabs (and Cache when content caching is on), with CPU and GPU history
windows beside it. It ships and updates with macOS, so there is no version
of its own to track.

Most Flash users keep it. Flash adds what Activity Monitor does not try to
do: a few figures on screen all the time, thresholds that raise an alert,
and the most common job, finding a process and stopping it, from the
keyboard.

| | Activity Monitor | Flash |
| --- | --- | --- |
| License, price | Built into macOS | MIT, free |
| Platforms | Every macOS | macOS 13+ |
| Permissions | None; an administrator password to quit another user's process | Accessibility; nothing more for the system figures, which a sandboxed plugin reads |
| Processes | Every process, by user or hierarchically; Quit, Force Quit, any signal; sample, inspect, system diagnostics | `@processes` in the flashlight: every visible process with its pid, CPU and memory share; SIGTERM after a confirmation; `process kill --pid=<n>` |
| Figures | CPU, GPU, memory pressure, energy impact, disk and network per process and in total | CPU and GPU use, load, memory, disks, network, battery and its health, top processes |
| History | CPU and GPU history windows; on a laptop, 12 hours of energy per app and of battery level | 20-sample charts per plugin; up to 512 numbers per named source |
| Alerts | None | `[monitors.<name>]` warning and error thresholds; the centred alert, and a macOS notification with `notify = true` |
| Surfaces | A window, its Dock icon | Flash's own bar, desktop widgets, popups |
| Configuration | View menu, columns, update frequency | One TOML file, live reload, `flash config check` |
| Maintenance | Ships with macOS | 1.1.0, October 2026 |

## Where Activity Monitor is stronger

- **Per-process accounting.** Energy impact, memory with compression and
  pressure, disk bytes and network packets for each process, in sortable
  columns. Flash has a CPU and a memory share per process and nothing per
  process for disk or network.
- **Twelve hours of energy.** On a laptop the Energy tab keeps each app's
  average impact and the battery level over the last 12 hours. Flash keeps
  no history beyond a short chart.
- **Diagnosis.** Sample a hung process, run a spindump or system
  diagnostics, see a process's open files and ports, send any signal.
  Flash sends SIGTERM and that is all.
- **The process tree** (View › All Processes, Hierarchically) shows what
  depends on what before you quit it.
- **Nothing to install.** It is there on every Mac, including the one you
  are helping someone fix.

## Where Flash is stronger

- **Always on screen.** CPU, memory, disk and battery in the bar or a
  desktop widget, without a window open; Activity Monitor's Dock icon shows
  one graph at a time.
- **Alerts.** Activity Monitor shows memory pressure when you look; Flash's
  built-in monitors raise an alert when memory pressure, a nearly full disk
  or a low battery crosses its threshold, and a monitor of your own can run
  a command when it does.
- **Keyboard first.** `@processes` finds a process by name and stops it after
  a `y`, from any app, without leaving the keyboard.

## Flash features you might like

- `:sysinfo cpu`, `:sysinfo memory`, `:sysinfo disks`, `:sysinfo network`
  and `:sysinfo power` open the details pagers, the closest Flash comes to
  Activity Monitor's tabs ([status plugins](../status-plugins.md)).
- `#{flash.top_cpu}` and `#{flash.top_mem}` in a widget: a live table of the
  busiest processes ([status format](../status-format.md)).
- `app quit --force` force-quits the focused app, the Force Quit button for
  the window in front of you.
- Hints work in Activity Monitor's own window: `f` clicks a tab, a column
  header or the Stop button.

## Moving from Activity Monitor

Keep it for diagnosis; move the glances and the quick kills.

| Activity Monitor | Flash |
| --- | --- |
| Find a process and Quit it | `@processes`, type its name, Return, then `y` (SIGTERM) |
| Force Quit the app in front | `app quit --force` |
| Force Quit any process | Activity Monitor, or `kill -9` in a terminal popup; Flash sends only SIGTERM |
| CPU graph in the Dock | `#{flash.plugin.sysinfo.cpu_label}` in the bar, or a widget |
| Memory pressure | The built-in `memory` monitor; `#{flash.plugin.sysinfo.memory_label}` in the bar |
| Energy tab, battery level | `:sysinfo power`; `#{flash.plugin.sysinfo.power_label}` |
| CPU and GPU history windows | Plugin charts (20 samples); keep Activity Monitor for longer views |
| Sample, spindump, open files and ports | Keep Activity Monitor |

```toml
[statusbar]
enabled = true
template = "#[align=right]#[label]CPU#[default] #{p-3:flash.plugin.sysinfo.cpu_label} #[label]MEM#[default] #{p-3:flash.plugin.sysinfo.memory_label} %H:%M"

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>P" = ["flash", "mode", "flashlight", "--query=@processes"]
"<leader>A" = ["flash", "app", "open", "--name=Activity Monitor"]
```

## Using both

Nothing conflicts: Activity Monitor is an ordinary app, and Flash's figures
come from its own sandboxed plugin, so neither slows the other. A practical
split is Flash's bar and monitors to notice that something is wrong,
`@processes` for the quick fix, and a mapped key (`app open --name=Activity
Monitor` above) for the times you need to see why. If you prefer a terminal
view, [htop](htop.md) and [btop](btop.md) fit in a Flash popup.

*Checked 2026-10-23 against the
[Activity Monitor User Guide](https://support.apple.com/guide/activity-monitor/welcome/mac),
its pages on [energy](https://support.apple.com/guide/activity-monitor/view-energy-consumption-actmntr43697/mac)
and [quitting a process](https://support.apple.com/guide/activity-monitor/quit-a-process-actmntr1002/mac).*
