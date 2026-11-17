# Flash and TG Pro

[TG Pro](https://www.tunabellysoftware.com/tgpro/) says "Know your Mac's
temperature. Take control of its cooling.": temperatures for every sensor,
fan control with Auto Boost rules, drive S.M.A.R.T. and battery health,
diagnostics and alerts. It is closed source, $10 one-time for up to three
personal Macs (its user guide describes a free version with everything but
hardware diagnostics), native on Intel and Apple silicon, macOS 10.14 to 27.
Version 2.104 shipped in September 2026 with support for the newest Macs; it
is updated several times a year. It covers exactly what Flash leaves out.

| | TG Pro | Flash |
| --- | --- | --- |
| License, price | Closed; $10 one-time | MIT, free |
| Metrics | Temperatures (CPU per core, GPU, drives, battery, memory, power, Thunderbolt ports), fans, drive S.M.A.R.T., battery health and cycles, last shutdown reason | CPU and GPU use, load, memory, disk space and I/O, default-route network, battery and its health, top processes, any command's output |
| Fans | Read and control: Auto Boost rules per sensor, AC and battery rule sets, manual and maximum modes | None |
| History | Highest temperature per sensor; CSV logs of every update | 20-sample charts per plugin; a named source keeps up to 512 numbers |
| Alerts | Temperature limits on any sensor or the highest CPU reading, Auto Boost changes, abnormal shutdowns, battery service; Notification Center, optional sound, e-mail | `[monitors.<name>]` warning and error thresholds on any numeric value; Flash's centred alert |
| Surfaces | Menu-bar item with stacked values, a main window | Flash's own bar, desktop widgets, popups |
| Keyboard | Global hotkeys for the window and the menu | Hints on bar segments, popups and details by mapping |
| Helpers | A service that applies fan changes and checks they come from TG Pro | None |
| Maintenance | 2.104, September 2026; active | 1.1.0, October 2026 |

## Where TG Pro is stronger

- **Everything thermal.** Temperatures across the machine, fan control
  with rules, and diagnostics. Flash reads no SMC sensor and will not drive a
  fan; its status plugins keep both out of scope on purpose.
- **Alerts that reach you away from the Mac**, by e-mail, plus sound and
  Notification Center. Flash's alert is a centred overlay on the Mac's own
  screen.
- **Hardware events** such as an abnormal shutdown or a battery that needs
  service, which no Flash value describes.
- **Logs** of every reading, with over-threshold rows marked, for later
  analysis.

## Where Flash is stronger

- **Everything that is not a temperature.** CPU, memory, disk, network,
  battery, processes and your own commands, each with a threshold.
- **Free and open source**, configured in one file with the bar, widgets
  and popups.
- **No helper service.** Flash changes no hardware state, so it installs
  nothing to do it.

## Flash features you might like

- `#{flash.plugin.sysinfo.power_details}` in a text popup: charge, health, cycles,
  design and full-charge capacity, battery temperature and adapter power.
- `#{flash.focused_app_details}` to see which app is heating the Mac
  ([process values](../status-format.md#process-values)).
- btop in a terminal popup, which also shows CPU temperature.

## Moving from TG Pro

Most TG Pro users should keep it: Flash has no replacement for fan control or
SMC sensors. What moves is the bar and the non-thermal alerts.

| TG Pro | Flash |
| --- | --- |
| Menu-bar temperatures | Keep TG Pro; or a named source running a sensor CLI such as [macmon](https://github.com/vladkens/macmon) |
| Fan control, Auto Boost | Keep TG Pro |
| Temperature notification | A `[monitors.<name>]` over that named source |
| Battery health | `:sysinfo power`, `#{flash.plugin.sysinfo.power_details}` |
| Abnormal shutdown, battery service alerts | Keep TG Pro |
| CSV logging | Keep TG Pro |

```toml
[statusbar.sources.cpu_temp]
command = ["/bin/sh", "-c", "macmon pipe -s 1 | jq '.temp.cpu_temp_avg | floor'"]
interval = 30

[monitors.cpu_temp]
value = "#{flash.source.cpu_temp} °C"
warning = 90
error = 100
message = "CPU hot"
```

`macmon` (Apple silicon only) and `jq` are yours to install; Flash only
runs them. TG Pro's items sit in the native menu bar, which Flash hides
while its own bar is on and reaches with `mouse menubar`.

*Checked 2026-10-20 against the
[TG Pro page](https://www.tunabellysoftware.com/tgpro/), its
[release notes](https://www.tunabellysoftware.com/tgpro/releasenotes/) and
[user guide](https://www.tunabellysoftware.com/support/tgpro_tutorial/), and
the [macmon README](https://github.com/vladkens/macmon).*
