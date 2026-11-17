# Flash and AlDente

[AlDente](https://apphousekitchen.com/) ("Don't overcook your MacBook
battery") is a "macOS menu bar app to limit the maximum charging percentage
and improve your MacBook's battery lifespan": it holds the battery at a
level you choose while the Mac stays plugged in, and discharges it to that
level on the adapter. It began as an open-source project; its repository now
says "AlDente is no longer open source", and AppHouseKitchen develops it as
proprietary software. The Charge Limiter and Discharge are free; AlDente Pro
(€11.49 a year, €23.99 once, or through Setapp, each licence for up to three
user accounts) adds Heat Protection, Sailing Mode, Top Up, Calibration Mode,
schedules, MagSafe LED control and Apple Shortcuts actions. Version 1.39
(8 September 2026) rebuilt charge control for macOS 27, and 1.39.4 followed
on 23 September; it runs on macOS 12 to 27, on Apple silicon and Intel
MacBooks, and writes its limits to the SMC through a privileged helper.

Flash does not control charging and will not: its `sysinfo` plugin reads
the battery and keeps hardware control out of scope. Nothing on this page
replaces AlDente. It is about what Flash shows and does around it.

| | AlDente | Flash |
| --- | --- | --- |
| License, price | Proprietary; free; Pro €11.49/year or €23.99 once, or Setapp | MIT, free |
| Platforms | macOS 12 to 27; Apple silicon and Intel MacBooks | macOS 13+ |
| Permissions | Your password to install a privileged helper that writes the SMC | Accessibility; the battery needs no other grant |
| Charging | Charge limit and discharge; Pro: heat protection, sailing mode, top up, calibration, schedules, MagSafe LED | None; Flash only reads |
| Battery figures | macOS charge, the hardware percentage in Pro, a live power-flow diagram, apps using significant energy (Pro) | Charge, state, time estimate, health, design and full-charge capacity, condition, cycles, temperature, adapter watts |
| Automation | Pro: Shortcuts actions to set the limit, discharge, top up, calibrate, and read percentage, state or temperature | Mappings and monitors that run any command, Shortcuts included |
| Configuration | Menu-bar popover and dashboard | One TOML file, live reload, `flash config check` |
| Maintenance | 1.39.4, September 2026; four patch releases that month | 1.1.0, October 2026 |

## Where AlDente is stronger

- **It changes what the battery does.** A charge limit, discharge on the
  adapter, a pause when the battery runs hot, a lower bound before charging
  resumes, calibration cycles: all of it is hardware control, and Flash has
  none.
- **Further than macOS's own limit.** Since macOS 26.4, Apple silicon Macs
  have a built-in Charge Limit from 80 % to 100 %. AlDente goes below 80 %,
  works on Intel MacBooks, and adds discharge, heat protection and sailing
  on top.
- **Battery care as a routine.** Pro's schedules run a top-up, a
  calibration or a discharge on an interval and catch up on missed runs,
  with a task history.
- **The power flow diagram** shows where the adapter's watts go, to the Mac
  and to the battery, as it happens.
- **Shortcuts actions** let the rest of macOS drive AlDente.

## Where Flash is stronger

- **The battery's health in one pager.** `:sysinfo power` lists cycles,
  design and full-charge capacity in mAh, the condition macOS reports, the
  health they work out to, the battery temperature and the adapter's watts,
  from the command line or a text popup under the bar.
- **One bar for everything.** The charge sits beside CPU, memory, disks,
  network and the mode you are in, and the same values feed widgets and
  popups.
- **Alerts and reactions.** The low-battery monitor is on by default, any
  value takes a threshold, and an event monitor on `core:power.changed` runs
  a command when you plug in or unplug.
- **Free, open source and helperless**: Flash writes nothing to the SMC,
  so it installs nothing privileged.

## Flash features you might like

- `#{flash.plugin.sysinfo.power_state}` reads `ac` when the battery sits on
  the adapter without charging, which is what AlDente's limit looks like
  from macOS: `#{?#{==:#{flash.plugin.sysinfo.power_state},ac},HELD ,}`
  shows it in the bar.
- A mapping can run a shortcut, so an AlDente Pro action you saved in
  Shortcuts (Top Up before a trip) or macOS 26.4's own Set Battery Charge
  Limit action is a key away; `@shortcuts` in the flashlight finds the rest.
- `#{flash.top_cpu}` in a widget or a text popup for the apps drawing the
  most, and `@processes` to stop one after a confirmation.
- A monitor on `core:clock.minute` with `at` and `days` runs a shortcut at
  set times ([runs and events](../monitors.md#runs-and-events)).

## Moving from AlDente

Keep AlDente for charging. What can move is how you see the battery and
reach AlDente's actions.

| AlDente | Flash |
| --- | --- |
| Charge limit, discharge, heat protection, sailing mode, calibration | Keep AlDente; on Apple silicon, macOS 26.4's Charge Limit if 80 % to 100 % is enough |
| Menu-bar percentage and live status icon | `#{flash.plugin.sysinfo.power_label}` and `power_state` in `[statusbar] template` |
| Hardware battery percentage | Not available: Flash shows the charge macOS reports |
| Power flow | The adapter's watts in `:sysinfo power`; no flow diagram |
| Apps using significant energy | `#{flash.top_cpu}`, `@processes` |
| Shortcuts actions | `["shortcuts", "run", "<your shortcut>"]` on a key, or `@shortcuts` |
| Schedules | Keep AlDente's, or a monitor on `core:clock.minute` running a shortcut |

```toml
[statusbar]
enabled = true
template = "#[align=right]#[label]BAT#[default] #{flash.plugin.sysinfo.power_label} #{?#{==:#{flash.plugin.sysinfo.power_state},ac},HELD ,}%H:%M"

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

# A shortcut you built from AlDente Pro's Top Up action.
[mode.normal.mappings]
"<leader>bt" = ["shortcuts", "run", "AlDente Top Up"]
"<leader>bs" = ["flash", "mode", "flashlight", "--query=@shortcuts"]
```

## Using both

This is the arrangement to aim for: AlDente owns charging, Flash shows the
battery and reaches AlDente's actions from the keyboard. They share no keys
and never touch the same state, since Flash only reads. Expect the charge to
sit still while AlDente holds the limit; that is `ac`, not a fault. AlDente's
menu-bar icon and popover live in the native menu bar, which Flash
auto-hides while its own bar is on; `mouse menubar` puts a label on the icon.

*Checked 2026-10-23 against AlDente's
[README](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring),
[1.39](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/discussions/1814)
and [1.39.4](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/discussions/1836)
release notes, [pricing](https://apphousekitchen.com/pricing/),
[features](https://apphousekitchen.com/aldente-overview/features/) and
[uninstall guide](https://apphousekitchen.com/how-to-uninstall-aldente-pro/),
and Apple's [Charge Limit article](https://support.apple.com/en-us/102338)
with [9to5Mac's coverage of macOS 26.4](https://9to5mac.com/2026/04/03/macos-26-4-adds-three-new-battery-features-on-mac-heres-how-to-use-them/).*
