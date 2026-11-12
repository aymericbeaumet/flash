# Coming from Vim

Flash's NORMAL mode is Vim's normal mode over every app: the same keys
switch tabs, move between windows, find, yank and repeat, but they act on
the apps you have open instead of a buffer. This page maps the Vim habits
that carry over, and names the few keys that mean something else here.
[Normal mode](normal-mode.md) has every binding in detail.

## Set it up

Bind a key for NORMAL and one for INSERT in `[mode.all.mappings]`; the
starter `flash.toml` has both commented out:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
```

NORMAL is the base mode, the way Vim's normal mode is. `i` enters INSERT at
the cursor, where keys go to the app; Vim's other insert and change keys
are unbound, since Flash does not edit text
([what Flash does not do with text](#what-flash-does-not-do-with-text)).
A click never enters INSERT, on a text field or anywhere else: it keeps NORMAL, as a click in Vim
keeps normal mode. Escape belongs to the app in INSERT, so your NORMAL
shortcut is the way back; ⌘⌃[ above echoes Vim's Control-[, and from
VISUAL it deselects as Escape does. In NORMAL and VISUAL plain `ctrl+[` is
Escape, as in Vim. Escape in NORMAL never leaves NORMAL: it first cancels
hints or a half-typed key (`g`, a count, `"`), then in a field you engaged
gives NORMAL's own keys back, and otherwise it is the app's own Escape
(`app cancel`), which closes a popover, a dialog or a search.

## Modes

| Vim | Flash |
| --- | --- |
| Normal | [NORMAL](normal-mode.md): keys run commands, unmapped keys are swallowed; in a field you engaged, Vim's motions too ([Vim motions in text](normal-mode.md#vim-motions-in-text)) |
| Insert | [INSERT](insert-mode.md): keys go to the app |
| Command-line (`:`) | [COMMAND](command-mode.md): `:` opens Flash's command line |
| Visual, Visual line | [VISUAL](visual-mode.md): in the focused field `v` and `V` select characters and lines and engage it, the motions grow the selection, and `y` copies it, `p` pastes over it |
| Visual outside text | [HOLD](hold-mode.md) (⌘⌃H from any mode): a mouse button held down at the pointer, so `h` `j` `k` `l`, `w` `b` `e`, `0` and `$` drag or select in a page, a PDF or a terminal; `y` copies, `p` pastes over it, Escape drops it. `"v" = ["flash", "mode", "hold"]` in `[mode.normal.mappings]` gives it Vim's key, and `"v" = ["flash", "mode", "visual"]` in `[mode.text.mappings]` keeps VISUAL on `v` in an engaged field |
| `:terminal` | [TERMINAL](terminal-mode.md): a [popup](popups.md) running a real terminal (`:ter`) |
| Operator-pending | A mouse prefix: `m` moves, `d` double-clicks, `c` right-clicks, before `f`, `F` or `s` |
| Your own modes (submodes, `:map` layers) | [Layers](layers.md), declared under `[mode.layers.<name>]` |

## Keys that carry over

| Vim | Flash | Does |
| --- | --- | --- |
| `i` | The same | INSERT at the cursor ([where typing starts](insert-mode.md#where-typing-starts)) |
| `h` `j` `k` `l` | The same | The arrow keys: the caret in an engaged field (`h` and `l` never leave the line), a list's selection, a page's view; a terminal scrolls instead ([arrows or scrolling](normal-mode.md#arrows-or-scrolling)) |
| `ctrl+d` / `ctrl+u`, `ctrl+f` / `ctrl+b` | The same, with a count (`3 ctrl+d`) | In an engaged field and in lists, the arrows `move_page_lines` times (15), a page twice that; else scroll `scroll_page_lines` (20 lines), a page twice that |
| `ctrl+e` / `ctrl+y` | The same, with a count (`5 ctrl+e`) | Scroll one line without moving the caret, wherever the focus is |
| `gg` / `G`, `{N}G` | The same | In an engaged field the first / last line's first non-blank, line N with a count; a list's first / last item where the app has a key for it, else the top / bottom |
| `w` `b` `e`, `W` `B` `E`, `ge` `gE` | The same, in text | Vim's word motions over the engaged field's text ([Vim motions in text](normal-mode.md#vim-motions-in-text)) |
| `0` `^` `$` `g_` `\|`, `+` `-` `_`, Return | The same, in text | The line's start, first non-blank, end, last non-blank, a column; the next or previous line's first non-blank |
| `%`, `{N}%`, `{` `}`, `(` `)` | The same, in text | The matching bracket, the line N percent through the text; paragraphs, sentences |
| `H` `M` `L` | The same, in text | The first, middle, last visible line; elsewhere `H` / `L` go back and forward (below) |
| `t` `T`, `;` `,` | The same, in text | Till a character on the line, the last search again or the other way; elsewhere `t` opens a tab |
| `zt` `zz` `zb` | The same, in text | Scroll the cursor's line to the top, middle, bottom |
| `gj` `gk` | The same, in text | Down, up a display row |
| `v`, `V`, `o` | The same, in a field | Select characters, whole lines, from the cursor, engaging the field; the motions grow the selection, `o` moves its other end ([VISUAL](visual-mode.md)) |
| `gv` | The same, in text | Select the last VISUAL range of the field again |
| `y`, `p` / `P` in Visual | The same | Copy the selection, paste over it; `"ay` and `"ap` with register `a` ([operators](visual-mode.md#operators)) |
| `p` / `P`, `"{x}`, `"+`, `"0` | The same | Paste after the cursor in an engaged field, at it with `P`, and at the insertion point elsewhere with either; `"a` names register `a`–`z` or `0`–`9`, which a yank fills without touching the clipboard, `"+` is the clipboard, `"0` the last bare yank; a count pastes that many times (`3"ap`) |
| `gt` / `gT`, `{N}gt` | The same, and `g1`–`g9` | Next / previous tab; tab N by position (`3gt` is tab 3) |
| `:tabnew`, `:tabclose` | `t` outside an engaged field, `x` (also `:tabnew`, `:tabc`) | Open, close a tab |
| `:tabmove +1` | `]m`, `>>` (also `:tabm +1`) | Move the tab |
| `ctrl+w h` `j` `k` `l` | The same | Focus the window in that direction, across apps |
| `ctrl+w w` / `W`, `ctrl+w q` / `c`, `ctrl+w n` | The same | The app's next / previous window, close it, open one |
| `ctrl+w p` | The same | The window you were in before this one, across apps |
| `ctrl+w H` `J` `K` `L`, `ctrl+w o`, `ctrl+w =` | The same | Move the window to that half of its screen, maximize it, centre it |
| `ctrl+w s` / `v` | The same | Split the pane, in tmux and the terminals that split |
| `''`, ``` `` ``` | The same | Back to where you were before the last jump (`movement back`, as `ctrl+o`) |
| `qA`, `@:`, `@@` | The same | Append to macro `a`; run the last command line again; play the last macro again |
| `:{N}`, `:$` | The same | Line N, the last line, of the field you engaged |
| `:map` | `?`, `:map` | The live page of every mapping in effect |
| `<leader>` | `<leader>` in mappings, `\` by default | Your sequence prefix; holding it enters HYPER |

A count repeats a command, a chord's too: `3]t` moves three tabs on,
`3 ctrl+d` scrolls three half pages and `3.` runs the last command with 3.
A count before a register counts as well (`3"ap`); one before a mark key
or `q` is accepted, as Vim accepts it, and means nothing (`3'a`).
`gt` reads its count as Vim does, the tab to go to, and a motion in text is
measured by it (`3w`, `10G`, `5|`). `]` and `[` pairs follow
vim-unimpaired: after `]t`, each further `t` moves another tab. A key that
continues no sequence abandons it, as in Vim: `gx` closes no tab, `z.`
repeats nothing. A sequence of mapped keys waits for its next key
`sequence_timeout_ms`; a count, a register, a mark or macro name and a
character search wait as long as Vim's do, for the key.

## Same key, different job

Flash's keys act on apps, tabs, windows and controls, so some Vim keys do
what Vimium does with them, and the ones that act on text in Vim act on
what the app holds. Each difference is deliberate:

| Key | In Vim | In Flash |
| --- | --- | --- |
| `f`, `F` | Find a character on the line | Hints on every control, and the [mouse grid](mouse-grid.md), in text too; Vim's find is `cursor next_char` / `previous_char`, unbound ([bind it](normal-mode.md#change-the-text-keys)) |
| `s` | Substitute a character | Jump to a visible letter (EasyMotion), then type its label; `ms`, `ds`, `cs` move the pointer there, double-click, right-click |
| `I` `a` `A` `o` `O`, `S` `C`, `gw` | Insert, change, format | Unbound, so swallowed: Flash does not edit text ([below](#what-flash-does-not-do-with-text)) |
| `x`, `X` | Delete a character | Close the tab, reopen the last closed one (Vimium), in an engaged field too; in [HOLD](hold-mode.md) `x` does nothing |
| `r`, `R` | Replace | Reload, hard-reload (Vimium); in an engaged field nothing |
| `t` | Till a character | The same in an engaged field; elsewhere a new tab |
| `d`, `c` | Delete, change operators | Mouse prefixes: double-click and right-click (`df`, `cf`), in text too; nothing in VISUAL |
| `y` | An operator waiting for its motion (`yw`, `yy`) | Copy the app's selection at once |
| `J` / `K` | Join lines, keyword lookup | Previous / next tab (Vimium) |
| `H` / `L` | Top / bottom of the screen | The same in an engaged field; elsewhere the app's back / forward (Vimium) |
| `<<` / `>>` | Shift the line | Move the tab left / right (Vimium) |
| `zi` / `zo` / `z0` | Folds | The app's zoom in, out, actual size (Surfingkeys) |
| `gs` | Sleep | A browser page's source (Vimium) |
| `gi` | Insert where you last left off | Focus the first text input and engage it, staying in NORMAL (Vimium) |
| `gm` | The middle of the screen line | The middle of a display: pick one by its number, and focus follows |
| `?` | Search backward | The live page of every mapping in effect |
| `/`, `n` / `N` | Search the buffer | The app's own Find and its next / previous match; `/` opens Find and `i` types the query |
| `m{x}`, `'{x}`, `` `{x} `` | A position in a buffer | An app: `m{x}` saves the focused app, `'{x}` brings it back, kept across restarts ([marks](marks.md)) |
| `mf`, `mF`, `ms` | Marks `f`, `F`, `s` | Move the pointer to a hint, a grid cell, a letter; set those marks with `:mark set --letter=f` |
| `q{x}` … `q`, `@{x}` | Record and replay keys | Record and replay commands, never keys: what NORMAL ran and the `:` lines you submitted ([repeat and macros](normal-mode.md#repeat-and-macros)) |
| `.` | Repeat the last change | Repeat the last command that is not a motion, a mode change or a command line |
| `u`, `ctrl+r` | Undo, redo in Vim's undo tree | The app's own undo and redo |
| `ZZ`, `ZQ` | Write and quit, quit discarding changes | Save and quit the app; quit it, and the app still asks about unsaved work, so `ZQ` discards nothing |
| `:q`, `:qa` | Close the window, quit Vim | Close the tab, or the window of an app without tabs, and quit the app with its last window (`app close`); quit the app |
| `ctrl+o` / `ctrl+i` | The jump list in the buffer | Flash's movement history, across apps, tabs and tmux windows |
| `j` / `k` in text | Logical lines (`gj` / `gk` for display rows) | Display rows: the app's own arrows; the other motions (`+`, `-`, `G`, `$`) count logical lines |
| Escape | Ends a command; in normal mode, nothing | Abandons a half-typed key first; then in an engaged field gives NORMAL's own keys back; else the app's own Escape (`app cancel`), which closes a popover, a dialog or a search |
| A count | Any size | At most 999 |
| `ctrl+v`, `iw` / `ap` | Blockwise Visual, text objects | Not there yet ([VISUAL](visual-mode.md#what-visual-leaves-out)) |

The letter jump is `s`, the key Vim's jump plugins (sneak, leap,
flash.nvim) take, since Flash never substitutes text. The other keys they
pick mean something here: `z` starts the zoom keys, `;` and `,` repeat
Vim's character search in text, `v` is visual mode and `gs` is Vimium's
page source.

In a field you engaged NORMAL has Vim's motions: Flash computes them from
the text Accessibility gives and puts the caret just before the character
Vim's cursor would be on ([Vim motions in text](normal-mode.md#vim-motions-in-text)).
A field is engaged once you act in it: leave INSERT there, click it, `gi`
or `v`. Escape gives NORMAL's own keys back, and so does the focus moving
on; the command line and a `<leader>` sequence keep the field engaged, so
`:42` goes to its line 42. A field the page focused on its own, a search
box on load or the address bar, stays a page: `x` closes the tab and the
Vim motions wait, though `j` still sends Down to the box that has the
focus ([engage a field](normal-mode.md#engage-a-field)). The motions
count logical lines, as in Vim with `wrap`, while `h` `j` `k` `l` move the
cursor with the app's own keys, so their line is the app's: `j` goes down
a display row, and a soft-wrapped paragraph ends at the visible row.
VISUAL selects with the motions: `v` or `V`, the motions, then `y` copies
or `p` pastes over the selection, as Vim's visual mode does, and `gv`
selects the last one again ([VISUAL](visual-mode.md)). Operators on a
motion (`dw`, `cw`, `y$`) and edits are not Flash's: in NORMAL `d`, `c`
and `y` keep Flash's meanings. In an engaged field `r` and `R` do
nothing, since reloading the page would lose what you typed, while `x`
closes the tab as everywhere. In a terminal the text table is not read, `i` only enters INSERT,
leaving the cursor to the shell or the Vim running in it, and `h` `j` `k`
`l` scroll. `.` repeats commands, not motions, as in Vim: it never repeats
a `j` or a `w`. Registers hold text in the running Flash; the unnamed
register is the system clipboard, which a named yank (`"ay`) leaves as it
was, as Vim's does with `clipboard=unnamedplus`. The app's own ⌘C and ⌘V
belong to INSERT: no mode but INSERT binds them.

## What Flash does not do with text

Flash does not edit text. It moves through text, selects it, copies it and
pastes it, and does nothing else to it: no key or command deletes, changes
or cuts text, not even through the app's own Cut, and nothing goes into a
field but what you paste or pick. This is a decision, not a gap waiting to
be filled:

- Only `i` enters INSERT, at the cursor: `mode insert` takes no argument.
  Vim's `I`, `a`, `A`, `o`, `O`, `S` and `C` are unbound in NORMAL, so they
  are swallowed like any key you have not mapped, and so is ⌘X. VISUAL has
  `y` and `p` but no `d`, `x`, `c` or `s`, and [HOLD](hold-mode.md) no cut.
  Once you are in INSERT the app's own keys place the cursor and edit, as
  they do without Flash ([where typing starts](insert-mode.md#where-typing-starts)).
- The motions and VISUAL stay: they choose what you copy, and where `i`
  starts typing.
- `f`, `F` and `s` are Flash's jump and mouse keys: a labelled control, the
  [mouse grid](mouse-grid.md) and a visible letter, with `m`, `d` and `c`
  before them to move the pointer, double-click or right-click. Vim's `s`
  is the letter jump here.
- What Flash puts into a field is what you paste or pick: `p`, `P`, ⌘V
  and VISUAL's `p` paste a register with the app's own Paste, which the
  app's undo takes back, and a flashlight pick (an emoji, a snippet, a
  clipboard entry) goes in at the cursor.

Two reasons. Flash is a keyboard layer for the desktop: its keys act on
apps, windows, tabs and the controls in them, and a text editor's keys
belong to the editor. And editing through Accessibility is unreliable and
skips the app's undo. Writing a field's text means setting `AXSelectedText`
or `AXValue`, and the engines disagree on what that does: WebKit's
`AXSelectedText` setter (Safari, Mail's compose window, every web view)
reports success and changes nothing; Chromium's web content (Chrome, Slack,
Discord, Notion) does not take it, and its `AXValue` replaces the text with
no undo entry and without the input events a React page or a ProseMirror
editor listens for; TextEdit takes either write with no undo entry and
without marking the document edited; Firefox's `AXSelectedText` deletes the
wrong span; Mac Catalyst apps select the text and leave it as it was. The
edits every engine records on its undo stack are its own: a selection, then
its Delete or its Paste. An editor built on that has to measure, app by app
and engine by engine, which writes land, and still meets apps where they do
not: kindaVim, the most complete Vim in macOS fields, works per app and
reports the same Firefox, Catalyst and undo failures. Flash keeps the part
every engine handles: reading the text, setting the caret and the
selection, and the app's own Copy and Paste.

To edit inside a field with Vim's keys, use a tool made for it beside
Flash, in Flash's INSERT, where every key reaches the app:
[kindaVim](alternatives/kindavim.md) brings Vim's operators and text
objects to macOS fields, and [SketchyVim](alternatives/sketchyvim.md) runs
Vim itself behind the field.

## The command line

`:` takes Flash's commands (`:tab next`, `:window move --position=lefthalf`),
cut to unique prefixes (`:ta nex`), and Vim's ex commands at their usual
minimums. Every one is in the [alias table](commands.md#vim-command-line-aliases):

| Ex command | Runs |
| --- | --- |
| `:q`, `:wq`, `:x`, `:qa`, `:qa!` | Close the tab, or the window of an app without tabs, quitting the app with its last window; save, then the same; quit the app; force-quit it |
| `:w`, `:up` | Save |
| `:sav`, `:e!`, `:p`, `:ha` | Save as; revert to the last saved version, after asking; print |
| `:opt`, `:hid` | The app's settings; hide the app |
| `:tabn`, `:tabp`, `:tabn 3`, `:tabm +1` | Next, previous, third tab; move the tab |
| `:bn`, `:bp`, `:b 3`, `:bd` | Buffers are tabs: next, previous, third, close |
| `:ls`, `:buffers`, `:files` | The window switcher: every window, most recently used first |
| `:sp`, `:vs`, `:new` | Split the pane; open a window |
| `:winc l` | Any `ctrl+w` key from the command line |
| `:norm 3gt` | Run what typing those keys in NORMAL runs (`3gt` is tab 3, `ma` sets mark a, `@a` plays macro a) |
| `:!git status` | Run a shell command and show its output |
| `:reg`, `:di`, `:mes`, `:checkh`, `:ve` | Clipboard history and registers, logs, `resident doctor`, About |
| `:42`, `:$` | Line 42, the last line, of the field you engaged |
| `:so` | Reload the configuration |
| `:h normal-mode` | Open a page of this documentation |

`!` keeps its meaning where Vim's would matter: `:qa!` force-quits, while
`:q!` and `:w!` run as without it, since Flash holds no unsaved changes. A
topic alone runs its only action only when that action just shows
something (`:logs`, `:mappings`): `:display` is Vim's `:di`, the registers,
never the displays going to sleep (`:display sleep` does that).

The line edits as Vim's does: `ctrl+w` deletes the word before the caret,
`ctrl+u` everything back to the `:`, and `ctrl+r` then a register name
inserts that register (`ctrl+r a`, `ctrl+r +` the clipboard, `ctrl+r :` the
last command line). Up and Down recall only the past lines that start with
what you typed (`:tab` then Up skips `:q`), and `@:` in NORMAL runs the last
one again.

## From the shell

Every command line entry runs from a terminal as the same words:
`flash tab next`, `flash normal 3gt`, `flash '!date'`. Scripts get an exit
code: 0 when the command ran, 1 when it failed or found nothing to act on,
and 2 when the words name no command or more than one
([commands](commands.md)).

## Make it yours

Remap anything in `[mode.normal.mappings]`, and remove a default with
`false`, as `:unmap` would:

```toml
[mode.normal]
leader = "<space>"

[mode.normal.mappings]
"t" = false
"<leader>w" = ["flash", "window", "switch"]
```

Mark keys and `q` / `@` give way to any mapping on the same keys: a `'a`
you bind runs instead of jumping to mark `a`, and `'d` still jumps.

The motions live in `[mode.text.mappings]`, read before NORMAL's table
while a field is engaged: a key mapped there changes it in text alone, and
`"H" = ["flash", "history", "back"]` there gives `H` its NORMAL meaning back
in text ([change the text keys](normal-mode.md#change-the-text-keys)).
`v` and `V` are NORMAL's, in `[mode.normal.mappings]`, and VISUAL's
operators live in `[mode.visual.mappings]`, read before the motions
([change the keys](visual-mode.md#change-the-keys)).

## From Vimium

`f` hints and clicks, `<a-f>` (`alt+f`) keeps hinting after each click,
`J` / `K` and `gt` / `gT` switch tabs, `x` / `X`
close and reopen, `H` / `L` go back and forward, `r` reloads, `gi` focuses
an input, `/` finds, `gg` / `G` scroll to the ends, `g0` / `g$` take the
first and last tab, `<<` / `>>` move the tab and `gs` shows the source: the
same keys. HOLD (⌘⌃H) is visual mode in a page; in a text field `v` and `V`
are [VISUAL](visual-mode.md). Hold Command on the last hint key to open a link
in a new tab, with `f` or along an `alt+f` chain. A few Vimium keys ship unbound, each for a reason:

| Vimium | Why it is not a default | Add it |
| --- | --- | --- |
| `yy`, `yf` (copy the page's, a link's URL) | `y` copies the selection at once; a `yy` would make it wait for `sequence_timeout_ms` | `"yy" = ["flash", "url", "copy"]`, `"yf" = ["flash", "mouse", "target", "--copy-url"]` |
| `T`, `b` (search tabs, bookmarks) | Searching lives in the flashlight, one key away | `"T" = ["flash", "mode", "flashlight", "--query=@tabs"]`, `--query=@bookmarks` |
| `o` / `O` (open a URL) | Opening lives in the flashlight; `o` and `O` stay free, as Vim's open-line keys Flash does not have | `:flashlight`, or the flashlight shortcut you map |
| `F` (open in a new tab) | `F` is the [mouse grid](mouse-grid.md) | `f`, then Command on the last hint key |
| `p` / `P` (open the clipboard's URL) | `p` and `P` paste, as in Vim | `:open <url>` |
| `[[` / `]]`, `gu` / `gU`, `W`, `yt`, `^` | Flash has no command for a page's next link, editing the URL, detaching or duplicating a tab, or the last-used tab | None yet |

[Mapping syntax](mappings.md) spells keys, chords and sequences, and the
[alternatives](alternatives/vimium.md) pages cover Vimium and Surfingkeys
users.
