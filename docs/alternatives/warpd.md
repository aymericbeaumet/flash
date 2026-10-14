# Flash and warpd

[warpd](https://github.com/rvaiya/warpd) is "A modal keyboard-driven
virtual pointer" in MIT-licensed C for Linux (X11 and wlroots) and macOS,
with a Windows alpha. It knows nothing about elements: its hint mode
"indiscriminately covers the entire screen" with labels, its grid bisects
the screen, and its normal mode moves the pointer with `hjkl` and counts. The
last macOS release was v1.3.5 in November 2022; the last commit was May 2023,
and a 2026 issue asking whether it is maintained has no reply.

| | warpd | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Linux X11 and wlroots, macOS, Windows alpha | macOS 14+ |
| Permissions | Accessibility | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot` |
| Targets | Pixels: uniform hint labels, grid, history hints; no element detection | Accessibility elements; keyboard grid; bisect |
| Pointer modes | Normal (vi pointer with counts), hint, two-stage hint, grid, screen selection; drag with `v`, scroll with `e`/`r` | Hints, search, grid, bisect, pointer mode, screens, drag, select, words, path, sticky |
| Configuration | `~/.config/warpd/config`; CLI flags; built to be scripted | One TOML file; `flash <verb>` CLI |
| Maintenance | Unmaintained since 2023 | 1.0.0, October 2026 |

## Where warpd is stronger

- **Linux.** It is the reference modal pointer there.
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

- `mouse_pointer` is warpd's normal mode on macOS: `hjkl`, click keys, `v`
  drag ([commands](../commands.md)).
- `mouse_grid --bisect` halves the screen the way warpd's grid does.
- `mouse_screens` is screen selection; `mouse_position --action=hints` are
  history hints.

## Moving from warpd

| warpd | Flash |
| --- | --- |
| `warpd --hint` | `["flash", "mouse_target"]` for elements, `mouse_grid` for positions |
| `warpd --grid` | `["flash", "mouse_grid", "--bisect"]` |
| `warpd --normal` | `["flash", "mouse_pointer"]` |
| `--oneshot --click` | `flash mouse_target` then type; `flash mouse_repeat` re-clicks the last point |
| History hints | `mouse_position --action=save`, then `--action=hints` |
| Screen selection | `["flash", "mouse_screens"]` |
| `e` / `r` scroll | NORMAL `ctrl+e` / `ctrl+y`, `ctrl+d` / `ctrl+u` |

```toml
[mode.all.mappings]
"alt+meta+x" = ["flash", "mouse_target"]
"alt+meta+g" = ["flash", "mouse_grid", "--bisect"]
"alt+meta+c" = ["flash", "mouse_pointer"]
```

*Checked 2026-10-14 against the warpd
[README](https://github.com/rvaiya/warpd) and man page.*
