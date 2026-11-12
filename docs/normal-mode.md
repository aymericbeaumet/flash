# NORMAL

NORMAL is a persistent, Vim-like layer over every app: keys run commands
instead of typing. Keys and chords you have not mapped are swallowed, so
nothing pressed in NORMAL becomes stray text; only explicit mappings act.
Escape is one of them: it is the app's own cancel (`app cancel`), so it
still closes a popover, a dialog or a search, and a terminal never gets it.
Press `i` to type ([INSERT](insert-mode.md)), and your NORMAL shortcut to
come back; a click, anywhere and however made, keeps NORMAL. The
live [key mappings](/mappings) page lists the mappings in effect for the
focused app, with plugin overrides and your own. [Coming from Vim](vim.md)
maps Vim habits onto these keys, the [modes](modes.md) page puts NORMAL
beside the others, and how Flash captures keys is in
[input capture](input-internals.md).

## Enter and leave NORMAL

- Your `mode normal` shortcut enters it from any mode. There is none by
  default: binding one in [`[mode.all.mappings]`](config:mode.all.mappings)
  is what turns the modes on ([advanced mode](modes.md#advanced-mode)).
- Closing the command line, a popup or a layer you opened from NORMAL
  returns to it.
- It leaves for INSERT only through `mode insert` ([enter INSERT](insert-mode.md#enter-insert)).
  `:` opens [COMMAND](command-mode.md), `v` and `V` in a focused field
  [VISUAL](visual-mode.md), ⌘⌃H [HOLD](hold-mode.md), holding the
  hyper key [HYPER](hyper-mode.md), and a key you bind to `mode layer` a
  [layer](layers.md).
- The pill reads `mode.labels.normal` (default `NORMAL`), green on the bar's
  dark fill.

Its keys are [`[mode.normal.mappings]`](config:mode.normal.mappings), with
the [`leader`](config:mode.normal.leader) prefix that `<leader>` sequences
start with (`\` by default) and the [`hyper`](config:mode.normal.hyper) key.
Once you engage a field, by leaving INSERT in it, clicking it, `gi` or
`v`, it reads [`[mode.text.mappings]`](config:mode.text.mappings) first,
Vim's motions, until Escape or the focus moves on
([engage a field](#engage-a-field)).
[`[mode] sequence_timeout_ms`](config:mode.sequence_timeout_ms) is how long a
half-typed sequence of mapped keys (`g`, `]`, `ctrl+w`) waits for its next
key. What Vim itself waits on waits as long as it takes, as in Vim: a count,
a register (`"`), a mark (`'`, `` ` ``, `m`), a macro name (`q`, `@`) and a
character search (`t`).

Pause on a prefix (`g`, `]`, `z`, `ctrl+w`, `<leader>`) and, after
[`[mode] which_key_ms`](config:mode.which_key_ms) (500 by default), a palette
lists the keys that can follow it and what each runs, as Neovim's which-key
does; a key that starts longer mappings shows how many. Each row shows the
whole sequence with the keys you already typed faded, a count and register
included (`3]t`), as a hint label fades its typed letters, so you see exactly
where you are. The active-window border stays visible behind the palette.
While it is up the sequence waits for your key instead of
timing out, a mapping it already completes (`g` beside `gt`) included. Any
key takes it down: one that continues nothing drops the half-typed sequence
and itself, as Vim does, so `gx` closes no tab and `z.` repeats nothing, and
a click or a scroll drops the sequence too, so the next key starts fresh.
`which_key_ms = 0` never shows it.

The list includes built-in mark continuations, such as `''` and `` '` ``
(`movement back`), beside configured shortcuts such as `'a`. Configured
continuations come first and keep priority over built-ins, including a key
that starts a longer mapping. Bare mark (`m`, `'`, `` ` ``), macro (`q`, `@`)
and register (`"`) selectors list the names they accept. These are accepted
slot names, not a list of saved values: an empty mark, macro or register may
have nothing to jump to, play or paste. A character search accepts arbitrary
text, so it has no finite continuation list. Counts and selected registers
are reflected in the command shown, for example `3gt` is `tab select --index=3`.
Long palettes use columns so entries do not disappear below a window-list
limit. If an unusually large configured table exceeds the display’s column
capacity, a footer gives the remaining count and points to `:mappings`.
The complete next key remains visible, modifiers included; a long already-typed
prefix may be abbreviated.

The same which-key palette follows HOLD’s effective mappings, and lists HYPER
and layer mappings after entry and after a sequence prefix. Releasing HYPER, leaving a layer, completing a mapping
or interacting with the pointer dismisses it. A displayed prefix waits for its
next key without expiring; `[mode] which_key_ms = 0` disables the palette in
all these modes. HYPER reads literal keys. Layers retain counts and registers,
while a mapped digit or quote prefix takes priority; neither mode acquires
NORMAL’s built-in mark or macro continuations.

## Keys at a glance

| Keys | Do |
| --- | --- |
| `f`, `F`, `s` | Click a labelled control, a grid position, a visible letter; prefix `m` to move the pointer, `d` to double-click, `c` to right-click (`cf`) |
| `h` `j` `k` `l` | The arrow keys: the caret in an engaged field (never leaving the line), a list's selection, a page's view; a terminal scrolls instead ([arrows or scrolling](#arrows-or-scrolling)) |
| `ctrl+d` / `ctrl+u`, `ctrl+f` / `ctrl+b`, `gg` / `G` | Half a page, a page, the top or bottom: arrows in an engaged field or a list, else a scroll; in the field `gg` / `G` are Vim's first / last line |
| `w` `b` `e`, `0` `^` `$`, `%`, `{` `}`, `t` `T` `;` `,`, `H` `M` `L`, `zz`, … | In a field you engaged, Vim's motions: the caret goes where Vim's cursor would ([Vim motions in text](#vim-motions-in-text)) |
| `v`, `V` | In the focused field, select characters, whole lines, and grow the selection with the motions; the field is engaged ([VISUAL](visual-mode.md)) |
| `ctrl+e` / `ctrl+y` | Scroll one line down / up, wherever the focus is; `5 ctrl+e` five |
| `i`, `gi` | Enter INSERT at the cursor; focus the first text input, engaged, and stay in NORMAL |
| `I` `a` `A` `o` `O`, `S` `C` | Nothing: Flash does not edit text, so Vim's other insert and change keys are unbound ([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)) |
| Escape, `ctrl+[` | Cancel hints or a half-typed key; in an engaged field, give NORMAL's own keys back ([engage a field](#engage-a-field)); else the app's own cancel (`app cancel`): a popover, a dialog or a search closes |
| `:`, `?` | The command line; the live mapping reference |
| `gt` / `gT`, `]t` / `[t`, `K` / `J` | Next / previous tab; `3gt` is tab 3 |
| `g1`–`g9`, `g0` / `g^`, `g$` | A tab by position, the first, the last |
| `t`, `x`, `X` | New tab (in an engaged field, Vim's till), close the tab (nothing there), reopen the last closed one |
| `]m` / `[m`, `>>` / `<<` | Move the tab right / left |
| `]a` / `[a`, `]w` / `[w` | Next / previous app, most recent first; the app's next / previous window |
| `ctrl+w` then `h` `j` `k` `l` | Focus the window in that direction |
| `ctrl+w` then `H` `J` `K` `L`, `o`, `=` | Move the window to that half of its screen, maximize it, centre it |
| `ctrl+w` then `w` / `W`, `q` / `c`, `n`, `s` / `v` | The app's next / previous window, close it, open one, split the pane |
| `ctrl+w` then `p` | The window you were in before this one |
| `H` / `L`, `ctrl+o` / `ctrl+i` | The app's back / forward (in an engaged field, the first / last visible line); Flash's movement history |
| `/`, `n` / `N` | The app's Find, its next / previous match |
| `y`, `p` / `P`, `"a` | Copy, paste (in an engaged field `p` after the cursor, `P` at it), a named register before either |
| `u`, `ctrl+r` | Undo, redo |
| `r`, `R` | Reload, hard-reload; nothing in an engaged field |
| `.`, `q{x}` / `q`, `@{x}`, `@:` | Repeat the last command; record a macro, stop, play it; run the last command line again |
| `m{x}`, `'{x}` / `` `{x} ``, `''` | Save the focused app as mark `x`; bring it back; back to before the jump |
| `zi` / `zo` / `z0`, `gs` | The app's zoom in, out, actual size; a page's source |
| `gm`, `2gm` | Pick a display by its number, or display 2 at once: the pointer and keyboard focus go there |
| `ZZ`, `ZQ` | Save and quit the app; quit it |

## Default keys in detail

Defaults map keys to commands, never to raw key chords: each command
resolves in the focused app's context (see [source commands](#source-commands)),
and an app without the command gets nothing. Other tab, pane, archive and
document-URL commands remain available for explicit mappings.

- `h` `j` `k` `l` move what has focus, as Vim's move the cursor (`move left`,
  `move down`, `move up`, `move right`): the caret in a field you engaged,
  the selection in a list, a table or an outline, and otherwise the view,
  which scrolls. `ctrl+d` / `ctrl+u` move half a page and `ctrl+f` / `ctrl+b` a
  page (`move half_page_down`, `move page_down`, …), and `gg` / `G` go to the
  top / bottom (`move top`, `move bottom`), or in an engaged field to the
  first / last line's first non-blank, as Vim's do
  ([Vim motions in text](#vim-motions-in-text)). [Arrows or
  scrolling](#arrows-or-scrolling) has what each key sends where.
  `ctrl+e` / `ctrl+y` always scroll, as Vim's scroll the view without
  moving the cursor. A scroll is a mouse-wheel scroll: one line per press
  for `ctrl+e` / `ctrl+y`, as in Vim (`scroll line_down` / `scroll
  line_up`), 3 lines for `j` / `k` where they scroll, a step that reads
  well in a page, 20 lines, half a page, for `ctrl+d` / `ctrl+u`, and twice
  that, a full page, for `ctrl+f` / `ctrl+b`. A count multiplies each,
  chords included: `5 ctrl+e` scrolls five lines and `3 ctrl+d` three half
  pages. Configure the `j` / `k` step with `[mode] scroll_step_lines`, the
  half page with `scroll_page_lines`, the arrows of a half page with
  `move_page_lines`, and set `scroll_smooth_ms` to spread each scroll over
  that many milliseconds.
- `u` undoes and `ctrl+r` redoes. Bare `d` is unbound: it is the double-click
  prefix.
- `i` enters INSERT (`mode insert`) at the cursor, the one way in. Vim's
  other insert and change keys, `I`, `a`, `A`, `o`, `O`, `S` and `C`, are
  unbound and swallowed: Flash moves, selects, copies and pastes but never
  edits text ([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)).
  Move first, then press `i`: `$` then `i` types at the end of the line,
  `^` then `i` at its first non-blank ([where typing
  starts](insert-mode.md#where-typing-starts)). `s` is the letter jump.
  `:` opens the command line (`mode command`). `gi` focuses the first text
  input (`input focus`), engages it and keeps NORMAL.
- `ZZ` saves and quits the focused app (`app save_and_quit`); `ZQ` quits it
  (`app quit`). `:q` is vim's quit (`app close`): the tab; in an app with
  no tab to close, such as Messages, the window, and the app itself with
  its last window.
- `ctrl+w` is vim's window prefix: `ctrl+w h` / `j` / `k` / `l` focus the
  window in that direction (`window focus --direction=…`), `ctrl+w w` / `W`
  the app's next / previous window (`window next` / `window previous`),
  `ctrl+w q` or `ctrl+w c` close the window (`window close`) and `ctrl+w n`
  opens one (`window new`). `ctrl+w H` / `J` / `K` / `L` move the window to
  that half of its screen, as vim moves a split to that edge, `ctrl+w o`
  maximizes it (vim's only) and `ctrl+w =` centres it; `ctrl+w s` / `v` split
  the pane (`pane split_horizontal` / `split_vertical`) in tmux and the
  terminals that split. A chord followed by a key is a sequence to the
  mapping syntax, read by the interpreter. `:winc[md] {c}` runs the same key
  from the command line.
- `y` copies immediately and clears the copied selection; `p` and `P`
  paste at the cursor, and in an engaged field `p` puts after it as Vim's
  `p` does, with `P` at it ([put after the cursor](#put-after-the-cursor)).
  Prefix either key with `"` and a register name to use a named buffer, for
  example `"ay` and `"ap`, and a count before or after the register to
  paste that many times (`3"ap`, `"a3p`). Names `a`–`z` and `0`–`9` hold
  text in the running Flash process; uppercase names append when yanking.
  A bare yank updates the unnamed register, which Flash shares with the
  system clipboard, and saves its text in `"0`; a named yank writes its
  register alone and leaves both as they were, as Vim's does with
  `clipboard=unnamedplus`, so `"ay` keeps what you copied. `"+` and `"*`
  select the clipboard explicitly. `"_y` discards text without changing
  any register. Where the app gives Flash no text, a named yank falls back
  to the app's own Copy, which lands on the clipboard too. The prefix also works for HOLD copy and paste. The command
  equivalents accept `--register=<name>`. Every successful yank clears the
  selection, including named, append, clipboard and black-hole registers; a
  failed copy leaves it alone. Delayed work is cancelled if the target app or
  captured selection changes. Hardware key, click, drag and scroll counts
  also cancel stale work without tracking key values; releasing the yank key
  does not cancel it. Web content without AX selection attributes can clear
  after a successful copy or explicit black-hole yank. Clearing uses
  Accessibility where available.
  Terminals never receive a clearing arrow key: a terminal that does not expose
  a writable AX selection may keep its highlight after copying.
- `clipboard copy` and `clipboard paste` are the app's own copy and paste:
  they act on whatever the app has selected or focused, and each runs the
  app's `clipboard` binding, so a terminal gets the Cmd-C and Cmd-V every
  emulator binds. No key binds them, in NORMAL or in VISUAL: a mode that is
  not INSERT sends the app no chord of its own, so ⌘C and ⌘V do nothing
  until you enter INSERT or map them yourself. `y` and `p` are the keys.
- `/` opens Find (`app find`, Cmd-F) and keeps NORMAL: enter INSERT (`i`) to
  type the query. `n` / `N` go to the next / previous
  match (`app find_next` / `app find_previous`, Cmd-G / Cmd-Shift-G by
  convention): commands asked of the app like Find itself, with no typing, so
  NORMAL stays. Finder has no Find matches to step through and its
  Cmd-Shift-G is Go to Folder, so there they do nothing.
- Escape asks the focused app to cancel (`app cancel`, its Escape by
  convention): a popover, a sheet, a dialog, a search field or a menu
  closes, as Escape does without Flash. What Flash has open goes first:
  hints, a half-typed sequence, a count, a register, mark or macro key
  waiting for its name, and an engaged field's Escape
  ([engage a field](#engage-a-field)) take the key. Plain `ctrl+[` is
  Escape too, as in Vim, in NORMAL and VISUAL. A context menu or
  Mission Control gets the key itself, and a terminal gets nothing, VS
  Code's integrated one included (a shell or vim would read it). `"<esc>" = false` in
  [`[mode.normal.mappings]`](config:mode.normal.mappings) swallows it again.
- `x` closes the current tab (`tab close`); `X` reopens the last closed one
  (`tab reopen`). Inside tmux `x` first asks `Close this tmux window?` in the
  alert, with `[y]es / [n]o` and the keys in the hint colour: the terminals
  plugin declares the close destructive (`confirm` on its `tab close`
  entry), so `y` closes the window and any other key — `n`, Escape, a
  click — closes only the question. Wrap any command the same way with
  `alert confirm --prompt=… --command=…`. `X` acts in browsers and editors; tmux,
  terminals and Finder keep no closed tabs, so there it does nothing. In a
  field you engaged `x` closes the tab all the same
  ([keys in text](#keys-in-text)).
- `r` reloads (`app reload`); `R` hard-reloads (`app reload --force`).
  Browsers use their own chords (Safari's hard reload is Cmd-Option-R) and
  tmux refreshes its client. Other apps, terminals included, do nothing:
  Cmd-R replies in Mail and runs in Xcode. In an engaged field both do
  nothing, so what you typed stays.
- `[a` / `]a` cycle previous/next app in MRU order. Quitting the focused
  app (`:qa`, `ZQ`, `app quit`, or the app's own quit) focuses that
  previous app, from command mode and from every other mode.
- `[w` / `]w` cycle the focused app's windows (`window previous` /
  `window next`), the windows of every app alike, terminals included; repeat
  the final `w` to keep cycling.
- `[t` / `]t` switch to the previous/next tab (`tab previous` / `tab next`);
  repeat the final `t` to keep switching. `gT` / `gt` and `J` / `K` (Vimium)
  do the same. Inside tmux they switch tmux windows;
  elsewhere the app's own chord (Control-(Shift-)Tab in Messages), else
  Cmd-Shift-[ / Cmd-Shift-], which WhatsApp binds to its previous/next chat.
- `t` opens a tab (`tab new`): a tmux window inside tmux, Cmd-N in editors
  whose Cmd-T searches symbols, nothing in Notes, TextEdit, Pages and Mail,
  whose Cmd-T opens the Fonts panel, and Cmd-T elsewhere, terminals included.
  NORMAL stays either way; enter INSERT to type in the new tab. In an
  engaged field `t` is Vim's till instead
  ([character search](#character-search)), and in a field the page
  focused on its own it still opens a tab.
- `g1`–`g9` select a tab by position (`tab select`): a tmux window by ordinal,
  a browser tab through the browsers plugin, a native tab strip through
  Accessibility, else Cmd-1…Cmd-9. These commands preserve NORMAL.
- `g0` / `g^` go to the first tab and `g$` to the last. tmux and plugin
  sources select their own first and last windows; otherwise the first tab is
  Cmd-1, and the last is the chord an app's plugin declares (Cmd-9 in
  browsers).
- `[m` / `]m` move the current tab left/right; repeat `m` to continue moving it.
  `<<` / `>>` (Vimium) do the same.
  Firefox and Chromium browsers use their native Control-Shift-Page Up/Down
  (checked in Chrome; a Chromium browser that drops the chord does nothing).
  Safari, which has no shortcut, moves
  the neighbouring tab across the current one by AppleScript; tmux reorders
  its window.
- `ctrl+o` / `ctrl+i` traverse Flash's movement history.
- `H` / `L` go back/forward in the focused app's own history, as in Vimium:
  Cmd-[ / Cmd-] in browsers, Finder and most apps. Editors where Cmd-[
  outdents use their own chord (Control-Minus in VS Code, Cursor, Zed and
  Sublime Text; Control-Command-Arrow in Xcode). Terminals and apps without
  history (Notes, TextEdit, Pages, Mail) do nothing. In an engaged field
  they are Vim's first and last visible line instead
  ([Vim motions in text](#vim-motions-in-text)).
- A mouse action is a prefix and a finisher. Prefixes are none, `m` (move),
  `d` (double) and `c` (context, the right-click). Finishers are `f` (a
  discovered target), `F` (a screen position through the grid) and `s` (one
  visible letter). `c` is the operator Vim and Vimium leave free; `r`
  reloads, so it is not the right-click. The pointer hides while labels are
  up, even with another app in front, and returns when it moves; the labels
  going away leave it to that move. Pointer mode and a cursor-following grid
  keep it visible. So `df` double-clicks an element, `dF` double-clicks a
  grid position, and `ds` double-clicks a letter. `cf`, `cF` and `cs` are
  the right-click of each.
- `alt+f` is the click chain (`mouse target --multi`), Vimium's `<a-f>`: the
  labels come back after every click, following what the click changed,
  until Escape. A click on an input is no exception; see
  [click several targets](hints.md#click-several-targets).
- While Mission Control or App Exposé is up, `f` labels its windows, its
  desktops and its add-desktop button, and every key NORMAL does not map
  reaches the Dock, so Escape closes it; see
  [Mission Control](hints.md#mission-control).
  A system dialog in front of the focused app, such as the Gatekeeper prompt,
  is the surface `f` and `s` walk even when its process does not become
  frontmost. A window's close button is a hint when the window has one, and
  so are a dialog's default, cancel, and help buttons.
- `s`, then one letter, then a two-character hint jumps to that
  letter in the focused window's visible text (EasyMotion). The same prefixes
  apply: `cs` right-clicks, `ds` double-clicks, `ms` moves the pointer. `s`
  starts no other mapping, so the jump fires at once. Vim's `s` substitutes
  text, which Flash never does
  ([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)).
  Nothing is drawn for the search letter itself: the hints are the only
  surface, sitting on each match.
  The search character matches either case, so `v` and `V` find the same
  glyphs, and the other character of that US key, so `3` and `#` do too,
  everywhere in the focused window and on the status bar of that window's
  screen (the surfaces `f` reaches). A letter on a status-bar link or popup
  does what `f` does there; a letter on plain bar text moves the pointer onto
  it. The click and the move land one point left of the glyph's centre, still
  on the letter, so a later selection can start on that glyph's leading side;
  in HOLD they land one point right of it, so the selection a held button
  draws ends on that letter.
  The jump keeps NORMAL, even on a letter inside a text field or a
  terminal, as every click does.
  Hint labels are uppercase and accept either case. Backspace
  edits the letter, Escape cancels, and no match stays silent. Holding the
  hyper key, or any other key that enters a mode, ends the jump and enters
  that mode instead of typing into it. `mouse bigram --move`
  moves the pointer without clicking. The text comes from Accessibility.
  Each visible line is measured once, so a common letter costs the same as a
  rare one. Each match then asks Accessibility where its glyph is drawn, so a
  label sits on its letter even when the text is narrower than its element;
  an app that does not answer keeps an even spread of the characters across
  the line. Characters truncated behind an ellipsis get no label. The click
  re-reads the glyph's bounds.
  A terminal whose tree has no text asks the plugin that hints it for its
  text grid (`text_grid`): tmux reads the client attached to that window over
  its control-mode connection and returns pane text, the tmux status line,
  and each pane-border title, measured on the same window `f` and `cf` use.
  The search never waits on a process launch, and a letter typed before the
  grid arrives is answered once it does. Those two label the same targets,
  including pane titles and the status bar. On the status bar,
  `cf` right-clicks, which pins the popup. `s` labels the letters
  on that grid. Flash never reads screen pixels.
- A prefix letter must not also be a mapping of its own, or that mapping waits
  for `sequence_timeout_ms` before it fires. Triple click therefore ships
  unbound, because `tf` would stall the bare `t` (new tab). To bind `tf` /
  `tF`, remove the default `t` with `"t" = false` in the same table; `tf`
  then fires on its second key with no timeout; in an engaged field the
  text table's `t` hides `tf` too, so add `"t" = false` under
  `[mode.text.mappings]` as well. A pending sequence is dropped
  when the focused app or the effective mappings change, and its timeout
  never fires a mapping from the previous table.
- A count before `f`, `F` or `s` is a finger count, as on a trackpad. `2f`
  secondary-clicks the pick, `2df` smart-zooms there and `3f` looks up the
  word there (`mouse target --gesture=look_up|smart_zoom`). The gestures move
  the pointer like `mf` and keep NORMAL. `flash mouse gesture` performs the other
  trackpad gestures; see [commands](commands.md).
- `f` and `F` clicks keep NORMAL, on a text field, a password field or a
  terminal (tmux pane and window hints included) as anywhere else: press
  `i` after the click to type there. An `f` click on a text input, and an
  `F` click whose focus settles on a field, engage it, so the motions act on
  its text ([engage a field](#engage-a-field)). A hint
  click moves the pointer to the target and leaves it there; `m` (move)
  moves it without clicking. With `[hints] restore_pointer = true`,
  every committed click, drag or selection — hint or grid, and `mouse repeat`
  — puts the pointer back where it was; `m` and `mouse pointer` still move it.
  NORMAL's scrolls land at the pointer while it is inside the focused
  window, so with the option on they keep scrolling where the pointer was,
  not in the area you just clicked; use `mf` or `scroll target` to move it
  there. With the pointer outside the focused window, they scroll that
  window instead ([where a scroll lands](#where-a-scroll-lands)).
- Terminal link hints add Shift, so `f` opens the link through the terminal.
  The hover and click carry the same modifiers.
- Modifiers held on the final hint key ride the click (`hints.magic_modifiers`,
  and Shift always): `f` then Shift-`<hint>` is a Shift-click, on targets and on
  the grid alike. Link text repeated in a terminal pane resolves to the copy
  under the hint.
- While labels are up, `Tab` restarts the same click on the mouse grid and
  `Shift-Tab` widens it to every app on the screen, or narrows it back.
  `Backspace` with nothing typed returns to the surface the session came from.
  A chord on Tab cancels, like any other unknown chord.
- `mouse target --path` picks two labels and clicks every target between them
  in reading order, from the first pick to the second; the first pick is
  marked until the second lands. `--sticky` keeps the same labels up after each
  click, with no new walk, until Escape or Return; `--multi` walks again after
  each click and whenever the app reports a change before the next pick.
  `--words` labels the visible words of the window's text instead of its
  controls, landing on each word's leading edge; with `--select` it highlights
  the text between two words, with `--drag` it drags one. Nothing of this
  reads the screen: the words come from the text Accessibility exposes, the
  same walk `s` uses.
- `[hints] label_order` decides which target gets the easiest label: the first
  in reading order, the one nearest the centre of the window, or, with
  `zones`, the first key of every label names the keyboard-shaped zone of the
  window the target sits in. `[hints] key_priority` lists the keys handed out
  first. See [configuration](configuration.md#hint-labels).
- `gm` (go to a monitor) shows each display's number at its centre; typing
  one moves the pointer there and focuses that display's frontmost window
  (`mouse screens --focus`). A count picks at once, as `3gt` picks a tab:
  `2gm` is display 2, counting from the left. With one display `gm` acts on
  it without a label. See [pick a display](mouse-grid.md#pick-a-display).
- `mouse warp` jumps the pointer to an edge or the centre of the focused
  window or its screen, and `mouse position` saves, labels, cycles and
  forgets pointer positions. Neither ships bound; see [commands](commands.md).
- `cF`, `dF` and `mF` use the [mouse grid](#mouse-grid) for a right-click, a
  double click and a move.
- `?` opens the browser mapping reference for the focused app. In the command
  line, `:mappings` or `:map` does the same. `:` opens the command line
  (`mode command`).
  The reference shows effective plugin-merged and configured mappings,
  including expanded leader bindings and argv mappings. Each row names where
  the binding comes from:
  a built-in default, a config file, or a plugin.
- `:help` opens the browser help homepage; `:help <topic>` opens that page of
  this documentation (`:help plugins`) or a plugin's own guide. Every Flash command
  runs as its two words (`:tab next`); `Tab` completes the topic, then its
  action, and each word may be cut to a unique prefix (`:ta nex`). Vim's ex
  commands run under their names at their vim minimums (`:q`, `:tabn`,
  `:wq`); see [commands](commands.md#vim-command-line-aliases). `:flashlight
  <query>` searches source candidates; `:open <args>` forwards verbatim to
  `open` (URLs, files, `-a App`).

## Repeat and macros

`.` runs the last NORMAL command again with the count it ran with; a count
before it replaces that count, `1.` included (`macro repeat
--count=N`). Commands that only change the mode (`i`, `v`, `V`, a layer),
open the command line or show help are not what `.` repeats, and neither is
a motion, `move` or `cursor` (`j`, `ctrl+d`, `w`, `gg`), nor a command line:
Vim's `.` repeats a change, never a motion. A macro still records them.
A chord is a NORMAL key like any other: `3 ctrl+d` takes its count, and `.`
and a recording take the chord.

While no mapping takes them, `q` and `@` are vim's macro keys. `q{x}` starts
recording into register `x` (a letter or digit), `q{X}` appends to it, `q`
stops (in VISUAL too), and `@{x}` replays what NORMAL ran in between, `@@`
the last macro played and `3@x` it three times (`macro record
--register=x`, `macro stop`, `macro play`). `@:` runs the last command line
again (`macro play --register=:`). A recording keeps the commands NORMAL
dispatched — `gt`, `ctrl+w H`, a plugin command, another macro's `@y` — and
each `:` line as you submitted it, never the keys that chose them, so
nothing is logged or written: the macros live in the running resident until
it quits. A replayed step that fails or finds no app stops the rest, and a
macro may replay another eight deep. `flash macro play --register=x`
replays one from a terminal. Map `q` or `@` yourself to give them back to
something else. A key that names no register (`q.`, `@/`), Escape included,
abandons the `q` or `@` and runs nothing, as in Vim; so does one after `"`
(`".` never repeats, `":` never opens the command line) and after a mark
key (`'/`).

## Mouse grid

`mouse grid` (`F`) splits the screen like the left half of your keyboard: 4
rows × 5 columns, each cell labelled with the key at the same position in the
`hints.keys` layout's number, top, home and bottom rows. On QWERTY:

```text
+---+---+---+---+---+
| 1 | 2 | 3 | 4 | 5 |
+---+---+---+---+---+
| q | w | e | r | t |
+---+---+---+---+---+
| a | s | d | f | g |
+---+---+---+---+---+
| z | x | c | v | b |
+---+---+---+---+---+
```

Each cell also shows, faintly, the grid of the step that follows it, every
sub-cell labelled with the two keys that reach it (`qw` is `q`, then `w`), so
the next key can be read before the first is pressed; the step's own labels are
drawn on top and stay the first thing to find. The clicking step and cells too
small for a two-letter label show no preview. `hints.mouse_grid_preview =
false` turns it off. The clicking step's labels are see-through, so the exact
point each one clicks shows under it.

Colemak uses `12345` / `qwfpg` / `arstd` / `zxcvb` and Dvorak `12345` /
`',.py` / `aoeui` / `;qjkx`; a literal `hints.keys` gets the QWERTY block, and
`hints.mouse_grid_keys` sets any other matrix. Press the key where you want to
go: the grid zooms into that cell and tiles it with the same keys, so every
step uses the same muscle memory. The last of `hints.mouse_grid_steps` (default
3) clicks, as does any step whose cells reach 18 points. When the clicking
step's cells are smaller than a label, they are drawn as one glued cluster
centred on (and covering) the chosen cell; each click lands on its label.

The grid starts on the display of the focused window and covers Flash's
status bar, or on the pointer's display when no window is focused. It still
stops at the Dock, and at the menu bar when the Flash bar is hidden.

| Key | Action |
| --- | --- |
| a grid key | Zoom into that cell; on the last step, click its centre |
| `space` | Zoom into the centre; on the last step, click the centre |
| `return` | Click the centre of the current region now |
| `backspace` | Undo the last grid key (zoom, move, display switch); with nothing left, back to the labels the grid was opened from |
| `cmd-backspace` / `alt-backspace` | Start over on the whole display |
| arrows | Slide the region by its own size, stopping at the display edge |
| `shift`-arrows | Put the pointer on that edge of the region, so a drag or a held button can start on a grid line |
| `tab` / `shift-tab` | Move to the next / previous display |
| `` ` `` | Toggle cursor-follow (`hints.mouse_grid_cursor_follow`) |
| `escape` | Cancel; a pointer moved by cursor-follow goes back |
| any other key | Cancel |

Modifiers held on the key that clicks ride the click (`hints.magic_modifiers`,
and Shift always), so Shift-`1` Shift-clicks the `1` cell. Command, Control or
Option chords outside the magic modifiers cancel. Every click flag works with
the grid: `--drag` and `--select` pick a first point, then restart on the
whole display for the second; Backspace from there returns to the first
point's step. `--multi` restarts on the same display after each click.

`mouse grid --bisect` halves the region instead: `h` / `j` / `k` / `l` keep
the left, bottom, top or right half, and `y` / `u` / `b` / `n` (drawn as
quadrants) keep the top-left, top-right, bottom-left or bottom-right quarter.
It ignores the step count and clicks once the kept region is at most 18 points
on both sides, or on `return`; the other grid keys work as above.
`mouse grid --zoom-to-depth=N` starts N steps deep on the cell under the
pointer, on the pointer's display, stopping while one selection remains;
Backspace walks back out.

## Movement history

`ctrl+o` and `ctrl+i` move backward and forward across apps and source locations,
including browser tabs and tmux windows. App focus and location-catalog changes
feed the same history. A tab switch a source performs is a stop the moment it
replies: tmux names the window it switched to, and Firefox posts its own tab
key and then names the tab it landed on, so the browser keeps its wrap, its
tab groups and a sidebar of vertical tabs,
so a fast run of `]t` leaves one stop per press where the catalog, which
refreshes once the burst settles, would show only the last. That catalog lags
such a run by a step, so the observation in flight names the location the
switch left and is dropped until one names the recorded stop; the run replays
in the order it was made. A browser driven
by its own chord (Chrome, Safari) records the tab its catalog shows once it
settles. Repeated observations of the same location coalesce;
returning to a location after visiting another remains a chronological stop.
Choosing a new destination after moving backward discards the forward branch.

Locations restore through their owning source. A browser tab restores through
its `flash-browser://tab?pid=…&url=…` route: the browser process and the tab's
URL, or its title when the tab exposes no URL, so a title change keeps the
destination and a restarted browser's stops fail rather than land elsewhere.
Chromium browsers and Safari select the first tab with that URL by
AppleScript; Firefox re-walks its tab strip and presses the match through
Accessibility.
Tmux keeps stable window IDs so reordering a window does not change its history
destination. Apps without a more precise source restore application focus.
The stack does not capture page scroll positions, editor cursor positions, or
terminal scrollback offsets. History is in memory and bounded to 20 stops in
each direction.

## Source commands

Every command that asks the focused app to do something is a source command,
spelled exactly as a mapping writes it (`tab next`; `app reload --force` is
`app reload` with its flag): tabs, panes, reload, archive, back/forward,
`gg` / `G`, and the app's generic commands — `app undo`, `app redo`,
`app find`, `app find_next`, `app find_previous`, `app save`, `app print`,
`document open`, `window new`, `window close`, `clipboard copy` and
`clipboard paste`, which back `u`, `ctrl+r`, `/`, `n`,
`N`, `:w`, `:e`, `:new`, `:q`, `:clo`, the yank
fallback when no Accessibility selection is exposed, and the paste that
delivers a flashlight answer. So are the cursor moves `input line_start`,
`input line_end`, `input char_left`, `input char_right`, `input line_up`,
`input line_down`, `input document_start` and `input document_end`, which
back the [`move` keys](#arrows-or-scrolling) in text; the `input select_*`
keys VISUAL extends a selection with where the app gives no text; the
`cursor` motions, whose binding runs only where the app gives no text
([how a motion lands](#how-a-motion-lands)); and the list moves `move down`, `move up`, `move left`,
`move right`, `move top` and `move bottom`, which back `h` `j` `k` `l`, the
half pages, the pages and `gg` / `G` in a list (a half page or a page
repeats the one-step move). No default or bundled mapping sends a raw chord
instead (`key send` remains an explicit escape hatch). Each command runs one
policy that knows no app and no chord:

1. a source that performs it in the focused app — a plugin declaring the
   command in its manifest `commands[]` under Flash's topic: tmux for the
   windows and panes of the tmux client hosting the focused terminal, the
   browsers plugin for `tab select` and the tab moves — or the Accessibility
   tab strip for `tab select`;
2. for `window close`, the focused window's close button (Flash's own step);
3. else the binding a plugin declares for the command in that app
   (`bindings`, keyed by the command line, see
   [plugin protocol](plugin-protocol.md)): a chord, a chord sequence, a
   menu-bar item pressed through Accessibility, or `false` for an app
   without the command;
4. else Flash's own scrolling for `resource next` / `resource previous`
   (wheel lines), and `scroll top` / `scroll bottom` and `move top` /
   `move bottom` (the focused-window scroller);
5. else nothing.

The macOS conventions — Cmd-Shift-[ / Cmd-Shift-] switch tabs, Cmd-T opens
one, Cmd-W closes it, Cmd-1…Cmd-9 select one, Cmd-[ / Cmd-] go back/forward,
Cmd-Z / Cmd-Shift-Z, Cmd-F, Cmd-S, Cmd-P, Cmd-O, Cmd-N, Cmd-C / Cmd-V,
in text Cmd-Left / Cmd-Right, Cmd-Up / Cmd-Down, Option-Left /
Option-Right, the arrows and Shift with them, and in a list the arrows —
are `""` bindings of the bundled `defaults` plugin, which also carries the
apps that differ (editors, Messages, Xcode, Notes and friends). No shared chord goes to a list's first or last item (Finder's
Cmd-Up opens the enclosing folder), so `move top` and `move bottom` have no
default binding and fall back to the scroller. The `terminals` plugin binds
every text move and selection key, every `cursor` motion and every
`move` to `false`, since a shell would receive them as input.
Browsers and terminals override them in their own plugins. With
`[plugins] disabled = ["defaults"]` those commands do nothing. Reload, reopen,
the last tab, tab moves, panes and archiving have no shared binding: their
chords mean different things across apps, so they act only where a source or
an app-specific binding knows the app. The inspector's Mappings page lists how
each command resolves in the focused app.

A source that claims a command and fails reports `.failed`, and no binding
follows it; a menu item that is missing or disabled fails the same way. App
knowledge lives in manifest data (the `browsers`, `defaults` and `terminals`
plugins), never in host conditionals. A terminal treats a Command chord a
plugin binds for that emulator as bound, like the chords every emulator
binds; any other Command chord is refused (see below), while a menu
press is always allowed.

### App operations

The everyday commands of an app's menus are source commands too, so a key,
the command line or a script reaches them without knowing the app's chord.
The bundled plugins bind them:

| Command | `:` alias | What the app gets |
| --- | --- | --- |
| `app print` | `:p[rint]`, `:ha[rdcopy]` | Cmd-P |
| `document save_as` | `:sav[eas]` | Cmd-Shift-S; Option-Cmd-Shift-S in TextEdit, Preview, Pages, Numbers, Keynote and Xcode, where Cmd-Shift-S duplicates |
| `document duplicate` | | Cmd-Shift-S in those document apps; nothing elsewhere |
| `document export_pdf` | | File › Export as PDF…; nothing in Pages, Numbers and Keynote |
| `document revert` | `:e!` | File › Revert To › Last Saved; File › Revert File in VS Code; File › Revert to Saved… in Xcode |
| `document rename` | | File › Rename… |
| `document page_setup` | | File › Page Setup… |
| `app settings` | `:opt[ions]` | Cmd-Comma, also in the terminals that bind it |
| `app select_all` | | Cmd-A; nothing in a terminal |
| `app help` | | Cmd-Shift-/, the Help menu |
| `app cancel` | | Escape, NORMAL's own Escape; nothing in a terminal |
| `window close_all` | | Option-Cmd-W; Cmd-K Cmd-W in VS Code; Option-Shift-Cmd-W in Chrome; nothing in Safari, the other browsers and terminals |
| `window zoom` | | Window › Zoom |
| `url bookmark`, `url edit`, `history show` | | In browsers, Cmd-D (not in Arc, whose Cmd-D pins a tab, or Opera), Cmd-L and Cmd-Y (Cmd-Shift-H in Opera) |
| `window new --private` | | In browsers, Cmd-Shift-N; Cmd-Shift-P in Firefox |
| `app stop`, `app downloads`, `app developer_tools` | | In browsers, Cmd-Period (Safari, Chrome, Brave, Firefox); the downloads (Option-Cmd-L in Safari, Edge and Vivaldi, Cmd-Shift-J in Chrome and Brave, Cmd-J in Firefox and Opera); Option-Cmd-I (not in Opera) |
| `tab duplicate`, `tab pin`, `tab detach` | | Safari's Window menu and Chrome's Tab menu (Duplicate Tab, Pin Tab, Move Tab to New Window) |
| `tab mute` | | Control-M in Firefox, Edge and Brave |

A menu item is pressed by its title, so an app without it, or one whose
menu reads otherwise at that moment, does nothing and the command fails.

`document revert` and `window close_all` ask first in the centred alert,
as `system restart` does: `y` runs them, any other key closes the
question. Both can lose unsaved work, and Flash asks only in an app that
has the command.

Four are Flash's own, with no chord: `app hide` (`:hid[e]`) hides the
focused app, `app hide_others` every other app, `app show_all` shows every
hidden app, and `app raise` brings every window of the focused app to the
front, as the Window menu's Bring All to Front does.

`menu press --path=<Menu,Item,…>` presses any menu-bar item of the focused
app by its titles, comma-separated, the way a binding's menu item is
pressed: through Accessibility, off the main thread, failing on a missing
or disabled item. Write the titles as the menu shows them in English,
ellipsis included (`["flash", "menu", "press", "--path=File,Export as PDF…"]`);
a title with a comma in it cannot be named. It is your escape hatch, like
`key send`: no default or bundled mapping uses it.

## What NORMAL swallows

NORMAL is hermetic: every unmapped key and modifier chord is swallowed, and
only explicit mappings act. No default maps a chord for the app to act on,
⌘C and ⌘V included: every mode but INSERT leaves the app's own chords to
INSERT. Escape is mapped by default, to `app cancel`:
the focused app gets its own Escape back as a command, and a terminal gets
nothing. The one exception is Mission Control and App Exposé, which have no
app behind them to type into: while the Dock shows one, the keys NORMAL does
not map reach it, and so does the key NORMAL maps to `app cancel`, so Escape
closes it; a native context menu gets that Escape too. Map a key to the command it stands for; for a
chord no command covers, `key send` is the explicit escape hatch, or the
user enters INSERT first. The release of a swallowed key is swallowed with it,
because a terminal running the Kitty keyboard protocol encodes key releases to
its pty. A held key's repeats follow its press: a key whose press entered
INSERT repeats nothing into the app, and a key the app received keeps
repeating there.

A synthesized chord reaches an iOS app (Mac Catalyst or iPad) with its
modifiers pressed and released around the key, as a keyboard sends it: UIKit
matches key commands against the modifier state it tracks from those presses
and ignores a lone key event carrying modifier flags.

Hermeticity also bounds what NORMAL synthesizes. A terminal emulator does not
ignore a Command chord it has no binding for: its encoder falls through to the
plain-text path and writes the chord's base character, so an unbound `cmd+g`
types a literal `g` into the shell, hardware or synthetic. In a terminal
Flash therefore refuses to synthesize any Command chord outside the set every
emulator binds (copy, paste, close, new tab, new window, quit, find, the tab
digits, and Shift-bracket tab traversal); a chord a plugin binds for that
emulator specifically, such as the bare brackets of the emulators whose splits
live on them, is added. A plugin-wide binding for every app never is, so
`app save` does nothing in a terminal rather than type an `s`. A refused mapping does
nothing and NORMAL stays.

## Arrows or scrolling

`h` `j` `k` `l`, `ctrl+d` / `ctrl+u`, `ctrl+f` / `ctrl+b` and `gg` / `G` are
one `move` command each (`move down`, `move half_page_down`, `move top`, …).
`h` `j` `k` `l` are always the arrow keys, except in a terminal: the caret
moves in a text field, the selection in Finder's list, and a web page or a
PDF scrolls on them as it does on the arrows. What the page keys and the
edges send depends on where the keyboard focus sits in the focused app:

| Focused context | `j` / `k` | `h` / `l` | `ctrl+d` / `ctrl+u` (`ctrl+f` / `ctrl+b`) | `gg` / `G` |
| --- | --- | --- | --- | --- |
| Editable text you engaged ([engage a field](#engage-a-field)) | Down / Up (`input line_down`, `input line_up`) | Left / Right, never leaving the line | Down / Up `move_page_lines` times (twice that) | Vim's first / last line, from the text table ([Vim motions in text](#vim-motions-in-text)); `move top` / `move bottom` send Cmd-Up / Cmd-Down (`input document_start`, `input document_end`) |
| Lists, tables, outlines, column browsers, collection views, sidebars | Down / Up (`move down`, `move up`) | Left / Right (`move left`, `move right`) | Down / Up `move_page_lines` times (twice that) | The app's `move top` / `move bottom`, else the scroller to the top / bottom |
| Web page or document with no focused control, or a field you have not engaged | Down / Up (`move down`, `move up`), which the page scrolls on | Left / Right (`move left`, `move right`) | `scroll half_page_down` / `half_page_up`, 20 lines (`page_down` / `page_up`, 40) | `scroll top` / `scroll bottom` |
| Terminals | `scroll down` / `scroll up`, 3 lines: never an arrow, which the shell would take (Up recalls history) | `scroll left` / `scroll right` | As in a page | As in a page |

Editable text is a text field, a text area, a search field, a combo box, a
password field, a web input or an editable region whose value the app says
can be set (a password field always counts). Until you engage the field
([engage a field](#engage-a-field)) it counts as a page: `h` and `l` do
not stop at its line's edges and the Vim motions do not apply, but the
arrows of `h` `j` `k` `l` still reach it, since the keyboard focus is
there. On google.com, whose search box takes the focus on load, `j` moves
into its suggestions until you click the page or press Escape in the box.
The arrows go in a single-line field too, where a search field's Up and Down
pick its suggestions and Safari's address bar's Down moves into its
list. `h` stops at the start of the line and `l` on its last
character, as in Vim, counted in whole characters (an emoji or an accented
letter is one) in the text Accessibility gives; where the app gives none,
as in a password field, the arrows go as counted and the field's own edges
stop them.

A list is the focused element, or one of its first three ancestors, with a
list, table, outline, column-browser, grid, row or cell role (`AXList`,
`AXTable`, `AXOutline`, `AXBrowser`, `AXGrid`, `AXRow`, `AXCell`), so an
element focused inside a row or a cell counts too. Its arrows are the app's
`move` bindings, the arrow keys in the bundled `defaults` plugin, so the app
handles them natively: Finder's column view moves between columns, and an
outline's Left and Right collapse and expand a row. A web page's plain list
(`<ul>`, `<ol>`) is not one: it has no selection, and an arrow would scroll
the page anyway.

Everything else is a page: a field you have not engaged, a web area with
no focused control, a scroll area, a group, a PDF, an image, a link, a
slider, a pop-up button, nothing focused, or a role Flash does not know.
There `h` `j` `k` `l` send the arrow keys, which the app scrolls on, and
the page keys and `gg` / `G` scroll ([scrolling](#scrolling)).

A terminal scrolls the same way and never receives an arrow: Up in a shell
recalls history. A declared terminal emulator, tmux panes inside one
included, is recognised from its bundle without any read, and xterm.js in
web content (the integrated terminals of VS Code, Cursor, Hyper and Tabby,
web terminals) by its hidden input: a text area with the class
`xterm-helper-textarea`, which Chromium (every Electron app) and WebKit show
Accessibility as the element's DOM classes, or, in Firefox, which shows no
classes, xterm.js's own `Terminal input` label. The
`terminals` plugin also binds every `move` and `input` binding key to
`false`, so nothing ever sends them there.

The arrows of one `move` (`5j`, a half page) go 4 ms apart, so a half page
takes about 60 ms. `[mode] send_key_interval_ms` does not pace them: it
paces chords for terminals and remote desktops, which never receive these
arrows. A count multiplies: `3 ctrl+d` is 45 arrows, while `gg` and
`G` send one key whatever the count.

[`[mode] move_page_lines`](config:mode.move_page_lines) (15 by default, 1
to 200) is how many arrows a half page sends where these keys move a caret
or a selection; a page sends twice as many. Vim's `ctrl+d` moves half a
window, and a typical text or list view shows about 30 rows, so 15 is half
of one: overshooting in a list is harder to follow than a second press, and
`ctrl+f`'s 30 is about a page. `scroll_step_lines` and `scroll_page_lines`
still set how far the keys scroll in a page or a terminal.

### Where the focus is

Flash classifies the focused element once per focus change, not per key.
After every focus change the Accessibility observers report (an app coming
forward, `AXFocusedUIElementChanged`, the focused or main window
changing), it reads the element's role and the roles
of its first ancestors off the main loop and caches the answer, the focus
region; a keypress only reads that cache. A key pressed while the read
after a focus change is still pending waits for it, in order, rather than
act on what was focused before. A reading for another app than the one the
key was meant for counts as unknown: a page, which scrolls. The same
reading ends a field's engagement when it names another element or app,
and after a click, `gi` or an `f` engages the field it names
([engage a field](#engage-a-field)); NORMAL's table follows the
engagement, never the region a reading reports.
[Input capture](input-internals.md#the-focus-region) has the details.

### Force one behaviour

Bind the command you want instead of `move`: `scroll …` always scrolls,
`input line_down` and the other `input` moves always move the caret, in a
field engaged or not (and do nothing outside editable text), and
`key arrow --direction=…` sends a raw arrow wherever the focus is. To keep
the page keys scrolling everywhere:

<!-- modes: assumed on -->

```toml
[mode.normal.mappings]
"j" = ["flash", "scroll", "down"]
"k" = ["flash", "scroll", "up"]
"ctrl+d" = ["flash", "scroll", "half_page_down"]
"ctrl+u" = ["flash", "scroll", "half_page_up"]
```

`ctrl+e` / `ctrl+y` already scroll wherever the focus is.

### Where a scroll lands

Every vertical scroll (`j` / `k` in a page, `ctrl+e` / `ctrl+y`, `ctrl+d` /
`ctrl+u`, `ctrl+f` / `ctrl+b`) lands at the pointer while the pointer is
inside the focused window, so it scrolls the view under it, the one you are
looking at. With the pointer outside the focused window it lands in the
middle of the focused element's scroll area, read with the focus region, or
else in the middle of the focused window, so the scroll reaches the window
you are working in rather than whatever the pointer rests on. With no
focused-window frame known (`[overlay] window_border = false`, or before
the border's first read) it stays at the pointer. `scroll target` moves the
pointer onto the scroll area you pick.

## Vim motions in text

In a field you engaged, NORMAL reads
[`[mode.text.mappings]`](config:mode.text.mappings) before its own table:
Vim's motions, which move the caret where Vim's cursor would land. NORMAL's
table answers every key the text table leaves unmapped, as it does under
HOLD's, so `f`, `gt`, `/`, `u`, `y` and `h` `j` `k` `l` work in a field as
they do anywhere. With no field engaged the table is not read at all, and
every key keeps its NORMAL meaning. The live [key mappings](/mappings) page
shows the table as its Text mode, and `flash resident status` reports the
mapping scope `text` while a field is engaged.

### Engage a field

A field is editable text: a text field, a text area, a search field, a
combo box, a password field, a web input or an editable region, never a
terminal (a declared emulator, tmux or xterm.js). The keyboard focus
sitting in one is not enough. NORMAL acts on a field once you engage it,
by an act of your own in it:

- leaving INSERT (`mode normal` or `mode leave`) with the focus in it, so
  after `i` and your typing the motions act where you typed;
- `gi` (`input focus`), on the field it focuses;
- a click with the primary button, single, double or triple, whose focus
  settles on the field: with the mouse, with `f` on a text input or with
  `F`. A right or middle click, or one in the menu bar, engages nothing;
- `v` or `V`, which start [VISUAL](visual-mode.md) in it.

Flash asks nothing about what is under the pointer. After a click it reads
the focus again, and every reading until your next key engages the field it
names, so a reading from before the click is corrected by the one after.

The engagement ends:

- when the focus settles on another element, or another app comes forward;
- on Escape in NORMAL, the text table's `mode leave`: hints, a popup or the
  command line close first, then Escape gives NORMAL's own keys back and
  leaves the field focused (the next Escape is the app's, `app cancel`);
- on any mode change but the trips through INSERT, VISUAL, the command line
  and a HYPER hold: HOLD, a layer, TERMINAL and turning the modes off all
  end it. Leaving VISUAL keeps the field engaged, so does closing the
  command line (`:42` goes to line 42 of the field), and so does a
  `<leader>` sequence typed in it.

Nothing waits on a timer: a reading that names the engaged field keeps it
engaged, whatever else it reports.

A field the page focused on its own is not engaged. Google Docs keeps a
hidden editor focused, google.com puts the focus in its search box on load,
and a new tab focuses the address bar. There the field is a page: `x`
closes the tab, `t` opens one, `H` and `L` go back and forward, `j` and `k`
scroll ([arrows or scrolling](#arrows-or-scrolling)), and the motions
move nothing in it. Click the field, or press `gi`, to work on its text.

Some apps are never engaged: an editor with its own modal editing or
partial Accessibility text, where Vim's motions are the editor's and the
text Flash would read is incomplete. VS Code and its forks (VSCodium,
Cursor, Windsurf), the JetBrains IDEs, Zed and Sublime Text are declared by
the bundled `defaults` plugin (manifest `own_text_editing`; a plugin of
your own adds more, [plugin protocol](plugin-protocol.md#manifest)). In
them every key keeps its page meaning, `v` and `V` do nothing, and the text
table is never read. An app's `enabled` key under `[mode.apps."<bundle id>".text]`
forces it either way: `true` engages a declared editor after all, `false`
keeps another app out.

```toml
[mode.apps."com.microsoft.VSCode".text]
enabled = true                        # engage VS Code's editor after all

[mode.apps."com.apple.Notes".text]
enabled = false                       # never engage a Notes field
```

[`[mode.text] enabled = false`](config:mode.text) turns the engagement off
everywhere, for a [kindaVim](alternatives/kindavim.md) or
[SketchyVim](alternatives/sketchyvim.md) user who keeps Vim inside the
field: Flash never engages a field, `v` and `V` do nothing, and no per-app
key brings it back.

NORMAL's table changes only when the engagement does, never on a focus
reading alone. A page whose focus flaps between a field and the page never
swaps the table under you, and a half-typed sequence (`]t`, `3g`) still
waits for its next key. The focus is read off the main loop after each
focus change, never through Accessibility on the keypress
([where the focus is](#where-the-focus-is)). One rule decides which text
NORMAL acts on, for these keys, the `move` keys, `p` and
[VISUAL](visual-mode.md) alike. The debug log says
`[text] engaged` or `[text] disengaged` with the reason and the app's
bundle, never the text.

### The motions

| Key | Command | The caret goes to |
| --- | --- | --- |
| `w` / `W` | `cursor next_word` / `next_big_word` | The start of the next word / WORD |
| `b` / `B` | `cursor previous_word` / `previous_big_word` | The start of this or the previous word / WORD |
| `e` / `E` | `cursor word_end` / `big_word_end` | The end of this or the next word / WORD |
| `ge` / `gE` | `cursor previous_word_end` / `previous_big_word_end` | The end of the previous word / WORD |
| `0` | `cursor line_start` | The line's first character |
| `^` | `cursor first_nonblank` | The line's first non-blank character |
| `$` | `cursor line_end` | The line's last character, count - 1 lines down |
| `g_` | `cursor last_nonblank` | The line's last non-blank character, count - 1 lines down |
| `\|` | `cursor column` | The column the count names, in characters (a tab is one) |
| `gg` / `G` | `cursor first_line` / `last_line` | The first / last line's first non-blank; `{N}gg` and `{N}G` line N's (`cursor line --index=N`) |
| `%` | `cursor matching_bracket` | The bracket matching the next `(` `)` `[` `]` `{` `}` on the line; `{N}%` the line N percent through the text (`cursor line --percent=N`) |
| `{` / `}` | `cursor previous_paragraph` / `next_paragraph` | The previous / next empty line |
| `(` / `)` | `cursor previous_sentence` / `next_sentence` | The start of this or the previous sentence / of the next one |
| `+`, Return | `cursor next_line` | The first non-blank count lines down |
| `-` | `cursor previous_line` | The first non-blank count lines up |
| `_` | `cursor line_nonblank` | The first non-blank count - 1 lines down |
| `H` / `M` / `L` | `cursor screen_top` / `screen_middle` / `screen_bottom` | The first non-blank of the first / middle / last visible line; `3H` the third from the top, `3L` the third from the bottom |
| `t` / `T` | `cursor till_next_char` / `till_previous_char` | Just before the next / just after the previous occurrence on the line of the character typed next; `3tx` the third |
| `;` / `,` | `cursor repeat_char` / `repeat_char_back` | The last character search again / the other way |
| `zt` / `zz` / `zb` | `scroll cursor_top` / `cursor_middle` / `cursor_bottom` | Nowhere: the text scrolls so the caret's line sits at the top / middle / bottom |
| `gj` / `gk` | `move down` / `move up` | One display row down / up: the arrows already move by rows |
| `p` / `P` | `register paste --after` / `register paste` | Vim's put: after the cursor / at it |

A word is a run of letters, digits and underscores, or of other non-blank
characters, as with Vim's default `iskeyword`; a WORD (`W`, `B`, `E`, `gE`)
runs to the next blank. An empty line is a paragraph boundary for `{` and
`}`, and a line of blanks is not, as in Vim. A sentence ends at `.`, `!` or
`?` followed by a blank or the line's end, by Vim's own rule (a port of its
`findsent`). `%` counts nesting and knows no quotes. `j` and `k` stay
NORMAL's `move`, the arrows, as do `h`, `l` and the page keys, and `ctrl+e`
/ `ctrl+y` scroll.

### Counts and the caret

A count measures the motion, as in Vim: `3w` is three words on, `2$` the
end of the next line, `5|` column 5, `10G` and `10gg` line 10, `50%` the
line half way through the text and `3H` the third visible line. A `0` typed
after a count digit is part of the count (`10j`); on its own it is the
line's start.

macOS draws a caret between two characters, where Vim's cursor sits on one.
Flash puts the caret just before the character Vim's cursor would be on, so
`$` leaves it before the line's last character and `e` before the word's
last character, and `p` then puts after that character, as in Vim. With
a selection showing, the cursor is where the selection starts, and a motion
leaves a caret; after `v` or `V`, a motion grows a selection instead
([VISUAL](visual-mode.md)). A character is a whole grapheme (an emoji or an
accented letter is one), at the UTF-16 offsets Accessibility counts. A line
is a logical line, between two line breaks, not a wrapped row: `j` / `k` (the
arrows) and `gj` / `gk` move by the rows the app draws.

### How a motion lands

Flash reads the text through Accessibility and only ever sets the caret or
the selection: it never writes the text
([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)).
One read, off the
keyboard path, gives the selection, the length and the text, and for `H`
`M` `L` the visible range (`AXVisibleCharacterRange`). Flash computes where
Vim lands, sets `AXSelectedTextRange` to that caret on the same focused
element and reads it back. The motions are checked against Vim 9.1 by a
differential fuzzer: about 200,000 random cases over every motion but `H`
`M` `L`, with no mismatch. A motion Vim would not make (`%` with no bracket
on the line, `tx` with no `x` after the cursor) leaves the caret where it
is, and `H` `M` `L` do nothing where the app does not say what is visible.
Nothing read is kept ([privacy](privacy.md)).

A secure field never gives its text, and text over 1,000,000 UTF-16 units,
or whose text and length disagree, counts as none. Where the app gives no
text, the app's own chord for the motion runs where macOS has one, the
`cursor` bindings of the bundled `defaults` plugin: Option-Left for `b` and
`B`, Option-Right for `e` and `E` (which lands just after the word, an
approximation), Cmd-Left / Cmd-Right for `0` / `$` and Cmd-Up / Cmd-Down
for `gg` / `G`. Every other motion does nothing there rather than guess. A
plugin overrides those chords for an app with `cursor` bindings of its own
([source commands](#source-commands)). A terminal gets none of it: the text
table is never read there, and the `terminals` plugin binds the `cursor`
chords to `false`.

`.` does not repeat a motion, since Vim's `.` repeats changes; a macro
records it ([repeat and macros](#repeat-and-macros)).

### Character search

`t` and `T` read the next key as the character, as in Vim: `t,` lands just
before the next comma on the line, `T(` just after the previous `(`, and
`3tx` before the third `x`. `;` repeats the last search and `,` repeats it
the other way. A repeated `t` or `T` skips the match right next to the
caret, so it makes progress, as Vim does by default. The search waits for
its character as long as it takes, as Vim's does; Escape, Return or a chord
cancels it, and Tab is a character like any other.

`f` and `F` stay the hints in text too, as everywhere: a field is one more
place to click from. Vim's find onto the character is `cursor next_char`
and `cursor previous_char` (`--char=<c>` names the character; without it,
the next key typed is), repeated by `;` and `,` like `t` and unbound by
default; [change the text keys](#change-the-text-keys) binds them.

### Scroll around the cursor

`zt`, `zz` and `zb` scroll the text so the caret's line sits at the top, the
middle or the bottom of its scroll area (`scroll cursor_top`,
`cursor_middle`, `cursor_bottom`), and leave the caret where it is. Flash
measures the caret's line through `AXBoundsForRange` and the scroll area's
frame, and posts a pixel wheel of that distance in the scroll area; an app
that gives neither does not scroll. NORMAL's `zi`, `zo` and `z0` still zoom.

### Put after the cursor

`p` is Vim's put after the cursor (`register paste --after`): one character
right, unless the line ends at the cursor, then the app's own paste of the
register. `P` puts at the cursor (`register paste`). With the caret before
the character Vim's cursor is on, `p` puts the text after that character, as
Vim's does. `"ap` and `"aP` name a register as anywhere else, and with no
field engaged `p` and `P` both paste at the cursor.

### Keys in text

Each of these keys keeps its NORMAL meaning with no field engaged, a field
the page focused on its own included:

| Key | No field engaged | In an engaged field |
| --- | --- | --- |
| `H` / `L` | The app's back / forward (`history back`, `history forward`) | The first / last visible line (`cursor screen_top`, `screen_bottom`) |
| `t` | A new tab (`tab new`) | Till the next character typed (`cursor till_next_char`) |
| `gg` / `G` | `move top` / `move bottom`: a list's first / last item, else the top / bottom of the page | The first / last line's first non-blank (`cursor first_line`, `last_line`), instead of `move`'s Cmd-Up / Cmd-Down |
| `p` | Paste at the cursor (`register paste`) | Paste after the cursor (`register paste --after`) |
| `w` `W` `b` `B` `e` `E` `ge` `gE`, `0` `^` `$` `g_` `\|`, `%`, `{` `}` `(` `)`, `+` Return `-` `_`, `M`, `T` `;` `,`, `zt` `zz` `zb`, `gj` `gk` | Unbound: swallowed, free to map | The motions above |
| `gv` | Unbound: swallowed | The last [VISUAL](visual-mode.md) selection of this field, again (`mode visual --reselect`) |
| `v`, `V` | Select characters, whole lines in the focused field and engage it; with no field focused, or in an app that is never engaged, nothing ([VISUAL](visual-mode.md)) | The same |
| `f` / `F` | The hints, the mouse grid | The same |
| `x` | Close the tab | The same |
| `r`, `R` | Reload, hard-reload | Nothing, so what you typed stays |
| `d`, `c`, `y` | The double-click and right-click prefixes, yank | The same |
| Escape | Cancels hints, as everywhere; else the app's own cancel (`app cancel`) | Closes hints, a popup or the command line first; else ends the engagement (`mode leave`): NORMAL's own keys come back |

Vim's operators on a motion (`dw`, `cw`, `y$`) are not Flash's, since
Flash never deletes or changes text
([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)).
To copy, select with `v` or `V` and the motions, then `y` copies the
selection and `p` pastes over it ([VISUAL](visual-mode.md)). In NORMAL `d`, `c` and `y` keep
Flash's meanings in a field: `y` copies the selection, `d` and `c` start a
double-click and a right-click.

### Change the text keys

[`[mode.text.mappings]`](config:mode.text.mappings) layers over NORMAL's
table as [`[mode.hold.mappings]`](config:mode.hold.mappings) does: a key
mapped there wins in an engaged field, a key there hides the NORMAL keys it
starts (the text table's `t` hides a NORMAL `tf`), and `"<key>" = false`
removes the key there, NORMAL's binding of it included. To give a key back
its NORMAL meaning in a field, map it there to NORMAL's command. The text
table removes `r` and `R` by default, since reloading the page would lose
what you typed; map them there to take them back. `x` is not in it: the
tab closes in a field too. It maps Escape to `mode leave`, which ends the engagement;
`"<esc>" = false` there keeps the field engaged until the focus moves or
the mode changes. `v` and `V` are not in it: they are NORMAL's keys, in
[`[mode.normal.mappings]`](config:mode.normal.mappings), so they work in a
field before it is engaged
([change the keys](visual-mode.md#change-the-keys)). To keep `H`, `L` and
`t` Flash's in a field, and put Vim's `f` and `F` on the hint keys there:

```toml
[mode.text.mappings]
"H" = ["flash", "history", "back"]          # as with no field engaged
"L" = ["flash", "history", "forward"]
"t" = ["flash", "tab", "new"]
"f" = ["flash", "cursor", "next_char"]      # Vim's f; mf, df and cf still hint
"F" = ["flash", "cursor", "previous_char"]
```

The text table takes no `<leader>` key, which belongs to NORMAL's table,
but NORMAL's table answers in a field for every key the text table leaves
free. To keep `f` the hints and still have Vim's find, map it there; with
no field engaged it has no text to search and does nothing:

```toml
[mode.normal.mappings]
"<leader>f" = ["flash", "cursor", "next_char"]
"<leader>F" = ["flash", "cursor", "previous_char"]
```

`[mode.apps."<bundle-id>".text.mappings]` changes the text keys for one app
([app-specific mappings](configuration.md#app-specific-mappings)), and a
plugin's manifest `mappings` reach the table with `"mode": "text"`
([plugin protocol](plugin-protocol.md)).

## Scrolling

`ctrl+e` / `ctrl+y` always scroll, as Vim's scroll the view without moving
the cursor; `j` / `k`, `ctrl+d` / `ctrl+u` and `ctrl+f` / `ctrl+b` scroll
where a `move` scrolls, in a page and in a terminal. These scrolls
synthesize line-based mouse-wheel events in every app, including terminals,
where [a scroll lands](#where-a-scroll-lands). They use no app-specific
scrolling action or Accessibility scroll fallback. The receiving app handles
the event just as it handles a physical wheel. With
`[mode] scroll_smooth_ms` set, one keypress becomes several smaller line
events spread over that duration (at most 300 ms): the first moves at once,
the rest follow at least a frame apart on the click queue, and they add up to
the same lines, so terminals scroll exactly as far. A new scroll, including
`gg` / `G` and `h` / `l`, drops what the previous one has left. `[mode] scroll_step`
continues to set horizontal movement in pixels. Where `gg` and `G` scroll
(`scroll top` / `scroll bottom`), they keep their source-aware edge
behavior. Inside tmux they follow tmux's own wheel routing:
a pane in a mode scrolls that mode (history-top, cancel); a program that
tracks the mouse, such as a full-screen CLI, owns its scrolling and receives
1,000 wheel reports; any other pane enters copy-mode at the top of its history
and is already at its live bottom. Another terminal scrolls 1,000 lines as a
line wheel, like the vertical scrolls.

HOLD has its own `ctrl+d` / `ctrl+u`, `ctrl+f` / `ctrl+b` and `gg` / `G`,
bound to the `scroll` commands rather than `move`, so a held selection
follows the page whatever has focus; `ctrl+e` / `ctrl+y` are NORMAL's and
scroll there too ([HOLD](hold-mode.md)).

## NORMAL stays

NORMAL is persistent by default; `mode normal` takes no persistence
option. No command asked of the app changes the mode: opening Find (`/`),
its matches (`n` / `N`), a new tab (`t`), switching tabs, `input focus`
(`gi`) and the `input`, `move` and `cursor` moves (`h` `j` `k` `l` moving a
caret and Vim's motions in text included) preserve NORMAL even when the app
focuses an editable field.
Accessibility focus notifications never change the mode.
No click changes it either: `f`, `F`, the letter jump `s` and a click with
the mouse keep NORMAL on a text field, a password field or a terminal as on
a button, a link, the desktop or the Dock, and so do the keys you type after
it. A click, `gi` or leaving INSERT in a field engages that field, which
changes the table NORMAL reads, never the mode
([engage a field](#engage-a-field)). Only an explicit `mode insert`
mapping hands typing to the app (see
[entering INSERT](insert-mode.md#enter-insert)), and it takes no argument:
nothing moves the cursor or deletes text before INSERT.

## Context menus

A context menu Flash saw open keeps the keyboard until it closes: a recapture
a system event asks for — an app launching, a Space change, the panel resigning
key — never ends it, while its close notification, an explicit mode entry or
another app coming forward does. A surface that posts no menu notifications
keeps the bounded window that stood in for a close signal.
While a context menu is open its app's NORMAL mappings still fire, so `f`
labels the menu's items rather than the window behind it: the walk starts at
the menus the app reported opening (submenus included; a browser's context
menu is reachable no other way) and keeps targets inside their frames. A
submenu closing leaves the menu it hangs from in charge of the keyboard. The hint session takes the keyboard back from the menu while it runs,
so labels and Escape reach Flash, and gives it back when it ends. This needs
the session tap: Flash's key-window fallback would close the menu by becoming
key, so under secure input `f` walks the window as before.
A label or configuration refresh preserves native-menu capture suspension; only an explicit
mode entry resets that interaction context.

## Rejected commands

Unknown commands and unsupported subcommands do nothing visible: no toast, only
a warning log naming the invocation and pointing to the mapping or
configuration. Invalid mapping arrays report their source location during
configuration loading. Malformed built-in commands cannot silently become plugin
calls. Plugin execution failures still raise the error toast.

The CLI accepts `--key=value` and boolean `--flag` arguments, rejects stray
positional subcommands, and returns status 2 when parsing or resident dispatch
rejects an invocation. Successful dispatch does not imply an asynchronous plugin
operation completed successfully; later failures appear in the toast and logs.
An empty command prompt remains quiet.
