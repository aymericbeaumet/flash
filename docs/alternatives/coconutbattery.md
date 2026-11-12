# Flash and coconutBattery

[coconutBattery](https://www.coconut-flavour.com/coconutbattery/) calls
itself "The standard for battery reading since 2005", and twenty years on it
is still the first thing many Mac owners install to see how a battery is
ageing: current charge, full-charge against design capacity, cycle count,
battery temperature and the age of the Mac, for the Mac itself and for an
iPhone or iPad plugged in over USB. It is closed-source freeware from
coconut-flavour.com, sold only from its own site; version 4.4 shipped on
9 September 2026 with support for macOS, iOS and iPadOS 27, and it needs
macOS 12 or later. coconutBattery Plus, a one-time purchase (a Standard
licence with updates for 4.x, or a Lifetime licence with every future Plus
update, both for unlimited devices), adds notifications, Wi-Fi readings of
iPhones and iPads, a Battery Lifetime Analyzer, an Advanced Viewer with SSD
statistics and custom print templates; a trial runs ten launches in Plus mode.

Flash reads the Mac's battery from IOKit too, through its `sysinfo` status
plugin: the battery's own registry entry for capacities, cycles and
temperature. What differs is what each does with the figures: coconutBattery
is a battery instrument,
Flash puts the figures in its bar, widgets and popups and raises an alert
when the charge runs low.

| | coconutBattery | Flash |
| --- | --- | --- |
| License, price | Closed; free, Plus one-time (Standard or Lifetime licence) | MIT, free |
| Platforms | macOS 12+; reads iPhone and iPad batteries | macOS 13+ |
| Permissions | None documented; Plus pairs the Mac with iPhones and iPads over Wi-Fi | Accessibility; the battery needs no other grant; Notifications only for a monitor with `notify = true` |
| Battery figures | Charge, full-charge and design capacity, cycle count, temperature, the Mac's age; in Plus, lifetime ranges of temperature, voltage and charge rate, and operating time | Charge, state, source, time estimate, health (full-charge over design capacity), both capacities in mAh, condition, cycles, temperature, adapter watts |
| Other devices | iPhone and iPad over USB; over Wi-Fi in Plus | None |
| History | Saved health readings in a History Viewer | A 20-sample charge sparkline in the details; no stored readings |
| Alerts | Plus: Mac below a percentage or a remaining time, iPhone or iPad below a threshold | The built-in `battery` monitor (below 20 % and 10 %), any threshold you write; the centred alert, Notification Center with `notify = true` |
| Surfaces | Window, menu bar | Flash's own bar, desktop widgets, text popups |
| Configuration | Preferences window | One TOML file, live reload, `flash config check` |
| Maintenance | 4.4, September 2026; updated for every macOS | 1.1.0, October 2026 |

## Where coconutBattery is stronger

- **Your other devices.** An iPhone or iPad on the cable shows the same
  health readout as the Mac, and Plus reads them over Wi-Fi and warns when
  one runs low. Flash only knows the battery inside the Mac it runs on.
- **Health over time.** coconutBattery saves readings, so the History
  Viewer shows the capacity fading month after month. Flash shows the battery
  as it is now; its sparkline is the last twenty charge samples and is gone
  when the plugin restarts.
- **The battery's lifetime log.** Plus's Lifetime Analyzer reads the
  minimum, maximum and average temperature, voltage and charge and discharge
  rates the battery has recorded, and its operating time. Flash has nothing
  like it.
- **SSD statistics.** The Advanced Viewer shows data read and written by the
  internal SSD; Flash's disk figures are free space and live I/O rates.
- **A remaining-time alert.** Plus can warn when the time left drops below a
  value. Flash shows the estimate in `:sysinfo power` but publishes no number
  a monitor could read, so its alerts are on the percentage.
- **Printable reports** with your own HTML templates, and a readout people
  have trusted when buying or selling a used Mac for two decades.

## Where Flash is stronger

- **The charge sits with everything else.** One bar shows battery, CPU,
  memory, disk, network, the mode you are in and your own commands, and the
  same values feed desktop widgets and popups, from one file.
- **Alerts at no cost, on any value.** The low-battery monitor is on by
  default; retune it, add your own on any figure, post it to Notification
  Center, or make it run a command, which coconutBattery's notifications do
  not.
- **Reacting to power changes.** An event monitor on `core:power.changed`
  runs a command when you plug in or unplug.
- **Keyboard reach.** `:sysinfo power` opens the details from the command
  line, and every bar segment takes a hint.
- **Free and open source**, with the battery read by a sandboxed plugin
  that spawns no process ([status plugins](../status-plugins.md)).

## Flash features you might like

- `:sysinfo power`: charge, state, source, estimate, health, design and
  full-charge capacity in mAh, condition, cycles, temperature, adapter watts
  and a charge sparkline, in a pager.
- `#{flash.plugin.sysinfo.power_label}` for the bar, and the raw
  `power_percent` and `power_state` values for meters and conditionals
  ([raw numeric segments](../status-plugins.md#raw-numeric-segments)).
- A desktop widget with a charge meter,
  `#[meter=20]#{flash.plugin.sysinfo.power_percent}#[nometer]`
  ([widgets](../widgets.md)).
- `[monitors.battery]` to move the thresholds, and `notify = true` to keep a
  Notification Center entry ([monitors](../monitors.md#built-in-monitors)).

## Moving from coconutBattery

| coconutBattery | Flash |
| --- | --- |
| The main window: charge, capacities, cycles, temperature | `:sysinfo power`, or a text popup of `#{flash.plugin.sysinfo.power_details}` |
| Mac battery details in the menu bar | `#{flash.plugin.sysinfo.power_label}` in `[statusbar] template` |
| Plus notification below a percentage | The built-in `battery` monitor: `warning`, `error`, and `notify = true` for Notification Center |
| Plus notification on remaining time | Not available |
| iPhone and iPad batteries, over USB or Wi-Fi | Keep coconutBattery |
| History Viewer, Lifetime Analyzer | Keep coconutBattery |
| Advanced Viewer SSD statistics | Keep coconutBattery; `:sysinfo disks` shows space and I/O only |
| Printed reports | Keep coconutBattery |

```toml
# Warn at 25 % instead of 20 %, and leave a Notification Center entry.
[monitors.battery]
warning = 25
notify = true

[popup.battery]
text = "#{flash.plugin.sysinfo.power_details}"

[statusbar]
enabled = true
template = "#[align=right]#[popup=battery]#[label]BAT#[default] #{flash.plugin.sysinfo.power_label}#[nopopup] %H:%M"

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>bb" = ["flash", "mode", "terminal", "--name=battery"]
```

Hovering the `BAT` segment shows the details under it; `\bb` in NORMAL
opens them in the middle of the screen.

## Using both

Nothing conflicts: both only read the battery, and coconutBattery binds no
keys Flash wants. Keep coconutBattery for the health history and your iPhone
and iPad, and let Flash carry the charge in its bar. If Plus notifications
are on, pick one low-battery warning: `[monitors.battery] enabled = false`
silences Flash's. coconutBattery's menu-bar item lives in the native menu
bar, which Flash auto-hides while its own bar is on; `mouse menubar` labels
it, and `["flash", "app", "open", "--name=coconutBattery"]` on a key opens
its window.

*Checked 2026-10-23 against the
[coconutBattery page](https://www.coconut-flavour.com/coconutbattery/) (its
edition comparison, FAQ and 4.4 release notes) and the field descriptions on
[TechSpot](https://www.techspot.com/downloads/6461-coconutbattery.html).*
