# Flash and Hammerspoon

[Hammerspoon](https://www.hammerspoon.org) is "Staggeringly powerful macOS
desktop automation with Lua": "a bridge between the operating system and a
Lua scripting engine". It is MIT, about 16,000 stars, macOS 13+, with
infrequent releases (1.1.1 in February 2026) and a maintainer who called it
"kinda already in maintenance mode" in 2023. It is not a hint tool, but
many people use it for the hotkeys, window moves and launchers that Flash
also provides, and the question "why not Hammerspoon" is fair.

| | Hammerspoon | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 13+ | macOS 14+ |
| Permissions | Accessibility, plus whatever a module needs | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot` |
| Model | You write `init.lua`; ~140 Spoons as plugins | A ready-made keyboard layer; TOML, no code |
| Hints | `hs.hints` labels windows only; element hints need `hs.axuielement` code (Vimnav.spoon did it, now archived) | Element hints in every app, built in |
| Modes | Modal hotkeys you build with `hs.hotkey.modal` | NORMAL, INSERT, COMMAND, TERMINAL, with per-app action resolution |
| Windows | Full control through `hs.window`, including filters and layouts | Named positions, proportional frames, placement rules, directional focus, full screen |
| Bar and widgets | `hs.menubar`, `hs.canvas` drawn by you | Status bar and widgets from tmux formats |
| Extensibility | Any Lua, any API | Plugins over JSON lines, sandboxed; `flash <verb>` CLI |
| Maintenance | 1.1.1, February 2026; slow | 1.0.0, October 2026 |

## Where Hammerspoon is stronger

- **It can do anything.** URL handlers, audio devices, Wi-Fi events, USB,
  timers, notifications, drawing, AppleScript, HTTP servers: if macOS has
  an API, there is a module.
- **Window management is programmable** beyond fixed positions: filters,
  layouts per display, event-driven arrangements.
- **Spoons** package ready-made behaviours, and the community has written
  Lua for most needs over a decade.
- **One process for all your automation**, if you already live in it.

## Where Flash is stronger

- **Element hints, modes and a bar without writing them.** The Vimium-style
  Spoon that existed is archived; Hammerspoon's own `hs.hints` only labels
  windows.
- **Latency.** Flash's hint path is prepared per window and measured;
  Hammerspoon window moves were called "deathly slow" on HN, and every
  callback runs Lua on the main thread.
- **A declarative file** that `flash config_check` validates, with live
  reload and a `:help` page that shows the effective mappings.
- **A plugin sandbox** with declared capabilities. Lua in Hammerspoon has
  the whole machine.

## Flash features you might like

- `window_move --position=lefthalf` and `--x=10% --y=10% --width=80%
  --height=80%`, and placement rules by app and title
  ([windows](../windows.md)).
- `app_open --name=Firefox`, `media output 'Studio Speakers'`,
  `media volumedown` as mappings.
- Alerts and the mode pill in the bar replace `hs.alert` for most uses.
- `flash <verb>` from Lua keeps Hammerspoon as the glue where you want it.

## Moving from Hammerspoon

The [migration guide](../hammerspoon.md) maps hotkeys, window controls, app
launching and alerts one by one, and lists what stays better in Lua. The
short version:

| Hammerspoon | Flash |
| --- | --- |
| `hs.hotkey.bind({"cmd","alt"}, "left", ...)` | `"cmd+alt+left" = ["flash", "window_move", "--position=lefthalf"]` |
| `hs.application.launchOrFocus("Firefox")` | `["flash", "app_open", "--name=Firefox"]` |
| `hs.hotkey.modal` | `[mode.normal.mappings]` and `enter_normal_mode` |
| `hs.hints.windowHints()` | `:flashlight @windows`, or `window_focus --direction=` |
| `hs.menubar` items | `[statusbar]` templates ([status format](../status-format.md)) |
| `hs.alert.show` | Flash's alert for its own verbs; keep Hammerspoon for custom alerts |
| Event-driven Lua (Wi-Fi, USB, screen changes) | Keep Hammerspoon, call `flash <verb>` from it |

```toml
[mode.all.mappings]
"cmd+alt+left" = ["flash", "window_move", "--position=lefthalf"]
"cmd+alt+right" = ["flash", "window_move", "--position=righthalf"]
"cmd+alt+f" = ["flash", "app_open", "--name=Firefox"]
```

Running both is the normal arrangement for Hammerspoon users: Flash owns
hints, modes and the bar; Hammerspoon keeps the automations Flash does not
attempt.

*Checked 2026-10-14 against
[hammerspoon.org](https://www.hammerspoon.org), the
[hs.hints](https://www.hammerspoon.org/docs/hs.hints.html) and
[hs.axuielement](https://www.hammerspoon.org/docs/hs.axuielement.html)
docs, and the [Spoons list](https://www.hammerspoon.org/Spoons/).*
