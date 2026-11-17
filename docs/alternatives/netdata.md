# Flash and Netdata

[Netdata](https://github.com/netdata/netdata) is "an open-source, real-time
infrastructure monitoring platform. Monitor, detect, and act across your
entire infrastructure.": an agent that collects per-second metrics, stores
them on disk, ships hundreds of preconfigured alerts and serves a web
dashboard. The agent is GPL-3, about 81,000 stars, with frequent releases
(v2.12.1 on 8 October 2026); its dashboard UI is closed source but free, and
Netdata Cloud has free and paid tiers. macOS is a community, best-effort
platform: Netdata's own install page says it works "albeit with some
limitations", the Homebrew package is community-maintained, and "The
number of charts displaying system metrics is limited".

| | Netdata on macOS | Flash |
| --- | --- | --- |
| License, price | GPL-3 agent, free; closed but free dashboard; Cloud has paid tiers | MIT, free |
| Metrics | CPU, memory, swap, load, disks and mount points, network interfaces, battery, Apple silicon GPU, NVMe S.M.A.R.T. | CPU and GPU use, load, memory, disk space and I/O, default-route network, battery and its health, top processes, any command's output |
| Sensors, fans | SMC temperatures, fans, voltages and power; thermal pressure through a setuid helper | Battery temperature only |
| History | Per-second, then per-minute and per-hour tiers, as long as the disk allows | 20-sample charts per plugin; a named source keeps up to 512 numbers |
| Alerts | Hundreds of built-in alerts, about 18 for the macOS collectors; e-mail, Slack, Telegram, PagerDuty, Discord, Teams and more, sent by the agent itself | `[monitors.<name>]` warning and error thresholds on any numeric value; Flash's centred alert |
| Surfaces | Web dashboard on `localhost:19999`, Netdata Cloud | Flash's own bar, desktop widgets, popups |
| Scripting | HTTP API; exports to Prometheus, InfluxDB, Graphite, OpenTSDB | Named sources and `#()` jobs feed it; plugins over JSON lines |
| Maintenance | v2.12.1, October 2026; very active, macOS best effort | 1.1.0, October 2026 |

## Where Netdata is stronger

- **Real history.** Every metric at one-second resolution, kept for as long
  as the disk allows, with charts to zoom through. Flash keeps 20 samples
  per plugin chart and up to 512 per named source, for sparklines.
- **An alert library and delivery.** Hundreds of tuned alerts, and
  notifications to e-mail, chat and paging services that reach you away
  from the Mac. Flash's alert appears on the Mac's screen only.
- **It never sleeps.** The agent keeps collecting and alerting while the
  display is off; Flash's clock pauses while displays sleep or the session
  is locked.
- **Sensors and S.M.A.R.T.** on macOS, and a fleet view across many
  machines and operating systems.

## Where Flash is stronger

- **Built for the Mac's screen.** Values in the bar and on the desktop,
  alerts over whatever you are doing, no dashboard tab to keep open.
- **A supported macOS path.** Netdata calls its own macOS support limited
  and community-maintained; Flash is macOS only.
- **Small and scoped.** Flash's samplers run only while something reads
  their values, and nothing listens beyond loopback; Netdata is a resident
  collector with a web server.
- **Thresholds on any value**, including a named source printing a number
  from any command, in the same file as the bar.

## Flash features you might like

- A `#[link=http://localhost:19999]` around a bar label, to open the Netdata
  dashboard with one click or one hint ([status format](../status-format.md)).
- The built-in monitors (low battery, a nearly full disk, memory pressure,
  plugin failures, slow process spawns), and `flash monitors show` for the
  help's monitors page ([monitors](../monitors.md)).
- `#{flash.top_cpu}` and `#{flash.focused_app_details}` for a per-process
  view in a widget or a popup.

## Moving from Netdata

| Netdata | Flash |
| --- | --- |
| `warn: $this > 80`, `crit: $this > 90` | `warning = 80`, `error = 90` (`direction = "above"` is the default) |
| Disk space alert | The built-in `disk` monitor |
| Battery capacity alert | The built-in `battery` monitor |
| CPU, RAM, network charts | `#[spark]` over the plugin histories |
| Per-second history, Cloud, exporters | Keep Netdata |
| Slack, e-mail, PagerDuty notifications | Keep Netdata; Flash alerts only on screen |
| Sensor and NVMe charts | Keep Netdata |

```toml
[monitors.download]
value = "#{flash.plugin.sysinfo.network_down_bps}"
warning = 50000000
error = 100000000
message = "Heavy download"

[statusbar]
enabled = true
template = "#[align=right]#[link=http://localhost:19999]#[label]NET#[default]#[nolink] #{p-4:flash.plugin.sysinfo.network_label} %H:%M"
```

On a Mac that already reports to Netdata, keep the agent for history and
remote alerts, and let Flash show the figures you glance at and the alerts
you need to see at the desk.

*Checked 2026-10-20 against the Netdata
[README](https://github.com/netdata/netdata),
[platform support](https://github.com/netdata/netdata/blob/master/packaging/PLATFORM_SUPPORT.md),
[macOS install](https://learn.netdata.cloud/docs/installing/macos) and
[macOS collector](https://github.com/netdata/netdata/blob/master/src/collectors/macos.plugin/integrations/macos.md)
pages, and its
[notification](https://github.com/netdata/netdata/blob/master/src/health/notifications/README.md)
docs.*
