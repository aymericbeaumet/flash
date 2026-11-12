# INSERT

INSERT gives the keyboard back to the app: every key types or reaches the
app as if Flash were not there, and only your chords act. It is the mode you
type in, as NORMAL is the one you command from. The pill reads
`mode.labels.insert` (default `INSERT`) in light blue.

## Enter INSERT

INSERT has exactly one entry (`InsertEntry`): bare `mode insert`. NORMAL's
`i` runs it, and so does any mapping you configure. It takes no argument
and types at the cursor: Flash never moves the cursor or deletes text
first, so Vim's `I`, `a`, `A`, `o`, `O`, `s`, `S` and `C` are not ways in
(see [where typing starts](#where-typing-starts)).

Nothing else enters INSERT. A click keeps the mode you are in, wherever it
lands and however it is made: with the mouse, with `f` (`mouse target`) or
with `F` (`mouse grid`), on a text field, a search field, a password field,
a terminal, a button, a link or the desktop. Flash does not ask what is
under the pointer, and the keys you type after a click go where the mode
sends them: in NORMAL, click into a field, then press `i` to type there. A
primary click whose focus settles on a field engages it, so NORMAL's
motions act on its text ([engage a field](normal-mode.md#engage-a-field)).

Every other mapping and command preserves NORMAL: Find (`/`) and its matches
(`n` / `N`), a new tab (`t`), tab switching, `input focus` (`gi`), the
cursor moves run alone (`input line_end`, …) and the `move` keys (`h` `j`
`k` `l` moving a caret), HOLD's and VISUAL's operators and the letter jump
`s` included. Focus changes and app activation preserve it too.
Entering a mode preserves the focused external app. Mode events carry no
activation target: a NORMAL capture can outlive an app switch, so its captured
PID must never be reactivated on INSERT entry. Committed clicks and app commands
own their focus changes; the mode change only releases or restores capture.
Moving the pointer, dragging, or selecting with the grid does not request INSERT.
A click chain (`alt+f`, `mouse target --multi`) keeps the mode too: a click
on an input is a click like any other, so the chain goes on after it, and
Escape ends it in the mode it started in. It discovers
the app's targets again after each click, and again whenever the app reports
a change before the next pick, so controls the click revealed get hints and
removed ones lose theirs; a target that is still there keeps its label. The
previous labels stay drawn until the new set replaces them, and an app left
with no targets after a click ends the chain
([click several targets](hints.md#click-several-targets)).
Use `mode leave` / `mode normal` to return from INSERT to NORMAL.

## Where typing starts

`mode insert` (`i`) hands the keyboard over where the cursor is, and does
nothing else. Flash does not edit text
([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)):
it never places the cursor for you on the way in, and never deletes what
you are about to type over. Vim's `I`, `a`, `A`, `o`, `O`, `S` and `C` are
unbound in NORMAL, so they are swallowed; `s` is the letter jump; and
VISUAL has no `c` or `s`.

Place the cursor before you press `i`, with NORMAL's motions in a field you
engaged ([engage a field](normal-mode.md#engage-a-field)), or after it, with
the app's own keys, which INSERT leaves to the app:

| Vim | In Flash |
| --- | --- |
| `I` | `^`, then `i` |
| `a` | `i`, then Right |
| `A` | `i`, then Cmd-Right |
| `o` / `O` | `i`, then Cmd-Right and Return / Cmd-Left, Return and Up |
| `s`, `S`, `C`, VISUAL's `c` | `i`, then the app's own Delete, or Shift with the arrows to select what you type over |

What the app does with those keys is the app's, undo included: a code
editor's Cmd-Left stops at the first non-blank, and a chat app's Return
sends the message.

## Leave INSERT

There is no default way back: bind `mode normal` or `mode leave` to a chord
in [`[mode.all.mappings]`](config:mode.all.mappings), which is also what
turns the modes on ([advanced mode](modes.md#advanced-mode)):

```toml
[mode.all.mappings]
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"cmd+ctrl+[" = ["flash", "mode", "normal"]
"alt+space" = ["flash", "mode", "terminal"]
```

Leaving INSERT with the focus in a field engages it: NORMAL reads its text
table there, so the motions act where you typed
([engage a field](normal-mode.md#engage-a-field)).

Closing a command line or a popup, or leaving a [layer](layers.md), that you
opened from INSERT puts you back in INSERT. That restores where you were; it
is not a way in.

## Keys in INSERT

- Every key goes to the app except a chord bound in
  [`[mode.insert.mappings]`](config:mode.insert.mappings) or
  [`[mode.all.mappings]`](config:mode.all.mappings). A bare key or a
  sequence in either table is never read here: INSERT does not hold the
  keyboard, so bind chords with a modifier.
- [`[mode.insert.mappings]`](config:mode.insert.mappings) is empty by default. A chord there overrides the
  same chord in [`[mode.all.mappings]`](config:mode.all.mappings) while INSERT is on.
- With advanced mode off, Flash reads these two tables the whole time.

## Who owns activation

INSERT's keys belong to the focused app, so Flash never stays the active app
in INSERT. If Flash still owns activation after closing a surface or no-tap
capture, it schedules a handback to the latest observed focused app and checks
that Flash still owns activation before yielding. Another app already active
keeps activation. Otherwise every key the tap
passes, Command chords included, would reach Flash instead. About and a
hint session keep it.
