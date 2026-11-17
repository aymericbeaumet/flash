# Flash and bspwm

[bspwm](https://github.com/baskerville/bspwm) "is a tiling window manager
that represents windows as the leaves of a full binary tree". It "only
responds to X events, and the messages it receives on a dedicated socket":
`bspc` writes those messages, `bspwmrc` "is simply a shell script that calls
bspc", and the keyboard belongs to "a third party program (e.g. sxhkd)". It
is BSD-2-Clause C for X11 on Linux and the BSDs, about 8,300 stars, 0.9.12
in October 2025, with commits into January 2026. It does not run on macOS.
There, [yabai](yabai.md) keeps the binary space partitioning (with skhd for
keys); Flash's opt-in [tiling](../tiling.md) is a different tree,
AeroSpace's, and brings the hotkey daemon inside.

| | bspwm | Flash |
| --- | --- | --- |
| License, price | BSD-2-Clause, free | MIT, free |
| Platforms | X11 on Linux and the BSDs | macOS 13+ |
| Tree | Full binary tree; automatic insertion (longest side, alternate, spiral) or manual preselection; receptacles | Containers of tiles or accordion, horizontal or vertical; a new window goes after the focused one |
| Window states | tiled, pseudo_tiled, floating, fullscreen; flags hidden, sticky, private, locked, marked | tiled, floating, `tile fullscreen` |
| Desktops | Real desktops per monitor (`bspc monitor -d`) | Emulated workspaces, one pool across displays |
| Keys | None: sxhkd or any other daemon | Built in: chords, modes, layers, per-app tables |
| Scripting | `bspc` messages, `query` (JSON with `-T`), `subscribe`, `external_rules_command` | The `flash` CLI over a versioned socket ([IPC protocol](../ipc-protocol.md)), `workspace list`, `flash events watch`, events for monitors and plugins |
| Configuration | `bspwmrc` shell script and `sxhkdrc` | One TOML file, live reload on save |
| Maintenance | 0.9.12, October 2025 | 1.1.0, October 2026; tiling is new |

## Where bspwm is stronger

- **The binary tree, with real choices.** Automatic insertion schemes,
  `bspc node -p west` with `--presel-ratio` to say where the next window
  lands, receptacles to build a layout before its windows exist, and
  `pseudo_tiled` windows that keep their floating size. Flash has no
  preselection or receptacle, and its tree is AeroSpace's containers rather
  than a bsp split.
- **Node flags.** sticky, private, locked (ignores `node --close`), hidden
  and marked for deferred moves. Flash has none; on macOS even yabai needs
  SIP partly off for sticky windows.
- **`bspc` is a query language.** `bspc query -N -n .floating`, a JSON tree
  with `-T`, `subscribe` for every node, desktop and monitor event, and
  `external_rules_command` to decide a new window's rule in a script.
  Flash's rules are fixed fields (bundle ID, title) and it has no tree
  query yet ([not yet](../tiling.md#not-yet)).
- **Real desktops.** macOS gives no public API to switch Spaces, so Flash
  parks a hidden workspace's windows off a bottom corner of the display.
- **It owns the windows.** bspwm sees a window before it maps; Flash moves
  windows through Accessibility once they appear, and apps that refuse a
  frame keep theirs ([limits](../tiling.md#limits)).

## Where Flash is stronger

- **No second daemon and no shell per keypress.** sxhkd forks a shell to run
  `bspc` on each binding; a Flash mapping whose argv starts with `flash`
  runs in the resident's process, and the keys live in the same file as the
  layout.
- **The workspace in the bar without a `subscribe` loop.**
  `#{flash.workspace}` and `#{flash.workspaces}` update as you switch, where
  a bspwm bar reads `bspc subscribe report`.
- **No SIP change** for any of it, where yabai's Space control and sticky
  windows need its scripting addition.
- **Keys that act inside apps**: hints, scrolling and tab switching in
  NORMAL, with per-app tables by bundle ID.

## Flash features you might like

- `tile join --direction=` groups the focused window with its neighbour in
  a new container: preselection after the fact.
- `window last` and `workspace back_and_forth` are `bspc node -f last` and
  `bspc desktop -f last`.
- A [monitor](../monitors.md#runs-and-events) on `core:workspace.changed`
  gets `FLASH_EVENT_WORKSPACE` and `FLASH_EVENT_PREVIOUS`, the
  `bspc subscribe desktop_focus` script without the loop.
- [Layers](../layers.md) for sxhkd's chord chains; see [sxhkd](sxhkd.md).

## Moving from bspwm

| bspwm | Flash, `[tiling] enabled = true` |
| --- | --- |
| `bspc node -f west`, `bspc node -s west` | `window focus --direction=left`, `tile swap --direction=left` |
| `bspc node -t floating`, `-t fullscreen` | `tile float` (again to tile it), `tile fullscreen` |
| `bspc node -t pseudo_tiled` | None |
| `bspc desktop -l next` (monocle) | `tile layout --type=toggle`, tiles to accordion and back, or `tile fullscreen` |
| `bspc node -p west`, `--presel-ratio` | None; `tile join --direction=left` afterwards |
| `bspc node -z right 20 0` | `tile resize --dimension=width --amount=20` |
| `bspc node -c`, `bspc node -k` | `window close`, `app quit --force` |
| `bspc desktop -f '^2'`, `bspc node -d '^2'` | `workspace switch --name=II`, `workspace move_window --name=II` |
| `bspc monitor -d I II III IV V` | `[tiling] workspaces = ["I", "II", "III", "IV", "V"]` |
| `bspc config window_gap 12` | `[tiling.gaps] inner = 12` |
| `bspc config split_ratio 0.52` | None; `tile balance` evens the shares |
| `bspc rule -a Gimp desktop='^8' state=floating` | `[[tiling.rules]]` with `bundle_id`, `workspace` and `float` |
| `bspc rule -a Screenkey manage=off` | `[[tiling.rules]]` with `float = true` |
| `bspc query -D -d focused --names` | `flash workspace list`, the focused one marked `*` |
| `sxhkdrc` | `[mode.all.mappings]`; see [sxhkd](sxhkd.md) |

A bspwmrc and the example sxhkdrc's window keys, with Option for Super:

```toml
[tiling]
enabled = true
workspaces = ["I", "II", "III", "IV", "V"]

[tiling.gaps]
inner = 12
outer = 12

[[tiling.rules]]
bundle_id = "com.apple.ActivityMonitor"
float = true

[[tiling.rules]]
bundle_id = "com.google.Chrome"
workspace = "II"

[mode.all.mappings]
"alt+h" = ["flash", "window", "focus", "--direction=left"]
"alt+j" = ["flash", "window", "focus", "--direction=down"]
"alt+k" = ["flash", "window", "focus", "--direction=up"]
"alt+l" = ["flash", "window", "focus", "--direction=right"]
"alt+shift+h" = ["flash", "tile", "swap", "--direction=left"]
"alt+shift+j" = ["flash", "tile", "swap", "--direction=down"]
"alt+shift+k" = ["flash", "tile", "swap", "--direction=up"]
"alt+shift+l" = ["flash", "tile", "swap", "--direction=right"]
"alt+s" = ["flash", "tile", "float"]
"alt+shift+f" = ["flash", "tile", "fullscreen"]
"alt+m" = ["flash", "tile", "layout", "--type=toggle"]
"alt+w" = ["flash", "window", "close"]
"alt+<backtick>" = ["flash", "window", "last"]
"alt+1" = ["flash", "workspace", "switch", "--name=I"]
"alt+2" = ["flash", "workspace", "switch", "--name=II"]
"alt+3" = ["flash", "workspace", "switch", "--name=III"]
"alt+shift+1" = ["flash", "workspace", "move_window", "--name=I"]
"alt+shift+2" = ["flash", "workspace", "move_window", "--name=II"]
"alt+shift+3" = ["flash", "workspace", "move_window", "--name=III"]
"alt+ctrl+l" = ["flash", "tile", "resize", "--dimension=width", "--amount=20"]
"alt+ctrl+h" = ["flash", "tile", "resize", "--dimension=width", "--amount=-20"]
```

## Keeping the bsp model

If the binary tree is the point, run [yabai](yabai.md) with Flash's
`[tiling]` off: yabai tiles, and Flash keeps the keys, hints and bar. Two
tilers fight over every window, so run one.

*Checked 2026-10-23 against the bspwm [README](https://github.com/baskerville/bspwm),
[bspwm(1)](https://github.com/baskerville/bspwm/blob/master/doc/bspwm.1.asciidoc),
and the example [bspwmrc](https://github.com/baskerville/bspwm/blob/master/examples/bspwmrc)
and [sxhkdrc](https://github.com/baskerville/bspwm/blob/master/examples/sxhkdrc).*
