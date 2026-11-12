# Flash and Stats

[Stats](https://github.com/exelban/stats) is a "macOS system monitor in your
menu bar": one module per resource, each with its own menu-bar widget, popup
and notification settings. It is MIT Swift, free, about 42,700 stars, macOS
12+, with near-weekly releases (3.0.22 on 18 October 2026). It is the
most-starred open-source answer to iStat Menus.

| | Stats | Flash |
| --- | --- | --- |
| License, price | MIT, free; the optional remote System Stats service has paid plans | MIT, free |
| Metrics | CPU, GPU, RAM and memory pressure, disks with S.M.A.R.T., network with per-process traffic, battery, Bluetooth device batteries, time zones | CPU and GPU use, load, memory, disk space and I/O, default-route network, battery and its health, top processes, the focused app's process tree, any command's output |
| Sensors, fans | Temperature, voltage and power sensors; fan control "in legacy mode" through a helper | Battery temperature only; no SMC sensors or fans |
| History | Line and bar charts; popups keep 1 to 10 minutes | 20-sample charts per plugin; a named source keeps up to 512 numbers |
| Alerts | Per-module thresholds: CPU, GPU, RAM, swap and pressure, disk, battery low and high, Bluetooth batteries, sensors; connectivity, IP and Wi-Fi changes; macOS notifications | `[monitors.<name>]` warning and error thresholds on any numeric value; Flash's centred alert |
| Surfaces | Menu-bar widgets per module or combined, popups, macOS widgets | Flash's own bar, which hides the native menu bar; desktop widgets; popups |
| Keyboard | A shortcut per module popup | Hints on bar segments, popups and details by mapping or `:sysinfo cpu` |
| Configuration | Settings window; export and import | One TOML file, validated by `flash config check` |
| Maintenance | 3.0.22, October 2026; very active | 1.1.0, October 2026 |

## Where Stats is stronger

- **More hardware.** SMC temperatures, voltages and power, fan speeds,
  S.M.A.R.T., GPU detail, Bluetooth batteries and per-process network
  traffic. Flash's plugins stop at what public APIs give without a helper.
- **More alert kinds out of the box.** Memory pressure levels, free memory,
  swap size, per-sensor limits, and events that are not numbers: the
  internet going down, a new public IP, a different Wi-Fi network.
- **macOS notifications**, delivered through Notification Center. Flash's
  alert is its own centred overlay and appears only while Flash runs.
- **A dozen menu-bar widget styles**, and nothing to write: every module is
  a set of checkboxes.
- **Other machines.** The same author's System Stats service collects Linux,
  macOS and Windows hosts, with stored history, and alerts by email, Slack
  or webhooks on its paid plans.

## Where Flash is stronger

- **Thresholds on any value.** Stats alerts on its own modules; a Flash
  monitor reads anything the bar can show, including a named source that
  prints a number from any command.
- **One file for the bar, widgets, popups and monitors**, in your dotfiles,
  with live reload. Stats keeps its settings in its own window.
- **Terminal popups.** btop, htop or `nettop` open in a real terminal under a
  segment or from one key, where Stats shows its fixed popup.
- **Keyboard access to the bar itself**: hints label its links and popup
  segments, and a hint on a popup segment opens it.
- **No helper.** Stats' fan control needs an SMC helper and no longer
  receives fixes; Flash has nothing to install or remove.

## Flash features you might like

- `#[spark]#{flash.plugin.sysinfo.network_down_history}#[nospark]` for Stats' network
  chart, `#[meter=20]` for its bar widget ([status format](../status-format.md)).
- `[widgets.<name>]` on the desktop, with no WidgetKit toggle to enable.
- The built-in monitors (low battery, a nearly full disk, memory pressure,
  plugin failures, slow process spawns), and `flash monitors show` for the
  help's monitors page ([monitors](../monitors.md)).
- `#{flash.top_cpu}` and `#{flash.top_mem}`, Stats' top-process lists as a
  table ([process values](../status-format.md#process-values)).

## Moving from Stats

| Stats | Flash |
| --- | --- |
| CPU module, line chart | `#{p-3:flash.plugin.sysinfo.cpu_label}`, `#[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]` |
| RAM module | `#{flash.plugin.sysinfo.memory_percent}`; used memory, not pressure |
| Memory pressure notification | The built-in `memory` monitor, over `#{flash.memory_pressure}` |
| Disk module | `#{flash.plugin.sysinfo.disks_percent}`, `#{flash.plugin.sysinfo.disks_read}` and `write` |
| Network module | `#{flash.plugin.sysinfo.network_label}`, `down_bps`, `up_bps` |
| Per-process traffic | `nettop` in a terminal popup |
| Battery module | `#{flash.plugin.sysinfo.power_percent}`, `#{flash.plugin.sysinfo.power_state}` |
| Sensors, fans | Not available; keep Stats, or a named source running a sensor CLI |
| CPU notification threshold | `[monitors.<name>]` over `#{flash.plugin.sysinfo.cpu_percent}` |
| Battery "Low level notification" | The built-in `battery` monitor; `[monitors.battery] warning = 30` retunes it |
| Disk utilization notification | The built-in `disk` monitor |
| Connectivity, IP, Wi-Fi notifications | Not available; monitors compare numbers |
| Popup shortcut | A mapping to `mode terminal --name=<popup>` |
| Combined modules | One template line |

```toml
[monitors.cpu]
value = "#{flash.plugin.sysinfo.cpu_percent}%%"
warning = 80
error = 95
message = "CPU busy"

# The built-in battery monitor warns at 20 % and errs at 10 %; warn earlier.
[monitors.battery]
warning = 30

[popup.traffic]
command = ["nettop", "-P"]
size = "90%x85%"
```

Stats and Flash run side by side without friction: Stats' items sit in the
native menu bar, which Flash hides while its own bar is on and reaches with
`mouse menubar`. Stats for sensors and Flash for the bar is a sensible
split.

*Checked 2026-10-20 against the Stats
[README](https://github.com/exelban/stats),
[releases](https://github.com/exelban/stats/releases), its per-module
notification settings in the source, [mac-stats.com](https://mac-stats.com)
and [System Stats pricing](https://system-stats.com/pricing).*
