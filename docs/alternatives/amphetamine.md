# Flash and Amphetamine

[Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704) is a
"Powerful keep-awake utility" by William Gustafson, and the most complete one
on the Mac: sessions that last indefinitely, for a time, until a set time,
while a file downloads or while an app runs, and fifteen trigger conditions
that start and end sessions on their own, from a connected display or
Bluetooth device to a Wi-Fi network, a VPN, the CPU load or idle time. It
can keep a closed MacBook awake, keep drives spinning (Drive Alive), move the
pointer, let the display sleep while the Mac stays up, and speaks
AppleScript. It is closed source and free on the Mac App Store, with no
in-app purchases and no paid tier. Version 5.3.2, from November 2023,
is the latest in its version history; the listing gives macOS 10.13 or later.

Flash's part is smaller: `caffeinate on`, `off` and `toggle`, optionally for
`--minutes`, a `#{flash.caffeinate}` value for the bar, and event monitors
you can turn into triggers.

| | Amphetamine | Flash |
| --- | --- | --- |
| License, price | Closed; free, no in-app purchases | MIT, free |
| Platforms | macOS 10.13+, per its App Store listing | macOS 13+ |
| Permissions | Not stated on its listing; closed-lid sessions on Apple silicon use an optional script, Power Protect | Accessibility; nothing more to keep the Mac awake |
| Sessions | Indefinite, for a duration, until a time, while a file downloads, while an app runs; extend a running one | `caffeinate on`, for `--minutes=<n>` or until `caffeinate off` |
| Triggers | Fifteen built in, combined in its window | [Event and value monitors](../monitors.md#runs-and-events) that run `caffeinate on` and `off` |
| What stays awake | The system, and the display unless you let it sleep; the screen saver if allowed; a closed lid; drives | The system, idle sleep, the disk and the display, as `caffeinate -dimsu`; no closed-lid mode |
| Status | Its menu-bar icon, time remaining in the menu | `#{flash.caffeinate}` is `on` while held; no time remaining |
| Configuration | Preferences window, hot keys, AppleScript | One TOML file, live reload, `flash config check`; `flash caffeinate …` from a shell |
| Maintenance | 5.3.2, November 2023 | 1.1.0, October 2026 |

## Where Amphetamine is stronger

- **Triggers without writing anything.** Pick a condition in a window and it
  starts the session while it holds and ends it when it stops. In Flash each
  condition is a monitor, some of them with a short script, and a threshold
  monitor fires on the rise only: "CPU above 50 %" can start a hold, but
  nothing ends it when the load drops, so pair it with `--minutes`.
- **Conditions Flash cannot see.** Bluetooth devices, headphones or another
  audio output, a mirrored display, Cisco AnyConnect, and a download that
  finishes. Flash has no event for any of them.
- **Closed-Display Mode.** A MacBook stays awake with its lid shut. Flash's
  hold does nothing for a closed lid.
- **Finer control over what sleeps.** Let the display sleep or the screen
  saver run while the Mac stays awake, keep external drives spinning, move
  the pointer periodically, lock the screen after a while. Flash's hold always
  keeps the display on too.
- **Sessions you can see and stretch.** The time remaining in the menu and
  extending a session in place; Flash only says `on`.

## Where Flash is stronger

- **A trigger can be anything Flash can read.** A named source that prints
  a number from any command (a build queue, a render's progress) is a monitor
  value like the battery, so "stay awake while my jobs run" is three lines.
- **A trigger can do more than keep awake.** A monitor's `run` takes a list,
  so launching Zoom can keep the Mac awake and set the output device in one
  go; a time-of-day monitor with `days` ends every hold at 19:00 on weekdays.
- **The command line.** `flash caffeinate on --minutes=90` before a long job
  in a shell script, `flash caffeinate status` to check, no AppleScript.
- **Open source, and updated.** You can read how the hold works and follow
  its changes; Amphetamine's latest version is 5.3.2, from November 2023.

## Flash features you might like

- `#{?flash.caffeinate,#[label]AWAKE#[default] ,}` in the bar, and a
  `#[range=user|<name>]` span with a `[statusbar.click]` action that toggles
  it, as a click on Amphetamine's menu-bar icon does.
- An away monitor (`event = "core:user.idle"`, `idle = 600`) that pauses the
  music and runs `screen lock`, Amphetamine's lock after inactivity
  ([runs and events](../monitors.md#runs-and-events)).
- `display sleep`, `system sleep`, `screensaver start` and `screen lock` on
  keys, from the same file ([system and processes](../commands.md#system-and-processes)).
- The built-in battery monitor already warns at 20 %; its `run` ends a hold
  there, Amphetamine's "Auto-end session if battery is low".

## Moving from Amphetamine

| Amphetamine | Flash |
| --- | --- |
| Start a session, indefinitely | `caffeinate on` |
| For two hours | `caffeinate on --minutes=120` |
| Until a set time | `caffeinate on`, and a `core:clock.minute` monitor `at` that time running `caffeinate off` |
| End a session | `caffeinate off`; quitting Flash ends it too |
| Hot keys | `caffeinate toggle` on a chord in `[mode.all.mappings]` |
| While an app is running | `core:apps.launched` and `core:apps.terminated` monitors with `app = "<bundle id>"` |
| While an app is frontmost | A `core:focus.changed` monitor whose script reads `FLASH_EVENT_BUNDLE_ID` |
| External display | A `core:displays.changed` monitor whose script counts `FLASH_EVENT_DISPLAYS` |
| USB device | `core:usb.attached` and `core:usb.detached`; `FLASH_EVENT_NAME` names the device |
| Power adapter, charging | A monitor on `#{flash.plugin.sysinfo.power_state}` without thresholds: its `run` gets `FLASH_VALUE` (`charging`, `discharging`, `charged`, `ac`) on every change |
| Battery low | `run = ["flash", "caffeinate", "off"]` on the built-in `[monitors.battery]` |
| Wi-Fi network, IP address, DNS servers | A `core:network.changed` monitor whose script checks the network |
| A drive or volume mounted | `core:volumes.changed` |
| CPU above a threshold | A monitor on `#{flash.plugin.sysinfo.cpu_percent}` with `warning` and `alert = false`, running a bounded hold |
| Idle above a threshold | `core:user.idle` with `idle = <seconds>`, and `core:user.active` on the way back |
| Lock the screen after inactivity | `core:user.idle` running `screen lock` |
| Bluetooth, headphones, mirroring, VPN, a downloading file | Not available |
| Closed-Display Mode, Drive Alive, mouse movement, allowing display sleep | Not available |

```toml
[mode.all.mappings]
"cmd+ctrl+a" = ["flash", "caffeinate", "toggle"]
"cmd+ctrl+shift+a" = ["flash", "caffeinate", "toggle", "--minutes=120"]

# While Xcode runs.
[monitors.xcode_awake]
event = "core:apps.launched"
app = "com.apple.dt.Xcode"
run = ["flash", "caffeinate", "on"]

[monitors.xcode_sleep]
event = "core:apps.terminated"
app = "com.apple.dt.Xcode"
run = ["flash", "caffeinate", "off"]

# A busy CPU keeps the Mac awake for half an hour from the rise.
[monitors.busy]
value = "#{flash.plugin.sysinfo.cpu_percent}"
warning = 70
alert = false
run = ["flash", "caffeinate", "on", "--minutes=30"]

# End any hold when the battery runs low (the built-in monitor rises at 20 %).
[monitors.battery]
run = ["flash", "caffeinate", "off"]

# And every evening on weekdays.
[monitors.evening]
event = "core:clock.minute"
at = "19:00"
days = ["mon", "tue", "wed", "thu", "fri"]
run = ["flash", "caffeinate", "off"]
```

App events fire on a launch or a quit, so an app already running when Flash
starts keeps the Mac awake only from its next launch.

## Using both

Each app holds its own power assertion, and macOS stays awake while any
holds one, so the two never fight: Flash's `caffeinate off` does not end an
Amphetamine session, nor the other way round. Give each condition to one of
them, so a session does not outlive the trigger you were watching.

A natural split: keep Amphetamine for a closed lid, Bluetooth and headphone
triggers, and display sleep; let Flash hold the Mac awake from your keys,
scripts and monitors. While Flash's status bar is on, the native menu bar
auto-hides and Amphetamine's icon with it; `mouse menubar` labels it when you
need its menu. In NORMAL, Flash swallows every chord it has not mapped, so use
Amphetamine's hot keys from INSERT, or bind `caffeinate toggle` instead.

*Checked 2026-10-23 against Amphetamine's
[App Store listing](https://apps.apple.com/us/app/amphetamine/id937984704),
its description and version history.*
