# Modes

A mode decides what your keys do. In NORMAL they run commands, in INSERT
they type into the app, and the other modes are the surfaces and holds in
between. One mode is active at a time, and the status bar's pill
(`#{flash.mode}`) names it.

Until a shortcut in [`[mode.all.mappings]`](config:mode.all.mappings) runs
`mode normal` or `mode leave`, Flash has no modes: your shortcuts run their
commands and every other key types as usual. Binding one turns the modes
on, which the reference file calls [advanced mode](#advanced-mode).

| Mode | What the keyboard does | Enter | Leave | Its keys |
| --- | --- | --- | --- | --- |
| [NORMAL](normal-mode.md) | Keys run commands; keys you have not mapped are swallowed | Your `mode normal` shortcut, or closing a surface opened from NORMAL | `i`; `v` `V` in a field | [`[mode.normal.mappings]`](config:mode.normal.mappings), after [`[mode.text.mappings]`](config:mode.text.mappings) in a field you engaged |
| [VISUAL](visual-mode.md) | A selection in the focused text: the motions grow it, operators act on it | `v` `V` in a focused field (`mode visual`), which they engage | Escape, `v` / `V` again, an operator | [`[mode.visual.mappings]`](config:mode.visual.mappings), then the motions |
| [INSERT](insert-mode.md) | Keys go to the app; only your chords act | `i` (`mode insert`), never a click; or closing a surface opened from INSERT | Your `mode normal` or `mode leave` shortcut | [`[mode.insert.mappings]`](config:mode.insert.mappings) |
| [COMMAND](command-mode.md) | You type a command or a flashlight search | `:` in NORMAL, `mode command`, `mode flashlight` | Return runs it, Escape closes it | [`[mode.command.mappings]`](config:mode.command.mappings) |
| [TERMINAL](terminal-mode.md) | A popup's terminal has the keyboard | `mode terminal`, a click into a popup | `mode leave`, Command-W in a popup | [`[mode.terminal.mappings]`](config:mode.terminal.mappings) |
| [HYPER](hyper-mode.md) | Keys pressed while the hyper key is held: the function row and arrows by default | Hold the hyper key, the leader (`\`) by default | Release it | [`[mode.hyper.mappings]`](config:mode.hyper.mappings) |
| [HOLD](hold-mode.md) | A mouse button is held, so keys drag or select | ⌘⌃H (`mode hold`) | Return drops, Escape puts it back | [`[mode.hold.mappings]`](config:mode.hold.mappings) |
| [Layers](layers.md) | A key table of your own | `mode layer --name=<name>` | Escape, `mode leave` | [`[mode.layers.<name>.mappings]`](config:mode.layers.resize.mappings) |

The live [key mappings](/mappings) page draws your keyboard for any of
them, with what each key does in that mode.

## Which keys a mode reads

Each mode reads its own table, then [`[mode.all.mappings]`](config:mode.all.mappings);
an app's own table, `[mode.apps."<bundle-id>"]`, comes first for that app
([app-specific mappings](configuration.md#app-specific-mappings)), and
plugins add theirs at their priority. Bare keys and sequences act only
while Flash holds the keyboard: in NORMAL, VISUAL, HYPER, HOLD and a layer. In
INSERT and COMMAND only chords with a modifier act, because every other key
belongs to what you are typing into; TERMINAL reads its own table with its
own [sequence rules](terminal-mode.md#keys-in-a-popup).

Two tables layer over NORMAL's. HOLD reads
[`[mode.hold.mappings]`](config:mode.hold.mappings) first, and NORMAL reads
[`[mode.text.mappings]`](config:mode.text.mappings) first while a field is
engaged: editable text you acted in, by leaving INSERT there, clicking it,
`gi` or `v`. Its keys are Vim's motions
([Vim motions in text](normal-mode.md#vim-motions-in-text)). In both,
NORMAL's table answers every key the first one leaves unmapped, and
`false` there removes a NORMAL key. The mode stays NORMAL in a field; only
its table changes, when the engagement does: Escape, the focus moving on
and any mode change but INSERT, VISUAL, the command line and a HYPER hold
end it
([engage a field](normal-mode.md#engage-a-field)). A field focused on its
own, a page's search box or the address bar, is not engaged, and NORMAL's
own keys apply there.

VISUAL reads [`[mode.visual.mappings]`](config:mode.visual.mappings) first,
then only the motions (`move`, `cursor`, `scroll`) of the text table and
NORMAL's that it does not shadow, then `[mode.all.mappings]`; every other
key is swallowed, so tabs, hints and app commands wait until it ends
([change the keys](visual-mode.md#change-the-keys)).

Modified bindings in [`[mode.normal.mappings]`](config:mode.normal.mappings), [`[mode.insert.mappings]`](config:mode.insert.mappings), and
[`[mode.command.mappings]`](config:mode.command.mappings) override the same physical chord from the all-mode
map. The command map is empty by default, so the shared exit works without
duplicating it per mode.

`flash resident status` reports the mode as `mode` and the table it reads
as `mapping_scope`: `text` while a field is engaged in NORMAL, and
`visual` as both in VISUAL, charwise or linewise.

## Leave a mode

`mode leave` and `mode terminal` ship without default mappings in every scope
except TERMINAL, whose Command-W is `mode leave`, and VISUAL, whose Escape
is. NORMAL binds the vim keys:
`i` is `mode insert`, which takes no argument (Vim's other insert and
change keys are unbound: [Flash does not edit text](vim.md#what-flash-does-not-do-with-text)),
`:` is `mode command` and
`gi` is `input focus`, which focuses an input, engages it and keeps
NORMAL; `v` and `V` are `mode visual`. In an engaged field the text table's
Escape is `mode leave`, which hands the keys back to NORMAL's own. Users
choose the rest of their shortcuts, including bindings that prefill the
command line with `:flashlight`.

`mode leave` provides one configured exit across surfaces. It dismisses a popup,
text or terminal alike, and restores its prior base mode/app (the default
[`[mode.terminal.mappings]`](config:mode.terminal.mappings) bind it to Command-W), restores the saved mode from command or
finder input, leaves a [layer](layers.md) for the mode it was entered from,
leaves INSERT for NORMAL, and leaves VISUAL for NORMAL, deselecting
(VISUAL's Escape). In NORMAL it dismisses active hints, or else ends a
field's engagement; with neither, and in disabled mode, it is a no-op. An
all-scope binding to either `mode normal` or `mode leave` enables advanced
mode. For a shifted bracket,
use `"cmd+shift+[" = ["flash", "mode", "leave"]`; the key matcher handles the `{`
character produced by Shift.

## Advanced mode

Bind `["flash", "mode", "leave"]` in [`[mode.all.mappings]`](config:mode.all.mappings) to enable advanced
mode with one exit shortcut. It returns INSERT to
NORMAL, closes command-line, finder, and terminal surfaces using their recorded
return mode, ends a field's engagement in NORMAL, and otherwise does nothing
in idle NORMAL or with advanced mode disabled.
`mode normal` remains the explicit action for selecting NORMAL even when
a command panel was opened with `--restore-mode`.

Advanced-mode eligibility follows the base mode through command, finder, and
terminal surfaces. Opening a surface while disabled cannot enable NORMAL.
Changing the enabling binding while a surface is open updates its return mode:
enabling returns to NORMAL, and disabling returns to the disabled base mode.

## The status pill

`#{flash.mode}` in a [status format](status-format.md) shows the mode's
label, on a pill whose colour names the mode:

| Mode | Label key, default | Pill |
| --- | --- | --- |
| NORMAL | `normal`, `NORMAL` | Green text on the bar's dark fill |
| INSERT | `insert`, `INSERT` | Light blue |
| COMMAND | `command`, `COMMAND` | Mauve |
| TERMINAL | `terminal`, `TERMINAL` | Mauve, like COMMAND |
| HYPER | `hyper`, `HYPER` | Purple |
| HOLD | `hold`, `HOLD` | Yellow |
| VISUAL | `visual`, `VISUAL`; `visual_line`, `V-LINE` for whole lines | Red |
| A layer | its own `label`, the name in capitals by default | Orange |

Set the labels with [`[mode] labels`](config:mode.labels), for example
`labels = { normal = "N", insert = "I" }`; a layer's comes from its
[`label`](config:mode.layers.resize.label).

The status pill resolves its mode label and palette from the current mode
together. Background status evaluations preserve the live `#{flash.mode}`
reference, so plugin updates and queued renders cannot repaint an old label
with the new mode's colors. Mode labels update without a fade.

## Mode commands

| Command | Does |
| --- | --- |
| `mode normal` | Enter NORMAL |
| `mode insert` | Enter INSERT |
| `mode command [--input=<text>] [--restore-mode]` | Open the command line, optionally pre-filled with `--input` |
| `mode flashlight [--query=<text>] [--restore-mode]` | Open the [flashlight](flashlight.md), optionally pre-filled with `--query` (a `@type`, a `!bang` or text) |
| `mode terminal [--name=<popup>]` | Show and focus a popup; without `--name`, the `terminal` popup |
| `mode hold [--secondary] [--middle]` | Grab what is under the pointer (HOLD), or drop it |
| `mode visual [--line]` | Start a selection in the focused field (`v`), of whole lines with `--line` (`V`), engaging it; with nothing editable focused, nothing; for the kind showing, leave it |
| `mode layer --name=<layer>` | Enter a layer: its own keys act until Escape or `mode leave` |
| `mode leave` | Leave the current mode: INSERT, VISUAL, a layer, the command line or a popup; in NORMAL, end a field's engagement |

Each runs the same from a terminal (`flash mode insert`), a mapping and the
command line; [commands](commands.md#command-reference) lists the rest.
