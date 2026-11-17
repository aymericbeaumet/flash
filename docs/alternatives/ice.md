# Flash and Ice

[Ice](https://github.com/jordanbaird/Ice) is "a powerful menu bar management
tool": "while its primary function is hiding and showing menu bar items, it
aims to cover a wide variety of additional features". It is Jordan Baird's
free, open-source menu bar manager: GPL-3.0, about 30,000 GitHub stars,
macOS 14 and later, installed from its releases or `brew install --cask
jordanbaird-ice`. The last stable release is 0.11.12 (October 2024); two
0.11.13 betas for macOS 26 Tahoe followed in June and September 2025, and
the repository has had no commit since September 2025. On macOS 27, users
report that hiding no longer works, and a community pull request restoring
it ([#995](https://github.com/jordanbaird/Ice/pull/995)) is open, not merged.

Flash does not tidy the native menu bar. Its [status bar](../statusbar.md)
draws over that band and asks macOS to auto-hide the native one, which still
slides in, with every status item in place, when the pointer reaches the top
edge.

| | Ice | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free; GitHub Sponsors and Buy Me a Coffee | MIT, free |
| Platforms | macOS 14+; macOS 26 in beta builds | macOS 13+ |
| Permissions | Accessibility, required, to read and arrange the menu bar; Screen Recording, optional, for item images and appearance editing (a limited mode works without it since 0.11.12) | Accessibility; status items are located from WindowServer geometry, never captured |
| The native menu bar | Hidden and always-hidden sections, shown on hover, click or scroll, rehidden automatically; drag-and-drop layout; item spacing (beta) | Auto-hidden as a whole while Flash's bar is on; ordered by macOS (Command-drag) |
| Notch | The Ice Bar: hidden items in a panel under the menu bar; app menus hidden when they overlap shown items | Flash's centre lane yields to the camera housing (`notch_margin`) |
| Finding an item | A search panel on a hotkey | `mouse menubar`: a label on each app menu and status item on screen |
| Appearance | Tint (solid or gradient), shadow, border, rounded or split shapes for the native bar | Styles in the template, for Flash's own bar |
| Configuration | Settings window | One TOML file, live reload, `flash config check` |
| Maintenance | 0.11.12, October 2024; betas to September 2025; macOS 27 support an open pull request | 1.1.0, October 2026 |

## Where Ice is stronger

- **It keeps the native menu bar on screen and tidy.** Every app's item
  stays where macOS puts it, with its own menu, and only the ones you chose
  are tucked away. Flash cannot hide a single status item: it hides the
  whole native bar or none of it.
- **The Ice Bar on a notched MacBook.** Items that macOS would push behind
  the camera housing open in a panel under the menu bar. Flash only keeps its
  own segments clear of the notch; what fits in the native bar beside it is
  up to macOS.
- **Layout and looks.** The drag-and-drop editor, item spacing and the
  tint, shadow, border and shapes of the native bar have no Flash
  counterpart; Flash styles the bar it draws, nothing else.
- **Search by name.** Ice's search panel finds an item you cannot see by
  typing its name. Flash labels what is on screen, so a hidden item has to
  be shown first.
- **A small permission set by default.** Ice needs Accessibility only;
  Screen Recording is for the images and appearance features you can leave
  off.

## Where Flash is stronger

- **Nothing left to tidy.** With `[statusbar] enabled = true` the band shows
  what your template says: the mode, the focused app, CPU, battery, the next
  meeting, the time. The native bar and every item in it are one pointer
  reach away, and turning Flash's bar off restores the menu bar only if
  Flash was the one that hid it.
- **The menu bar from the keyboard.** `mouse menubar` labels the focused
  app's menus, Apple menu first, and the status items, so opening the Wi-Fi
  or a VPN item is two keys. `@menus` in the flashlight searches the focused
  app's menu commands and presses the one you pick. In NORMAL, `f` also
  reaches the links and popup labels on Flash's own bar.
- **No screen capture.** Flash finds status items from WindowServer
  geometry and draws its labels over them; it never reads their images, and
  [privacy](../privacy.md) lists every permission it can ask for.
- **Maintained in the open.** Flash 1.1.0 shipped in October 2026; Ice's
  stable release is from October 2024, and the macOS 26 and 27 work sits in
  betas and pull requests.

## Flash features you might like

- A label in the bar can open a [popup](../popups.md) on hover, `#[popup=power]`
  around the battery figure, for what a status item's dropdown used to show:
  `#{flash.plugin.sysinfo.power_details}` lists charge, health, cycles and
  adapter power.
- `notificationcenter toggle` and `controlcenter toggle` press the menu
  bar's clock and Control Center item through Accessibility, so the two
  panels open from a key ([system surfaces](../commands.md#system-surfaces)).
- [`[startup] run`](../startup.md) can set how the native clock and battery
  look when the bar slides in (`defaults write com.apple.menuextra.clock …`,
  then `killall ControlCenter`), in the same file.
- `[statusbar] monitor = "primary"` keeps Flash's bar to the main display
  and leaves the native menu bar's auto-hide to apply everywhere, since that
  setting is system-wide.

## Moving from Ice

| Ice | Flash |
| --- | --- |
| Hidden section, always-hidden section | `[statusbar] enabled = true`: the whole native bar stays hidden until the pointer reaches the top edge |
| Show hidden items on hover, click or scroll | Reach the top edge; Flash's bar drops below the native one while it shows |
| Automatically rehide | macOS slides the native bar away when the pointer leaves it |
| Ice Bar under the notch | The revealed native bar; Flash's centre lane leaves the notch clear |
| Search panel | `mouse menubar` for the items on screen; `@menus` for the focused app's menu commands |
| Hotkey to toggle a section | Not available: Flash never shows or hides another app's item |
| Drag-and-drop arrangement | Command-drag in the native bar, which macOS remembers; Flash orders only its template |
| Tint, shadow, border, shapes | `#[fg=…,bg=…]` and `#[pill]` in `[statusbar] template`, for Flash's bar |
| Launch at login | `[app] autostart = true`, the default |

```toml
[statusbar]
enabled = true
template = "#[align=left]#[pill]#{flash.mode}#[nopill] #{flash.focused_app_name}#[align=right]#[popup=power]#{flash.plugin.sysinfo.power_label}#[nopopup] · %a %H:%M"

[popup.power]
text = "#{flash.plugin.sysinfo.power_details}"

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"cmd+ctrl+m" = ["flash", "mouse", "menubar"]
"cmd+ctrl+n" = ["flash", "notificationcenter", "toggle"]

[mode.normal.mappings]
"<leader>m" = ["flash", "mode", "flashlight", "--query=@menus"]
```

## Using both

With Flash's bar off, the two never meet: Ice tidies the native menu bar and
Flash adds `mouse menubar` and `@menus` on top of it. Flash clicks a status
item where it sits, so show Ice's hidden section first (its hotkey, or a
click in the menu bar), then label it.

With Flash's bar on, Ice still manages the native bar that slides in at the
top edge, hidden sections included, but you will see that bar far less
often, and its appearance settings style a band Flash covers. Most people
who turn Flash's bar on find Ice has little left to do; keep it if you want
the native bar to arrive tidy, or for the Ice Bar on a notched screen.

*Checked 2026-10-23 against Ice's
[README](https://github.com/jordanbaird/Ice), its
[releases](https://github.com/jordanbaird/Ice/releases) and commit history,
its [permission descriptions](https://github.com/jordanbaird/Ice/blob/main/Ice/Permissions/Permission.swift),
and its open macOS 27 [pull request](https://github.com/jordanbaird/Ice/pull/995)
and [issues](https://github.com/jordanbaird/Ice/issues/1008).*
