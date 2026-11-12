# Flash and Hidden Bar

[Hidden Bar](https://github.com/dwarvesf/hidden) is "an ultra-light MacOS
utility that helps hide menu bar icons": an arrow in the menu bar, and the
icons you Command-drag to its left disappear when you click it. That is
nearly the whole app, which is the point. It comes from the Dwarves
Foundation, is MIT-licensed and free, about 15,000 GitHub stars, and installs
from its releases, `brew install --cask hiddenbar`, or the Mac App Store.
After a quiet spell from 2022, version 1.10 (March 2026) and 1.11 and 1.11.1
(18 September 2026) brought it back: 1.11 needs macOS 13 or later (1.10
stays available for 10.13 to 12) and hides icons on macOS 27 again in the
direct download. The App Store copy is still 1.8 from 2021 and cannot hide
on macOS 27.

Flash has no arrow and hides no single icon. Its
[status bar](../statusbar.md) takes the whole band and lets the native menu
bar auto-hide beneath it, icons and all, until the pointer reaches the top
edge.

| | Hidden Bar | Flash |
| --- | --- | --- |
| License, price | MIT, free, App Store included | MIT, free |
| Platforms | macOS 13+ (1.11); 10.13 to 12 with 1.10 | macOS 13+ |
| Permissions | None for its classic hiding; Accessibility for the macOS 27 hiding | Accessibility |
| What it hides | The icons left of its arrow, plus an optional always-hidden section; on macOS 27, per app, and never the clock, Wi-Fi, Sound or Control Center | The whole native menu bar while Flash's bar is on |
| Showing them again | Click the arrow, a global shortcut, or hover with a Terminal-only setting; auto-collapse after a delay | Reach the top edge; macOS slides the native bar back |
| Keyboard | One global shortcut to expand or collapse | `mouse menubar` labels app menus and status items; hints on Flash's bar; NORMAL mode |
| Configuration | A small Preferences window and a few `defaults` keys | One TOML file, live reload, `flash config check` |
| Maintenance | 1.11.1, September 2026 | 1.1.0, October 2026 |

## Where Hidden Bar is stronger

- **It keeps the menu bar you know.** The native bar stays on screen with
  the icons you want, in the order you dragged them, each with its own menu.
  Flash cannot remove one icon; it covers the band with a bar of its own.
- **Nothing to learn.** One arrow, one drag, one optional shortcut. Flash
  asks you to write a template before its bar shows anything useful.
- **Light and sandboxable.** Its classic hiding, a separator that widens to
  push icons off screen, asks for no permission and ships sandboxed in the
  App Store; Flash needs Accessibility for everything it does.
- **Older Macs.** 1.10 runs on macOS 10.13 to 12 and 1.11 on 13; Flash needs
  14.
- **Notch help is on the way**: a Notch Overflow menu for icons the camera
  housing covers is merged on its development branch, not yet released.

## Where Flash is stronger

- **The clean bar, all the way.** With Flash's bar on, no third-party icon
  shows at all until you reach for it, and the band holds what you choose:
  the focused app, the battery, the time, a meeting, a CPU figure.
- **No icon gets lost.** macOS puts a new or updated app's icon at the far
  left, which Hidden Bar's manual notes can land it in the hidden zone until
  you drag it out. Flash hides the native bar whole, so every icon is where
  macOS left it when the bar slides in.
- **The keyboard reaches the menu bar.** `mouse menubar` labels the focused
  app's menus and the status items on screen, so opening one is two keys
  rather than an expand and a click.
- **One file for the rest.** Popups under bar labels, hints in every app,
  windows, the flashlight and NORMAL mode, configured together.

## Flash features you might like

- macOS 26 itself can switch an app's icon off: System Settings › Menu Bar ›
  Allow in the Menu Bar. That and Flash's bar cover most of what an
  always-hidden section is for.
- `#[popup=<name>]` around a label shows a [popup](../popups.md) on hover,
  for the details a status item's menu used to give you.
- `notificationcenter toggle` and `controlcenter toggle` open the panels
  behind the clock and Control Center from a key
  ([system surfaces](../commands.md#system-surfaces)).
- `[statusbar] monitor = "primary"` draws Flash's bar on the main display
  only.

## Moving from Hidden Bar

| Hidden Bar | Flash |
| --- | --- |
| Click the arrow to collapse | `[statusbar] enabled = true`: the native bar stays hidden |
| Click again, or the global shortcut, to expand | Reach the top edge; no key reveals the native bar |
| Command-drag icons across the arrow | Command-drag still orders the native bar; Flash orders only its template |
| Always-hidden section | System Settings › Menu Bar › Allow in the Menu Bar, or quit the app |
| Auto collapse after a delay | macOS slides the native bar away when the pointer leaves it |
| `hoverToExpand` | Reaching the top edge is the hover |
| Start Hidden Bar at login | `[app] autostart = true`, the default |

```toml
[statusbar]
enabled = true
monitor = "primary"
template = "#[align=left]#{flash.focused_app_name}#[align=right]#{flash.plugin.sysinfo.power_label} · %a %d %b %H:%M"

[mode.all.mappings]
"cmd+ctrl+m" = ["flash", "mouse", "menubar"]
```

## Using both

They coexist without conflict. With Flash's bar off, Hidden Bar keeps the
native bar trim and Flash adds hints and `mouse menubar`; Flash clicks an
icon where it sits, so expand Hidden Bar first if the icon is in its hidden
zone. With Flash's bar on, Hidden Bar still works on the native bar that
slides in at the top edge, and its arrow is there when it does; you will
just need it less, since the native bar is out of sight the rest of the
time. Pick different chords for Hidden Bar's shortcut and Flash's mappings.

*Checked 2026-10-23 against Hidden Bar's
[README](https://github.com/dwarvesf/hidden),
[manual](https://github.com/dwarvesf/hidden/blob/develop/docs/MANUAL.md),
[changelog](https://github.com/dwarvesf/hidden/blob/develop/CHANGELOG.md) and
[releases](https://github.com/dwarvesf/hidden/releases), its
[App Store listing](https://apps.apple.com/app/hidden-bar/id1452453066), and
Apple's [Menu Bar settings](https://support.apple.com/guide/mac-help/change-menu-bar-settings-mchlad96d366/mac)
guide.*
