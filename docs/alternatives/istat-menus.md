# Flash and iStat Menus

[iStat Menus](https://bjango.com/mac/istatmenus/) is "The ultimate system
monitor": "Everything about your Mac, right in your menu bar", by Bjango.
It is closed source, a one-time licence with a 14-day trial, $11.99 on the
Mac App Store (where it cannot control fans) and part of Setapp. Version 7.5
shipped in September 2026 and releases are regular; it needs macOS 13.5
(14 from the App Store). It is the reference menu-bar monitor on the Mac, and
it measures far more than Flash does.

| | iStat Menus 7 | Flash |
| --- | --- | --- |
| License, price | Closed; one-time licence, $11.99 on the App Store, or Setapp | MIT, free |
| Metrics | CPU per core, GPU, memory pressure, compressed memory and swap, disk space and activity, network with per-app bandwidth, battery including Bluetooth devices, weather, world clocks | CPU and GPU use, load, memory, disk space and I/O, default-route network, battery and its health, top processes, the focused app's process tree, AI quotas, any command's output |
| Sensors, fans | Temperatures, fans, voltages, current and power; fan control outside the App Store build; S.M.A.R.T. | Battery temperature only; no SMC sensors, fans or S.M.A.R.T. |
| History | Stored graphs; the help documents hour (6 s samples) and day (144 s samples) views | 20-sample charts per plugin; a named source keeps up to 512 numbers |
| Alerts | Rules on CPU, GPU, memory, disks, network, sensors, battery, power and weather; temporary or persistent macOS notifications | `[monitors.<name>]` warning and error thresholds on any numeric value; Flash's centred alert |
| Surfaces | Menu-bar items, or one combined item | Flash's own bar, which hides the native menu bar; desktop widgets; popups |
| Keyboard | Hotkeys that open and close a menu | Hints on bar segments, popups and details by mapping or `:sysinfo cpu` |
| Configuration | Settings window, settings export | One TOML file, validated by `flash config check` |
| Helpers | iStat Menus Helper for sensors, fans and persistent notifications | None; plugins are sandboxed child processes |
| Maintenance | 7.5, September 2026; active | 1.1.0, October 2026 |

## Where iStat Menus is stronger

- **Sensors and fans.** Temperatures, voltages, power and fan speeds from
  the SMC, fan control, and S.M.A.R.T. status. Flash reads none of them and
  its status plugins treat them as out of scope.
- **Breadth.** Memory pressure as macOS reports it, per-app network
  bandwidth, Bluetooth device batteries, weather and world clocks.
- **Stored history graphs** in a history database; Flash keeps the last 20
  samples of each plugin chart, and up to 512 for a named source.
- **Notifications that stay.** Rules can post persistent macOS
  notifications that remain until closed. Flash's alert is its own centred
  overlay, not a macOS notification, and only appears while Flash runs.
- **Polish and no configuration.** A settings window, colours and item
  order to taste, and a product refined over seven major versions.

## Where Flash is stronger

- **Thresholds on any value, not only hardware.** A monitor reads whatever
  the bar can show: a plugin segment, or a named source printing a number
  from any command, so a failing CI job or a full mailbox can raise the
  same alert as a full disk.
- **Free, open source, and one file** in your dotfiles; the bar, widgets,
  popups and monitors share the same values and the same scheduler.
- **Terminal popups.** Hovering the CPU segment, or one key, opens btop in a
  real terminal instead of a fixed dropdown.
- **No helper.** iStat Menus installs a helper for sensors and fans;
  Flash's `sysinfo` plugin is helperless, sandboxed and spawns no process for
  its samples.
- **Desktop widgets** from the same templates as the bar.

## Flash features you might like

- `#{flash.top_cpu}` and `#{flash.top_mem}` tables in a widget or a text
  popup, like the top-apps list in iStat's CPU and memory menus
  ([process values](../status-format.md#process-values)).
- `#{flash.focused_app_details}`: the focused app and all its helper
  processes, summed.
- `:sysinfo cpu`, `:sysinfo memory`, `:sysinfo disks`, `:sysinfo network` and
  `:sysinfo power`: the details pager, from the keyboard.
- The built-in monitors (low battery, a nearly full disk, memory pressure,
  plugin failures, slow process spawns), and `flash monitors show` for the
  help's monitors page ([monitors](../monitors.md)).

## Moving from iStat Menus

| iStat Menus | Flash |
| --- | --- |
| CPU item with a graph | `#{p-3:flash.plugin.sysinfo.cpu_label}` and `#[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]` |
| Memory item | `#{flash.plugin.sysinfo.memory_percent}`; it counts cached pages and is not pressure |
| Memory pressure | `#{flash.memory_pressure}`, watched by the built-in `memory` monitor |
| Disk space, activity | `#{flash.plugin.sysinfo.disks_percent}`, `#{flash.plugin.sysinfo.disks_read}` and `write` |
| Network item | `#{flash.plugin.sysinfo.network_label}`, `down_bps`, `up_bps` |
| Per-app bandwidth | Apple's `nettop` in a terminal popup |
| Battery item | `#{flash.plugin.sysinfo.power_percent}`, `#{flash.plugin.sysinfo.power_state}` |
| Sensors, fans | Not available; keep iStat Menus, or a named source running a sensor CLI such as [macmon](https://github.com/vladkens/macmon) |
| Rule: CPU above a value | `[monitors.<name>]` over `#{flash.plugin.sysinfo.cpu_percent}` |
| Rule: low disk space | The built-in `disk` monitor; `[monitors.disk] warning = 80` retunes it |
| Hotkey to open a menu | `["flash", "mode", "terminal", "--name=btop"]` |
| Combined mode | One template line |
| Weather, world clocks | Not bundled; a named source, or `TZ=… date` in a `#()` job |

```toml
[statusbar]
enabled = true
template = "#[align=right]#[popup=btop]#[label]CPU#[default] #{p-3:flash.plugin.sysinfo.cpu_label} #[label]MEM#[default] #{p-3:flash.plugin.sysinfo.memory_label}#[nopopup] %H:%M"

[popup.btop]
command = ["btop"]
size = "90%x85%"
persistent = true

[monitors.cpu]
value = "#{flash.plugin.sysinfo.cpu_percent}%%"
warning = 80
error = 95
message = "CPU busy"

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"'b" = ["flash", "mode", "terminal", "--name=btop"]
```

The two can share a Mac: iStat Menus items live in the native menu bar,
which Flash hides while its own bar is enabled and reaches with
`mouse menubar`. Keep iStat Menus for sensors, fans and stored history, and
let Flash's monitors cover the values iStat cannot see.

*Checked 2026-10-20 against the
[iStat Menus page](https://bjango.com/mac/istatmenus/), its
[version history](https://bjango.com/mac/istatmenus/versionhistory/), the
help on [rules](https://bjango.com/help/istatmenus7/rules/),
[hotkeys](https://bjango.com/help/istatmenus7/hotkeys/),
[history graphs](https://bjango.com/help/istatmenus7/historygraphs/) and the
[App Store build](https://bjango.com/help/istatmenus7/macappstore/), and the
[App Store listing](https://apps.apple.com/us/app/istat-menus-7/id6499559693?mt=12).*
