# Flash and swayidle

[swayidle](https://github.com/swaywm/swayidle) is "sway's idle management
daemon", usable with "any Wayland compositor which implements the
ext-idle-notify protocol": `timeout 300 'swaylock -f'` with an optional
`resume`, and, with systemd, `before-sleep`, `after-resume`, `lock`,
`unlock` and `idlehint`. Its man page's example locks after five minutes,
powers the outputs off after ten, and locks before suspend. It is MIT C,
about 770 stars, v1.9.0 in November 2025, released independently of sway.
It has no macOS build. On a Mac the lock screen, display sleep and the
screen saver belong to macOS; Flash adds the hooks around them, as event
[monitors](../monitors.md#runs-and-events).

| | swayidle | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Wayland compositors with ext-idle-notify, systemd or elogind for the sleep and lock events | macOS 13+ |
| Idle | `timeout <seconds> <command> [resume <command>]`, any number | `core:user.idle` with `idle = <seconds>`, `core:user.active` on return |
| Sleep | `before-sleep` delays suspend until the command ends (`-w`), `after-resume` | `core:system.slept`, `core:system.woke`; nothing can delay sleep |
| Lock | `lock`, `unlock` from logind; the locker is yours (swaylock) | `core:screen.locked`, `core:screen.unlocked`; macOS's own lock screen |
| Inhibition | The compositor holds idle back for an inhibitor (sway's `inhibit_idle`) | `caffeinate on` keeps the Mac awake; `core:user.idle` counts input only |
| Configuration | Arguments, or `~/.config/swayidle/config` | `[monitors.<name>]` in `flash.toml` |
| Maintenance | v1.9.0, November 2025 | 1.1.0, October 2026 |

## Where swayidle is stronger

- **`before-sleep` really runs before sleep.** With `-w` swayidle holds
  logind's delay lock until swaylock has locked, so the machine never
  wakes unlocked. macOS gives an app no way to delay sleep: Flash's
  `core:system.slept` is a notice, not a hook that holds sleep back.
- **Inhibitors.** A full-screen video or an app asking to stay awake keeps
  the compositor from reporting idle, so a timeout waits. Flash's
  `core:user.idle` is time since your last key, click or scroll, and does
  not know that a film is playing.
- **Your locker.** swaylock, with its colours, images and plugins, is a
  program you choose. macOS draws its own lock screen and no app replaces
  it.
- **SIGUSR1** enters the idle state at once, and `idlehint` keeps logind's
  idle hint honest for other tools.

## Where Flash is stronger

- **Idle and return in one place.** A monitor on `core:user.active` runs
  once you are back after at least its `idle` seconds, with
  `FLASH_EVENT_IDLE_SECONDS` saying how long you were away.
- **Hooks beyond idle**: the same table reacts to a display being connected,
  an app launching or a time of day (`core:clock.minute` with `at` and
  `days`), so one file holds what swayidle, a udev rule and a cron line did.
- **A list of commands per event**, run in order, each after the previous
  one succeeded, with a timeout and a cooldown.

## Flash features you might like

- `caffeinate on --minutes=90` (or `caffeinate toggle`) is the idle
  inhibitor for a talk or a download; `#{flash.caffeinate}` shows it in
  the bar.
- `screen lock`, `display sleep`, `system sleep` and `screensaver start`
  are commands for keys and scripts, `loginctl lock-session` included.
- The [monitors page](/monitors) lists each event monitor, how often it
  ran and when last.

## Moving from swayidle

| swayidle | Flash |
| --- | --- |
| `timeout 300 'swaylock -f'` | macOS's own inactivity settings with `require_password`, or a `core:user.idle` monitor (`idle = 300`) running `screen lock` |
| `timeout 600 'swaymsg "output * power off"'` | `core:user.idle` with `idle = 600` running `display sleep` |
| `resume 'swaymsg "output * power on"'` | Nothing: input wakes the displays; `core:user.active` for anything else |
| `before-sleep 'swaylock -f'` | "Require password after screen saver begins or display is turned off: Immediately" in System Settings › Lock Screen, set once |
| `after-resume …` | `core:system.woke` |
| `lock …`, `unlock …` | `core:screen.locked`, `core:screen.unlocked` |
| `swaymsg inhibit_idle fullscreen` | Media apps hold macOS's own display sleep back; `caffeinate on` for the rest |
| `idlehint 300` | Not applicable |
| `pkill -USR1 swayidle` | `flash screen lock` or `flash display sleep` |

macOS's own screen saver and display sleep timers respect apps that ask the
Mac to stay awake, which Flash's idle events do not, so keep them for
locking and use monitors for the rest:

```toml
# Away ten minutes: displays off (the lock follows from require_password).
[monitors.away]
event = "core:user.idle"
idle = 600
run = ["flash", "display", "sleep"]

# Back after at least ten minutes: open the calendar.
[monitors.back]
event = "core:user.active"
idle = 600
run = ["flash", "app", "open", "--name=Calendar"]

# Locking ends a caffeinate hold, so the Mac can sleep.
[monitors.locked]
event = "core:screen.locked"
run = ["flash", "caffeinate", "off"]

[monitors.woke]
event = "core:system.woke"
run = ["~/bin/after-resume"]
```

*Checked 2026-10-23 against the swayidle
[README](https://github.com/swaywm/swayidle),
[swayidle(1)](https://github.com/swaywm/swayidle/blob/master/swayidle.1.scd)
and its releases.*
