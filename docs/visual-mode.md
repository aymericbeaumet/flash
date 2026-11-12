# VISUAL

VISUAL selects text with Vim's motions, as Vim's visual mode does. In a
focused text field, `v` starts a selection at the cursor and engages the
field, every motion grows or shrinks the selection, and an operator acts on
it: `y` copies it and `p` pastes over it. VISUAL selects what you copy; it
never cuts, deletes or changes text
([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)).
It needs editable text; to select in a page, a PDF or a terminal, [HOLD](hold-mode.md) holds
the mouse button instead.

- `v` selects characters, `V` whole lines. The other key switches between
  them; the same key again deselects.
- `h` `j` `k` `l`, `w` `b` `e`, `0` `^` `$`, `gg` / `G`, `ctrl+d` /
  `ctrl+u` and every other motion of NORMAL and the text table move one end
  of the selection, with counts (`3j`, `2w`). `o` moves the other end.
- `y` copies, `p` and `P` paste over the selection; ⌘C and ⌘V copy and
  paste it too. `d`, `x`, `c`, `s` and ⌘X are swallowed, as every key
  VISUAL does not map.
- Escape, `ctrl+[` or your `mode normal` shortcut (⌘⌃[) deselects and
  returns to NORMAL, the field still engaged; `gv` there selects the same
  range again.

The pill is red and shows `mode.labels.visual` (default `VISUAL`), or
`mode.labels.visual_line` (default `V-LINE`) for whole lines. The keys live
in [`[mode.visual.mappings]`](config:mode.visual.mappings), read before the
motions.

## Enter and leave

`v` (`mode visual`) and `V` (`mode visual --line`) are NORMAL's keys, in
[`[mode.normal.mappings]`](config:mode.normal.mappings). They start VISUAL
in the focused field, a text field, a text area, a search field, a combo
box, a password field, a web input or an editable region with the app's
keyboard focus, whether or not you engaged it yet, and engage it
([engage a field](normal-mode.md#engage-a-field)). With nothing editable
focused, in a page, a list, a Finder view or a terminal, they do nothing,
silently, and VISUAL never starts.

The selection starts at the cursor, the character just after the caret
([counts and the caret](normal-mode.md#counts-and-the-caret)), so `v`
selects that one character. A caret at the end of a non-empty line starts
on the line's last character, as Vim's cursor never rests past it. That
first end, the anchor, stays where it is; the motions move the other one.

| What happens | Then | The selection |
| --- | --- | --- |
| Escape (`mode leave`), `ctrl+[`, `mode normal`, `v` in a charwise selection, `V` in a linewise one | NORMAL, the field engaged | Deselected: the caret sits at the moving end |
| `y`, `p`, `P`, ⌘C, ⌘V | NORMAL, the field engaged | What the [operator](#operators) leaves |
| A click | NORMAL | As the click made it |
| Another app comes forward, or the focus moves to another element | NORMAL, no field engaged | Untouched |

Leaving VISUAL for NORMAL keeps the field engaged, so NORMAL goes on
reading its [text table](normal-mode.md#vim-motions-in-text) there and the
motions move the caret; Escape again gives NORMAL's own keys back. A
selection changed by other means, by the app or a click, ends VISUAL in
NORMAL at the next motion, which does nothing: Flash no longer knows its
ends. An operator acts on the selection the app shows, except where it
needs Flash's ends (a named register): that one ends VISUAL instead. VISUAL
never ends in INSERT: only `mode insert`, NORMAL's `i`, goes
[into INSERT](insert-mode.md#enter-insert).

`gv` (`mode visual --reselect`), in the text table, selects the range
VISUAL last ended with again, of the same kind, as Vim's does: in the
field you engaged, the one it was made in, with its ends brought back into
the text if the text got shorter. In another field, another app, or after
a selection Flash could not measure ([without the text](#without-the-text)),
it does nothing.

## Motions

VISUAL reads its own keys first, then every motion the text table and
NORMAL map: the `move`, `cursor` and `scroll` commands, `scroll cursor_top`
and its siblings included. A motion takes the moving end where it would
take NORMAL's cursor, so `w` grows the selection by a word, `b` shrinks it
back, `$` reaches the line's end and `G` the last line. A count measures
the motion as in NORMAL: `3j`, `2w`, `10G`. `ctrl+e` / `ctrl+y` and `zt`
`zz` `zb` scroll the text and leave the selection as it is. Every other key
is swallowed: tabs, hints, history and app commands are not VISUAL's, so
`f`, `gt`, `u` and `/` do nothing there. `q` still stops a macro recording
([repeat and macros](normal-mode.md#repeat-and-macros)).

A few keys follow Vim's visual mode rather than NORMAL's arrows:

- `j` and `k` move a logical line, between two line breaks, keeping their
  column, and `h` and `l` a character. Flash computes them from the text;
  it sends no arrow.
- `l` and `$` may reach the line break, so the selection takes it, as in
  Vim.
- `ctrl+d` / `ctrl+u` move
  [`[mode] move_page_lines`](config:mode.move_page_lines) lines (15 by
  default), and `ctrl+f` / `ctrl+b` twice that.
- `gg` / `G` go to the first / last line.

A charwise selection (`v`) covers every character from the anchor through
the character at the moving end, both included, as in Vim: with the anchor
on the `a` of `abc`, `l` selects `ab`. With the moving end before the
anchor, the selection runs from the moving end through the anchor's
character. A linewise selection (`V`) covers whole lines, from the first
line either end is on through the last, with the last one's line break; on
a last line with no break it ends at the text's end. `v` in a linewise
selection, and `V` in a charwise one, switch kind and keep both ends.

`o` (`selection swap_ends`) swaps the ends: the anchor becomes the moving
end, so the motions grow the selection from its other side, and `o` again
swaps back.

## Operators

| Key | Command | Does | Then |
| --- | --- | --- | --- |
| `y`, ⌘C | `selection copy` | The app's Copy, the text also into `"0`, then the app's Left, which collapses the selection to its start, where Vim leaves the cursor | NORMAL |
| `p`, `P`, ⌘V | `selection paste` | VISUAL ends, then the register's paste replaces the selection (`register paste`) | NORMAL |
| `o` | `selection swap_ends` | The other end moves from now on | VISUAL |
| `v`, `V` | `mode visual`, `mode visual --line` | The other kind, both ends kept; the same kind again deselects | VISUAL, or NORMAL |
| Escape | `mode leave` | Deselects: the caret sits at the moving end | NORMAL |

Each operator acts with the app's own keys: its `clipboard copy` binding
(⌘C in the bundled `defaults` plugin) and its paste. The app can undo a
paste, and a web page sees the events it listens for. `p` replaces the
selection with the register's text; unlike Vim's, it does not put the text
it replaces in the unnamed register. `Vy` copies the whole lines with their
breaks.

## Registers

A register prefix works as in NORMAL: `"` and a register's name before the
operator ([registers](clipboard.md)).

- `y` alone copies onto the clipboard and puts the text in `"0` too, as a
  bare yank in NORMAL does.
- `"ay` writes the selected text Flash read into register `a`; the
  clipboard and `"0` stay as they were.
- `"ap` pastes register `a` over the selection, borrowing the clipboard for
  that one paste, as `register paste` does.
- `"+` and `"*` are the system clipboard, so `"+y` is `y`.

Where the app gives no text ([without the text](#without-the-text)), Flash
has nothing to write a register from, and a named register falls back to
the app's own Copy, onto the clipboard.

## How Flash does it

Flash reads the focused field's text through Accessibility, off the keyboard
path, and computes each motion with the engine of NORMAL's
[motions in text](normal-mode.md#how-a-motion-lands), checked against Vim
9.1. It sets the range as the app's selection with `AXSelectedTextRange` on
the same focused element and reads it back. It never writes text through
Accessibility, neither `AXSelectedText` nor `AXValue`: a copy is the app's
own Copy, and a paste over the selection the app's own Paste. Steps run one after another, so a
held `j` never reads a stale end. Where the app does not take the first
selection Flash sets, VISUAL goes on with the app's own selection keys
([without the text](#without-the-text)). Nothing read is kept but the text
a named register is given ([privacy](privacy.md)).

## Without the text

A secure (password) field never gives its text, text over 1,000,000 UTF-16
units counts as none, some apps expose no text through Accessibility, and
some do not take the selection Flash sets. There VISUAL extends the app's
own selection with the app's selection keys, the `input select_*`
commands, which the bundled `defaults` plugin binds to the macOS keys:

| Key | Command | macOS key |
| --- | --- | --- |
| `h` / `l` | `input select_left` / `select_right` | Shift-Left / Shift-Right |
| `j` / `k` | `input select_down` / `select_up` | Shift-Down / Shift-Up |
| `w`, `e` | `input select_word_right` | Shift-Option-Right |
| `b` | `input select_word_left` | Shift-Option-Left |
| `0`, `^` | `input select_line_start` | Shift-Cmd-Left |
| `$`, `g_` | `input select_line_end` | Shift-Cmd-Right |
| `gg` | `input select_document_start` | Shift-Cmd-Up |
| `G` | `input select_document_end` | Shift-Cmd-Down |

A count repeats the character, line and word keys (`3j` is three
Shift-Downs); every other motion does nothing there rather than guess. `v`
selects nothing until the first motion, and `V` selects the line with
Cmd-Left then Shift-Cmd-Right, without its break. Escape collapses the
selection with the app's Right. The operators use the app's Copy and Paste
on the selection as the app made it, and `o` changes nothing, since the app
decides which end its keys extend.

A plugin overrides these keys for an app with `input select_*` bindings of
its own, as for the other `input` moves
([plugin protocol](plugin-protocol.md)); the `terminals` plugin binds every
one to `false`.

## Terminals and pages

A terminal never enters VISUAL. A declared emulator, tmux panes in one and
xterm.js in web content (VS Code's integrated terminal among them) are never
a field, so `v` and `V` do nothing there and NORMAL never reads the text
table. A web page, a PDF, a list or nothing focused is not text either.
Select there with [HOLD](hold-mode.md), which holds the mouse button down,
or with `mouse target --select`, which clicks one label and Shift-clicks
another.

## Change the keys

[`[mode.visual.mappings]`](config:mode.visual.mappings) is VISUAL's own
table, where `v` and `V` switch the kind or deselect. The `v` and `V` that
start VISUAL are NORMAL's, in
[`[mode.normal.mappings]`](config:mode.normal.mappings): `"v" = false` there
frees the key in NORMAL, in a field and out. VISUAL reads its table
first, then the motions (`move`, `cursor`, `scroll`) of the text table and
NORMAL that it does not shadow, then
[`[mode.all.mappings]`](config:mode.all.mappings); any other key is
swallowed. A key mapped there wins in VISUAL, and `"<key>" = false`
removes it, an inherited motion included. To make `Y` copy too and keep
`P` from pasting:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.visual.mappings]
"Y" = ["flash", "selection", "copy"]
"P" = false
```

A motion you map in the text table moves the selection too: with Vim's `f`
there ([change the text keys](normal-mode.md#change-the-text-keys)), `f`
extends the selection to the character typed next. The table takes no
`<leader>` keys, which belong to NORMAL's table. `mode visual` starts only
in editable text, whichever table binds it, and engages that field.
`[mode.apps."<bundle-id>".visual.mappings]` changes the keys for one app
([app-specific mappings](configuration.md#app-specific-mappings)), and a
plugin's manifest `mappings` reach the table with `"mode": "visual"`
([plugin protocol](plugin-protocol.md)).

## The status pill

`#{flash.mode}` in a [status format](status-format.md) shows
`mode.labels.visual` (default `VISUAL`) for a charwise selection and
`mode.labels.visual_line` (default `V-LINE`) for a linewise one, on a red
pill, and the focused window's border turns red too. Set them with
[`[mode] labels`](config:mode.labels):

```toml
[mode]
labels = { visual = "V", visual_line = "VL" }
```

`flash resident status` reports the mode `visual` for both kinds, with the
mapping scope `visual`, and the `core:mode.changed` event that plugins and
[IPC](ipc-protocol.md) clients hear names it the same. The live
[key mappings](/mappings) page draws VISUAL's keys as its Visual mode, and
the which-key palette lists them.

## What VISUAL leaves out

VISUAL swallows every key it does not map. Vim's visual keys that edit the
selection are not Flash's, by design, since Flash never edits text
([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)):

- `d`, `x`, ⌘X: cut or delete.
- `c`, `s`: change.
- `~`, `u`, `U`: change the case.
- `>`, `<`: indent.
- `J`: join the lines.
- `r`: replace every selected character.

These, which only select, are not there yet:

- Text objects: `iw`, `ap` and the rest.
- Blockwise selection, `ctrl+v`.
