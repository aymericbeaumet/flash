# Flash and river

[river](https://codeberg.org/river/river) is "a non-monolithic Wayland
compositor": since 0.4 it "does not combine the compositor and window
manager into one program", and any window manager speaking the stable
river-window-management-v1 protocol does the policy (layout, bindings,
focus, decorations) while river renders, frame perfect, and lets you
hot-swap the window manager without restarting your session. The river wiki
lists community window managers in C, Zig, Rust, Janet, Guile and Elisp. The
dynamic tiler many people know, with `riverctl` and `rivertile`, lives on
as [river-classic](https://codeberg.org/river/river-classic) (0.3.17 in April
2026, "river 0.3.x forever!"). river is GPL-3.0 Zig, 0.5.0 in October 2026,
developed on Codeberg with a GitHub mirror. Both are Linux Wayland
compositors with no macOS build; on a Mac, Flash brings your `riverctl map`
lines over as mappings, modes as layers, tags as emulated workspaces with its
opt-in [tiling](../tiling.md).

| | river / river-classic | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free | MIT, free |
| Platforms | Linux, Wayland | macOS 13+ |
| Window management | Any river-window-management-v1 program (0.4+); `riverctl` with a layout generator such as `rivertile` (classic) | Built in, opt-in: a tree of tiles and accordions |
| Workspaces | Tags as a bitmask: a view can carry several, an output can show several | Named workspaces, one per display, a window in exactly one |
| Modes | `riverctl declare-mode`, `enter-mode`, a `locked` mode for the lock screen | Layers, plus NORMAL and INSERT for every app |
| Configuration | An executable `init`, often a shell script of `riverctl` calls | `flash.toml`, applied on save, `flash config check` |
| Maintenance | 0.5.0, October 2026; classic 0.3.17, April 2026 | 1.1.0, October 2026; tiling is new |

## Where river is stronger

- **You choose, or write, the window manager.** The protocol makes a window
  manager a small program in any language, swappable live. Flash's tiling
  is one model, built in, and plugins cannot replace it.
- **Tags.** `set-focused-tags`, `toggle-view-tags` and the all-tags mask
  show several sets at once and put a view on several. Flash's workspaces
  are exclusive.
- **The compositor's guarantees.** Frame-perfect rendering, windows placed
  before they are drawn, a `locked` mode for media keys on the lock screen,
  `map-pointer` for Super-drag moves and resizes. On macOS, WindowServer is
  the only compositor: a tiler moves windows after they appear, through
  Accessibility, and no public API switches Spaces.
- **An init script.** Your configuration is a program; loops like `for i in
  $(seq 1 9)` write nine bindings at once. Flash's file lists each mapping.

## Where Flash is stronger

- **A mode that is more than a key table.** Flash's NORMAL is persistent
  across apps, with hints on every button and link, scrolling and tab keys
  everywhere, and INSERT handing the keyboard back; layers sit on top with
  counts and sequences.
- **Bar, popups and widgets in the same file**, with `#{flash.workspace}`
  and no status program to pipe into a separate bar.
- **Runs on a stock Mac**, with Accessibility as the only grant.

## Flash features you might like

- `riverctl declare-mode` is a [layer](../layers.md); its label shows in
  the bar's pill, and Escape leaves it without a mapping back to `normal`.
  Flash's NORMAL is not river's mode of that name: it is a Vim-style mode
  over every app, and Flash's INSERT is closest to river's `passthrough`.
- `[startup] run` sets key repeat from the same file: macOS counts it in
  1/60 s ticks, so `riverctl set-repeat 50 300` (50 a second, after 300 ms)
  is `KeyRepeat` 1 and `InitialKeyRepeat` 18, applied at the next login
  ([startup commands](../startup.md)).
- A persistent terminal [popup](../popups.md) for the foot window you kept
  on Super+Shift+Return.
- `#{flash.workspaces}` lists the workspaces in the bar.

## Moving from river

| river-classic `init` | Flash (`[tiling] enabled = true`) |
| --- | --- |
| `riverctl map normal Super J focus-view next` | `"alt+j" = ["flash", "window", "focus", "--direction=next"]` in `[mode.all.mappings]` |
| `riverctl map normal Super+Shift J swap next` | `tile swap --direction=down` |
| `riverctl map normal Super Return zoom` | No main area: `tile swap --direction=left` |
| `send-layout-cmd rivertile "main-ratio +0.05"` | `tile resize --dimension=width --amount=50` |
| `send-layout-cmd rivertile "main-location top"` | `tile layout --type=vertical` |
| `rivertile -view-padding 6 -outer-padding 6` | `[tiling.gaps] inner = 6`, `outer = 6` |
| `toggle-float`, `toggle-fullscreen` | `tile float`, `tile fullscreen` |
| `close` | `window close` |
| `focus-output next`, `send-to-output next` | `window focus --direction=right` across displays, `window move --screen=+1` (tiling off) |
| `set-focused-tags 1`, `set-view-tags 1` | `workspace switch --name=1`, `workspace move_window --name=1` |
| `toggle-focused-tags`, all-tags mask | Not available |
| `riverctl rule-add -app-id 'float*' float` | `[[tiling.rules]]` with `bundle_id` and `float = true` |
| `riverctl declare-mode resize`, `enter-mode resize` | `[mode.layers.resize]`, `mode layer --name=resize` |
| The `passthrough` mode (every key to the client but one) | INSERT: keys reach the app and only your chords act |
| `riverctl map locked None XF86AudioPlay spawn …` | Media keys stay macOS's; HYPER's `8` presses play |
| `riverctl spawn foot` | `["flash", "app", "open", "--name=Terminal"]`, or a popup |
| `riverctl set-repeat 50 300` | `defaults write NSGlobalDomain KeyRepeat -int 1` and `InitialKeyRepeat -int 18` in `[startup] run` |

```toml
[tiling]
enabled = true
workspaces = ["1", "2", "3", "4"]

[tiling.gaps]
inner = 6
outer = 6

[startup]
run = [
  ["defaults", "write", "NSGlobalDomain", "KeyRepeat", "-int", "1"],
  ["defaults", "write", "NSGlobalDomain", "InitialKeyRepeat", "-int", "18"],
]

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"alt+j" = ["flash", "window", "focus", "--direction=next"]
"alt+k" = ["flash", "window", "focus", "--direction=previous"]
"alt+shift+j" = ["flash", "tile", "swap", "--direction=down"]
"alt+shift+k" = ["flash", "tile", "swap", "--direction=up"]
"alt+h" = ["flash", "tile", "resize", "--dimension=width", "--amount=-50"]
"alt+l" = ["flash", "tile", "resize", "--dimension=width", "--amount=50"]
"alt+<space>" = ["flash", "tile", "float"]
"alt+shift+f" = ["flash", "tile", "fullscreen"]
"alt+q" = ["flash", "window", "close"]
"alt+shift+<return>" = ["flash", "mode", "terminal", "--name=foot"]
"alt+1" = ["flash", "workspace", "switch", "--name=1"]
"alt+2" = ["flash", "workspace", "switch", "--name=2"]
"alt+shift+1" = ["flash", "workspace", "move_window", "--name=1"]
"alt+shift+2" = ["flash", "workspace", "move_window", "--name=2"]
"alt+r" = ["flash", "mode", "layer", "--name=layout"]

[mode.layers.layout]
label = "LAYOUT"

[mode.layers.layout.mappings]
"h" = ["flash", "tile", "resize", "--dimension=width", "--amount=-50"]
"l" = ["flash", "tile", "resize", "--dimension=width", "--amount=50"]
"v" = ["flash", "tile", "layout", "--type=vertical"]
"s" = ["flash", "tile", "layout", "--type=horizontal"]
"<equal>" = ["flash", "tile", "balance"]

[popup.foot]
command = ["$SHELL", "-l"]
size = "100x30"
persistent = true
```

Layers are part of Flash's modes, which the `mode normal` chord enables;
Flash then starts in NORMAL and swallows keys nothing maps until `i` or a
click ([advanced mode](../modes.md#advanced-mode)).

*Checked 2026-10-23 against the river
[README](https://codeberg.org/river/river) and 0.5.0 release notes, the
river-classic [example init](https://codeberg.org/river/river-classic/src/branch/main/example/init),
and the [window manager list](https://codeberg.org/river/wiki/src/branch/main/pages/wm-list.md)
on the river wiki.*
