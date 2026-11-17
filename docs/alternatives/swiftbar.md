# Flash and SwiftBar

[SwiftBar](https://github.com/swiftbar/SwiftBar), a "Powerful macOS menu bar
customization tool", turns scripts into menu-bar items "in three easy
steps": write a script, add it to SwiftBar, and there is no third step. The
script's first lines become the title in the menu bar and the lines after
`---` its dropdown menu, in the format BitBar started and xbar kept, so the
whole BitBar and xbar plugin catalogue runs on it. It is MIT-licensed Swift
by Alex Mabe (Ameba Labs), about 4,700 GitHub stars, for macOS 12 and
later; 2.1.1 shipped on 11 August 2026 and 2.1.2 betas followed into late
September, while xbar itself has had no release since 2021
([xbar](xbar.md)).

Flash's [status bar](../statusbar.md) reads the same scripts unchanged: a
named source with `output = "xbar"` keeps the title lines and drops the
rest. What it does not keep is the dropdown, and this page is mostly about
that trade.

| | SwiftBar | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 12+ | macOS 13+ |
| Permissions | None documented for itself; scripts ask for their own | Accessibility; a script's prompts are attributed to Flash, which runs it ([privacy](../privacy.md#permission-prompts)) |
| Where items appear | Native menu-bar items, beside every other app's | Flash's own bar over the top band, on every display or the primary one; the native menu bar auto-hides |
| Script output | Title lines that cycle, a dropdown with submenus, separators, Option alternates, checkmarks, badges, images, SF Symbols and web views; colours, fonts and ANSI per line | The title lines before `---`, without their `\|` parameters; several cycle with `cycle_interval`; styles come from the template |
| Plugin kinds | Standard (filename or cron schedule), Shortcuts, Ephemeral (URL scheme), Streamable (`~~~`) | Polled sources, pushed sources (`flash status set`), `#()` jobs that show a running command's latest line |
| Actions | `href`, `bash`, `refresh`, `shortcut` per line; a `swiftbar://` URL scheme | `#[link=…]`, `[statusbar.click]` actions, popups under a segment, `flash status refresh` |
| Configuration | A plugin folder, metadata in each script, a preferences window | One TOML file, live reload, `flash config check` |
| Maintenance | 2.1.1, August 2026; 2.1.2 in beta | 1.1.0, October 2026 |

## Where SwiftBar is stronger

- **The native menu bar.** Its items sit with every other app's status item,
  where macOS puts them. Flash draws its own bar over that band and lets the
  native one auto-hide; the other status items are still there when you
  reach the top edge, but not on screen all the time.
- **The dropdown.** Everything after `---` becomes a real menu: submenus
  with `--`, separators, Option-key alternates, checkmarks, badges, images,
  SF Symbols, web views, and an action on every line. Flash keeps the title
  and drops the menu; a [popup](../popups.md) under the segment, or a click
  action, is what replaces it.
- **Styling from the script.** `color=`, `font=`, `size=`, `sfimage=`,
  `md=` and ANSI codes let a plugin colour its own output. Flash discards
  them and styles values in its template.
- **More ways to run.** Cron schedules (`<swiftbar.schedule>`), refresh when
  the menu opens, Shortcuts plugins, ephemeral items created from a URL, a
  per-plugin hotkey, and data and cache folders handed to each script in
  `SWIFTBAR_PLUGIN_DATA_PATH` and `SWIFTBAR_PLUGIN_CACHE_PATH`.
- **The plugin repository** is a menu item away (Get Plugins…), and a
  lower macOS floor.

## Where Flash is stronger

- **The keyboard reaches the bar.** `f` labels the bar's links and popups
  with the rest of the screen, and `mouse menubar` labels the native status
  items too, SwiftBar's included.
- **A script runs only while it is shown, once.** The bar and desktop
  widgets share one set of sources on one clock, so a script both show runs
  once, and a source nothing shows does not run at all.
- **A failure keeps the last good value** instead of a warning sign in the
  bar, and a slow run is cut at `command_timeout`.
- **Numbers become more than text.** `history = 30` keeps a script's last
  30 numbers for a `#[spark]` sparkline, and a
  [monitor](../monitors.md) raises an alert, or posts a macOS notification
  with `notify = true`, when one crosses a threshold.
- **Popups are terminals.** A segment can open btop, `top` or any TUI in a
  real terminal, where a SwiftBar web view shows a page.

## Flash features you might like

- `flash status set --name=<source> --value=<text>` pushes a value from a
  hook the moment something happens, and `flash status clear` empties it:
  SwiftBar's ephemeral plugins and streamable updates without a running
  process of their own ([pushed status values](../commands.md#pushed-status-values)).
- `flash status refresh --name=<source>` is `swiftbar://refreshplugin`, and
  `flash notify send --title=… --body=…` is `swiftbar://notify`.
- `#{flash.plugin.sysinfo.cpu_label}` and the other system values replace
  the CPU, memory, battery and network plugins most bars start with
  ([status plugins](../status-plugins.md)).
- `output = "i3blocks"` and `"waybar"` read those bars' scripts the same way.

## Moving from SwiftBar

| SwiftBar | Flash |
| --- | --- |
| `cpu.10s.sh` in the plugin folder | `[statusbar.sources.cpu]` with `command`, `interval = 10`, `output = "xbar"`; `#{flash.source.cpu}` in the template |
| Several title lines cycling | The same lines, with `cycle_interval` |
| `<swiftbar.schedule>` cron times | A monitor on `core:clock.minute` with `at` running `flash status refresh` |
| The dropdown | A text or terminal popup: `#[popup=<name>]…#[nopopup]` around the segment |
| `href=` | `#[link=https://…]…#[nolink]` in the template |
| `bash=`, `terminal=false` | `#[range=user\|<name>]…#[norange]` and a `[statusbar.click]` argv |
| `refresh=true`, `swiftbar://refreshplugin` | `flash status refresh --name=<source>` |
| Streamable plugins | A script that runs `flash status set` per update, or a `#()` job, which shows a running command's latest line |
| Ephemeral plugins | A pushed source: `flash status set`, then `flash status clear` |
| `swiftbar://notify` | `flash notify send` |
| `shortcut=` to open a plugin's menu | A key to `mode terminal --name=<popup>`, which shows the popup centred |
| `color=`, `font=`, `sfimage=` | `#[fg=…]`, `#[bold]` and Flash's styles in the template; images and SF Symbols are dropped |
| `SWIFTBAR_*`, `OS_APPEARANCE` variables | Not set; give a source what it needs with `env = { … }` |
| Cmd-drag to reorder | The template's order |
| Shortcuts plugins, web views | Not available |

```toml
[statusbar]
enabled = true
template = "#[align=right]#[popup=cpu_top]#{flash.source.cpu}#[nopopup] · #[range=user|vpn]#{flash.source.vpn}#[norange] · %H:%M"

[statusbar.sources.cpu]
command = ["~/.swiftbar/cpu.10s.sh"]
interval = 10
output = "xbar"

[statusbar.sources.vpn]
command = ["~/.swiftbar/vpn.1m.sh"]
interval = 60
output = "xbar"

[statusbar.click]
vpn = ["flash", "status", "refresh", "--name=vpn"]

[popup.cpu_top]
command = ["top", "-o", "cpu"]
size = "70%x60%"

# <swiftbar.schedule>0 9 * * *</swiftbar.schedule>, as a monitor
[monitors.vpn_morning]
event = "core:clock.minute"
at = "09:00"
run = ["flash", "status", "refresh", "--name=vpn"]
```

## Using both

They coexist without conflict: SwiftBar's items live in the native menu
bar, Flash's in its own. The catch is that Flash's bar auto-hides the native
menu bar, so SwiftBar's items show only when you reach the top edge or run
`mouse menubar`. Two arrangements work well. Keep SwiftBar for the plugins
whose dropdown you use, and move the glanceable ones (CPU, the next
meeting, a VPN state) into Flash's bar. Or keep Flash's bar off
(`[statusbar] enabled = false`) and use Flash only for its keyboard, with
SwiftBar owning the menu bar. Either way, a script shown by both runs twice,
once per app.

*Checked 2026-10-23 against SwiftBar's
[README](https://github.com/swiftbar/SwiftBar),
[2.1.1 release notes](https://github.com/swiftbar/SwiftBar/releases/tag/v2.1.1) and
[releases](https://github.com/swiftbar/SwiftBar/releases).*
