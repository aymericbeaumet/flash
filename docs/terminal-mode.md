# TERMINAL

TERMINAL is the mode of a focused [popup](popups.md): its terminal gets
every key, so a TUI such as btop or newsboat runs as it would in any
terminal. The pill reads `mode.labels.terminal` (default `TERMINAL`) in
mauve.

## Enter and leave

Every popup is a terminal. TERMINAL sits beside NORMAL, INSERT, COMMAND, and
the momentary HYPER layer: `mode terminal [--name=<popup>]` enters it by showing the
popup standalone (the built-in `terminal` popup without a name), and clicking a
popup's body or pinning it from the status bar enters it too. Either way the
popup's local terminal view gets focus. `mode leave` leaves it, closing the
popup. Entering the popup already focused is a no-op; entering another replaces
it. The overlay owns no keyboard input in this mode: the
existing global tap passes keys through, every Carbon registration is suspended,
and only [`[mode.terminal.mappings]`](config:mode.terminal.mappings) can intercept keys in the popup. The label is
configured with `mode.labels.terminal` and defaults to `TERMINAL`.

| Key in a popup | Does |
| --- | --- |
| Command-W | `mode leave`: close the popup; a persistent process keeps running |
| Command-R | `popup restart`: restart the process now; a text popup rereads its values |
| Command-Q | `popup quit`: stop the process; a persistent popup restarts it |

Escape goes to the program, since terminal programs use it. These three are
the defaults of [`[mode.terminal.mappings]`](config:mode.terminal.mappings).

## Keys in a popup

Terminal mappings inherit only the effective INSERT-active bindings whose
winning action is `mode normal` or `mode leave`. Scope and plugin precedence are resolved
before this inheritance; an explicit terminal mapping overrides an inherited
binding with the same canonical key. Other all, normal, and insert bindings are
inactive. Plugins may contribute terminal mappings using the same priority rules.

The local sequence recognizer accepts the shared key syntax, including modified
chords and explicit sequences, but has no implicit Escape behavior, counts,
register prefixes, or `<leader>`. Only known sequence prefixes wait for
`mode.sequence_timeout_ms`. An exact mapping that also starts a longer sequence
waits for that timeout; a mismatch resolves the longest completed mapping and
reprocesses the remaining keys. Unmatched events retain their original modifiers
and are replayed exactly once to the terminal that received them; a key press
replayed to a fresh popup whose process has ended closes the popup instead
([lifecycles](popups.md#lifecycles)). Focus and
configuration changes flush unresolved events without dispatching a pending
command. `repeat = true` retains the explicit final-key repetition behavior.

## Focus and activation

Local mappings run before native copy/paste and terminal key encoding. Text
popups use the same focus mode for selection, copying, and scrolling. Leaving via
`mode normal` dismisses the popup and activates the captured external app
before NORMAL recapture. Losing popup focus restores the prior base mode without
activating a different app. The app captured on entry is part of the TERMINAL
mode value and is forgotten with it: the next popup captures its own, and no
other exit can activate an app a popup once covered. A popup's lifecycle, not its focus or visibility,
decides how long its process lives; see [popups](popups.md#lifecycles).

## Related

- [Popups](popups.md#declaring-popups): declaring `[popup.<name>]`, sizes and
  styles.
- [Lifecycles](popups.md#lifecycles): how long a popup's process lives.
- [Leave a mode](modes.md#leave-a-mode): one `mode leave` shortcut for every
  surface.
