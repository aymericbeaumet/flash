# Flash and KeepingYouAwake

[KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) "Prevents
your Mac from going to sleep", and does little else on purpose: click its
menu-bar cup to keep the Mac awake indefinitely, or pick a duration from its
menu. Marcel Dierkes started it in 2014 as a successor to Caffeine, and it is
a thin wrapper around Apple's own `caffeinate` tool. It is MIT, about 7,000
stars, installed from its releases or with `brew install --cask
keepingyouawake`. 1.6.8 (September 2025) runs on macOS 10.13 and later;
commits continue into August 2026, and the changelog's next version raises
the floor to macOS 12.

Flash's `caffeinate` commands do the same job from a key, the command line or
a monitor, and `#{flash.caffeinate}` shows it in Flash's bar.

| | KeepingYouAwake | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 10.13+ (1.6.8) | macOS 13+ |
| Permissions | None documented | Accessibility; nothing more to keep the Mac awake |
| How | Runs Apple's `caffeinate` | Power assertions in the resident, as `caffeinate -dimsu` |
| Durations | Indefinite, or preset durations you customise; a default for a click | `--minutes=<n>` on `caffeinate on` or `toggle`, or until `caffeinate off` |
| Automatic | Activate at launch or when an external display connects; deactivate below a battery level or in Low Power Mode | Monitors on any event or value Flash has: displays, battery, apps, idle, times of day |
| Display | Can allow the display to sleep | Keeps it awake |
| Scripting | `open -g "keepingyouawake:///activate?minutes=5"`, `deactivate`, `toggle` | `flash caffeinate on --minutes=5`, `off`, `toggle`, `status` |
| Configuration | Settings window | One TOML file, live reload, `flash config check` |
| Maintenance | 1.6.8, September 2025; commits in August 2026 | 1.1.0, October 2026 |

## Where KeepingYouAwake is stronger

- **One click and done.** The cup is the whole interface: click to keep the
  Mac awake, click again to let it sleep, and the icon says which. Flash needs
  a mapping or a bar segment you write first.
- **Display sleep, your choice.** An advanced setting keeps the Mac awake but
  lets the screen go dark. Flash's hold always keeps the display on.
- **Low Power Mode.** It stands down when the Mac enters Low Power Mode; Flash
  has no Low Power Mode event.
- **Nothing else to adopt.** A menu-bar app with a settings window; it asks
  you to learn nothing and changes nothing else about your Mac.
- **Older Macs.** 1.6.8 runs back to High Sierra.

## Where Flash is stronger

- **A command, not only a click.** `caffeinate toggle --minutes=60` on a
  chord in every mode, `:caffeinate on` in the command line, and `flash
  caffeinate status` printing the state for a script, where KeepingYouAwake's
  URL scheme can set the state but not report it.
- **Any trigger.** KeepingYouAwake starts on its own at launch or with an
  external display, and stops at a battery level or in Low Power Mode.
  Flash's monitors start or stop a hold on app launches, a USB device, idle
  time, a time of day, the battery, or any number a command prints.
- **The state in your bar.** `#{flash.caffeinate}` sits beside the clock and
  the battery in one template, and a click on it can toggle the hold.
- **No extra process.** The hold belongs to the resident Flash already runs.

## Flash features you might like

- `#[range=user|awake]…#[norange]` around the segment, with
  `awake = ["flash", "caffeinate", "toggle"]` in `[statusbar.click]`, for the
  cup's click.
- A `core:user.idle` monitor that runs `screen lock` when you walk away
  ([runs and events](../monitors.md#runs-and-events)).
- `display sleep` on a key, to darken the screens at once without locking.

## Moving from KeepingYouAwake

| KeepingYouAwake | Flash |
| --- | --- |
| Click the cup | `caffeinate toggle`, on a key or a bar click |
| Activate for a duration | `caffeinate on --minutes=<n>` |
| Default duration for a click | The `--minutes` you put in that mapping |
| The cup shows the state | `#{?flash.caffeinate,…,…}` in `[statusbar] template` |
| `keepingyouawake:///activate?minutes=5` | `flash caffeinate on --minutes=5` |
| `keepingyouawake:///deactivate`, `toggle` | `flash caffeinate off`, `flash caffeinate toggle` |
| Deactivate below a battery level | `run = ["flash", "caffeinate", "off"]` on the built-in `[monitors.battery]`; `warning` sets the level |
| Activate when an external display is connected | A `core:displays.changed` monitor and a short script, below |
| Activate at launch | No direct equivalent: `core:config.changed` fires at launch, but also on every save |
| Allow display sleep | Not available |
| Deactivate in Low Power Mode | Not available |
| Quit when the duration is over | Nothing to quit: the hold ends with its `--minutes` |

```toml
[statusbar]
enabled = true
template = "#[align=right]#[range=user|awake]#{?flash.caffeinate,#[label]AWAKE#[default],zz}#[norange] %H:%M"

[statusbar.click]
awake = ["flash", "caffeinate", "toggle"]

[mode.all.mappings]
"cmd+ctrl+k" = ["flash", "caffeinate", "toggle", "--minutes=60"]

# Let the Mac sleep again when the battery reaches 25 %; this also moves the
# built-in low-battery alert from 20 % to 25 %.
[monitors.battery]
warning = 25
run = ["flash", "caffeinate", "off"]

# Stay awake while an external display is connected.
[monitors.external_display]
event = "core:displays.changed"
run = ["~/bin/awake-with-display"]
```

`~/bin/awake-with-display`, made executable:

```sh
#!/bin/sh
# FLASH_EVENT_DISPLAYS lists every connected display, one per line.
if [ "$(printf '%s\n' "$FLASH_EVENT_DISPLAYS" | grep -c .)" -gt 1 ]; then
  exec flash caffeinate on
else
  exec flash caffeinate off
fi
```

The event fires when a display is connected or removed, not at launch, so a
display already plugged in when Flash starts counts from the next change.

## Using both

They do not conflict. Each keeps its own assertion and macOS stays awake
while either holds one, so `caffeinate off` in Flash leaves a KeepingYouAwake
session running, and the reverse. To avoid a Mac that will not sleep for a
reason you forgot, give each trigger, the battery and the external display
included, to only one of them.

With Flash's status bar on, the native menu bar auto-hides, and the cup with
it: it shows again at the top edge, and `mouse menubar` labels it. Scripts
that call the URL scheme keep working; switching them to `flash caffeinate`
is a one-word change per line.

*Checked 2026-10-23 against KeepingYouAwake's
[README](https://github.com/newmarcel/KeepingYouAwake),
[changelog](https://github.com/newmarcel/KeepingYouAwake/blob/main/CHANGELOG.md),
[automation guide](https://github.com/newmarcel/KeepingYouAwake/blob/main/Documentation/Automation.md),
[releases](https://github.com/newmarcel/KeepingYouAwake/releases) and
[site](https://keepingyouawake.app).*
