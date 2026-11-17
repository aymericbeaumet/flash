# Flash and Amethyst

[Amethyst](https://github.com/ianyh/Amethyst) is an "Automatic tiling
window manager for macOS à la xmonad": every window on a Space is laid out
by the layout you picked, and two modifier chords (`option+shift` and
`ctrl+option+shift`) cycle layouts, resize the main pane and throw windows
to other Spaces and screens. It is MIT Swift by Ian Ynda-Hummel, about
16,000 GitHub stars, free "and always will be", for macOS 10.15 and later
per its README. v0.24.3 in April 2026 fixed a reflow crash after 0.24.2
reworked native tabs, and commits continue in October 2026.

Flash's opt-in [tiling](../tiling.md) is a different model: AeroSpace's tree
of containers, which you shape with commands, over workspaces Flash
emulates. Neither is a superset of the other, and this page says where each
one fits.

| | Amethyst | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 10.15+ | macOS 13+ |
| Permissions | Accessibility | Accessibility |
| Tiling model | xmonad layouts: tall, wide, two pane, three columns, column, row, fullscreen, BSP, floating, and custom layouts in JavaScript (beta) | Opt-in tree: tiles and accordion containers, horizontal or vertical, that `tile join` and `tile layout` build |
| Spaces | Tiles each native Space; throws windows to Space 1–16 | Emulated workspaces; native Spaces left to macOS |
| Mouse | Optional focus follows mouse, drag to swap, drag to resize the layout | Drag a tile to another display; hand moves and resizes snap back |
| Beyond windows | None | Hints, modes, flashlight, status bar, widgets, popups, plugins |
| Configuration | Preferences window, or `~/.amethyst.yml` overriding it | One TOML file, live reload, `flash config check` |
| Maintenance | v0.24.3, April 2026; active | 1.1.0, October 2026; tiling is new |

## Where Amethyst is stronger

- **Ready-made layouts.** Pick `tall` and every window has a place: a main
  pane, the rest stacked beside it, `mod1 + ,` and `mod1 + .` for how many
  windows the main pane holds. Flash's tree starts as one row of tiles and
  you build anything else with `tile join` and `tile layout`; there is no
  main pane and no layout to cycle through.
- **Native Spaces.** Amethyst tiles whichever Space you are on and throws a
  window to Space 3 with `mod2 + 3`. Flash's workspaces are its own, and
  macOS gives it no API to move a window between Spaces
  ([out of scope](../tiling.md#out-of-scope-and-why)).
- **The mouse is part of the model.** `focus-follows-mouse`,
  `mouse-swaps-windows` and `mouse-resizes-windows` are options today;
  in Flash, drag to swap and hand resize are on the
  [not yet](../tiling.md#not-yet) list, and a tile you drag snaps back.
- **Custom layouts in JavaScript**, and BSP, column and row layouts beside
  xmonad's.
- **Years of app quirks** handled, and a lower macOS floor.

## Where Flash is stronger

- **One process for windows and everything else.** Hints in every app,
  NORMAL mode, the flashlight, the bar and popups share the file that holds
  the tiling.
- **The workspace in the bar**: `#{flash.workspace}` and
  `#{flash.workspaces}`, and `core:workspace.changed` for plugins and
  [monitors](../monitors.md), with nothing to wire up.
- **Tiling is optional.** With `[tiling]` off, Flash still places windows
  with `window move`, applies `[[window_rules]]` once per window and keeps a
  window's slot through display changes, and never moves anything you did
  not ask it to.
- **Directional focus** that crosses displays and containers the way the
  screen looks, rather than around a cycle.

## Flash features you might like

- `tile layout --type=accordion` is the closest thing to Amethyst's
  fullscreen layout: the focused window in front, the others showing
  `accordion_padding` points behind it.
- `[[tiling.rules]]` float an app or send it to a workspace, like
  Amethyst's `floating` list, with a `title_contains` match as well.
- `[tiling.monitors]` pins a workspace to the main or secondary display.
- A [layer](../layers.md) holds all the tiling keys behind one chord, so
  they need no modifiers at all.

## Moving from Amethyst

| Amethyst | Flash, `[tiling] enabled = true` |
| --- | --- |
| `mod1 + j` / `mod1 + k`, focus around the layout | `window focus --direction=left`, `right`, `up` or `down` |
| `mod2 + j` / `mod2 + k`, swap around the layout | `tile swap --direction=…` |
| `mod1 + enter`, swap with the main window | No main window; `tile move --direction=…` until it is where you want |
| `mod1 + h` / `mod1 + l`, shrink or expand the main pane | `tile resize --dimension=smart --amount=-50` or `50` |
| `mod1 + ,` / `mod1 + .`, main pane count | Not available; `tile join` builds the split you want |
| `mod1 + space`, cycle layouts; `mod1 + a`, `s`, `d`, `f` | `tile layout --type=toggle` switches tiles and accordion; `--type=horizontal` or `vertical` |
| `mod1 + t`, toggle float | `tile float` |
| `mod2 + t`, toggle global tiling | `[tiling] enabled` in the file; no command toggles it |
| `mod2 + 1` … `mod2 + 0`, throw to a Space | `workspace move_window --name=1` …, Flash's workspaces |
| `mod2 + w` / `e` / `r`, throw to a screen | `workspace move_window` to the workspace that display shows, or drag the window there |
| `mod1 + n` / `mod1 + p`, focus the next screen | `window focus --direction=…` crosses displays; `workspace move_to_monitor` moves a workspace |
| `floating` bundle IDs | `[[tiling.rules]]` with `bundle_id` and `float = true` |
| `window-margins`, `window-margin-size` | `[tiling.gaps] inner` |
| `screen-padding-left` … `-bottom` | `[tiling.gaps] outer_left` … `outer_bottom` |
| `mouse-follows-focus` | `[hints] pointer_follows_focus = true`, on app switches |
| `focus-follows-mouse`, `mouse-swaps-windows`, `mouse-resizes-windows` | Not available yet |
| Custom JavaScript layouts | Not available |

Amethyst's `mod1` (`option+shift`) chords, kept for the commands that have a
counterpart:

```toml
[tiling]
enabled = true
workspaces = ["1", "2", "3", "4"]

[tiling.gaps]
inner = 8
outer = 8

[mode.all.mappings]
"alt+shift+j" = ["flash", "window", "focus", "--direction=left"]
"alt+shift+k" = ["flash", "window", "focus", "--direction=right"]
"alt+shift+h" = ["flash", "tile", "resize", "--dimension=smart", "--amount=-50"]
"alt+shift+l" = ["flash", "tile", "resize", "--dimension=smart", "--amount=50"]
"alt+shift+<space>" = ["flash", "tile", "layout", "--type=toggle"]
"alt+shift+t" = ["flash", "tile", "float"]
"ctrl+alt+shift+j" = ["flash", "tile", "swap", "--direction=left"]
"ctrl+alt+shift+k" = ["flash", "tile", "swap", "--direction=right"]
"ctrl+alt+shift+1" = ["flash", "workspace", "move_window", "--name=1"]
"ctrl+alt+shift+2" = ["flash", "workspace", "move_window", "--name=2"]

[[tiling.rules]]
bundle_id = "com.apple.systempreferences"
float = true
```

Quit Amethyst before saving `[tiling] enabled = true`: two tilers fight over
every window.

## Using both

Keep Amethyst as the tiler and leave Flash's `[tiling]` off; that is the
arrangement for anyone who likes xmonad's layouts or needs native Spaces.
Flash then adds hints, modes and the bar around it. Two things to leave
alone: `window move` and `[[window_rules]]` on a window Amethyst tiles, which
Amethyst will reflow on its next pass, and Amethyst's `option+shift` and
`ctrl+option+shift` chords, which Flash's defaults do not use. NORMAL's
`ctrl+w h` `j` `k` `l` (`window focus --direction=`) work beside Amethyst,
since they only change focus.

*Checked 2026-10-23 against the Amethyst
[README](https://github.com/ianyh/Amethyst),
[configuration file reference](https://github.com/ianyh/Amethyst/blob/development/docs/configuration-files.md),
[releases](https://github.com/ianyh/Amethyst/releases) and
[commit history](https://github.com/ianyh/Amethyst/commits/development).*
