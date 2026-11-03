# Flash and xbar

[xbar](https://github.com/matryer/xbar), "the BitBar reboot", lets you "put
the output from any script or program into your macOS Menu Bar". Each
plugin is an executable whose filename carries its refresh interval
(`weather.15m.sh`), whose first lines become the menu-bar title and whose
lines after `---` become the dropdown. Mat Ryer and Lea Anthony rewrote it
from BitBar in Go with Wails; it is MIT-licensed, about 18,000 GitHub stars,
for macOS 10.15 and later. The app has not shipped since v2.1.7-beta on
29 October 2021, and its code was last touched in September 2024, but the
[plugin catalogue](https://xbarapp.com) is alive: new plugins were merged on
20 October 2026.

That catalogue is the part Flash can take over. A Flash
[status bar](../statusbar.md) source with `output = "xbar"` runs an xbar
plugin unchanged and keeps its title; the dropdown is what you give up.

| | xbar | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 10.15+ | macOS 13+ |
| Permissions | None documented for itself | Accessibility; a script's prompts are attributed to Flash, which runs it ([privacy](../privacy.md#permission-prompts)) |
| Where items appear | Native menu-bar items | Flash's own bar over the top band, on every display or the primary one; the native menu bar auto-hides |
| Script output | Title lines that cycle; a dropdown with `--` submenus, Option alternates, images, per-item key shortcuts; `color`, `font`, `size` and ANSI per line | The title lines before `---`, without their `\|` parameters; several cycle with `cycle_interval`; styles come from the template |
| Plugin settings | `<xbar.var>` metadata becomes preferences, stored in a `.vars.json` beside the plugin | `env = { … }` on the source |
| Refreshing | The filename's interval; `xbar://app.xbarapp.com/refreshPlugin?path=…` | `interval`; `flash status refresh --name=<source>`; `flash status set` to push a value |
| Configuration | The plugins folder and the app's plugin browser | One TOML file, live reload, `flash config check` |
| Maintenance | v2.1.7-beta, October 2021; catalogue active | 1.1.0, October 2026 |

## Where xbar is stronger

- **Native menu-bar items with real menus.** A plugin's dropdown has
  submenus (`--`, `----`), Option-key alternates, images, disabled lines
  and a key shortcut per item, and every line can open a URL or run a
  script. Flash keeps the title only; a [popup](../popups.md) or a click
  action replaces the menu, and nothing replaces nested submenus.
- **Preferences generated from the plugin.** `<xbar.var>` lines declare
  strings, numbers, booleans and choices that xbar asks for when you
  install the plugin and passes as environment variables. In Flash you
  write those values into the source's `env` yourself.
- **Styling from the script**: `color=`, `font=`, `size=`, `emojize` and
  ANSI colours apply per line. Flash discards them.
- **A plugin browser in the app**, and support back to macOS Catalina.

## Where Flash is stronger

- **It is maintained.** The xbar app has had no release in five years;
  Flash ships, and the scripts you rely on keep running in a bar that does.
- **The keyboard reaches the bar.** `f` labels its links and popups along
  with the rest of the screen.
- **Runs are shared and scoped.** The bar and desktop widgets read one set
  of sources on one clock, a script both show runs once, a source nothing
  shows does not run, and a failed run keeps the last good value.
- **A refresh you can trust from a script.** `flash status refresh` runs
  the source now and exits 1, saying why, when the name is unknown or
  nothing shows it.
- **Numbers become history and alerts.** `history = N` feeds a `#[spark]`
  sparkline, and a [monitor](../monitors.md) can alert, or post a macOS
  notification with `notify = true`, when a plugin's number crosses a
  threshold.

## Flash features you might like

- Terminal popups under a segment: the dropdown that only listed things can
  become the tool itself (`top`, `btop`, your editor on the file the plugin
  reads).
- `flash status set --name=<source> --value=<text>` from a hook, so a
  plugin that polled every ten seconds to notice a change can stop polling
  ([pushed status values](../commands.md#pushed-status-values)).
- The built-in system values (`#{flash.plugin.sysinfo.cpu_label}`, memory,
  disks, network, battery) and `#{flash.calendar.next}` cover what many
  xbar System and Time plugins print ([status plugins](../status-plugins.md)).
- `output = "i3blocks"` and `"waybar"` for scripts written for those bars.

## Moving from xbar

| xbar | Flash |
| --- | --- |
| `todo.1m.sh` in `~/Library/Application Support/xbar/plugins` | `[statusbar.sources.todo]` with that `command`, `interval = 60`, `output = "xbar"`; `#{flash.source.todo}` in the template |
| Several title lines cycling | The same lines, with `cycle_interval` |
| The dropdown and its submenus | A text or terminal popup: `#[popup=<name>]…#[nopopup]` around the segment |
| `href=` | `#[link=https://…]…#[nolink]` in the template |
| `shell=`, `param1=`, `terminal=false` | `#[range=user\|<name>]…#[norange]` and a `[statusbar.click]` argv |
| `terminal=true` | A terminal popup running the script |
| `refresh=true`, `xbar://…/refreshPlugin` | `flash status refresh --name=<source>` |
| `refreshAllPlugins` | One `flash status refresh` per source |
| `<xbar.var>` and `.vars.json` | `env = { VAR_NAME = "…" }` on the source |
| `XBARDarkMode` | Not set; a fixed value in `env`, or the script checks the appearance itself |
| `key=` on an item | A mapping to the same command, or to `mode terminal --name=<popup>` |
| `color=`, `font=`, `size=`, ANSI | `#[fg=…]`, `#[bold]` and Flash's styles in the template |
| `image=`, `templateImage=` | Dropped |

```toml
[statusbar]
enabled = true
template = "#[align=right]#[popup=todo]#{flash.source.todo}#[nopopup] · %a %H:%M"

[statusbar.sources.todo]
command = ["~/Library/Application Support/xbar/plugins/todo.1m.sh"]
interval = 60
output = "xbar"
env = { VAR_LIMIT = "5" }  # what xbar kept in todo.1m.sh.vars.json

[popup.todo]
command = ["/bin/sh", "-c", "exec ${EDITOR:-vi} ~/todo.txt"]
size = "60%x50%"
```

## Using both

Nothing conflicts, but every plugin xbar still runs is a second process
doing what Flash's source does, so remove a plugin from xbar's folder once
Flash shows it, or point Flash at a copy. While Flash's bar is on, the
native menu bar auto-hides, so xbar's items show only when you reach the
top edge or run `mouse menubar`. If you want to keep native items and their
menus on a maintained app, [SwiftBar](swiftbar.md) runs the same plugins;
Flash then covers the keyboard, and its bar can stay off
(`[statusbar] enabled = false`).

*Checked 2026-10-23 against xbar's
[README](https://github.com/matryer/xbar),
[releases](https://github.com/matryer/xbar/releases),
[URL handler](https://github.com/matryer/xbar/blob/main/app/incoming_urls.go),
the [plugin guide](https://github.com/matryer/xbar-plugins/blob/main/CONTRIBUTING.md)
and [plugin repository](https://github.com/matryer/xbar-plugins), and
[variables in xbar](https://xbarapp.com/docs/2021/03/14/variables-in-xbar.html).*
