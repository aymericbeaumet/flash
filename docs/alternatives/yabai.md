# Flash and yabai

[yabai](https://github.com/asmvik/yabai) is "Tiling window management for
the Mac", "designed to work as an extension to the built-in window manager
of macOS": binary space partitioning, native Spaces, signals, and an
optional scripting addition injected into Dock.app that needs SIP partially
disabled. It is MIT C, about 30,000 stars, v7.1.25 in May 2026, with
keyboard shortcuts delegated to skhd. Flash's opt-in [tiling](../tiling.md)
is AeroSpace's tree with emulated workspaces rather than yabai's binary
space partitioning over native Spaces, and needs no SIP change.

| | yabai | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 11+ (Intel), 12+ (Apple Silicon), up to 26 | macOS 13+ |
| Permissions | Accessibility; Screen Recording for animations; SIP partially disabled and passwordless sudo for the scripting addition | Accessibility; no SIP change |
| Windows | bsp, stack and float layouts over native Spaces; space control, opacity and animations with the scripting addition | Opt-in tree tiling (tiles and accordion, h/v) with emulated workspaces; named positions, proportional frames, placement rules, directional focus, full screen |
| Hotkeys | None; skhd or another daemon | Built in, per mode and per app |
| Hints, bar | None; signals for bars | Hints in every app, bar, widgets, popups |
| Configuration | `~/.yabairc` shell script | TOML, live reload |
| Maintenance | v7.1.25, May 2026 | 1.0.0, October 2026 |

## Where yabai is stronger

- **Native Spaces and full screen** work with it, which no other tiler
  manages; Flash's workspaces are its own, and it tiles only the active
  Space's windows.
- **A complete window model**: automatic bsp insertion, stacking, floating
  rules, modifier-drag move and resize, signals for every window event, and
  with the scripting addition animations, opacity and Space control, which
  Flash leaves out on purpose ([out of scope](../tiling.md#out-of-scope-and-why)).
- **Runs on older macOS versions.**

## Where Flash is stronger

- **No SIP change, no sudo, no scripting addition.** Flash, tiling
  included, is installable on a managed work machine where yabai's full
  feature set is not.
- **Hotkeys are built in**, with modes and per-app tables, so no skhd.
- **Hints, search, bar, widgets, popups, plugins.**

## Flash features you might like

- NORMAL mode as the keyboard layer skhd would provide, with the mode shown
  in the bar, and [layers](../layers.md) for skhd's modes: a
  `[mode.layers.<name>]` table of `yabai -m` argv that Escape leaves.
- `window focus --direction=` for focus moves that do not depend on the
  tiling tree.
- A bar source running `yabai -m query --spaces --space` for the current
  space.

## Moving from yabai

| yabai | Flash, `[tiling] enabled = true` |
| --- | --- |
| `window --focus west` | `window focus --direction=left` |
| `window --swap west` | `tile swap --direction=left` |
| `window --warp west` | `tile move --direction=left` |
| `window --toggle float` | `tile float` |
| `window --toggle zoom-fullscreen` | `tile fullscreen` |
| `window --resize right:50:0` | `tile resize --dimension=width --amount=50` |
| `space --balance` | `tile balance` |
| `space --layout stack` | `tile layout --type=accordion` |
| `space --focus 2` (scripting addition) | `workspace switch --name=2` |
| `window --space 2` | `workspace move_window --name=2` |
| `config window_gap 8`, `top_padding` … | `[tiling.gaps] inner = 8`, `outer_top` … |
| `rule --add app=… manage=off` | `[[tiling.rules]]` with `bundle_id` and `float = true` |
| `signal --add event=space_changed` | A plugin or [monitor](../monitors.md) on `core:workspace.changed`, or `flash events watch --name=core:workspace.changed` in a script |
| skhd bindings | `[mode.all.mappings]` and a [layer](../layers.md) |

A bsp split chooses its side as windows open; Flash's tree inserts after the
focused window, and `tile join` and `tile layout` build the splits. Stop
yabai before turning `[tiling]` on: two tilers fight over every window.

## Using both

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; layers need them
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"cmd+shift+space" = ["flash", "mouse", "target"]
"cmd+shift+y" = ["flash", "mode", "layer", "--name=yabai"]  # skhd's `:: yabai @`

[mode.layers.yabai.mappings]
"h" = ["yabai", "-m", "window", "--focus", "west"]
"l" = ["yabai", "-m", "window", "--focus", "east"]
"H" = ["yabai", "-m", "window", "--swap", "west"]
"L" = ["yabai", "-m", "window", "--swap", "east"]

[statusbar.sources.space]
command = ["sh", "-c", "yabai -m query --spaces --space | jq .index"]
```

Leave window placement to yabai, with Flash's `[tiling]` off; Flash's
`window move` on a tiled window will be undone by the tiler.

*Checked 2026-10-14 against the yabai
[README](https://github.com/asmvik/yabai) and
[wiki](https://github.com/asmvik/yabai/wiki); the scripting-addition
features against the wiki on 2026-10-23.*
