# Flash and Alfred

[Alfred](https://www.alfredapp.com) is "An award-winning app for macOS
which boosts your efficiency with hotkeys, keywords, text expansion and
more". The core launcher is free; the Powerpack (clipboard history,
snippets, workflows) is a one-time £34, or £59 with lifetime upgrades. It
runs on macOS 10.14 and later, Intel and Apple Silicon, with 5.8.1 in
September 2026 and Alfred 6 announced. Like Raycast it is a launcher, not a
hint tool.

| | Alfred | Flash |
| --- | --- | --- |
| License, price | Closed; free core, Powerpack one-time | MIT, free |
| Platforms | macOS 10.14+ | macOS 14+ |
| Permissions | Accessibility (snippets, key events), Full Disk Access (file search), Contacts, Automation, sometimes Input Monitoring | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot` |
| Launcher | Apps, files, web search, calculator; workflows from a gallery of hundreds | flashlight: apps, browser tabs, tmux windows, native windows, emoji, math, units, currency, plugin data |
| Hints, modes | None | Hints in every app, NORMAL mode |
| Clipboard, snippets | Powerpack | Clipboard and snippets plugins |
| Windows | None built in | Named positions, proportional frames, placement rules |
| Configuration | Preferences window, visual workflow editor | One TOML file |
| Maintenance | 5.8.1, September 2026 | 1.0.0, October 2026 |

## Where Alfred is stronger

- **Workflows with a visual editor** that are "easier to write and to debug"
  than code, and a gallery of hundreds.
- **File search** that goes deep into the file system, with Full Disk
  Access.
- **Snippets with text expansion** and a mature clipboard history.
- **Runs on very old macOS versions**, with one-time pricing and no
  account.

## Where Flash is stronger

- **Acting on the screen.** Alfred has nothing like hints or a modal layer.
- **Fewer permissions.** Alfred's own permissions page lists Accessibility,
  Full Disk Access, Contacts, Automation and sometimes Input Monitoring;
  Flash needs Accessibility, and Automation only when a browser's tabs are
  listed.
- **Free and open, with a file** instead of preferences and a Powerpack.
- **Tabs, tmux windows and native windows** in the same search as apps.
- **A bar and widgets.**

## Flash features you might like

- `:flashlight` for apps, tabs and windows, with inline math and currency.
- `@menus` runs any menu item of the frontmost app by name.
- Clipboard history and the snippets plugin cover the everyday part of the
  Powerpack.
- `app_open --name=` as a hotkey, without a workflow.

## Moving from Alfred

| Alfred | Flash |
| --- | --- |
| Launcher hotkey | `["flash", "enter_command_mode", "--input=:flashlight "]` |
| Calculator | Type the expression in flashlight |
| Clipboard history | Flash's built-in Clipboard page |
| Snippets | The snippets plugin |
| Hotkey to launch an app | `["flash", "app_open", "--name=<App>"]` |
| File search, web search | Keep Alfred's free core |
| Workflows | Keep Alfred, or a Flash plugin for the ones that feed search |

Alfred's free core and Flash coexist without conflict.

*Checked 2026-10-14 against
[alfredapp.com](https://www.alfredapp.com), its
[permissions page](https://www.alfredapp.com/help/getting-started/permissions/)
and [changelog](https://www.alfredapp.com/changelog/).*
