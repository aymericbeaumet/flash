# Flash and Glances

[Glances](https://github.com/nicolargo/glances) is "An Eye on your System":
a Python monitor with a terminal UI, a web UI and a REST API, per-resource
thresholds, an alert log, and exports to most time-series databases. It is
LGPL-3, free, about 33,800 stars, with frequent releases (4.5.8 on
11 October 2026), installed with `brew install glances`. On macOS its
sensors plugin (temperatures, fans) is marked Linux only, and its GPU plugin
lists no Apple GPU.

| | Glances | Flash |
| --- | --- | --- |
| License, price | LGPL-3, free | MIT, free |
| Metrics | CPU, memory, swap, load, file systems, disk I/O, network, processes, containers, and more through plugins | CPU and GPU use, load, memory, disk space and I/O, default-route network, battery and its health, top processes, any command's output |
| Sensors, fans | Linux only | Battery temperature only |
| History | 1,200 values, about an hour by default; exports to InfluxDB, Prometheus, Graphite, CSV, JSON and others | 20-sample charts per plugin; a named source keeps up to 512 numbers |
| Alerts | `careful`, `warning` and `critical` thresholds per plugin in `glances.conf`; an events panel; actions that run a command on warning or critical | `[monitors.<name>]` warning and error thresholds on any numeric value; Flash's centred alert |
| Surfaces | Terminal UI, web UI on port 61208, client and server mode | Flash's own bar, desktop widgets, popups |
| Scripting | REST API, Python API, an MCP server | Named sources and `#()` jobs feed it; plugins over JSON lines |
| Maintenance | 4.5.8, October 2026; active | 1.1.0, October 2026 |

## Where Glances is stronger

- **Actions.** `warning_action` and `critical_action` run any command with
  the alert's values, once or on every refresh until the alert ends. A Flash
  monitor only raises its alert.
- **Three levels and an events list.** `careful` sits below `warning`, and
  the events panel lists the last alerts. Flash has warning and error, and
  its monitors page shows only each monitor's latest change and alert.
- **Exports and remote use.** Long-term history belongs in the database it
  feeds; client/server mode and the web UI watch other machines.
- **Breadth and platforms**: containers, many plugins, Linux, BSD and
  Windows.

## Where Flash is stronger

- **Alerts you see without looking.** Glances marks a threshold inside its
  own UI; unless an action is set, nothing reaches you while it sits in a
  hidden terminal. A Flash monitor raises a centred alert over whatever you
  are doing.
- **Battery figures**: charge, state, health and cycles. Glances' sensors
  plugin, which carries the battery, is documented for Linux only.
- **A bar and desktop widgets** without a terminal or a browser tab, and no
  Python runtime to keep updated.
- **Glances is still there when you want it**, in a terminal popup.

## Flash features you might like

- `[popup.glances]` with `command = ["glances"]` and `persistent = true`,
  opened from a segment or a key ([popups](../popups.md)).
- `#[spark]#{flash.plugin.sysinfo.cpu_history}#[nospark]` for its sparklines.
- The built-in monitors, and `flash monitors show` for the help's monitors
  page ([monitors](../monitors.md)).

## Moving from Glances

| Glances | Flash |
| --- | --- |
| `[cpu] user_warning=70`, `user_critical=90` | `[monitors.<name>]` over `#{flash.plugin.sysinfo.cpu_percent}`, total CPU rather than user time |
| `[fs] warning`, `critical` | The built-in `disk` monitor, over the startup volume |
| `[load] critical=5.0` | `[monitors.<name>]` over `#{flash.plugin.sysinfo.cpu_load}`; Glances divides load by the core count, Flash shows the raw one-minute figure |
| `careful` level | No third level; use it as `warning` |
| `warning_action`, `critical_action` | Not available; keep Glances for actions |
| Events panel | `flash monitors show`: each monitor's state, when it changed and when it last alerted; alerts are also logged |
| `glances -w`, exports | Keep Glances |
| The terminal UI | `[popup.glances]` |

```toml
# Glances' default load levels on a 10-core Mac: warning 1 x 10, critical 5 x 10.
[monitors.load]
value = "#{flash.plugin.sysinfo.cpu_load}"
warning = 10
error = 50
message = "Load average high"

[popup.glances]
command = ["glances"]
size = "90%x85%"
persistent = true
```

Glances and Flash coexist well: Glances keeps exports and actions, Flash
shows the figures and the alerts.

*Checked 2026-10-20 against the Glances
[README](https://github.com/nicolargo/glances), and its documentation on
[configuration](https://glances.readthedocs.io/en/latest/config.html),
[actions](https://glances.readthedocs.io/en/latest/aoa/actions.html),
[load](https://glances.readthedocs.io/en/latest/aoa/load.html),
[events](https://glances.readthedocs.io/en/latest/aoa/events.html) and
[sensors](https://glances.readthedocs.io/en/latest/aoa/sensors.html).*
