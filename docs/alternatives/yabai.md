# Flash and yabai

[yabai](https://github.com/asmvik/yabai) is "Tiling window management for
the Mac", "designed to work as an extension to the built-in window manager
of macOS": binary space partitioning, native Spaces, signals, and an
optional scripting addition injected into Dock.app that needs SIP partially
disabled. It is MIT C, about 30,000 stars, v7.1.25 in May 2026, with
keyboard shortcuts delegated to skhd. Flash does not tile and runs next to
it.

| | yabai | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 11+ (Intel), 12+ (Apple Silicon), up to 26 | macOS 14+ |
| Permissions | Accessibility; Screen Recording for animations; SIP partially disabled and passwordless sudo for the scripting addition | Accessibility; no SIP change |
| Windows | bsp, stack and float layouts over native Spaces; space control, opacity and animations with the scripting addition | Named positions, proportional frames, placement rules, directional focus, full screen |
| Hotkeys | None; skhd or another daemon | Built in, per mode and per app |
| Hints, bar | None; signals for bars | Hints in every app, bar, widgets, popups |
| Configuration | `~/.yabairc` shell script | TOML, live reload |
| Maintenance | v7.1.25, May 2026 | 1.0.0, October 2026 |

## Where yabai is stronger

- **Native Spaces and full screen** work with it, which no other tiler
  manages.
- **A complete window model**: bsp, stacking, floating rules, animations,
  opacity, signals.
- **Runs on older macOS versions.**

## Where Flash is stronger

- **No SIP change, no sudo, no scripting addition.** Flash is installable on
  a managed work machine where yabai is not.
- **Hotkeys are built in**, with modes and per-app tables, so no skhd.
- **Hints, search, bar, widgets, popups, plugins.**

## Flash features you might like

- NORMAL mode as the keyboard layer skhd would provide, with the mode shown
  in the bar.
- `window_focus --direction=` for focus moves that do not depend on the
  tiling tree.
- A bar source running `yabai -m query --spaces --space` for the current
  space.

## Using both

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target"]

[statusbar.sources.space]
command = ["sh", "-c", "yabai -m query --spaces --space | jq .index"]
```

Leave window placement to yabai; Flash's `window_move` on a tiled window
will be undone by the tiler.

*Checked 2026-10-14 against the yabai
[README](https://github.com/asmvik/yabai) and
[wiki](https://github.com/asmvik/yabai/wiki).*
