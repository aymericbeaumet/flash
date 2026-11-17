# HYPER

HYPER lasts as long as you hold one key: what you press meanwhile reads its
own table, the Apple function row and arrows by default, and letting go
returns to NORMAL. It puts media, brightness and arrow keys under your
fingers without leaving the home row.

Holding `mode.normal.hyper` enters HYPER until that key is released. The
default is `<leader>`, which follows `mode.normal.leader`. When the key is
`<leader>` and the leader is not set (`leader = false`), HYPER stays off.
Any other single key works in its place (`a`, `<space>`, `cmd+space`). The
status pill is purple and shows `mode.labels.hyper` (default `HYPER`). Keys
pressed while it is held are read from [`[mode.hyper.mappings]`](config:mode.hyper.mappings), not from
NORMAL. The defaults are the Apple function row on `1`–`9`, `0`, `-`, and
`=`: brightness, Mission Control, Spotlight, Dictation, Focus, media, mute,
and volume. Shift plus the same key sends F1–F12. Arrows sit on the
physical keys where QWERTY has `e` `s` `d` `f` (up, left, down, right),
spelled as the letters those keys type in `[keyboard] layout`: QWERTY
`e` `s` `d` `f`, Colemak `f` `r` `s` `t`, Dvorak `.` `o` `e` `u`, Bépo
`p` `u` `i` `e`. F is the home-row index-finger mark, and it is right.
Shift posts a shifted arrow on that same letter, so Colemak down is
`shift+s`. A punctuation key uses the character Shift types there, so
Dvorak up is `>`. A mapping or `false` on one of those keys wins.
The arrow is posted into the focused app's key window, downstream of the
session tap. `postToPid` carries no window, so a terminal drops it while
the hyper key is still down. Volume is a system event and does not take
this path. F-keys use the same window posting.
Pointer movement and bisect stay on the hjkl columns.

While the hyper key is the leader, a key with no hyper mapping can still
complete a NORMAL `<leader>` sequence when that key continues one, so
`<leader>w` typed fast, with `w` down before the leader is up, still runs.
Unmapped keys are swallowed.

A hold enters HYPER right after a repeatable mapping too: `]t` arms a repeat
of `t`, which any other key drops, the hyper key included. Only a mapping
whose final key is the hyper key keeps that press as its repeat. Entering
HYPER drops whatever NORMAL had pending, with its timeout.

Releasing the key returns to NORMAL. The session tap can drop that key-up
after it swallowed the press and a synthetic event (a volume key, a posted
chord) lands in between; HYPER would otherwise stay up until the key is
pressed again. While HYPER is latched, `core:hyper-hold` reads the key from
the HID state table (`CGEventSource.keyState(.hidSystemState)`, and every
modifier in a chord such as `cmd+space`) and leaves once the key has been up
for two ticks. Combined session state is the wrong table: a swallowed press
can look up there. The next key sees the same reading, leaves first, and is
routed as a NORMAL key. A delivered key-up still leaves immediately. The
watch is registered only while the mode is HYPER. Leaving HYPER any other
way — `mode leave`, opening the command line, a focus change — ends the hold
and drops its pending keys the same way: the mode transition is the one
reset point, so no exit can leave a latched hold behind.

If nothing else was pressed and the hyper key is the leader, that tap arms
the `<leader>` prefix: press it,
release it, then the next key, and the sequence runs as before. Holding it
again enters HYPER while that prefix is armed. A mapped `<leader><leader>`
sequence still takes the second press. Any other pending sequence stays in
NORMAL. INSERT, the command line, a popup, and an open hint session keep
their own keys. See [`[mode.normal] hyper`](config:mode.normal.hyper) and [`[mode.hyper.mappings]`](config:mode.hyper.mappings).
