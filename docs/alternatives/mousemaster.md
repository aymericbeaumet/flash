# Flash and mousemaster

[mousemaster](https://github.com/petoncle/mousemaster) offers "mouseless
mouse control and advanced keyboard customization for Windows and macOS":
a keyboard mouse and a key remapper in one program, built from modes,
combos, commands and macros in a single `.properties` file that reloads on
save. It is Java, about 900 GitHub stars, with numbered releases roughly
monthly (v95 on 13 October 2026); the repository states no license. The
Windows build is a portable executable. The macOS build is new, unsigned,
and runs as root from a terminal, reading the keyboard through the
Karabiner-Elements virtual HID device. It credits warpd, mouseable, Neru
and kanata as inspiration and ships presets that imitate several of them.

Flash covers mousemaster's mouse side natively on macOS, with the
Accessibility permission only, and leaves key remapping to the tools that
do it best.

| | mousemaster | Flash |
| --- | --- | --- |
| License, price | Source on GitHub, no license stated; free, donations welcome | MIT, free |
| Platforms | Windows; macOS (new, unsigned, run with `sudo`); no Linux | macOS 13+ |
| Permissions | macOS: root, Karabiner-Elements' driver, Input Monitoring, Accessibility for UI hints, Screen Recording for zoom, granted to the terminal it runs in | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot screen` |
| Pointing | Continuous movement, grids, recursive 2×2 grids, Accessibility and vision UI hints, screen selection, position history, zoom | Hints, keyboard-shaped grid, bisect, pointer mode, screens, warps, saved positions, scroll target |
| Keyboard | Combos (sequences, chords, holds, taps, tap-dances), remapping, macros, key aliases, virtual keys | Modes, sequences, layers and per-app mappings to commands; no remapping |
| Beyond pointing | Cursor indicator, conditional properties | NORMAL mode, flashlight, status bar, widgets, popups, window placement, plugins |
| Configuration | One `.properties` file, live reload, six presets | One TOML file, live reload, `flash config check` |
| Maintenance | v95, October 2026; macOS testers wanted | 1.1.0, October 2026 |

## Where mousemaster is stronger

- **One tool for the mouse and the keyboard.** Its combo engine remaps
  keys, does tap-dances and timed holds, and switches modes on any of them.
  Flash's keyboard tap only decides which keys a mode swallows and routes
  them; remapping stays with Karabiner-Elements or kanata.
- **Everything is a primitive.** Modes inherit from each other, any
  property can depend on held keys, the active app or the screen, and the
  presets show how to rebuild warpd, Neru or mouseable from the same parts.
  Flash's modes are fixed, with [layers](../layers.md) as your own key
  tables.
- **Vision hints and zoom.** `ui-vision` labels what stands out on a screen
  capture, for apps with no accessibility tree, and zoom magnifies a hint's
  cell. Flash reads no pixels, so it has neither.
- **The same file on Windows.** One configuration follows you to a PC.

## Where Flash is stronger

- **No root, no driver.** Flash runs as you, from the Applications folder,
  with one Accessibility grant: no virtual HID device, no Input Monitoring,
  and no permissions lent to a terminal.
- **Hints that know the target.** Text fields win over controls laid on
  them, `--copy-url` copies a link, and `--words`, `--path`, `--sticky` and
  `--multi` work from what the app reports.
- **Everything after the click.** NORMAL mode, per-app actions, the
  flashlight, a status bar and popups, in the same file.

## Flash features you might like

- `mouse position --action=save|hints|next|previous|unsave|clear` with
  `[hints] position_history_scope = "app"` is mousemaster's position
  history, one list per app.
- `[hints] pointer_follows_focus = true` centres the pointer on the window
  you switch to, like mousemaster's "center mouse after Alt-Tab".
- `mouse warp --area=window --edge=center` and the other edges jump to a
  window's or the screen's sides.
- `?` opens the key mappings: your layout with the bindings of the mode you
  pick under it, the cheatsheet without holding a key.

## Moving from mousemaster

| mousemaster | Flash |
| --- | --- |
| Normal mode: continuous movement with acceleration (`ijkl`, `hjkl`) | `mouse pointer`: the layout's `hjkl` or the arrows, accelerating while held; `[hints] pointer_step`, `pointer_acceleration`, `pointer_max_step` |
| Slow movement while a modifier is held | Shift: the fine step |
| Press, release, toggle a button; drag | `m` `,` `.` in pointer mode, `v` to hold the button; `mode hold` (HOLD) from NORMAL or INSERT |
| Jump to the screen edges, window edges, window centre | `mouse warp --area=window` or `--area=screen`, with `--edge=center`, `top`, `bottom`, `left` or `right` |
| Wheel scrolling | `ctrl+e` / `ctrl+y` in NORMAL, and `ctrl+d` / `ctrl+u` in a page (in a list or a text field they move the selection or the caret), `scroll left` and `scroll right` sideways, `scroll target` to pick the area |
| Hint grid (labels across the screen) | `mouse grid`: one keyboard-shaped step per keypress, `mouse grid --zoom-to-depth=N` to start deeper |
| Recursive hint grid (2×2, cursor follows) | `mouse grid --bisect` (halves and quarters), or the keyboard grid with `[hints] mouse_grid_cursor_follow = true` |
| Grid mode: shrink, move, snap to the grid's edges | Bisect halves; the arrows slide the region; Shift-arrows snap the pointer to an edge |
| UI hints (`ui-accessibility`) | `mouse target`, Flash's default |
| Vision UI hints (`ui-vision`) | Not available: Flash never reads screen pixels |
| Screen selection mode | `mouse screens` (NORMAL `gm`): each display shows its number; the pointer lands on its centre, or where it left it with `--to=last`; `--direction=next` without labels; `Tab` in the grid moves to the next display |
| Position history: save, hints, cycle, per app | `mouse position --action=…`; `[hints] position_history_size`, `position_history_scope = "app"` |
| Center mouse after Alt-Tab | `[hints] pointer_follows_focus = true` |
| Cursor indicator by mouse state | The pointer-mode ring changes colour while a button is held; the window border shows the mode |
| Zoom | Not available: magnifying needs a screen capture |
| Idle mode, mode history, mode after an unhandled key | NORMAL, INSERT, COMMAND and TERMINAL; `mode leave`; unmapped NORMAL keys are swallowed by design |
| App-specific combos | `[mode.apps."<bundle id>".<mode>.mappings]` |
| Macros (`+leftctrl +v -v -leftctrl`) | `key send --keys=cmd+v`, `key sequence` |
| Combos: holds, taps, tap-dances, timed sequences; key aliases; virtual keys | Not in Flash. Keep [Karabiner-Elements](karabiner-elements.md) or [kanata](https://github.com/jtroo/kanata) for remapping; they run alongside Flash |
| Hint appearance (fonts, colours, animations) | [`[overlay]`](config:overlay) colours, font size and placement. No animations: hints are drawn in one commit |

[`docs/examples/mousemaster/flash.toml`](../examples/mousemaster/flash.toml)
follows the neo-mousekeys layout: `alt+e` enters NORMAL, `i` opens pointer
mode, and the hint, grid, screen and position modes sit on `f`, `g`, `c` and
`p` ([the example's notes](../examples/mousemaster/README.md)). Its core:

```toml
[hints]
pointer_step = 10
pointer_acceleration = 8
pointer_max_step = 120
pointer_follows_focus = true
position_history_scope = "app"

[mode.all.mappings]
"alt+e" = ["flash", "mode", "normal"]
"alt+q" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"i" = ["flash", "mouse", "pointer"]
"g" = ["flash", "mouse", "grid", "--bisect"]
"c" = ["flash", "mouse", "screens"]
"p" = ["flash", "mouse", "position", "--action=hints"]
"P" = ["flash", "mouse", "position", "--action=save"]
```

## Using both

On a Mac, run one keyboard mouse at a time: both draw an overlay and both
want the same chords, and two pointer modes fighting over `ijkl` help no
one. If you came for mousemaster's remapping, Karabiner-Elements, which its
macOS build already needs installed, does that job next to Flash without a
root process. On a Windows PC, keep mousemaster; the example above keeps the
same `alt+e` and `ijkl` habits on both machines.

*Checked 2026-10-23 against the mousemaster
[README](https://github.com/petoncle/mousemaster),
[configuration reference](https://github.com/petoncle/mousemaster/blob/main/docs/configuration-reference.md)
and [releases](https://github.com/petoncle/mousemaster/releases).*
