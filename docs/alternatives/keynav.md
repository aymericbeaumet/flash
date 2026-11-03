# Flash and keynav

[keynav](https://github.com/jordansissel/keynav), "retire your mouse", is
Jordan Sissel's X11 tool to "control the mouse with the keyboard" by
bisection: a start key draws a box over the screen, `h` `j` `k` `l` keep a
half of it, `y` `u` `b` `n` a quarter, and `space` warps there and clicks.
It is BSD-3 C from the author of xdotool, about 650 stars, versioned by date
with no tagged release, and its last commit was in August 2022. Its FAQ is
plain about platforms: "keynav is totally dependent on X11", so it does not
run on macOS. Flash's `mouse grid --bisect` is the same idea on a Mac, with
keynav's own keys.

| | keynav | Flash |
| --- | --- | --- |
| License, price | BSD-3, free | MIT, free |
| Platforms | X11 on Linux and FreeBSD | macOS 13+ |
| Model | One region, cut and moved until you warp or click | Bisect with the same keys, a keyboard-shaped grid, and labels on Accessibility elements |
| Commands | `cut-*`, `move-*`, `warp`, `click`, `drag`, `windowzoom`, `cursorzoom`, `grid` and `cell-select`, `record` and `playback`, `history-back`, `sh` | `mouse grid --bisect`, `mouse grid`, `mouse target`, `mouse pointer`, `mouse screens`, click flags on every one |
| Configuration | `~/.config/keynav/keynavrc`: `keysequence cmd1,cmd2,…` | `flash.toml` mappings to `mouse …` commands |
| Maintenance | Last commit August 2022 | 1.1.0, October 2026 |

## Where keynav is stronger

- **Commands you compose.** A keynavrc line chains any commands
  (`space warp,click 1,end`), with fractions of your choice
  (`cut-left .75`) and a `sh` command anywhere in the chain. Flash's grid
  keys and its bisect proportions are fixed.
- **`windowzoom` and `cursorzoom`** start the box on the active window or
  around the pointer. Flash's grid starts on the whole display;
  `--zoom-to-depth=N` starts it deep around the pointer, but nothing
  starts it on the window's frame.
- **Recording.** `record` and `playback` replay a sequence of keynav moves
  on one key. Flash's macros record NORMAL commands, not grid keys.
- **It is small and stable.** One C program that has done the same thing
  for years, on any X11 window manager.

## Where Flash is stronger

- **Labels on what you want to click.** On macOS most buttons, links and
  fields are in the Accessibility tree, so `f` labels them and one or two
  keys click; bisection stays for the places nothing is labelled.
- **A grid that takes fewer keys.** `mouse grid` splits each step into the
  4×5 block of keys under your left hand, so every key narrows the region
  twenty ways instead of two or four.
- **Every click is a flag**: `--secondary`, `--middle`, `--double`,
  `--drag`, `--select` and `--multi` work on the grid and the bisect alike.
- **Several displays.** Tab moves the grid to the next display, and
  `mouse screens` labels each one.
- **It is maintained**, and the [mouse grid](../mouse-grid.md) has its own
  page of keys.

## Flash features you might like

- `mouse grid --bisect` reads keynav's defaults: `h` `j` `k` `l` keep the
  left, bottom, top or right half, `y` `u` `b` `n` a quarter, Return clicks
  now, arrows slide the region by its own size and Backspace undoes a step,
  as `history-back` does. On Colemak, Dvorak or Bépo the halves sit where
  QWERTY's `hjkl` are.
- `[hints] mouse_grid_keys` sets your own grid, as keynav's `grid 3x3`
  with `cell-select` does.
- `mouse pointer` moves the pointer with `hjkl` when a cut is not precise
  enough, and `mouse position --action=save` remembers a spot to come back to.

## Moving from keynav

| keynav | Flash |
| --- | --- |
| `ctrl+semicolon start` | `"ctrl+<semicolon>" = ["flash", "mouse", "grid", "--bisect"]` in `[mode.all.mappings]` |
| `h cut-left`, `y cut-left,cut-up` | `h`, `y` in the bisect grid |
| `shift+h move-left` | Left arrow: slides the region by its own size |
| `space warp,click 1,end` | Return, or a step small enough, clicks |
| `semicolon warp,end` | `mouse grid --bisect --move` |
| `3 click 3`, `2 click 2` | `--secondary`, `--middle` on the command |
| `drag 1` | `--drag`: pick the grab point, then the drop point |
| `a history-back` | Backspace |
| `w windowzoom`, `c cursorzoom 200 200` | `--zoom-to-depth=2` starts around the pointer |
| `grid 3x3`, `cell-select 1x1` | `[hints] mouse_grid_keys = ["qwe", "asd", "zxc"]` and `mouse grid` |
| `q record`, `shift+at playback` | Not for grid keys; NORMAL's `q`/`@` replay commands |
| `sh "xdotool …"` | A mapping to any argv, or a Flash command |

```toml
[hints]
mouse_grid_keys = ["qwe", "asd", "zxc"]

[mode.all.mappings]
"ctrl+<semicolon>" = ["flash", "mouse", "grid", "--bisect"]
"ctrl+alt+<semicolon>" = ["flash", "mouse", "grid", "--bisect", "--secondary"]
"ctrl+<apostrophe>" = ["flash", "mouse", "grid"]
"ctrl+<period>" = ["flash", "mouse", "target"]
```

A chord in `[mode.all.mappings]` is taken in every app, so Control-; no
longer reaches an editor that binds it.

*Checked 2026-10-23 against the keynav
[README](https://github.com/jordansissel/keynav), its default
[keynavrc](https://github.com/jordansissel/keynav/blob/master/keynavrc) and
[keynav.pod](https://github.com/jordansissel/keynav/blob/master/keynav.pod).*
