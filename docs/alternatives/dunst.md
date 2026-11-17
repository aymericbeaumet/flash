# Flash and dunst

[dunst](https://dunst-project.org) is "a highly configurable and lightweight
notification daemon": it answers the freedesktop notification calls every
Linux app makes, draws the bubbles, and runs them through rules (match on
`appname`, `summary`, `body`, `urgency`, `category`, `desktop_entry`;
change the format, timeout or urgency, hide them, run a script), with
`dunstctl` for history, pausing and actions. It is BSD-3-Clause C for X11
and Wayland, about 5,600 stars, v1.13.2 in March 2026, with commits in
October 2026. It has no macOS build, and it could not have one: on a Mac,
Notification Center is the only notification server, and no app can
replace it or restyle another app's notifications. What a dunst user keeps on macOS is
the habit: posting notifications from scripts, acting on them from the
keyboard, and silencing them. Flash covers those three.

| | dunst | Flash |
| --- | --- | --- |
| License, price | BSD-3-Clause, free | MIT, free |
| Platforms | Linux and the BSDs, X11 and Wayland | macOS 13+ |
| Role | The notification server: every app's notification passes through it | A client of Notification Center: it posts its own and puts labels on everyone's |
| Rules | Sections that match and rewrite any notification, with `script` hooks | None over other apps' notifications; System Settings › Notifications sets each app's style |
| Posting from scripts | `notify-send`, `dunstify` with actions and stack tags | `flash notify send` with a click URL or command and a replacing `--id` |
| From the keyboard | `dunstctl close`, `history-pop`, `context` through dmenu | `mouse notifications` labels banners and their buttons; `notificationcenter toggle` |
| Pausing | `dunstctl set-paused`, pause levels per rule | macOS Focus; `key system --key=focus` presses the Focus key |
| Configuration | `dunstrc`, `dunstctl reload` | `flash.toml` for Flash's own; System Settings for the rest |
| Maintenance | v1.13.2, March 2026; active | 1.1.0, October 2026 |

## Where dunst is stronger

- **It sees every notification.** A rule can rewrite a chatty app's
  summary, demote its urgency, stack its duplicates or drop it from
  history. macOS exposes no public way for one app to read or change
  another's notifications, so neither Flash nor anything else can.
- **Scripts on notifications.** `script` runs with `DUNST_APP_NAME`,
  `DUNST_SUMMARY`, `DUNST_URGENCY` and the rest in its environment: speak a
  message, log it, forward it to a phone. Flash's
  [monitors](../monitors.md#runs-and-events) run on Flash's values and host
  events, never on another app's notification.
- **Pause levels.** `override_pause_level` lets a low-battery warning
  through while everything else waits, set from a script with
  `dunstctl set-pause-level`. macOS Focus filters by app and person and lets
  Time Sensitive notifications through, but it is configured in System
  Settings, not from a shell.
- **Every pixel is yours**: origin, offset, width, fonts, frame, progress
  bars, icons, and on X11 dunst's own shortcuts. Notification Center's
  banners look and sit the way macOS draws them.

## Where Flash is stronger

- **The banners get labels.** `mouse notifications` puts a hint on every
  banner, alert and button Notification Center shows, so Reply, Clear and
  the actions are a keystroke away, without the dmenu step of
  `dunstctl context`. With the panel open, `f` labels it too.
- **A click that does something.** `notify send --url=` opens a page when
  the notification is clicked, and `--command=` runs a Flash command, where
  `notify-send` needs a `dunstify -A` loop waiting for the answer.
- **Thresholds that notify.** A `[monitors.<name>]` table with
  `notify = true` posts when a value crosses its warning or error level,
  the job dunst users usually give a battery or disk script.
- **A second, louder channel.** `alert show` draws Flash's centred alert
  and lets it go: for what should interrupt now and not wait in a panel.

## Flash features you might like

- `--id=build` replaces the previous notification with the same id, as
  dunst's `x-dunst-stack-tag` hint does; `notify clear --id=build` removes it.
- `notificationcenter toggle` on a key is the `history-pop` habit: the
  panel keeps what you missed.
- A `core:user.active` monitor that opens Notification Center when you come
  back stands in for `idle_threshold`.
- The [notifications reference](../commands.md#notifications-logs-and-metrics)
  lists every flag; the first `notify send` asks macOS for permission.

## Moving from dunst

| dunst | Flash |
| --- | --- |
| `notify-send "Build done" "All tests passed"` | `flash notify send --title="Build done" --body="All tests passed"` |
| `notify-send -h string:x-dunst-stack-tag:build …` | `--id=build` on `notify send` |
| `dunstify -A open,Open …` and waiting for the action | `--url=https://…` or `--command="app open --name=Zoom"` on `notify send` |
| `dunstctl close`, `close-all` | `flash notify clear --id=…`, or `flash notify clear` for all of Flash's |
| `dunstctl context`, `dunstctl action` | `mouse notifications`, then the label of a button |
| `dunstctl history-pop` | `notificationcenter show` |
| `dunstctl set-paused toggle` | `key system --key=focus`, or a Focus schedule in System Settings |
| A rule with `skip_display = true` for one app | System Settings › Notifications › the app: off |
| `[urgency_critical]` with `timeout = 0` | That app's notification style in System Settings, which decides whether its banners stay |
| A rule's `script` | Not possible for other apps' notifications; a monitor for Flash's own events |
| `idle_threshold` | A `core:user.active` monitor that shows the panel when you return |

```toml
[mode.all.mappings]
"cmd+ctrl+n" = ["flash", "notificationcenter", "toggle"]
"cmd+ctrl+shift+n" = ["flash", "mouse", "notifications"]
"cmd+ctrl+6" = ["flash", "key", "system", "--key=focus"]

# Back after ten minutes away: show what came in.
[monitors.back]
event = "core:user.active"
idle = 600
run = ["flash", "notificationcenter", "show"]

# The built-in low-battery monitor, posted to Notification Center too.
[monitors.battery]
notify = true
```

And the `notify-send` lines of your scripts:

```sh
make test \
  && flash notify send --title="Build done" --body="All tests passed" --sound --id=build \
  || flash notify send --title="Build failed" --command="app open --name=Terminal" --id=build
```

*Checked 2026-10-23 against the dunst
[README](https://github.com/dunst-project/dunst), its
[dunst(5)](https://github.com/dunst-project/dunst/blob/master/docs/dunst.5.pod)
and [dunstctl(1)](https://github.com/dunst-project/dunst/blob/master/docs/dunstctl.pod)
man pages and its releases.*
