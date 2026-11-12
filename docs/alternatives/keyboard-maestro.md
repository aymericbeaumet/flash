# Flash and Keyboard Maestro

[Keyboard Maestro](https://www.keyboardmaestro.com) invites you to "Conduct
your Mac Like a Pro!": macros assembled from "Hundreds of Built-In Actions",
with conditions, loops and variables, fired by any of 39 kinds of trigger,
from a hot key or a typed string to the time of day, an app launching, a USB
device, a Wi-Fi network or a MIDI note. It is closed source from Stairways
Software, $36 once ($25 to upgrade), with a free trial, for macOS 10.13 or
later and outside the Mac App Store. 11.1 added OCR in more languages in July
2026 and 11.1.1 followed on 30 July 2026.

Keyboard Maestro is an automation language; Flash is a keyboard layer. They
meet on hot keys and on a handful of event triggers, and the rest of each is
its own. Many people will keep both.

| | Keyboard Maestro | Flash |
| --- | --- | --- |
| License, price | Closed; $36 once, $25 upgrade; free trial | MIT, free |
| Platforms | macOS 10.13+, Intel and Apple silicon | macOS 13+ |
| Permissions | Accessibility and Input Monitoring, for the editor and the Engine | Accessibility; Calendars, Automation or Notifications only for the features that ask ([privacy](../privacy.md)) |
| Triggers | 39 kinds: hot keys (pressed, released, held, tapped twice or more), typed strings, time of day, cron, periodic, idle, application, focused window, USB device and its keys, Wi-Fi network, mounted volume, power, sleep, wake, unlock, display layout, Space, appearance, clipboard, folder, MIDI, gestures, palettes, status menus, URL, scripts, web server, remote | Keys and sequences per mode and per app; event monitors on apps, focus, windows, displays, Spaces, sleep and wake, lock, idle, USB, network, volumes, power and times of day |
| Actions | Hundreds, with conditions, loops, variables, prompts, image and OCR searches, clipboard history and filters, scripts | Flash's commands: hints, the mouse grid, windows, tabs, apps, the flashlight, alerts, notifications; any argv |
| Configuration | The Keyboard Maestro editor | One TOML file, live reload, `flash config check` |
| Maintenance | 11.1.1, July 2026; active | 1.1.0, October 2026 |

## Where Keyboard Maestro is stronger

- **It is a programming language.** If, while and for each, pauses until a
  window or an image appears, variables, prompts, calculations, and an editor
  that shows the whole macro. Flash runs one command per key; any logic lives
  in a script you write.
- **Triggers Flash does not have.** Typed strings, the clipboard changing, a
  folder changing, MIDI, the keys of one USB device, cron and periodic
  schedules, gestures, a URL, a web server, another Mac. A hot key that fires
  on release, on a long press, or on two or three taps has no Flash
  equivalent either.
- **Text and the clipboard as material.** Text expansion, named clipboards,
  clipboard filters. Flash keeps a clipboard history and registers, expands
  no text, and runs nothing when you copy.
- **It reads the screen.** Found-image and OCR actions click and branch on
  what is drawn. Flash reads no pixels, by design: an app with no
  Accessibility tree gets the mouse grid.
- **Older Macs.** macOS 10.13 onwards.

## Where Flash is stronger

- **A keyboard that stays modal.** NORMAL holds the keyboard across every
  app until you enter INSERT, so plain letters, sequences and counts run
  commands, and keys you did not map are swallowed rather than typed. A
  Keyboard Maestro group toggled on is the closest thing, but every key in
  it is a hot key you defined, and the rest still type.
- **Clicking without coordinates.** Labelled hints on every element the
  Accessibility tree exposes, in any app, plus the grid and bisect. A macro
  presses a button it names or clicks a position or a found image.
- **Commands that resolve per app.** `tab next`, `app find` and `app save`
  reach each app through its plugin bindings, so one key works in a browser,
  Finder or tmux. A macro sends the keystroke or menu item you recorded for
  each app.
- **A text file.** Diffable, in your dotfiles, validated offline by
  `flash config check`. Keyboard Maestro's macros live in its editor.
- **Free and open source**, with a status bar, widgets and popups for what
  your automations report.

## Flash features you might like

- [Event monitors](../monitors.md#runs-and-events): `[monitors.<name>]` with
  `event`, `app`, `at`, `days` and `idle`, and a `run` that is one command
  or a list run in order. `message` raises Flash's alert and `notify = true`
  also leaves a macOS notification.
- `menu choose` is Prompt With List for shell scripts: lines in, the pick
  out, Escape exits 1 ([pick from a list](../flashlight.md#pick-from-a-list)).
- `alert show`, `alert confirm` and `notify send` for Display Text, a
  confirmation and a Notification
  ([notifications](../commands.md#notifications-logs-and-metrics)).
- NORMAL's `q{x}` … `q` records the Flash commands you run and `@{x}` replays
  them; the macros last until Flash quits
  ([repeat and macros](../normal-mode.md#repeat-and-macros)).
- `window switch` and `app switch` for the window and application switchers;
  `@menus` in the flashlight searches and presses the frontmost app's menu
  items; `@shortcuts` runs a Shortcuts shortcut.

## Moving from Keyboard Maestro

Move the hot keys and the simple event macros; keep the rest.

| Keyboard Maestro | Flash |
| --- | --- |
| Hot Key trigger, "is pressed" | A chord in `[mode.all.mappings]` |
| "is released", "is long pressed", "is tapped twice" | Not available; a NORMAL sequence (`gg`) is the closest |
| Group "Available in the following applications" | `[mode.apps."<bundle id>".all.mappings]` |
| Group "Activated for one action when" | A layer with `sticky = false` |
| Group "Activated/deactivated when" | A layer, sticky by default; Escape leaves it |
| Time of Day trigger | A monitor on `core:clock.minute` with `at` and `days` |
| Application trigger (launches, quits, activates) | `core:apps.launched`, `core:apps.terminated`, `core:focus.changed`, with `app = "<bundle id>"` |
| Focused Window trigger | `core:window.focus.changed` |
| Idle trigger | `core:user.idle` with `idle = <seconds>`, and `core:user.active` |
| USB Device trigger | `core:usb.attached`, `core:usb.detached`; `FLASH_EVENT_NAME` names the device |
| Wireless Network trigger | `core:network.changed`; for one network, a value monitor on a source that prints its name, whose `run` fires on every change |
| Mounted Volume, Power Status, Wake, Sleep, Unlock | `core:volumes.changed`, `core:power.changed`, `core:system.woke`, `core:system.slept`, `core:screen.unlocked` |
| Display Layout Changed, Space Changed | `core:displays.changed`, `core:space.changed` |
| Typed String, Clipboard Changed, Folder, MIDI, Cron, Periodic | Not available |
| Type a Keystroke | `key send --keys=cmd+shift+t`; `key sequence` for several |
| Activate a Specific Application | `app open --name=…` |
| Select or Show a Menu Item | `@menus` in the flashlight |
| Manipulate a Window (move, resize) | `window move --position=lefthalf`, or `--x`, `--y`, `--width`, `--height` in percent |
| Prompt With List | `menu choose` in a script |
| Display Text, Notification | `alert show --message=…`, `notify send --title=…` |
| Execute a Shell Script | The argv itself as the mapping or the monitor's `run` |
| Found Image, OCR | Not available |

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]                       # turns the modes on
"cmd+ctrl+alt+m" = ["flash", "mode", "layer", "--name=macros"]   # a group "activated for one action"
"cmd+ctrl+alt+k" = ["open", "kmtrigger://macro=Arrange%20Desk"]  # a Keyboard Maestro macro with a URL trigger

[mode.layers.macros]
label = "MACROS"
sticky = false

[mode.layers.macros.mappings]
"m" = ["flash", "app", "open", "--name=Mail"]
"d" = ["open", "~/Downloads"]
"w" = ["flash", "window", "switch"]
"s" = ["flash", "mode", "flashlight", "--query=@shortcuts"]

# Time of Day trigger, weekdays: a notification, then join the meeting
[monitors.standup]
event = "core:clock.minute"
at = "09:58"
days = ["mon", "tue", "wed", "thu", "fri"]
message = "Standup in two minutes"
notify = true
run = ["flash", "calendar", "join"]

# Idle trigger, and coming back
[monitors.away]
event = ["core:user.idle", "core:user.active"]
idle = 600
run = ["~/bin/away"]

# USB Device trigger
[monitors.desk]
event = "core:usb.attached"
run = ["~/bin/arrange-desk"]
```

`calendar join` asks for Calendars access the first time, and `notify = true`
for Notifications.

## Using both

The two call each other, so each can keep what it does best.

- Flash runs a macro through its URL trigger: `["open",
  "kmtrigger://macro=<name>"]` on a key or in a monitor's `run`, as above.
- A macro runs Flash through Execute a Shell Script. Its shell has only the
  system `PATH`, so give the full path: `/Applications/Flash.app/Contents/MacOS/flash mouse target`.
- Give each hot key one owner; `flash resident doctor` lists the chords
  another app holds.
- Keep typed-string triggers for what you type in INSERT. In NORMAL plain
  keys are commands, not text.
- Monitors and macros watching the same event both run. Move a trigger
  rather than copy it.

*Checked 2026-10-23 against [keyboardmaestro.com](https://www.keyboardmaestro.com/main/),
its [features](https://www.keyboardmaestro.com/main/features.html) page, the
wiki's [triggers](https://wiki.keyboardmaestro.com/Triggers),
[Hot Key trigger](https://wiki.keyboardmaestro.com/trigger/Hot_Key),
[URL trigger](https://wiki.keyboardmaestro.com/trigger/URL),
[macro groups](https://wiki.keyboardmaestro.com/manual/Macro_Groups),
[shell script action](https://wiki.keyboardmaestro.com/action/Execute_a_Shell_Script)
and [permissions](https://wiki.keyboardmaestro.com/assistance/Accessibility_Permission_Problem)
pages, the [11.1.1 announcement](https://forum.keyboardmaestro.com/t/keyboard-maestro-11-1-1/51789)
and the [11.1 press release](https://www.stairways.com/press/2026-07-21).*
