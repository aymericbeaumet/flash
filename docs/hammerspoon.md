# Coming from Hammerspoon

Flash is a keyboard-driven macOS app configured in TOML. Its commands, native
mappings, and managed plugins cover many everyday Hammerspoon setups without
translating arbitrary Lua. Keep Hammerspoon for workflows that need general Lua
execution, hardware integrations, or custom windows and web views.

| Hammerspoon | Flash |
| --- | --- |
| [`hs.hotkey.bind`](https://www.hammerspoon.org/docs/hs.hotkey.html), [`hs.hotkey.modal`](https://www.hammerspoon.org/docs/hs.hotkey.modal.html) | `[mode.all.mappings]` for global shortcuts; NORMAL, INSERT, COMMAND, and TERMINAL mappings for modes; `[mode.apps."<bundle-id>".<scope>.mappings]` for app-specific bindings |
| [`hs.hints`](https://www.hammerspoon.org/docs/hs.hints.html), [`hs.mouse`](https://www.hammerspoon.org/docs/hs.mouse.html) | `mouse_target`, `mouse_grid`, `mouse_pointer`, and `mouse_button` |
| [`hs.grid`](https://www.hammerspoon.org/docs/hs.grid.html), [`hs.window`](https://www.hammerspoon.org/docs/hs.window.html) | `window_move` slots, proportional frames, and display moves; `window_focus` directions; `window_minimize`, `window_restore`, and native `window_fullscreen` |
| [`hs.application`](https://www.hammerspoon.org/docs/hs.application.html) | `app_open --name=…`, `app_previous`, `app_next`, and `app_quit` |
| [`hs.window.switcher`](https://www.hammerspoon.org/docs/hs.window.switcher.html), [`hs.chooser`](https://www.hammerspoon.org/docs/hs.chooser.html) | `:flashlight @windows` for cross-app windows; the flashlight also searches apps, tabs, menus, emoji, and plugin catalogs |
| [`hs.alert`](https://www.hammerspoon.org/docs/hs.alert.html) | `alert_show --message=…` and `alert_dismiss` |
| [`hs.eventtap` keystrokes](https://www.hammerspoon.org/docs/hs.eventtap.html) | `send_key` and `send_keys` for explicit key sequences |
| [`hs.task`](https://www.hammerspoon.org/docs/hs.task.html) | A mapping can run an argv array; managed plugins can expose resident commands and data |
| [`hs.menubar`](https://www.hammerspoon.org/docs/hs.menubar.html), [`hs.canvas`](https://www.hammerspoon.org/docs/hs.canvas.html) | The configurable status bar and desktop widgets, with tmux-format templates and plugin data |
| [`hs.audiodevice`](https://www.hammerspoon.org/docs/hs.audiodevice.html), [`hs.caffeinate`](https://www.hammerspoon.org/docs/hs.caffeinate.html) | Bundled `media` commands for volume, playback, and [input/output device selection](audio.md); `caffeinate_on`, `caffeinate_off`, and `caffeinate_toggle` plugin verbs |
| [`hs.pasteboard`](https://www.hammerspoon.org/docs/hs.pasteboard.html), [`hs.shortcuts`](https://www.hammerspoon.org/docs/hs.shortcuts.html) | Clipboard history with `:clipboard`; Shortcuts catalog with `:flashlight @shortcuts` |

## Move a hotkey

This Hammerspoon binding:

```lua
hs.hotkey.bind({"cmd", "shift"}, "space", function()
  hs.execute("flash mouse_target")
end)
```

can live in `~/.config/flash/flash.toml` instead:

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]
"alt+h" = ["flash", "window_move", "--position=lefthalf"]
"alt+f" = ["flash", "window_fullscreen"]
"alt+m" = ["flash", "window_minimize"]
"alt+shift+m" = ["flash", "window_restore"]
"alt+l" = ["flash", "window_focus", "--direction=right"]
"alt+c" = ["flash", "caffeinate_toggle"]
```

Flash reloads mappings when the file changes. Run `flash config_check` to
validate them and `flash doctor` if a shortcut does not register. See
[configuration](configuration.md) for modifier syntax, scoped mappings, and
running external argv arrays.

Use `[mode.apps."<bundle-id>".<scope>.mappings]` for bindings that apply in
one app, and [`[[window_rules]]`](windows.md#place-windows-as-they-appear) for
opt-in placement when a matching window appears.

## Move a modal setup

Hammerspoon modal hotkeys enable a set of bindings while a mode is active.
Flash's NORMAL mode does the same for keyboard-driven app control, including
unmodified keys and multi-key sequences:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "enter_normal_mode"]
"cmd+ctrl+i" = ["flash", "enter_insert_mode"]

[mode.normal.mappings]
"h" = ["flash", "window_move", "--position=lefthalf"]
"l" = ["flash", "window_move", "--position=righthalf"]
"f" = ["flash", "mouse_target"]
```

NORMAL captures unmapped keys, so give users an explicit way back to INSERT.
Flash also supports scoped mappings, counts, and repeatable actions; see
[normal mode](normal-mode.md).

## Move automation in stages

Hammerspoon can call `flash <verb>` while you migrate a config. The `flash`
command sends the action to Flash's resident process. Keep Lua where an action
depends on Hammerspoon's broad module library; expose small external commands
through Flash's argv mappings, or use a [managed plugin](plugin-cookbook.md)
when it needs lifecycle, live data, or a searchable catalog. Flash does not
execute Lua or provide a drop-in `hs.*` API.

Flash does not add arbitrary event taps, URL callbacks, screen capture, or
custom window surfaces to reproduce Hammerspoon modules. Its
[privacy model](privacy.md) and [command inventory](commands.md) describe the
supported boundaries.
