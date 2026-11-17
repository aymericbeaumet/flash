# Flash and MenuMeters

[MenuMeters](https://github.com/yujitach/MenuMeters) is Yuji Tachikawa's
"fork of MenuMeters for El Capitan, Sierra, High Sierra, Mojave, Catalina
and Big Sur": Alex Harper's classic CPU, disk, memory and network meters,
rebuilt as menu-bar items once macOS stopped loading third-party menu
extras. It is GPL-2, free, about 3,100 stars, with the last release
(2.1.6.1) in November 2021 and the last commit in March 2022. Its own README
now sends readers elsewhere: Stats, iGlance and eul "are maintained
actively. They are heavily recommended."

| | MenuMeters | Flash |
| --- | --- | --- |
| License, price | GPL-2, free, unmaintained | MIT, free |
| Metrics | CPU load and top processes, disk activity and space, memory, network | CPU and GPU use, load, memory, disk space and I/O, default-route network, battery and its health, top processes, any command's output |
| Sensors, fans | None | Battery temperature only |
| History | Scrolling graphs in the menu bar | Sparklines from 20 samples per plugin; a named source keeps up to 512 numbers |
| Alerts | None | `[monitors.<name>]` warning and error thresholds; Flash's centred alert |
| Surfaces | Menu-bar items | Flash's own bar, desktop widgets, popups |
| Configuration | Preferences window | One TOML file |
| Maintenance | None since 2022; tested up to Catalina, per its site | 1.1.0, October 2026 |

## Where MenuMeters is stronger

- **Nothing to learn.** Four meters, switched on in its preferences, in the
  native menu bar next to your other extras; Flash's bar replaces the menu
  bar.
- **Older Macs.** The universal build starts at OS X 10.11; Flash needs
  macOS 13.

## Where Flash is stronger

- **It is maintained.** MenuMeters' author recommends moving on.
- **Alerts.** A Flash monitor raises an alert when a value crosses its
  threshold; MenuMeters only draws.
- **Battery and GPU figures**, terminal popups and desktop widgets, all
  from one file.

## Flash features you might like

- `#[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]` and
  `#[spark]#{flash.plugin.sysinfo.network_down_history}#[nospark]`, the closest thing
  to its scrolling graphs ([status format](../status-format.md#meters-and-sparklines)).
- `#{flash.top_cpu}` in a text popup for its CPU menu's process list.

## Moving from MenuMeters

| MenuMeters | Flash |
| --- | --- |
| CPU meter, graph | `#[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]` |
| CPU menu, top processes | `[popup.<name>]` with `text = "#{flash.top_cpu}"` |
| Disk meter | `#{flash.plugin.sysinfo.disks_read}`, `#{flash.plugin.sysinfo.disks_write}` |
| Memory meter | `#[meter=10]#{flash.plugin.sysinfo.memory_percent}#[nometer]` |
| Network meter | `#{flash.plugin.sysinfo.network_down_bps}`, `up_bps`, and their histories |
| No alerts | `[monitors.<name>]` |

```toml
[statusbar]
enabled = true
template = "#[align=right]#[popup=top]CPU #[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]#[nopopup] MEM #[meter=10]#{flash.plugin.sysinfo.memory_percent}#[nometer] %H:%M"

[popup.top]
text = "#{flash.top_cpu}"
```

*Checked 2026-10-20 against the MenuMeters
[README](https://github.com/yujitach/MenuMeters),
[releases](https://github.com/yujitach/MenuMeters/releases) and
[site](http://member.ipmu.jp/yuji.tachikawa/MenuMetersElCapitan/).*
