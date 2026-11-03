# Flash and warpd

[warpd](https://github.com/rvaiya/warpd) is "A modal keyboard-driven
virtual pointer" in MIT-licensed C for Linux (X11 and wlroots) and macOS,
with a Windows alpha, about 3,700 stars. It knows nothing about elements: its
hint mode "indiscriminately covers the entire screen" with labels, its grid
bisects the screen, and its normal mode moves the pointer with `hjkl` and
counts. The last macOS release was v1.3.5 in November 2022 and the last tag
a Windows alpha in April 2023; the last commit was June 2023, and a February
2026 issue asking whether it is maintained has no reply.

| | warpd | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Linux X11 and wlroots, macOS, Windows alpha | macOS 13+ |
| Permissions | Accessibility | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot screen` |
| Targets | Pixels: uniform hint labels, grid, history hints; no element detection | Accessibility elements; keyboard grid; bisect |
| Pointer modes | Normal (vi pointer with counts), hint, two-stage hint, grid, screen selection; drag with `v`, scroll with `e`/`r` | Hints, search, grid, bisect, pointer mode, screens, drag, select, words, path, sticky |
| Configuration | `~/.config/warpd/config`; CLI flags; built to be scripted | One TOML file; `flash <topic> <action>` CLI |
| Maintenance | v1.3.5 for macOS, November 2022; no commit since June 2023 | 1.1.0, October 2026 |

## Where warpd is stronger

- **Linux.** It is the reference modal pointer there, on X11 and on
  wlroots compositors alike.
- **Element-free design works everywhere**, including games and remote
  desktops, because it never asks the app anything.
- **A scriptable single binary**: `--oneshot`, `--click`, `--move`,
  `--query` make it "a poor man's xdotool".
- **Counts in normal mode** (`10l`) for precise movement.

## Where Flash is stronger

- **It knows what is on screen.** One label per button, link or field,
  instead of a label every few pixels.
- **It is maintained and installs from a cask.** warpd on macOS is a
  `curl | sudo tar` into `/`, a LaunchAgent, a self-signed certificate, and
  a `tccutil reset` on upgrade.
- **Non-Latin input sources** work; warpd hangs with them (#290).
- **Everything after the click.**

## Flash features you might like

- `mouse pointer` is warpd's normal mode on macOS, with warpd's own keys:
  `hjkl` (or the arrows) move, `m` `,` `.` click left, middle and right,
  `v` toggles a drag, and Shift moves by 2 points ([commands](../commands.md)).
- `mouse grid --bisect` halves the screen the way warpd's grid does.
- `mouse screens` is screen selection; `mouse position --action=hints` are
  history hints.

## From warpd on X11 or Wayland

Most warpd users run it on Linux, where the habits differ a little from
warpd's own macOS build:

- **Who binds the keys.** On Wayland, clients cannot grab global hotkeys,
  so the compositor runs `warpd --hint` (`bindsym Mod4+Mod1+x exec warpd
  --hint` in sway). On macOS warpd's daemon grabs `A-M-x` itself. In Flash
  a chord in `[mode.all.mappings]` works in every app, and NORMAL's `f`,
  `F` and `s` need no modifier at all.
- **What the platform lets through.** warpd's man page lists, for Wayland,
  no cursor hiding and no way to select elements that need focus, and for
  X, that its XInput use breaks xcape-style remappers. On macOS the limits
  are others: secure input (a password field, iTerm's secure keyboard entry)
  hides keys from every keyboard tap, Flash's included.
- **Remapping.** warpd's man page sends X users who move Caps Lock to
  [keyd](keyd.md), which has no macOS build. Karabiner-Elements or
  [kanata](kanata.md) take that job there, and Flash reads the keys they
  send ([keyboard tools](README.md#automation-and-keyboard)).
- **Scripts.** `warpd --move '<x> <y>'` has no Flash counterpart: Flash
  moves the pointer to targets, grid cells, a window's or screen's edges
  (`mouse warp`) and saved positions, never to raw coordinates.

## Moving from warpd

| warpd | Flash |
| --- | --- |
| `warpd --hint` | `["flash", "mouse", "target"]` for elements, `mouse grid` for positions |
| `warpd --grid` | `["flash", "mouse", "grid", "--bisect"]` |
| `warpd --normal` | `["flash", "mouse", "pointer"]` |
| `--oneshot --click` | `flash mouse target` then type; `flash mouse repeat` re-clicks the last point |
| History hints | `mouse position --action=save`, then `--action=hints` |
| Screen selection | `["flash", "mouse", "screens"]` |
| `e` / `r` scroll | NORMAL `ctrl+e` / `ctrl+y`; `ctrl+d` / `ctrl+u` in a page |
| `v`, then `c` (`copy_and_exit`) | `mode hold` (⌘⌃H), move, then `y` copies the selection |
| `hint_chars` | `[hints] keys` |
| `speed`, `acceleration`, `max_speed` | `[hints] pointer_step`, `pointer_acceleration`, `pointer_max_step`, in points |

```toml
[hints]
pointer_step = 10
pointer_max_step = 120

[mode.all.mappings]
"alt+ctrl+x" = ["flash", "mouse", "target"]
"alt+ctrl+g" = ["flash", "mouse", "grid", "--bisect"]
"alt+ctrl+c" = ["flash", "mouse", "pointer"]
"alt+ctrl+s" = ["flash", "mouse", "screens"]
```

*Checked 2026-10-23 against the warpd
[README](https://github.com/rvaiya/warpd), its
[man page](https://github.com/rvaiya/warpd/blob/master/warpd.1.md),
releases and issue tracker.*
