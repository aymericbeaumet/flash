# Flash and Macs Fan Control

[Macs Fan Control](https://crystalidea.com/macs-fan-control) does what its
tagline says: "Control fans on Apple computers". Each fan runs on Auto, as
macOS sets it, or on a custom rule: a constant speed, or a speed that
follows a temperature sensor you pick. It shows fan speeds and the
temperature sensors in real time, reads S.M.A.R.T. temperatures from
third-party drives, puts a configurable display in the menu bar, and sets
every fan back to Auto when it quits. It is closed-source freeware from
CrystalIDEA, with a one-time Pro licence per computer that adds custom fan
presets. Version 1.5.22 shipped on 13 October 2026 with support for the
newest Mac mini and Mac Studio models; the main build needs macOS 10.13 or
later (a legacy build covers 10.7 to 10.12), runs on Intel and Apple
silicon, and a Windows edition serves Intel Macs under Boot Camp. Fan writes
go through a privileged helper installed as a LaunchDaemon.

Flash reads no fan and no SMC sensor, and its `sysinfo` plugin keeps fan
control out of scope on purpose. If you came here to replace Macs Fan
Control, keep it. This page covers what Flash adds next to it.

| | Macs Fan Control | Flash |
| --- | --- | --- |
| License, price | Closed; free; Pro one-time, per computer | MIT, free |
| Platforms | macOS 10.13+ (legacy build for 10.7 to 10.12), Intel and Apple silicon; Windows under Boot Camp | macOS 13+ |
| Permissions | A privileged helper (`smcwrite` LaunchDaemon) for fan writes | Accessibility; nothing privileged |
| Fans | Read and set: Auto, constant RPM, or a curve on a sensor; saved presets in Pro | None of its own; a fan speed only from a command you run, such as macmon |
| Temperatures | SMC sensors; S.M.A.R.T. temperatures of third-party drives | Battery temperature only |
| What heats the Mac | Not its job | Top processes by CPU and memory, the focused app's process tree |
| Surfaces | Window, configurable menu-bar display | Flash's own bar, desktop widgets, popups |
| Configuration | Window, fan presets | One TOML file, live reload, `flash config check` |
| Maintenance | 1.5.22, 13 October 2026; releases follow new Mac models | 1.1.0, October 2026 |

## Where Macs Fan Control is stronger

- **It drives the fans.** A quieter curve for calls, a cooler one for long
  renders, a fixed speed: Flash cannot write a fan speed and will not.
- **Sensor-based rules.** A fan can follow the one sensor that matters for
  your work, which macOS's own curve does not let you choose.
- **Presets** in Pro switch between Auto and your custom settings at once.
- **The sensors.** SMC temperatures across the machine and drive
  S.M.A.R.T. temperatures, none of which Flash reads.
- **Safe by default.** Quitting returns every fan to Auto, so a forgotten
  custom speed does not outlive the app.
- **Old Macs and Boot Camp.** Its legacy build reaches back to macOS 10.7,
  and it runs under Windows on an Intel Mac; Flash needs macOS 13.

## Where Flash is stronger

- **Why the fans are loud.** Fans spin because something works.
  `#{flash.top_cpu}` lists the busiest processes, `#{flash.focused_app_details}`
  sums the focused app's helpers, and `@processes` stops a runaway after a
  confirmation ([process values](../status-format.md#process-values)).
- **The rest of the machine** in the same bar: CPU, memory, disks,
  network, battery and your own commands.
- **Thresholds and alerts** on any of those values, or on a temperature a
  command prints.
- **Nothing privileged installed**, because Flash changes no hardware.

## Flash features you might like

- A named source running [macmon](https://github.com/vladkens/macmon), a
  sudoless monitor for Apple silicon, puts fan RPM or CPU temperature in the
  bar: its `pipe` output carries `fans[].rpm` and `temp.cpu_temp_avg`.
- A desktop widget of `#{flash.top_cpu}`, so the culprit is on the desktop
  before you open anything.
- `[monitors.<name>]` on `#{flash.plugin.sysinfo.cpu_percent}` warns when the
  CPU load crosses your threshold, the usual cause of a fan ramp.
- `mouse menubar` labels Macs Fan Control's menu-bar display, so switching a
  preset needs no pointer.

## Moving from Macs Fan Control

| Macs Fan Control | Flash |
| --- | --- |
| Custom fan speeds, sensor curves, presets | Keep Macs Fan Control |
| Fan speed in the menu bar | A named source over `macmon pipe` (Apple silicon), shown as `#{flash.source.fan}` |
| Temperatures in the menu bar | The same source reading `.temp.cpu_temp_avg`; [TG Pro's page](tg-pro.md#moving-from-tg-pro) adds a temperature monitor |
| Drive S.M.A.R.T. temperatures | Keep Macs Fan Control |
| Finding what heats the Mac | `#{flash.top_cpu}` in a widget or popup, `@processes` |
| Opening its window | `["flash", "app", "open", "--name=Macs Fan Control"]` on a key |

```toml
# macmon and jq are yours to install; Flash only runs them.
# Fanless Macs report no fans, and the segment stays empty.
[statusbar.sources.fan]
command = ["/bin/sh", "-c", "macmon pipe -s 1 | jq '.fans[0].rpm // empty'"]
interval = 10

[statusbar]
enabled = true
template = "#[align=right]#[label]FAN#[default] #{flash.source.fan} #[label]CPU#[default] #{p-3:flash.plugin.sysinfo.cpu_label} %H:%M"

[widgets.heat]
anchor = "bottom_right"
template = """
Busiest now
#{flash.top_cpu}
"""

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>fc" = ["flash", "app", "open", "--name=Macs Fan Control"]
```

## Using both

Run both: Macs Fan Control owns the fans, Flash and macmon only read. They
share no keys. Macs Fan Control's display sits in the native menu bar, which
Flash auto-hides while its own bar is on; reach it at the top edge or with
`mouse menubar`, or keep Flash's bar off and use Flash for hints, widgets
and alerts alone.

*Checked 2026-10-23 against the
[Macs Fan Control page](https://crystalidea.com/macs-fan-control), its
[release notes](https://crystalidea.com/macs-fan-control/release-notes),
[supported systems](https://crystalidea.com/macs-fan-control/supported-operating-systems),
[purchase terms](https://crystalidea.com/macs-fan-control/buy) and
[uninstall notes](https://crystalidea.com/uninstall), and the
[macmon README](https://github.com/vladkens/macmon).*
