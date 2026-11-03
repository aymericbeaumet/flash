# Flash and iStatistica

[iStatistica Pro](https://www.imagetasks.com/istatistica/pro/) is "System
Monitor Reinvented", by ImageTasks: menu-bar monitors, Notification Center
widgets, an apps monitor and a LAN web API. It is closed source, $9.99 on the
Mac App Store; the $5.99 [iStatistica](https://www.imagetasks.com/istatistica/)
upgrades to Pro in-app for $3.99. Temperatures, fans and disk I/O need a
separate Sensors plugin from the vendor's site. Version 7.1.3 followed a
macOS 27 compatibility release in September; it runs natively on Apple
silicon and still supports OS X 10.11.

| | iStatistica Pro | Flash |
| --- | --- | --- |
| License, price | Closed; $9.99, or $5.99 plus a $3.99 upgrade | MIT, free |
| Metrics | CPU, GPU and VRAM, memory, disks, network with WAN and LAN addresses, battery and Bluetooth batteries, per-app CPU and memory | CPU and GPU use, load, memory, disk space and I/O, default-route network, battery and its health, top processes, the focused app's process tree, any command's output |
| Sensors, fans | 40+ temperature sensors and fan speeds with the Sensors plugin | Battery temperature only |
| History | Per-app CPU history; CSV export | 20-sample charts per plugin; a named source keeps up to 512 numbers |
| Alerts | "Notifications, alerts, and actions" on CPU, memory, GPU, disks, network and sensors; an alert can run a terminal command or a workflow | `[monitors.<name>]` warning and error thresholds on any numeric value; Flash's centred alert, no action |
| Surfaces | Menu-bar items, Notification Center widgets, a main window, a web page over the LAN | Flash's own bar, desktop widgets, popups |
| Scripting | JSON REST API with IP and passkey filters | Named sources and `#()` jobs feed it; plugins over JSON lines |
| Configuration | Preferences window | One TOML file |
| Maintenance | 7.1.3; active | 1.1.0, October 2026 |

## Where iStatistica is stronger

- **Actions on alerts.** An alert can run a terminal command or an Automator
  workflow, which is how its own blog sends e-mail on high load. A Flash
  monitor shows an alert and nothing else.
- **Sensors and fans** through its plugin, and GPU memory figures.
- **Remote reading.** A web page and a JSON REST API serve the figures to
  other devices on the network; Flash listens on loopback only.
- **macOS notifications and widgets**, and a main window with a RAM map and
  force-quit for apps.
- **Price of entry and reach.** Ten dollars once, back to OS X 10.11.

## Where Flash is stronger

- **Thresholds on any value.** A monitor reads anything the bar shows,
  including a named source printing a number from any command.
- **Free, open source and in your dotfiles**, with the bar, widgets, popups
  and monitors defined together.
- **Keyboard first.** Hints on bar segments, popups by mapping, `:sysinfo cpu`
  and the other details pagers.
- **Terminal popups** for btop, htop or `nettop`, rather than a fixed window.
- **Nothing extra to install** for what it does measure; its `sysinfo`
  plugin is bundled and sandboxed.

## Flash features you might like

- `#{flash.focused_app_details}` for the per-app view: CPU, memory, sockets,
  threads and disk I/O summed over an app and its helpers
  ([process values](../status-format.md#process-values)).
- `[statusbar.sources.<name>]` with `history = N` to chart any command
  ([status format](../status-format.md#jobs-sources-and-flash-styles)).
- The built-in monitors, and `flash monitors show` for the help's monitors
  page ([monitors](../monitors.md)).

## Moving from iStatistica

| iStatistica | Flash |
| --- | --- |
| CPU, memory, disk, network menu items | `#{p-3:flash.plugin.sysinfo.cpu_label}`, `memory.label`, `disks.label`, `#{p-4:flash.plugin.sysinfo.network_label}` |
| Battery menu item | `#{flash.plugin.sysinfo.power_label}`; health and cycles in `:sysinfo power` |
| Apps monitor | `#{flash.top_cpu}`, `#{flash.top_mem}`, or btop in a popup |
| Sensors plugin | Not available; keep iStatistica, or a named source running a sensor CLI |
| Alert on CPU, memory, disk | `[monitors.<name>]` |
| "Run terminal command" action | Not available; a monitor only alerts |
| CSV export, REST API | Not available |
| Notification Center widgets | `[widgets.<name>]` on the desktop |

```toml
[monitors.disk_writes]
value = "#{flash.plugin.sysinfo.disks_write_bps}"
warning = 200000000
error = 500000000
message = "Heavy disk writes"

[widgets.system]
anchor = "top_right"
template = """
CPU #[meter=20]#{flash.plugin.sysinfo.cpu_percent}#[nometer] #[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]
#{flash.top_cpu}
"""
```

*Checked 2026-10-20 against the
[iStatistica](https://www.imagetasks.com/istatistica/) and
[iStatistica Pro](https://www.imagetasks.com/istatistica/pro/) pages, the
[Sensors plugin](https://www.imagetasks.com/istatistica/download-plugin/)
page, the vendor's
[e-mail alerts article](https://www.imagetasks.com/blog/e-mail-alerts-for-high-CPU-GPU-or-memory-load/),
and the App Store listings for
[iStatistica Pro](https://apps.apple.com/us/app/istatistica-pro/id1447778660?mt=12)
and [iStatistica](https://apps.apple.com/us/app/istatistica/id1025822138?mt=12).*
