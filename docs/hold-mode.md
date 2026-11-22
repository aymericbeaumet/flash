# HOLD

HOLD drags and selects with the keyboard: a mouse button stays down, so
moving the pointer drags what it grabbed or extends a text selection, as
Vim's visual mode extends one. It selects anywhere the pointer can, a page,
a PDF or a terminal included; in a focused text field,
[VISUAL](visual-mode.md) selects with Vim's motions instead, without the
mouse.

HOLD drags something with a mouse button held down. `mode hold` grabs
what is under the pointer with the left button (`--secondary` or `--middle`
for another). ⌘⌃H toggles HOLD from NORMAL, INSERT or a [layer](layers.md). Then:

- `h` `j` `k` `l` nudge it 16 points, `H` `J` `K` `L` 96 points.
- `w` / `b` jump to the next or previous word; `e` reaches a word's end;
  `0` / `$` reach a line's start or end. With text under the pointer, each
  extends a selection while the button stays held.
- `f`, `F` and `s` pick where it goes: a target, a grid cell or a letter,
  as NORMAL's jump keys do. The letter pick lands just past the letter, so a
  text selection takes it.
- `ctrl+e` / `ctrl+y`, `ctrl+d` / `ctrl+u` and `ctrl+f` / `ctrl+b` scroll
  the page whatever has focus: HOLD binds the page keys to `scroll`, not to
  NORMAL's `move`, which would send arrows in a list or a text field. A text
  selection follows the text that moves under the pointer. `gg` / `G` reach
  the first / last line.
- `y` releases the button, copies selected text and clears the highlight after
  the copy succeeds. `p` pastes over the selected text. These operators end
  HOLD and keep NORMAL. HOLD has no cut and no change, since Flash never
  edits text ([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)):
  `d` and `c` keep their NORMAL meanings, as every key HOLD leaves alone,
  so they start a double-click and a right-click, and `x` does nothing
  (`"x" = false` in the HOLD table), so a drag never closes its tab.
  `selection swap_ends`, VISUAL's `o`, does nothing here.
- Return, or the key that entered HOLD, drops it where the pointer is;
  Escape puts it back where it was grabbed and lets go.

The badge is yellow and shows `mode.labels.hold` (default `HOLD`). The keys
live in [`[mode.hold.mappings]`](config:mode.hold.mappings), read before NORMAL's. An
all-mode chord enters HOLD from INSERT as well, and the drop returns to
NORMAL.

```toml
[mode.all.mappings]
"cmd+ctrl+h" = ["flash", "mode", "hold"]
```

## How Flash does it

HOLD is a mouse button Flash holds down (`mouse button`;
`mode hold` is its toggle). Every pointer move Flash makes while a
button is held is a drag of it. The press, drag and release do not inherit modifiers
from the shortcut that started the hold, so a Control shortcut does not turn
the press into a context click. The mode follows the hold exactly: whichever
path presses the button from NORMAL, a layer or INSERT enters HOLD,
whichever releases it leaves, and leaving the mode any other way
(`mode normal`, INSERT, the command line, `mode leave`, quitting
Flash, a committed click) releases the button. `mouse pointer`'s `v` holds a
drag the same way. A half-typed NORMAL sequence is dropped when the button
goes down or up, since the tables differ. After a scroll Flash re-posts the
held button's drag where the pointer is, once after the scroll and once after
the app's own smooth scroll settles, so the app sees the pointer over what
scrolled under it.
