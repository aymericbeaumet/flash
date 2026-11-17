# Flash and Hammerspoon

[Hammerspoon](https://www.hammerspoon.org) is "Staggeringly powerful macOS
desktop automation with Lua": "a bridge between the operating system and a
Lua scripting engine". It is MIT, about 16,000 GitHub stars, for macOS 13
and later. Releases are infrequent: 1.1.1 in February 2026 fixed the
download archive, and the last commit landed in July 2026. Its author is
writing Hammerspoon 2, an experimental JavaScript rewrite (0.0.15 in
October 2026, for the newest macOS only). Hammerspoon is not a hint tool,
but many people use it for the hotkeys, window moves and launchers that
Flash also provides, so "why not Hammerspoon" is a fair question, and for
some setups the answer is to keep it.

| | Hammerspoon | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 13+ | macOS 13+ |
| Permissions | Accessibility, plus whatever a module needs (Location, Screen Recording, Automation…) | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot screen` |
| Model | You write `init.lua`; 89 Spoons in the official repository, more from the community | A ready-made keyboard layer; TOML, no code |
| Hints | `hs.hints` labels windows only; element hints need `hs.axuielement` code (Vimnav.spoon did it, now archived) | Element hints in every app, built in |
| Modes | Modal hotkeys you build with `hs.hotkey.modal` | NORMAL, INSERT, VISUAL, COMMAND, TERMINAL, HYPER and HOLD, with per-app action resolution, and [layers](../layers.md) you declare in TOML |
| Windows | Full control through `hs.window`, `hs.window.filter`, `hs.layout` and `hs.grid` | Named positions, proportional frames, placement rules, directional focus, full screen, opt-in [tiling](../tiling.md) |
| Bar and widgets | `hs.menubar` items and `hs.canvas` drawings you write | Status bar and widgets from tmux-style formats and plugin values |
| Extensibility | Any Lua, any macOS API a module wraps | Plugins over JSON lines, most of them sandboxed; `flash <topic> <action>` and `flash events watch` from any program |
| Configuration | `~/.hammerspoon/init.lua`, reloaded by your code or the console | One TOML file, live reload, `flash config check` |
| Maintenance | 1.1.1, February 2026; slow, with Hammerspoon 2 in development | 1.1.0, October 2026 |

## Where Hammerspoon is stronger

- **It can do anything.** URL handlers, audio-device and Bluetooth events,
  HTTP servers, drawing, AppleScript, timers with any logic: if macOS has an
  API, there is a module. Flash's
  [event monitors](../monitors.md#runs-and-events) cover the common
  watchers (apps, displays, network, USB, idle, times of day) with
  commands to run, not a program.
- **Window management is programmable** beyond fixed positions: window
  filters, layouts per display, arrangements driven by events.
- **Spoons and a decade of shared Lua.** Most needs have a Spoon or a
  snippet someone already wrote; Flash's plugin set is younger and smaller.
- **Custom UI.** `hs.canvas`, `hs.webview` and `hs.chooser` draw whatever
  you want. Flash's surfaces are fixed: the overlay, the bar, widgets,
  popups and the centred alert.
- **One process for all your automation**, if you already live in it, and
  a console to try code live.

## Where Flash is stronger

- **Element hints, modes and a bar without writing them.** `hs.hints`
  labels windows only, and the Vimium-style Spoon that labelled elements is
  archived.
- **A prepared hint path.** Flash keeps the focused window's targets ready
  as it changes, so labels draw at once, and it logs the latency of every
  activation ([performance](../performance.md)).
- **A declarative file** that `flash config check` validates, with live
  reload and a `:help` page that shows the effective mappings on your
  keyboard layout.
- **A plugin sandbox** with declared capabilities. Lua in Hammerspoon has
  the whole machine.

## Flash features you might like

- `window move --position=lefthalf` and `--x=10% --y=10% --width=80%
  --height=80%`, and `[[window_rules]]` that place an app's windows as they
  appear ([windows](../windows.md#place-windows-as-they-appear)).
- `app open --name=Firefox`, `audio output --device='Studio Speakers'`,
  `volume down` and `caffeinate toggle` as mappings.
- The centred alert and the mode pill in the bar replace `hs.alert` for
  most uses, and `notify send` posts a macOS notification.
- `flash <topic> <action>` from Lua keeps Hammerspoon as the glue where you
  want it.

## Moving from Hammerspoon

Flash's commands, native mappings and managed plugins cover many everyday
Hammerspoon setups, without translating arbitrary Lua. Module by module:

| Hammerspoon | Flash |
| --- | --- |
| [`hs.hotkey.bind`](https://www.hammerspoon.org/docs/hs.hotkey.html), [`hs.hotkey.modal`](https://www.hammerspoon.org/docs/hs.hotkey.modal.html) | [`[mode.all.mappings]`](config:mode.all.mappings) for global shortcuts; `[mode.layers.<name>]` for a modal's own keys, entered by `mode layer`; NORMAL, INSERT, COMMAND and TERMINAL mappings for modes; `[mode.apps."<bundle-id>".<scope>.mappings]` for app-specific bindings |
| [`hs.hints`](https://www.hammerspoon.org/docs/hs.hints.html), [`hs.mouse`](https://www.hammerspoon.org/docs/hs.mouse.html) | `mouse target`, `mouse grid`, `mouse pointer` and `mouse button` |
| [`hs.grid`](https://www.hammerspoon.org/docs/hs.grid.html), [`hs.window`](https://www.hammerspoon.org/docs/hs.window.html) | `window move` slots, proportional frames and display moves; `window focus` directions; `window minimize`, `window restore` and native `window fullscreen` |
| [`hs.application`](https://www.hammerspoon.org/docs/hs.application.html) | `app open --name=…`, `app previous`, `app next` and `app quit` |
| [`hs.window.switcher`](https://www.hammerspoon.org/docs/hs.window.switcher.html), [`hs.chooser`](https://www.hammerspoon.org/docs/hs.chooser.html) | `window switch` (`:ls`) lists every window, most recently used first, one hint label each; the flashlight searches apps, tabs, windows, emoji and plugin catalogs; `window focus --direction=` for cross-app windows |
| [`hs.alert`](https://www.hammerspoon.org/docs/hs.alert.html) | `alert show --message=…`, with `--duration` and `--style`, and `alert dismiss`; `notify send` for Notification Center |
| [`hs.eventtap` keystrokes](https://www.hammerspoon.org/docs/hs.eventtap.html) | `key send` and `key sequence` for explicit key sequences |
| [`hs.task`](https://www.hammerspoon.org/docs/hs.task.html) | A mapping can run an argv array; managed plugins can expose resident commands and data |
| [`hs.application.watcher`](https://www.hammerspoon.org/docs/hs.application.watcher.html), [`hs.caffeinate.watcher`](https://www.hammerspoon.org/docs/hs.caffeinate.watcher.html), [`hs.screen.watcher`](https://www.hammerspoon.org/docs/hs.screen.watcher.html), [`hs.spaces.watcher`](https://www.hammerspoon.org/docs/hs.spaces.watcher.html) | A `[monitors.<name>]` with `event` (`core:apps.launched`, `core:system.woke`, `core:screen.unlocked`, `core:displays.changed`, `core:space.changed`) and a `run` ([events](../monitors.md#runs-and-events)) |
| [`hs.timer.doAt`](https://www.hammerspoon.org/docs/hs.timer.html#doAt) at a time of day | A `[monitors.<name>]` on `core:clock.minute` with `at = "HH:MM"` and optional `days` |
| [`hs.usb.watcher`](https://www.hammerspoon.org/docs/hs.usb.watcher.html), idle callbacks | A `[monitors.<name>]` on `core:usb.attached` / `core:usb.detached`, or on `core:user.idle` with `idle = <seconds>` and `core:user.active` |
| A watcher on a value (Wi-Fi network, a script's output) | A monitor whose `value` reads it and whose `run` fires on every change |
| [`hs.menubar`](https://www.hammerspoon.org/docs/hs.menubar.html), [`hs.canvas`](https://www.hammerspoon.org/docs/hs.canvas.html) | The [status bar](../statusbar.md) and [desktop widgets](../widgets.md), with tmux-style templates ([status format](../status-format.md)) and plugin data |
| [`hs.audiodevice`](https://www.hammerspoon.org/docs/hs.audiodevice.html), [`hs.caffeinate`](https://www.hammerspoon.org/docs/hs.caffeinate.html) | `volume up`, `volume down`, `volume mute`, the media keys through `key system`, and [device selection](../audio.md) with `audio input` and `audio output`; `caffeinate on`, `caffeinate off` and `caffeinate toggle` |
| [`hs.spaces`](https://www.hammerspoon.org/docs/hs.spaces.html) `toggleMissionControl`, `toggleAppExpose`, `toggleShowDesktop`, `toggleLaunchPad` | `missioncontrol`, `appwindows`, `desktop` and `launchpad`, each `show`, `hide` or `toggle`; `notificationcenter` and `controlcenter` for the two panels ([system surfaces](../commands.md#system-surfaces)) |
| [`hs.pasteboard`](https://www.hammerspoon.org/docs/hs.pasteboard.html), [`hs.shortcuts`](https://www.hammerspoon.org/docs/hs.shortcuts.html) | Clipboard history searched and pasted with `!clip` in the flashlight and listed by `:clipboard show` ([clipboard](../clipboard.md)); the Shortcuts catalog with `:flashlight @shortcuts` |
| Event-driven Lua beyond those (Bluetooth, URL events, arbitrary logic) | Keep Hammerspoon, and call `flash <topic> <action>` from it |

### Move a hotkey

This Hammerspoon binding:

```lua
hs.hotkey.bind({"cmd", "shift"}, "space", function()
  hs.execute("flash mouse target")
end)
```

lives in `~/.config/flash/flash.toml` instead, next to the window and app
keys most `init.lua` files start with:

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse", "target"]
"cmd+alt+left" = ["flash", "window", "move", "--position=lefthalf"]
"cmd+alt+right" = ["flash", "window", "move", "--position=righthalf"]
"cmd+alt+f" = ["flash", "app", "open", "--name=Firefox"]
"alt+shift+f" = ["flash", "window", "fullscreen"]
"alt+m" = ["flash", "window", "minimize"]
"alt+shift+m" = ["flash", "window", "restore"]
"alt+l" = ["flash", "window", "focus", "--direction=right"]
"alt+c" = ["flash", "caffeinate", "toggle"]
```

Flash reloads mappings when the file changes. Run `flash config check` to
validate them and `flash resident doctor` if a shortcut does not register.
See [modifier chords](../mappings.md#modifier-chords),
[scoped mappings](../configuration.md#commands-and-mappings) and
[external programs](../configuration.md#executables-and-opaque-arguments).
`[mode.apps."<bundle-id>".<scope>.mappings]` holds bindings for one app.

### Move a modal

A Flash [layer](../layers.md) is `hs.hotkey.modal`: `[mode.layers.<name>]`
holds its keys, `mode layer --name=<name>` is `modal:enter()`, and Escape is
`modal:exit()`, back to the mode it was entered from. Its label shows in the
bar while it is on, and keys it does not bind are swallowed rather than
typed:

```lua
local resize = hs.hotkey.modal.new({"cmd", "ctrl"}, "r")
resize:bind({}, "h", function() hs.window.focusedWindow():moveToUnit(hs.layout.left50) end)
resize:bind({}, "escape", function() resize:exit() end)
```

Layers live inside Flash's modes, which stay off until
`[mode.all.mappings]` binds `mode normal` or `mode leave`
([modes](../modes.md)). Binding one also turns on NORMAL, which captures
plain keys until `i` hands them back to the app, so give yourself both
directions:

```toml
[mode.all.mappings]
"cmd+ctrl+r" = ["flash", "mode", "layer", "--name=resize"]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.layers.resize]
label = "RESIZE"
sticky = true  # false leaves after one key, a one-shot modal

[mode.layers.resize.mappings]
"h" = ["flash", "window", "move", "--position=lefthalf"]
"l" = ["flash", "window", "move", "--position=righthalf"]
"f" = ["flash", "window", "fullscreen"]
```

NORMAL is itself a modal that stays on, across apps, with unmodified keys,
multi-key sequences, counts and repeat ([normal mode](../normal-mode.md)).
Window keys fit there behind the leader (`\` by default):

```toml
[mode.normal.mappings]
"<leader>h" = ["flash", "window", "move", "--position=lefthalf"]
"<leader>l" = ["flash", "window", "move", "--position=righthalf"]
```

### Move automation in stages

Hammerspoon can call `flash <topic> <action>` while you migrate: the
command reaches the running Flash and returns, so `hs.execute("flash
window move --position=lefthalf")` works the day you install Flash. Keep Lua
where an action depends on Hammerspoon's module library; expose small
external commands through argv mappings, or write a
[managed plugin](../plugin-cookbook.md) when it needs a lifecycle, live data
or a searchable catalog. Flash does not execute Lua or provide a drop-in
`hs.*` API, and it adds no event taps, URL callbacks, screen capture or
custom window surfaces to reproduce Hammerspoon modules; its
[privacy model](../privacy.md) and [commands](../commands.md) describe the
boundaries.

## Using both

Running both is the normal arrangement for Hammerspoon users: Flash owns
hints, modes and the bar; Hammerspoon keeps the automations Flash does not
attempt, and calls Flash where a Flash command does the job. Give each chord
one owner: a chord both apps claim works for only one of them, and
`flash resident doctor` lists the Flash hotkeys another app holds. Place a
given app's windows from one side only: a `[[window_rules]]` entry and an
`hs.window.filter` callback on the same app fight over its frame.

*Checked 2026-10-23 against [hammerspoon.org](https://www.hammerspoon.org),
the [1.1.1 release](https://github.com/Hammerspoon/hammerspoon/releases/tag/1.1.1)
and [commit history](https://github.com/Hammerspoon/hammerspoon/commits/master),
the [hs.hints](https://www.hammerspoon.org/docs/hs.hints.html) and
[hs.axuielement](https://www.hammerspoon.org/docs/hs.axuielement.html)
docs, the [Spoons repository](https://github.com/Hammerspoon/Spoons),
[Vimnav.spoon](https://github.com/y3owk1n/Vimnav.spoon) and
[Hammerspoon 2](https://github.com/cmsj/Hammerspoon2).*
