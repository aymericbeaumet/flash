# Flash and Kando

[Kando](https://github.com/kando-menu/kando) is a pie menu for the desktop,
"Do things with utmost efficiency." in its own words: press a shortcut and a
radial menu opens under the pointer, and a click, a flick or a held
modifier picks an item. It is Simon Schneegans' project, MIT-licensed source
code (its documentation and assets carry their own licences), about 6,500
GitHub stars, and it runs on Windows, macOS 11+ and Linux from the same
configuration. Version 3.0.0 shipped on 23 September 2026 with workflows:
each item now runs a sequence of actions instead of a single fixed type.

Kando is made for the pointer, a pen, a touch screen or a game controller;
Flash is made for the keyboard. They overlap where a Kando user reaches for
a menu from the keyboard, and that is where this page compares them.

| | Kando | Flash |
| --- | --- | --- |
| License, price | MIT source, free | MIT, free |
| Platforms | macOS 11+, Windows, Linux (most desktops, some with an extension or plugin) | macOS 13+ |
| Permissions | Accessibility to simulate keys and move the pointer; Screen Recording to read the focused window's name | Accessibility; Automation per browser to list tabs; Screen Recording only for `:screenshot screen` |
| Picking | Point and click, Marking Mode strokes, Turbo Mode on a held modifier, Hover Mode, arrow keys and quick-select keys | Keys only: one-shot layers, NORMAL sequences with a which-key palette, the flashlight's search |
| Actions | Workflows of: execute a command, open a URI or file, simulate a hotkey, run a macro, set the clipboard, focus a window, send a WebSocket message, open another menu | Every Flash command, and any program's argv; app-aware actions such as `tab next` or `window move` |
| Per context | Menu conditions on the app name, the window name and a screen area | `[mode.apps."<bundle id>"]` tables by exact bundle ID |
| Look | Menu themes, icon sets, sound themes, a graphical menu editor | A pill label and an orange window border while a layer is on |
| Configuration | Settings editor; `config.json` and `menus.json`, reloaded when saved | One TOML file, live reload, `flash config check` |
| Maintenance | 3.0.0, September 2026; active | 1.1.0, October 2026 |

## Where Kando is stronger

- **It is a menu you see.** Icons and labels around the pointer, in a theme
  you choose, with sounds if you like; you do not have to remember anything.
  A Flash layer shows its name in the pill and nothing else: the keys live
  in your head and in `flash.toml`. The which-key palette, which lists the
  keys that can follow a prefix, appears only for NORMAL prefixes.
- **Pointer, pen, touch and controller.** Marking Mode lets a practised hand
  flick through nested submenus without looking, Hover Mode selects by
  dwelling, and the menu works on a drawing tablet or a gamepad. Flash
  takes no input but keys.
- **Workflows.** One item can focus a window, simulate a shortcut, set the
  clipboard and close the menu, in the order you put them; hover workflows
  run as the pointer passes. A Flash key runs one command or one argv; a
  sequence of steps needs a shell script.
- **A graphical editor** with drag-and-drop items, and menu conditions on
  the window name and on a screen area, which Flash has no equivalent for.
- **Three systems, one configuration.** The same menus follow you to
  Windows and Linux.

## Where Flash is stronger

- **No Screen Recording.** Kando asks for it on macOS to read the focused
  window's name; Flash reads window titles through Accessibility and asks
  for Screen Recording only if you run `:screenshot screen`.
- **Actions that know the app.** A Kando item simulates the chord you
  recorded, in whichever app is in front. Flash's `tab next`,
  `window move --position=lefthalf` or `app find` resolve per app, so one key
  does the right thing in a browser, Finder or a tmux pane, and a terminal
  never receives a chord it would type.
- **Everything else on the keyboard.** Hints click any control, the
  flashlight finds apps, tabs, windows and menu items, and the bar, widgets
  and popups live in the same file.
- **A native app**, not an Electron one, and a text file that
  `flash config check` validates before you rely on it.

## Flash features you might like

- A one-shot layer (`sticky = false`) is the closest thing to a Kando menu:
  a chord opens it, one key runs an item, and you are back in the mode you
  came from, INSERT included ([layers](../layers.md)).
- `<leader>` sequences in NORMAL nest like submenus, and pausing on a prefix
  shows the which-key palette ([normal mode](../normal-mode.md)).
- `?` opens the live key mappings page, which draws each layer on your own
  keyboard layout: a printed version of your menu.
- `missioncontrol toggle`, `appwindows toggle`, `desktop toggle` and
  `key system --key=media_play` replace the hotkeys menus often simulate for
  system surfaces and media.
- `@shortcuts` runs a Shortcut from the flashlight, and `@menus` presses any
  menu item of the frontmost app.

## Moving from Kando

| Kando | Flash |
| --- | --- |
| A menu on Ctrl+Space | `"ctrl+<space>" = ["flash", "mode", "layer", "--name=pie"]` in `[mode.all.mappings]` |
| An item's quick-select key | The key in the layer's table |
| A submenu | An item that enters another layer, or a longer NORMAL sequence |
| Center click to go back | Escape leaves the layer |
| Execute Command | `["/bin/sh", "-c", "…"]` |
| Open URI, Open File | `["open", "https://…"]`, `["open", "~/Documents/report.pdf"]` |
| Simulate Hotkey | The Flash command for that action (`tab next`, `window minimize`); `key send --keys=…` for the rest |
| Execute Macro | `key sequence --keys=…`, or a recorded `q` macro of Flash commands |
| Focus Window | `app open --name=<app>`, `window switch`, `window focus --direction=…` |
| A workflow of several actions | A shell script that calls `flash` once per step |
| `appName` condition | `[mode.apps."<bundle id>".normal.mappings]` (layers themselves are global) |
| `windowName`, `screenArea` conditions | Not available |
| IPC `show-menu`, `--menu <name>` | `flash mode layer --name=<name>` from any script |
| Marking Mode, Hover Mode, pen, touch, controller | Not available |
| Themes, sound themes | Not available |

Layers need Flash's modes on, which one chord to `mode normal` or
`mode leave` in `[mode.all.mappings]` does. Opened from INSERT, a one-shot
layer runs its key and drops you back into INSERT, so typing is untouched:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns the modes on
"ctrl+<space>" = ["flash", "mode", "layer", "--name=pie"]

[mode.layers.pie]
label = "PIE"
sticky = false

[mode.layers.pie.mappings]
"f" = ["flash", "app", "open", "--name=Firefox"]
"t" = ["flash", "app", "open", "--name=Terminal"]
"d" = ["open", "~/Downloads"]
"m" = ["flash", "missioncontrol", "toggle"]
"w" = ["flash", "mode", "layer", "--name=pie_windows"]  # a submenu

[mode.layers.pie_windows]
label = "WINDOWS"
sticky = false

[mode.layers.pie_windows.mappings]
"h" = ["flash", "window", "move", "--position=lefthalf"]
"l" = ["flash", "window", "move", "--position=righthalf"]
"f" = ["flash", "window", "fullscreen"]
```

## Using both

Give each its own trigger: Kando's default Ctrl+Space and a Flash chord
cannot share a key, and Ctrl+Space is also macOS's shortcut for the
previous input source when that is turned on. A natural split keeps Kando
on a mouse button or the pen, through the tool you already use to open it
there, and Flash on the keyboard. Kando items can drive Flash: an Execute
Command action running `/Applications/Flash.app/Contents/MacOS/flash window
move --position=lefthalf` gets the same app-aware command as a Flash key,
without simulating a chord.

*Checked 2026-10-23 against Kando's
[repository](https://github.com/kando-menu/kando) and
[licence](https://github.com/kando-menu/kando/blob/main/LICENSE.md),
its [3.0.0 changelog](https://github.com/kando-menu/kando/blob/main/docs/changelog.md),
and [kando.menu](https://kando.menu/): the
[macOS installation guide](https://kando.menu/installation-on-macos/),
[usage guide](https://kando.menu/usage/),
[configuration files](https://kando.menu/config-files/) and
[IPC interface](https://kando.menu/ipc-interface/) pages.*
