# Flash and xss-lock

[xss-lock](https://bitbucket.org/raymonad/xss-lock) is the program behind
i3's default `exec --no-startup-id xss-lock --transfer-sleep-lock -- i3lock
--nofork` line. Its man page: it "hooks up your favorite locker to the MIT
screen saver extension for X and also to systemd's login manager". The
locker runs when the X screen saver activates after `xset s` inactivity,
when logind asks for a lock (`loginctl lock-session`), and before suspend,
holding logind's delay lock; `-n` runs a notifier such as a dimming script
first. It is MIT C by Raymond Wagenmaker, v0.3.0 from November 2013, last
changed in March 2014, and still packaged by Debian, Fedora, Gentoo and
OpenBSD. It is X11-only. On a Mac, the screen saver,
the lock screen and the sleep sequence are macOS's; what an xss-lock user
sets up becomes a lock setting plus a few Flash event
[monitors](../monitors.md#runs-and-events).

| | xss-lock | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | X11, with systemd's logind | macOS 13+ |
| Triggers | X screen saver activation, logind lock requests, sleep | `core:user.idle`, `core:screen.locked`, `core:system.slept`, and the rest of the host events |
| Locker | Any program (`i3lock`, `slock`, `xsecurelock`) | macOS's lock screen, `screen lock` |
| Before sleep | Holds logind's delay lock until the locker is up (`-l`) | macOS locks on sleep itself when the Lock Screen setting requires a password |
| Warning first | `-n dim-screen.sh` | A `core:user.idle` monitor with a shorter `idle` |
| Configuration | Command-line flags, `xset s TIMEOUT CYCLE` | System Settings › Lock Screen, `[monitors.<name>]` in `flash.toml` |
| Maintenance | 0.3.0, 2013; unchanged since 2014 | 1.1.0, October 2026 |

## Where xss-lock is stronger

- **The locker is yours.** i3lock with your image, xsecurelock with its
  auth helpers, a locker that pauses music first: xss-lock runs whatever
  you give it, and waits for it. macOS's lock screen is the only one, and
  no app can draw it.
- **Locked before the lid closes.** `--transfer-sleep-lock` hands logind's
  delay lock to the locker, so suspend waits until the screen is locked.
  No Mac app can delay sleep; there the operating system locks the session
  on its own, which is the same guarantee from another place.
- **It forwards lock requests.** `loginctl lock-sessions` from a script, a
  remote shell or a power daemon reaches your locker.
- **Finished software.** Twelve years without a change, and still the
  line in i3's default config.

## Where Flash is stronger

- **One file for the whole session.** Lock timing (`require_password`),
  what happens on lock and unlock, on sleep and wake, when you leave and
  when you come back, all in `flash.toml` instead of `.xinitrc` flags, an
  `xset` line and a dimming script.
- **Return hooks.** xss-lock has no "unlocked" or "back" event to act on;
  `core:screen.unlocked` and `core:user.active` run commands when you return.
- **Commands to lock and sleep.** `screen lock`, `display sleep`,
  `screensaver start` and `system sleep` go on keys and into scripts.

## Flash features you might like

- `caffeinate toggle` keeps the Mac and its displays awake during a
  presentation, what `xset s off` did, and `#{flash.caffeinate}` shows it.
- A `core:clock.minute` monitor with `at` and `days` locks or sleeps the
  Mac at a time of day.
- The [privacy page](../privacy.md#data-read-from-other-apps) says what
  Flash reads to know you are idle: how long ago the last input happened,
  never what it was.

## Moving from xss-lock

| xss-lock | Flash |
| --- | --- |
| `xss-lock -- i3lock -n` | "Require password after screen saver begins or display is turned off: Immediately" with macOS's screen saver or display sleep timers |
| `xset s 600` | Those timers, in System Settings › Lock Screen |
| `--transfer-sleep-lock` | Not needed: macOS locks before sleeping when a password is required |
| `-n dim-screen.sh` | A `core:user.idle` monitor whose `idle` comes a minute before the lock, running `alert show` or your script |
| `loginctl lock-session` | `flash screen lock` |
| `--ignore-sleep` | That setting with a delay, such as five minutes |
| A locker wrapper that pauses music | A `core:screen.locked` monitor |

```toml
[mode.all.mappings]
"cmd+ctrl+l" = ["flash", "screen", "lock"]

[monitors.locked]
event = "core:screen.locked"
run = ["flash", "caffeinate", "off"]

[monitors.unlocked]
event = "core:screen.unlocked"
run = ["~/bin/on-unlock"]
```

Set the password delay once, in System Settings › Lock Screen or with
`sysadminctl -screenLock immediate -password -` in a terminal: it needs your
password, so no startup command sets it
([startup commands](../startup.md#a-setting-that-needs-your-password)).

*Checked 2026-10-23 against the
[xss-lock(1)](https://manpages.debian.org/testing/xss-lock/xss-lock.1.en.html)
man page, its [repository](https://bitbucket.org/raymonad/xss-lock) and
i3's [default configuration](https://github.com/i3/i3/blob/next/etc/config).*
