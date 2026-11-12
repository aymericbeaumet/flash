# Flash and eul

[eul](https://github.com/gao-sun/eul) is a "macOS status monitoring app
written in SwiftUI": menu-bar components for CPU, GPU, memory, battery,
disk, network and fans, plus macOS widgets. It is MIT, free, about 10,000
stars, and dormant: the last release (1.6.2) dates from August 2021 and the
last commit from January 2022, with 77 open issues. Its README says the App
Store build is out of date and lacks the SMC features. It still runs, as a
universal binary for macOS 10.15 and later.

| | eul | Flash |
| --- | --- | --- |
| License, price | MIT, free, dormant | MIT, free |
| Metrics | CPU use and temperature, GPU, memory, battery and Bluetooth batteries, disk, network with a per-process top list, fan speeds | CPU and GPU use, load, memory, disk space and I/O, default-route network, battery and its health, top processes, any command's output |
| Sensors, fans | CPU temperature; fan speeds, read only | Battery temperature only |
| History | Short in-memory graphs per component | 20-sample charts per plugin; a named source keeps up to 512 numbers |
| Alerts | None | `[monitors.<name>]` warning and error thresholds; Flash's centred alert |
| Surfaces | Menu-bar components, four macOS widgets | Flash's own bar, desktop widgets, popups |
| Configuration | Preferences window | One TOML file |
| Maintenance | None since 2022 | 1.1.0, October 2026 |

## Where eul is stronger

- **CPU temperature and fan speeds** in the menu bar, read from the SMC.
  Flash does not read the SMC.
- **A per-process network list**, which Flash does not have.
- **A small, readable SwiftUI codebase** under MIT, useful reading for anyone
  building a menu-bar monitor.

## Where Flash is stronger

- **It is maintained.** eul's last release, in August 2021, predates the
  M1 Pro and every later chip.
- **Alerts.** eul only displays; a Flash monitor raises an alert when a value
  crosses its warning or error threshold.
- **Terminal popups and desktop widgets** from the same templates as the bar.
- **A file instead of preferences**, so a setup survives a reinstall.

## Flash features you might like

- `#[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]` for eul's graphs.
- `nettop` or btop in a terminal popup for per-process traffic.
- The [system panel widget](../examples/widgets/README.md) for eul's
  macOS widgets.

## Moving from eul

| eul | Flash |
| --- | --- |
| CPU component | `#{p-3:flash.plugin.sysinfo.cpu_label}` |
| Memory component | `#{p-3:flash.plugin.sysinfo.memory_label}` |
| Battery component | `#{flash.plugin.sysinfo.power_label}` |
| Disk component | `#{p-3:flash.plugin.sysinfo.disks_label}` |
| Network component, top list | `#{p-4:flash.plugin.sysinfo.network_label}`; `nettop` in a popup |
| CPU temperature, fans | Not available; [Stats](stats.md) or [iStat Menus](istat-menus.md) read them |
| Widgets | `[widgets.<name>]` |
| No alerts | `[monitors.<name>]` |

```toml
[monitors.load]
value = "#{flash.plugin.sysinfo.cpu_load}"
warning = 8
error = 16
message = "Load average high"
```

*Checked 2026-10-20 against the eul
[repository](https://github.com/gao-sun/eul), its
[releases](https://github.com/gao-sun/eul/releases) and
[commits](https://github.com/gao-sun/eul/commits).*
