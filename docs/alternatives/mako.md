# Flash and mako

[mako](https://github.com/emersion/mako) is "a lightweight notification
daemon for Wayland. Works on Sway.": it implements the freedesktop
notification specification, starts on demand through D-Bus activation, and
styles notifications with INI-style criteria sections (`[app-name=…]`,
`[urgency=high]`, `[mode=do-not-disturb]`) and button bindings, driven at
run time by `makoctl`. It is MIT C, about 3,300 stars, v1.11.0 in March
2026, by Simon Ser (emersion). It draws through the wlr layer-shell
protocol, so it has no macOS counterpart to install: Notification
Center is the only place notifications appear on a Mac. Flash brings the
`makoctl` side over: notifications from scripts, keyboard access to the
ones on screen, and a do-not-disturb switch.

| | mako | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Wayland compositors with layer-shell (sway, river, Hyprland…) | macOS 13+ |
| Role | The notification server | A client of Notification Center |
| Styling | Criteria sections: colours, borders, icons, `format`, `anchor`, `output`, `group-by`, `max-visible` | Notification Center's own look; per-app style and grouping in System Settings |
| Actions | `on-button-left`, `on-touch`, `on-notify=exec …`, `makoctl invoke`, `makoctl menu` | A click URL or Flash command on your own; `mouse notifications` labels everyone's buttons |
| Modes | `[mode=…]` sections, `makoctl mode -a/-r/-t` | macOS Focus; `key system --key=focus` |
| Configuration | `~/.config/mako/config`, `makoctl reload` | `flash.toml` for Flash's own; System Settings for the rest |
| Maintenance | v1.11.0, March 2026 | 1.1.0, October 2026 |

## Where mako is stronger

- **Criteria over any notification.** `[app-name=Spotify] invisible=1`,
  `[urgency=critical] default-timeout=0`, a regular expression on
  `summary~`: mako restyles, hides and times out whatever arrives. macOS
  offers no app the notifications of another, so per-app on, off, style,
  sound and grouping in System Settings is all anyone can change.
- **Modes from the shell.** `makoctl mode -t do-not-disturb` is one line in
  a sway binding or a script, and a mode can change styling as well as
  hide. macOS Focus is scripted through Shortcuts at best, and no Flash
  command reports whether one is on.
- **`on-notify=exec`** plays a sound, logs, or pings a device on every
  notification that matches; nothing on macOS runs code when another app
  notifies.
- **Small and predictable**: one daemon, one text file, placement per
  output and layer.

## Where Flash is stronger

- **Labels instead of `makoctl menu`.** `mouse notifications` hints every
  banner, alert and button on screen, so invoking an action is typing its
  label, with no picker in between.
- **History on screen.** Notification Center keeps what you missed;
  `notificationcenter toggle` opens it and `f` labels what it shows, where
  `makoctl restore` brings back the last one.
- **Notifications from Flash's own events.** An event monitor with
  `notify = true` posts its `message` when a display, a USB device or a
  wake happens, with no script around `notify-send`.
- **Clicks that act.** `notify send --command=` runs a Flash command when
  the banner is clicked; mako's `invoke-action` needs the sending app to
  handle the action.

## Flash features you might like

- `flash notify send --id=<id>` replaces the previous one with that id,
  so a progress or status script never stacks banners.
- `--sound` on `notify send` is the `on-notify=exec mpv …` habit for your
  own notifications.
- A Shortcuts shortcut with a Set Focus action, run by
  `/usr/bin/shortcuts run`, is the closest to `makoctl mode -a`.
- `alert show --message=… --style=warning` for a message that should
  interrupt and then disappear.

## Moving from mako

| mako | Flash |
| --- | --- |
| `notify-send …` from a script | `flash notify send --title=… --body=…` |
| `makoctl dismiss`, `dismiss -a` | `flash notify clear --id=…`, `flash notify clear` (Flash's own) |
| `makoctl restore`, `makoctl history` | `notificationcenter show` |
| `makoctl invoke`, `makoctl menu -n "$id" -- fuzzel --dmenu` | `mouse notifications`, then the action's label |
| `makoctl mode -t do-not-disturb` | `key system --key=focus`, or `/usr/bin/shortcuts run "<your Focus shortcut>"` |
| `[app-name=Spotify] invisible=1` | System Settings › Notifications › Spotify: off |
| `[urgency=critical] default-timeout=0` | The app's notification style in System Settings |
| `group-by=app-name` | Notification grouping, per app, in System Settings |
| `on-notify=exec mpv …` | `--sound` on Flash's own; other apps' sounds are System Settings' |
| `anchor=top-right`, `output=…` | Not configurable: Notification Center decides |

```toml
[mode.all.mappings]
"cmd+ctrl+n" = ["flash", "mouse", "notifications"]
"cmd+ctrl+shift+n" = ["flash", "notificationcenter", "toggle"]
# A shortcut you made in Shortcuts with a "Set Focus" action.
"cmd+ctrl+d" = ["/usr/bin/shortcuts", "run", "Toggle Do Not Disturb"]

# A notification that stays in Notification Center when a USB device arrives.
[monitors.usb]
event = "core:usb.attached"
message = "USB device connected"
notify = true

[monitors.docking]
event = "core:displays.changed"
message = "Displays changed"
notify = true
```

*Checked 2026-10-23 against the mako
[README](https://github.com/emersion/mako),
[mako(5)](https://github.com/emersion/mako/blob/master/doc/mako.5.scd),
[makoctl(1)](https://github.com/emersion/mako/blob/master/doc/makoctl.1.scd)
and its releases.*
