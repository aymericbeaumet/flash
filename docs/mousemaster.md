# Coming from mousemaster

[mousemaster](https://github.com/petoncle/mousemaster) is a keyboard mouse
and key remapper for Windows, with a macOS build that runs as root through the
Karabiner virtual HID device. It composes modes, combos and commands from a
properties file. Flash covers its mouse side natively on macOS, with the
Accessibility permission only, and leaves key remapping to the tools that do it
best.

## Mode by mode

| mousemaster | Flash |
| --- | --- |
| Normal mode: continuous movement with acceleration (`ijkl`, `hjkl`) | `mouse_pointer`: the layout's `hjkl` or the arrows, accelerating while held; `[hints] pointer_step`, `pointer_acceleration`, `pointer_max_step` |
| Slow movement while a modifier is held | Shift: the 2-point fine step |
| Press, release, toggle a button; drag | `m` `,` `.` in pointer mode, `v` to hold the button; `mouse_button --state=down|up|toggle` anywhere |
| Jump to the screen edges, window edges, window centre | `mouse_warp --area=window|screen --edge=center|top|bottom|left|right` |
| Wheel scrolling | `ctrl+e` / `ctrl+y` and `ctrl+d` / `ctrl+u` in NORMAL, `h` / `l` sideways, `scroll_target` to pick the area |
| Hint grid (labels across the screen) | `mouse_grid`: one keyboard-shaped step per keypress, `mouse_grid --zoom-to-depth=N` to start deeper |
| Recursive hint grid (`3×3`, cursor follows) | `mouse_grid --bisect` (halves and quarters) or the keyboard grid with `mouse_grid_cursor_follow = true` |
| Grid mode: shrink, move, snap to the grid's edges | Bisect halves; the arrows slide the region; `Shift`-arrows snap the pointer to an edge |
| UI hints (accessibility) | `mouse_target`, Flash's default |
| Vision UI hints (screen capture) | Not available: Flash never reads screen pixels |
| Screen selection mode | `mouse_screens`: one label per display, the pointer lands on its centre; `Tab` in the grid moves to the next display |
| Position history: save, hints, cycle, per app | `mouse_position --action=save|hints|next|previous|unsave|clear`; `[hints] position_history_size`, `position_history_scope = "app"` |
| Center mouse after Alt-Tab | `[hints] pointer_follows_focus = true` |
| Cursor indicator by mouse state | The pointer-mode ring changes colour while a button is held; the window border shows the mode |
| Zoom | Not available: magnifying needs Screen Recording |
| Idle mode, mode history, mode after an unhandled key | NORMAL, INSERT, COMMAND and TERMINAL; `leave_mode`; unmapped NORMAL keys are swallowed by design |
| App-specific combos | `[mode.apps."<bundle id>".<mode>.mappings]` |
| Macros (`+leftctrl +v -v -leftctrl`) | `send_key --keys=cmd+v`, `send_keys` |
| Combos: holds, taps, tap-dances, timed sequences; key aliases; virtual keys | Not in Flash. Flash's keyboard tap only decides which key it swallows. Keep [Karabiner-Elements](https://karabiner-elements.pqrs.org) or [kanata](https://github.com/jtroo/kanata) for remapping; they run alongside Flash |
| Cheatsheet while a key is held | `?` opens the mapping list; the [keyboard map](help.md) draws the bindings of the live mode |
| Hint appearance (fonts, gradients, animations) | `[overlay]` colours, font size and placement. No animations: hints are drawn in one commit |

## A mousemaster-shaped configuration

[`docs/examples/mousemaster/flash.toml`](examples/mousemaster/flash.toml)
follows the neo-mousekeys layout: one chord enters pointer mode, `ijkl` is the
pointer's cluster through the arrows, and the hint, grid and screen modes sit on
`f`, `g` and `c` of NORMAL:

```toml
[hints]
pointer_step = 10
pointer_acceleration = 8
pointer_max_step = 120
pointer_follows_focus = true
position_history_scope = "app"

[mode.all.mappings]
"alt+e" = ["flash", "enter_normal_mode"]

[mode.normal.mappings]
"i" = ["flash", "mouse_pointer"]
"g" = ["flash", "mouse_grid", "--bisect"]
"c" = ["flash", "mouse_screens"]
"p" = ["flash", "mouse_position", "--action=hints"]
"P" = ["flash", "mouse_position", "--action=save"]
```

## What stays different

- **Remapping is someone else's job.** mousemaster's combo engine is a
  keyboard remapper; Flash's tap swallows the keys of a mode and routes them,
  and does nothing else with them. That rule keeps the keyboard path short and
  the permission set to Accessibility alone.
- **No screen capture.** Vision hints and zoom read pixels; Flash does not.
- **One process, no root.** Flash runs as the user, from the Applications
  folder, with no virtual HID driver.
