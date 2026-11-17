# Mouse grid and pointer

`flash mouse grid` (NORMAL `F`) divides the display into a keyboard-shaped
grid, including Flash's status bar. Press the key nearest your destination to
zoom into its cell. Repeat until the last step clicks. Every step uses the
same layout. The grid stops at the Dock, and at the menu bar when the Flash
bar is hidden.

```text
1 2 3 4 5
q w e r t
a s d f g
z x c v b
```

These are the QWERTY keys. Layout references in `[hints] keys` select the
corresponding left-hand block; `mouse_grid_keys` supplies your own
rectangular matrix. `mouse_grid_steps` defaults to three.

| Key | Action |
| --- | --- |
| Grid key | Refine, then click on the last step |
| Space | Refine toward the center |
| Return | Click the current region's center now |
| Backspace | Undo a selection, move or display switch |
| Command/Option-Backspace | Start over on the display |
| Arrow keys | Move the region by its own size |
| Tab / Shift-Tab | Next / previous display |
| Backtick | Toggle cursor-follow |
| Escape | Cancel |

## Change the action or geometry

`cF`, `dF` and `mF` request a right-click, a double click and movement. The
grid accepts the same click modifiers and action flags as
[hints](hints.md). `--drag` and `--select` collect two positions; `--multi`
starts again after each click, a click into an input included, until Escape
or a menu takes the keyboard, so it takes no `--secondary`.
`--zoom-to-depth=N` begins around the pointer.

`flash mouse grid --bisect` keeps a half with the keys at the QWERTY h/j/k/l
positions of `[keyboard] layout` (h/j/k/l on QWERTY, h/n/e/i on Colemak,
d/h/t/n on Dvorak, c/t/s/r on Bépo) and a quadrant with the keys at y/u and
b/n. Bépo's top-left quadrant is the dead key `^`. Return commits
immediately; otherwise it commits when the region is small enough.

## Pick a display

`flash mouse screens` (NORMAL `gm`) is monitor select. Every display shows
its number at its centre, counted left to right and then top to bottom, the
numbers `[widgets.<name>] screen` uses. Type one and the pointer moves to the
centre of that display; Escape cancels. With one display there is nothing to
pick, so it acts at once. The mode never changes, and a display unplugged
while its number is up cancels the pick.

| Option | Does |
| --- | --- |
| `--index=<n>`, or a count (`2gm`) | Display `n` at once, without labels |
| `--direction=next`, `--direction=previous` | The display after or before the pointer's, wrapping |
| `--to=last` | Land where the pointer was when a pick last took it off that display, or on the centre the first time (`--to=center`, the default) |
| `--focus` | Focus the frontmost window on that display as well, so `f`, `F` and the window commands start there; a display without windows keeps focus where it is |

`gm` is `mouse screens --focus`. Bind other combinations yourself, such as a
key that hops between two displays and comes back where you left each:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"]d" = ["flash", "mouse", "screens", "--direction=next", "--to=last", "--focus"]
"[d" = ["flash", "mouse", "screens", "--direction=previous", "--to=last", "--focus"]
```

## Select, drag or steer the pointer

`mode hold` (⌘⌃H by default; `--secondary` for the right button) grabs what
is under the pointer (HOLD): `h` `j` `k` `l` nudge it, `w` / `b` jump by word
and `f` picks where it goes. On selected text, `y` copies and clears the
highlight; `p` pastes over it. Return drops and Escape puts it back. `mouse pointer`
opens keyboard pointer control.

[Normal mode](normal-mode.md#mouse-grid) details the grid and
[HOLD](hold-mode.md); the
[command reference](commands.md#command-reference) has the exact flags, and
the live [key mappings](/mappings) the shortcuts in effect on this Mac.
