# Flash and Hyprland

[Hyprland](https://hyprland.org) is "a 100% independent, dynamic tiling
Wayland compositor that doesn't sacrifice on its looks": its own renderer
(no wlroots), animations with custom bezier and spring curves, blur and
shadows, dwindle, master, scrolling and monocle layouts, special workspaces,
window groups, socket IPC and a plugin manager. It is BSD-3 C++, about
39,000 stars, v0.56.2 in August 2026 with daily commits since, and since
0.55 it is configured in Lua (`hl.bind`, `hl.define_submap`,
`hl.window_rule`). It has no macOS build. On a Mac, Flash takes
the keyboard half of a Hyprland setup (binds, submaps, a bar, a dropdown
terminal) and opt-in [tiling](../tiling.md) with emulated workspaces; the
looks stay behind, because macOS draws every window itself.

| | Hyprland | Flash |
| --- | --- | --- |
| License, price | BSD-3, free | MIT, free |
| Platforms | Linux, Wayland | macOS 13+ |
| What it is | The compositor: it draws every window | An app beside WindowServer, moving windows through Accessibility |
| Layouts | Dwindle, master, scrolling, monocle, Lua and plugin layouts, per workspace | One tree: tiles and accordion, horizontal or vertical |
| Workspaces | Real, dynamic, plus special (scratchpad) workspaces | Emulated: hidden windows parked in a bottom corner |
| Looks | Animations, blur, shadows, gradient borders, shaders | None; macOS's own window chrome |
| Binds | `hl.bind` with flags (`repeating`, `release`, `long_press`, `locked`), submaps, per-device binds | Chords in every mode, NORMAL keys and sequences, layers |
| Configuration | `hyprland.lua`, reloaded on save, `hyprctl` | `flash.toml`, reloaded on save, `flash config check` |
| Maintenance | v0.56.2, August 2026; fast-moving | 1.1.0, October 2026 |

## Where Hyprland is stronger

- **It owns the pixels.** Animations, blur, rounded corners, shaders and
  tearing control are compositor features. On macOS only WindowServer
  composites, so no third-party tool, Flash included, can animate or blur
  another app's window.
- **Layouts and real workspaces.** Dwindle, master and scrolling, chosen per
  workspace, and workspaces the compositor really switches. Flash has one
  tree and parks hidden windows off screen, because macOS has no public API
  to create or switch Spaces.
- **Windows are placed before they are drawn.** A Wayland compositor maps a
  window where the layout wants it. On macOS a window appears where its app
  puts it, and a tiler moves it afterwards through Accessibility; apps with a
  minimum size or a terminal's cell grid keep their own frame.
- **Binds the platform cannot offer elsewhere**: `locked` binds that work
  on the lock screen, binds on lid switches, per-device binds, long presses.
- **Plugins in the compositor** and an ecosystem around it (hypridle,
  hyprlock, hyprpaper), with a large, active community.

## Where Flash is stronger

- **It runs on the Mac in front of you**, with Accessibility as its only
  grant, no SIP change and nothing injected into the Dock.
- **Plain keys instead of SUPER chords.** NORMAL mode reads single letters
  and sequences, so window commands, hints and tab switching need no
  modifier, and INSERT gives the keyboard back to the app.
- **Hints in every app.** `f` labels every button and link of the focused
  window; Hyprland leaves clicking to the mouse or a separate tool such as
  [hints](hints.md).
- **The bar is part of it**: `#{flash.workspace}` and `#{flash.workspaces}`
  need no Waybar module or socket script.

## Flash features you might like

- A [layer](../layers.md) is a submap: `[mode.layers.<name>]`, entered with
  `mode layer --name=<name>`, left with Escape. It swallows every key it does
  not map, as a submap with a `catchall` bind would, and `sticky = false`
  is the submap that resets after one key.
- A persistent [popup](../popups.md) is the special workspace: the same
  running terminal or TUI shown and hidden on one key.
- `mouse target`, `mouse grid --bisect` and `mouse pointer` cover what
  Hyprland users add hints, warpd or keynav for.
- [Monitors](../monitors.md) on `core:workspace.changed`,
  `core:focus.changed` or `core:displays.changed` replace a socket2 script;
  `flash events watch` streams the same events as NDJSON for a script that
  still wants them.

## Moving from Hyprland

| Hyprland | Flash (`[tiling] enabled = true`) |
| --- | --- |
| `hl.bind("SUPER + H", hl.dsp.focus({ direction = … }))` | `"alt+h" = ["flash", "window", "focus", "--direction=left"]` in `[mode.all.mappings]` |
| `hl.dsp.window.move({ direction })` | `tile move --direction=left` |
| `hl.dsp.window.swap({ direction })` | `tile swap --direction=left` |
| `hl.dsp.window.float({ action = "toggle" })` | `tile float` |
| `hl.dsp.window.fullscreen(…)` | `tile fullscreen` within the workspace, `window fullscreen` for native full screen |
| `hl.dsp.focus({ workspace })`, `hl.dsp.window.move({ workspace })` | `workspace switch --name=2`, `workspace move_window --name=2` |
| `hl.dsp.focus({ last })` | `window last`; `workspace back_and_forth` for workspaces |
| `hl.dsp.workspace.toggle_special("term")` | `mode terminal --name=term` on a `persistent` popup |
| `hl.dsp.group.toggle()` (tabbed groups) | `tile layout --type=accordion` |
| `hl.define_submap("resize", …)`, `hl.dsp.submap("reset")` | `[mode.layers.resize]`; Escape leaves |
| `hl.window_rule({ match = { class = … }, float = true })` | `[[tiling.rules]]` with `bundle_id` and `float = true` |
| Workspace rules pinning a workspace to a monitor | `[tiling.monitors]` |
| `general` gaps | `[tiling.gaps] inner`, `outer` |
| `hyprctl dispatch …` | `flash <topic> <action>` from any shell |
| socket2 `workspacev2`, `activewindowv2` | `core:workspace.changed`, `core:window.focus.changed` |
| hypridle, hyprlock | `core:user.idle` monitors and `screen lock` (see [swayidle](swayidle.md)) |
| Dwindle, master, scrolling layouts; animations; blur | Not available |

Apps are matched by bundle identifier, not window class:
`osascript -e 'id of app "Firefox"'` prints one.

```toml
[tiling]
enabled = true
workspaces = ["1", "2", "3", "4", "5"]

[tiling.gaps]
inner = 5
outer = 10

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"alt+h" = ["flash", "window", "focus", "--direction=left"]
"alt+j" = ["flash", "window", "focus", "--direction=down"]
"alt+k" = ["flash", "window", "focus", "--direction=up"]
"alt+l" = ["flash", "window", "focus", "--direction=right"]
"alt+v" = ["flash", "tile", "float"]
"alt+shift+f" = ["flash", "tile", "fullscreen"]
"alt+1" = ["flash", "workspace", "switch", "--name=1"]
"alt+2" = ["flash", "workspace", "switch", "--name=2"]
"alt+shift+1" = ["flash", "workspace", "move_window", "--name=1"]
"alt+shift+2" = ["flash", "workspace", "move_window", "--name=2"]
"alt+s" = ["flash", "mode", "terminal", "--name=special"]
"alt+r" = ["flash", "mode", "layer", "--name=resize"]

[mode.layers.resize.mappings]
"h" = ["flash", "tile", "resize", "--dimension=width", "--amount=-40"]
"l" = ["flash", "tile", "resize", "--dimension=width", "--amount=40"]
"k" = ["flash", "tile", "resize", "--dimension=height", "--amount=-40"]
"j" = ["flash", "tile", "resize", "--dimension=height", "--amount=40"]

[popup.special]
command = ["$SHELL", "-l"]
size = "90%x80%"
persistent = true

[[tiling.rules]]
bundle_id = "com.apple.systempreferences"
float = true
```

The first two chords turn on Flash's modes, which a layer belongs to: Flash
then starts in NORMAL, where keys you have not mapped are swallowed, and `i`
hands typing back to the app ([advanced mode](../modes.md#advanced-mode)).
Every chord above is taken system-wide, so Option-H no longer types its
accented character anywhere; pick `cmd+ctrl+…` if you need those.

*Checked 2026-10-23 against the Hyprland
[README](https://github.com/hyprwm/Hyprland), its releases, and the wiki's
[binds](https://wiki.hypr.land/Configuring/Basics/Binds/),
[dispatchers](https://wiki.hypr.land/Configuring/Basics/Dispatchers/) and
[window rules](https://wiki.hypr.land/Configuring/Basics/Window-Rules/) pages.*
