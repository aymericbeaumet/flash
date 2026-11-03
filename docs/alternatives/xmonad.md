# Flash and xmonad

[xmonad](https://xmonad.org) is "a tiling window manager for X11", "written,
configured and extensible in Haskell": windows tile the screen without gaps
or overlap, layouts apply per workspace, and xmonad-contrib adds "hundreds of
additional community-maintained tiling algorithms and extension modules",
which together are "quite literally, libraries for creating your own window
manager". It is BSD-3, about 3,600 stars, with xmonad 0.18.1 and
xmonad-contrib 0.18.2 released in March 2026; the core is deliberately
small and stable. It manages X11 windows only, so it has nothing to tile on a
Mac. There, [Amethyst](amethyst.md) is the tiler built "à la xmonad",
and Flash covers the keyboard, the bar and a scratchpad, with an opt-in
[tiling](../tiling.md) tree that is i3's model rather than xmonad's.

| | xmonad | Flash |
| --- | --- | --- |
| License, price | BSD-3, free | MIT, free |
| Platforms | X11 on Linux and the BSDs | macOS 13+ |
| Model | Master area and stack; layouts as Haskell values (`Tall`, `Mirror`, `Full`, contrib's many more) | One tree of containers: tiles or accordion, horizontal or vertical; no master area |
| Workspaces | Real, one per screen, `view` and `greedyView` | Emulated: hidden windows parked in a bottom corner |
| Keys | `keys` and EZConfig (`"M-S-<Return>"`), Submap, per-window keys from contrib | Chords in every mode, NORMAL keys and sequences, layers, per-app tables |
| Bar | xmobar or any bar through `XMonad.Hooks.StatusBar` | Built in, with `#{flash.workspace}` |
| Configuration | `xmonad.hs`, compiled; `M-q` recompiles and restarts | `flash.toml`, applied on save, `flash config check` |
| Maintenance | 0.18.1 / contrib 0.18.2, March 2026; steady | 1.1.0, October 2026; tiling is new |

## Where xmonad is stronger

- **Your window manager is a program.** Layout algorithms, hooks and key
  handlers are Haskell, checked by the compiler before they run, with
  contrib's layouts (grids, columns, tabs, BSP) and combinators to compose
  them. Flash is configured in data: no language, no layouts of your own,
  and plugins cannot add one.
- **The master and stack model.** `M-h`/`M-l` resize the master area,
  `M-,`/`M-.` change how many windows it holds, and `M-Return` swaps a
  window into it. Flash's tree has no master; [Amethyst](amethyst.md)
  is the macOS tiler that keeps that idea.
- **Real workspaces on every screen.** `greedyView` pulls a workspace to
  the focused screen in one step. macOS has no public API to switch Spaces,
  so Flash moves the windows of hidden workspaces off screen instead.
- **Placement before the first frame.** xmonad tiles a window as it maps.
  On macOS a window appears where its app puts it and is moved afterwards
  through Accessibility, and an app with a minimum size keeps it.
- **Stability by design**: a small core that changes slowly, and a
  community that has kept it going since 2007.

## Where Flash is stronger

- **No toolchain.** Nothing compiles: saving `flash.toml` applies it, and
  `flash config check` reports a mistake as `file:line:col` before you
  reload, without GHC installed.
- **Keys beyond windows.** NORMAL mode adds hints on every button and link,
  Vim keys for tabs and scrolling in every app, and a command line where
  `:ta nex` is `tab next`.
- **The bar, popups and widgets are part of it**, fed by the same values,
  so there is no xmobar pipe to set up.
- **A Mac without SIP changes**, Accessibility being the only grant.

## Flash features you might like

- `sticky = false` makes a [layer](../layers.md) behave like
  `XMonad.Actions.Submap`: one key, then back to where you were.
- A persistent terminal [popup](../popups.md) is a named scratchpad: the
  same process shown and hidden on one key.
- `window switch` (`:ls`) lists every window with a hint label, the job of
  `XMonad.Actions.WindowBringer` or a window prompt.
- [Monitors](../monitors.md) on `core:workspace.changed` take the place of
  a `logHook` that prints workspaces for a bar.

## Moving from xmonad

| xmonad | Flash (`[tiling] enabled = true`) |
| --- | --- |
| `M-j`, `M-k` (focus down and up the stack) | `window focus --direction=down` / `up`, by geometry; `--direction=next` / `previous` walk the stacking order |
| `M-Return` (swap with master) | No master: `tile swap --direction=left` swaps with the left neighbour |
| `M-h`, `M-l` (shrink and expand the master) | `tile resize --dimension=width --amount=-50` / `50` |
| `M-space` (next layout) | `tile layout --type=toggle` (tiles and accordion) |
| `Mirror Tall`, `Full` | `tile layout --type=vertical`, `tile layout --type=accordion` or `tile fullscreen` |
| `M-t` (sink a floating window) | `tile float`, which toggles |
| `M-S-c` | `window close` |
| `M-1` … `M-9`, `M-S-1` … `M-S-9` | `workspace switch --name=1`, `workspace move_window --name=1` |
| `M-w`, `M-e`, `M-r` (screens) | `window focus --direction=` crosses displays; `workspace move_to_monitor --direction=next` moves a workspace |
| `className =? "Gimp" --> doFloat` | `[[tiling.rules]]` with `bundle_id` and `float = true` |
| `className =? "Slack" --> doShift "chat"` | `[[tiling.rules]]` with `workspace = "chat"` |
| `XMonad.Layout.Spacing` | `[tiling.gaps]` |
| `XMonad.Util.NamedScratchpad` | A `persistent = true` terminal popup, `mode terminal --name=` |
| `XMonad.Actions.Submap` | A layer with `sticky = false` |
| `spawn "dmenu_run"`, `XMonad.Prompt` | `mode flashlight`; `menu choose` for scripts that pipe to dmenu |
| xmobar through `XMonad.Hooks.StatusBar` | `[statusbar]` with `#{flash.workspaces}` |
| `M-q` (recompile, restart) | Save the file; `flash config check` validates it |

```toml
[tiling]
enabled = true
workspaces = ["1", "2", "3", "4", "chat"]
layout = "tiles"

[tiling.gaps]
inner = 4
outer = 4

[[tiling.rules]]
bundle_id = "com.tinyspeck.slackmacgap"
workspace = "chat"

[mode.all.mappings]
"alt+j" = ["flash", "window", "focus", "--direction=down"]
"alt+k" = ["flash", "window", "focus", "--direction=up"]
"alt+h" = ["flash", "tile", "resize", "--dimension=width", "--amount=-50"]
"alt+l" = ["flash", "tile", "resize", "--dimension=width", "--amount=50"]
"alt+<return>" = ["flash", "tile", "swap", "--direction=left"]
"alt+<space>" = ["flash", "tile", "layout", "--type=toggle"]
"alt+t" = ["flash", "tile", "float"]
"alt+shift+c" = ["flash", "window", "close"]
"alt+p" = ["flash", "mode", "flashlight"]
"alt+1" = ["flash", "workspace", "switch", "--name=1"]
"alt+2" = ["flash", "workspace", "switch", "--name=2"]
"alt+shift+1" = ["flash", "workspace", "move_window", "--name=1"]
"alt+shift+2" = ["flash", "workspace", "move_window", "--name=2"]
"alt+<backtick>" = ["flash", "mode", "terminal", "--name=scratch"]

[popup.scratch]
command = ["$SHELL", "-l"]
size = "80%x60%"
persistent = true

[statusbar]
enabled = true
template = "#[align=left]#[pill] #{flash.workspace} #[nopill] #{flash.workspaces}#[align=right]%H:%M"
```

A Submap of launchers is a one-shot layer. Layers live in Flash's modes,
which the `mode normal` chord turns on; from then Flash starts in NORMAL,
where unmapped keys are swallowed until `i` or a click
([advanced mode](../modes.md#advanced-mode)):

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"alt+o" = ["flash", "mode", "layer", "--name=launch"]

[mode.layers.launch]
sticky = false

[mode.layers.launch.mappings]
"f" = ["flash", "app", "open", "--name=Firefox"]
"t" = ["flash", "app", "open", "--name=Terminal"]
"m" = ["flash", "app", "open", "--name=Mail"]
```

## Using Amethyst for the layouts

If the master and stack are what you miss, leave Flash's `[tiling]` off and
let Amethyst tile: its default modifiers are Option-Shift and
Control-Option-Shift, so keep Flash's window chords off those, and Flash
still brings the bar, hints, NORMAL mode and popups.

*Checked 2026-10-23 against the xmonad
[README](https://github.com/xmonad/xmonad), [site](https://xmonad.org),
the xmonad and xmonad-contrib releases, and the
[Amethyst README](https://github.com/ianyh/Amethyst).*
