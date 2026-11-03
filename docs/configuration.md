# Configuration and command boundaries

`config.default.toml` is the canonical configuration reference. Loading applies
the bundled default file, then the selected user file, then supported environment
overrides. `FLASH_CONFIG` selects a file; otherwise Flash uses
`$XDG_CONFIG_HOME/flash/flash.toml` or `~/.config/flash/flash.toml`.
The resident watches these configuration files for changes. CLI arguments invoke
commands; they do not configure the resident's startup.

Open your file from the menu-bar bolt's **Open Configuration** entry; it
reloads when saved. On first launch Flash creates a commented starter if
needed, then leaves your edits yours. `flash config check` validates
independently of the resident, and `flash config check --file=/path/to/flash.toml`
checks another file. The live [runtime](/state) page shows the selected path
and its diagnostics.

## Find the setting

| Section | Controls |
| --- | --- |
| [`[app]`](config:app) | Autostart, menu-bar icon, the input source that reads keypresses, [updates](updates.md), and [hiding Flash from screen capture](#screen-capture) |
| [`[keyboard]`](config:keyboard) | Logical layout for hints, the grid, bisect and HYPER arrows ([logical layout](#logical-layout)) |
| [`[hints]`](config:hints) | Label alphabet, grid geometry and pointer behavior ([hint labels](#hint-labels)) |
| [`[overlay]`](config:overlay), [`[overlay.dark]`](config:overlay.dark) | Appearance and click feedback ([overlay appearance](#overlay-appearance)) |
| [`[mode]`](config:mode), [`[mode.normal]`](config:mode.normal) | Mode labels, sequences, leader, hyper key, scrolling and moving ([modes](modes.md)) |
| [`[mode.all.mappings]`](config:mode.all.mappings) | Chords in every mode ([which keys a mode reads](modes.md#which-keys-a-mode-reads), [mapping syntax](mappings.md)) |
| [`[mode.normal.mappings]`](config:mode.normal.mappings) | [NORMAL](normal-mode.md)'s keys |
| [`[mode.text]`](config:mode.text) | Whether NORMAL engages a field at all: `enabled = false` leaves every field to kindaVim or SketchyVim ([engage a field](normal-mode.md#engage-a-field)) |
| [`[mode.text.mappings]`](config:mode.text.mappings) | NORMAL's keys in a field you engaged, read first ([Vim motions in text](normal-mode.md#vim-motions-in-text)) |
| [`[mode.visual.mappings]`](config:mode.visual.mappings) | Keys on a selection in the focused text ([VISUAL](visual-mode.md)) |
| [`[mode.insert.mappings]`](config:mode.insert.mappings) | Chords while typing in [INSERT](insert-mode.md#keys-in-insert) |
| [`[mode.command.mappings]`](config:mode.command.mappings) | Chords while the [command line](command-mode.md#keys-while-it-is-open) is open |
| [`[mode.terminal.mappings]`](config:mode.terminal.mappings) | Keys in a focused popup ([TERMINAL](terminal-mode.md#keys-in-a-popup)) |
| [`[mode.hyper.mappings]`](config:mode.hyper.mappings) | Keys while the hyper key is held ([HYPER](hyper-mode.md)) |
| [`[mode.hold.mappings]`](config:mode.hold.mappings) | Keys while a button is held ([HOLD](hold-mode.md)) |
| [`[mode.layers.<name>]`](config:mode.layers.resize) | Your own key tables, entered by `mode layer`: `label`, `sticky` and `mappings` ([layers](layers.md)) |
| [`[flashlight]`](config:flashlight) | Search, aliases, your own bangs and source precedence ([flashlight](flashlight.md)) |
| [`[statusbar]`](config:statusbar), [`[statusbar.click]`](config:statusbar.click) | Bar format, the URL schemes a `#[link]` may open (`link_schemes`) and clickable actions ([status bar](statusbar.md)) |
| `[statusbar.sources.<name>]` | Commands providing reusable status values ([status plugins](status-plugins.md)) |
| `[widgets.<name>]` | Passive desktop status panels ([widgets](widgets.md)) |
| [`[monitors.<name>]`](config:monitors) | Values that raise an alert when they cross a threshold ([monitors](monitors.md)) |
| [`[popup]`](config:popup), [`[popup.<name>]`](config:popup.terminal) | Shared popup style and named terminal/text popups ([popups](popups.md)) |
| [`[clipboard]`](config:clipboard) | Clipboard history size ([clipboard](clipboard.md)) |
| [`[calendar]`](config:calendar) | The events the next-meeting values and `calendar join` count ([calendar](calendar.md#settings)) |
| [`[tiling]`](config:tiling), `[tiling.gaps]`, `[tiling.monitors]`, `[[tiling.rules]]` | Opt-in tiling and workspaces: layout, gaps, pinned workspaces and floating rules ([tiling](tiling.md)) |
| [`[startup]`](config:startup) | Commands run once each time Flash starts, such as `defaults write` lines ([startup commands](startup.md)) |
| [`[plugins]`](config:plugins), `[plugins.<id>]` | Enabled plugins and their settings ([plugins](plugins.md#enable-and-configure)) |
| [`[debug]`](config:debug) | Logging and the local inspector |

Each section name links to its place in
[`config.default.toml`](https://github.com/aymericbeaumet/flash/blob/main/config.default.toml),
the reference file with every option and its default.

The inspector runtime page shows the resolved configuration as JSON and edits
the selected file. Values that still come from the bundled default use the
base text colour. A value a later layer wrote uses the override style and
names that layer: `config` with the filename, or `env` with the `FLASH_`
variable. Save writes the editor after the text parses as TOML. Purge
defaults removes assignments that equal the bundled file and leaves the
result in the editor; it does not write until Save. The request body is
limited to 256KB.

Every layer uses the same TOML schema, diagnostics and validators. Invalid values
are reported with their source and preserve the previous valid value according
to that field's validation contract. Derivation runs after all layers are applied.
Authored settings remain intact: for example, `hints.magic_modifiers` retains
Shift while `effectiveMagicModifiers` excludes it for non-letter alphabets.
Likewise `hints.mouse_grid_keys` defaults to `[]`, and `resolvedMouseGridKeys`
derives the grid's matrix after every layer: the left-hand 4×5 block of the
resolved `hints.keys` layout (QWERTY for a literal alphabet). A written-out
default would pin QWERTY in the bundled layer over a user's `<colemak>`. An
explicit matrix needs at least 2×2 keys, rows of equal length, and unique
characters (compared lowercased) without whitespace or the reserved `` ` ``;
a malformed one is reported and keeps the previous value.
Resolving configuration again is idempotent and does not accumulate warnings.
A later layer's [`[startup] run`](config:startup.run) replaces the whole list,
and a list with one malformed command is rejected whole, keeping the earlier
layer's: a layer never runs part of what it declared. A removed section, such
as `[macos]`, is reported where it is with what replaced it, and never
applied ([startup commands](startup.md)).
Tables named by the user — `[plugins.<id>]`, `[popup.<name>]` (see
[popups](popups.md)), `[statusbar.sources.<name>]`, `[widgets.<name>]` (see
[desktop widgets](widgets.md)) and `[monitors.<name>]` (see
[monitors](monitors.md)) — are validated key by key.

`[monitors.<name>]` tables merge across layers like every section: the bundled
file declares the built-in monitors, and a user file overriding one key
(`warning = 80`, `enabled = false`) keeps the rest; `false` removes a
threshold. Whether a monitor is complete — a value, at least one threshold,
thresholds in the order its `direction` needs — is judged once every layer is
applied; an incomplete enabled monitor is reported and does not run.

[`[telemetry.receiver]`](config:telemetry.receiver) and [`[telemetry.exporter]`](config:telemetry.exporter) ([telemetry](telemetry.md))
are validated key by key in every layer; checks that span keys run once all
layers are applied: an exporter `endpoint` that is the receiver's own address
is reported and the exporter stays off, as is a receiver on the help server's
port. Exporter `headers` are explicit values only (never read from the
environment), and the inspector's configuration view lists their names
without values. A status format reading `#{flash.otel…}` is checked for the
form and reported while the receiver is off. `[statusbar] link_schemes` is
an array of exact lowercase scheme names, each once; any other value is
rejected whole, so a typo never widens what a `#[link]` may open. The
receiver's `token` is a runtime concern: `flash resident doctor` warns when
the receiver is on without one while a monitor runs commands from a received
metric.

`statusbar.template`, text popups, widget templates and monitor values and
messages share one
[status format](status-format.md) language, including Flash's
[meters and sparklines](status-format.md#flash-extensions). Each is written
inline; there are no `@option` tables.
The configurations under [`docs/examples`](examples/widgets/README.md) are
loaded over the bundled defaults by the test suite and must produce no
diagnostic; `flash config check` applies the same check to your own file.

## Keyboard layout

Hint labels, grid keys and NORMAL mappings are characters, matched against the
key you press. `[app] keyboard_layout` picks the layout that match reads keys
on:

- `"auto"` (default) reads keys as typed while the selected input source can
  type Latin letters. Under a non-Latin source (Russian, Greek, Hebrew, a CJK
  input method) it reads each key on the ASCII-capable layout macOS pairs with
  that source, or on US-ANSI when there is none, so `f` still opens hints under
  ЙЦУКЕН.
- An input-source ID, such as `"com.apple.keylayout.US"`, always reads keys on
  that layout, whatever is selected. An ID that is not installed falls back to
  US-ANSI; `flash resident doctor` reports it.

The table is rebuilt when the selected input source changes and on every
config load, never on a keypress; the keyboard tap's swallow decision does not
read it. `--search` still matches the text you actually type, since it filters
by visible text. `flash resident status` shows the selected source and the reference
layout.

## Logical layout

`[keyboard] layout` names where keys sit for hint labels, the mouse grid,
bisect, pointer movement and HYPER arrows. It defaults to `qwerty` and also
accepts `colemak`, `dvorak` and `bepo`. This is not the input source:
`[app] keyboard_layout` only decides how a keypress is read.

When `hints.keys` is still the bundled default and the layout is not QWERTY,
hint labels use that layout's letters — home row, top row and bottom row —
the same alphabet as `keys = "<colemak>"`. QWERTY keeps the bundled home-row
and top-row alphabet. A `hints.keys` token in your file wins, including an
explicit QWERTY token or a narrower selector such as
`<colemak_homerow+colemak_toprow>`. The mouse grid uses the left-hand block
of the resolved hint layout.

Two-key labels alternate hands while the alphabet can spell them that way.
One-key labels stay in front only while the keys held back as prefixes can
cover the rest with those alternations. Among those labels, a hand change
ranks first, then less travel between keyboard rows (a same-row pair, then
a one-row jump, then a two-row jump), then key ease. Key ease is the
physical row and column, one formula for every layout: home row above
bottom row above top row, and on a row the index finger, then middle, the
inward index reach, ring, and pinky. The left key of a mirrored pair ranks
one point higher.

Bisect halves use the home-row columns where QWERTY has `h` `j` `k` `l`
(left, down, up, right): Colemak `h` `n` `e` `i`, Dvorak `d` `h` `t` `n`,
Bépo `c` `t` `s` `r`. Quadrants use the keys at QWERTY `y` `u` and `b` `n`.
Bépo's top-left quadrant is the dead key `^`, so one press may not type it.

HYPER posts arrows from the physical QWERTY ESDF positions (up, left,
down, right): QWERTY `e` `s` `d` `f`, Colemak `f` `r` `s` `t`, Dvorak
`.` `o` `e` `u`, Bépo `p` `u` `i` `e`. F is the home-row index-finger
mark, and it is right. Shift posts a shifted arrow on that same letter:
Colemak's D position types `s`, and its shifted arrow is `shift+s`. A
punctuation key uses the character Shift types there, so Dvorak up is
`>`. A mapping or `false` on one of the keys wins. Pointer movement and bisect stay on
the hjkl columns. The bindings are derived, so `config.default.toml`
does not list them.


## Hint labels

`[hints] label_order` says which target gets the easiest label. `reading`
(the default) hands the one-key labels out in reading order, top to bottom
and left to right. `center` gives them to the targets nearest the centre of
the window, or of the screen for `--scope=screen`, so the thing you are most
likely looking at takes one key. `zones` makes the first key of every label
predictable before the labels show: the window splits into bands and columns
laid out like the alphabet's keys on the keyboard (two bands of ten columns
with the default alphabet, `q` top-left, `p` top-right, `a` to `l` below),
each target's first key is its zone, and the rest of the label is handed out
inside the zone as usual. Every label is then at least two keys long.

`[hints] key_priority` is a string of hint keys, best first. The listed keys
outrank the layout's ease, in the order written, and every other key keeps
its place behind them, so `"fjdk"` puts the index and middle fingers first
whatever the layout says. A key that is not in `hints.keys` is reported in
`flash config check` and ignored.

`[hints] adjust_digits` picks what `1`–`9` do in `mouse target --adjust`:
tenths of the target's width (`width`, the default), or a numeric keypad over
the target (`grid`, `7` `8` `9` along the top).

`mouse position` keeps `position_history_size` saved pointer positions, one
list for every app, or one per app with `position_history_scope = "app"`.
`pointer_follows_focus = true` centres the pointer on a newly focused app's
window when it was outside it. `pointer_step`, `pointer_acceleration` and
`pointer_max_step` set `mouse pointer`'s movement in points.

## Editor support

`flash.toml` has a [JSON Schema](https://json-schema.org) built from the
loader's own key tables and the bundled defaults, so it cannot disagree with
what Flash accepts. An editor with a TOML language server
([Taplo](https://taplo.tamasfe.dev), [Tombi](https://tombi-toml.github.io/tombi/),
VS Code's Even Better TOML, Neovim or Helix with Taplo) uses it to complete
keys and values, show each key's documentation on hover, and flag an unknown
key or a wrong value as you type, before Flash reloads.

The starter Flash creates begins with the directive that points editors at it:

```toml
#:schema https://raw.githubusercontent.com/aymericbeaumet/flash/main/docs/schema/flash.schema.json
```

That URL follows the latest Flash. To match the version you run exactly, write
its schema next to your file and point the directive there:

```bash
flash config schema > ~/.config/flash/flash.schema.json
```

```toml
#:schema ./flash.schema.json
```

The editor's checks are a convenience; `flash config check` stays the
authority, since it also reads what a schema cannot express (key syntax,
command arguments, plugin settings).

## Environment overrides

Supported names are the uppercased field path with dots replaced by underscores,
prefixed by `FLASH_`. The inventory is `ConfigEnvironment.environmentFields`:

- `hints.keys`, `hints.min_length`, `hints.magic_modifiers`.
- `overlay.font_size`, `overlay.hint_fg`, `overlay.hint_bg_top`,
  `overlay.hint_bg_bottom`, `overlay.hint_border`, and their `important_hint_*`
  counterparts.
- `flashlight.suggestion_count`, `flashlight.ignored_apps`.
- `debug.show_hints_bounds`, `debug.hints_bounds_bg`, `debug.hints_bounds_fg`,
  `debug.log_level`.

For example, `FLASH_DEBUG_SHOW_HINTS_BOUNDS=true` enables bounds, and
`FLASH_HINTS_MAGIC_MODIFIERS='["cmd", "ctrl"]'` replaces the modifier array.
Booleans are `true` or `false`; arrays use TOML array syntax. Numbers use the same
ranges as the file. Malformed overrides produce diagnostics instead of bypassing
the schema or silently coercing values.

## Executables and opaque arguments

Only an executable in argv position zero receives configuration-relative path
resolution. A bare executable is found through PATH; `./bin/tool` resolves from
the file defining that command. Remaining arguments retain their exact strings
during loading, including URLs, `--option=relative/path`, and shell programs.
Runtime home/environment expansion follows the command's launch contract.

Named sources (`working_directory`) and terminal popups (`cwd`) can set `"."`
when their arguments refer to files beside the defining TOML file. A working directory is
an explicit path field and resolves against that file, including `.`, `..`, and
hidden directories such as `.cache`. It does not depend on Flash's launch
directory. Use an explicit shell argv for shell syntax, such as
`["/bin/sh", "-c", "cat /tmp/value"]`.

## Commands and mappings

Every command is two words, `flash <topic> <action>`, followed by its
arguments ([commands](commands.md)). CLI, command-line and mapping arguments
share `CommandArguments`: `--flag` or `--name=value`, with hyphens normalized
to underscores. Positional entries, empty names, duplicate names and
malformed argument keys are rejected. Each `VerbDefinition` declares its
summary, parameter names/types and parser under its `"<topic> <action>"` key.
Unknown parameters and conflicting actions are rejected. A Flash topic never
falls through to a plugin: plugin commands cannot take one of its names.

CLI usage, the command catalog and command-line completion (topics, then
their actions) derive from those definitions.
Colon-command descriptions live beside their command specifications. When adding
a command, update its definition, canonical configuration examples and contract
tests together rather than adding a second parser or help inventory.

INSERT is entered explicitly. NORMAL's `i` is bound to `mode insert`,
which takes no argument and types at the cursor; Vim's other insert and
change keys are unbound, since Flash does not edit text
([where typing starts](insert-mode.md#where-typing-starts)). Bind
`mode insert` to any other key as well. Nothing else enters INSERT: a click, made
with the mouse, `f` or `F`, keeps the mode on an input as anywhere else.
NORMAL persists across every other command and focus
change, `/` (Find), `n` / `N` (its matches) and `t` (new tab) included; `gi`
(`input focus`) only focuses an input without changing mode. `:` opens the
command line (`mode command`); `mode leave` and `mode terminal` have no
default key but a popup's Command-W and VISUAL's Escape, both `mode leave`.

Vertical NORMAL scrolling sends mouse-wheel events in every app, at the
pointer while it is inside the focused window and otherwise in that
window's scroll area
([where a scroll lands](normal-mode.md#where-a-scroll-lands)).
`[mode] scroll_step_lines = 3` controls `j` / `k` where they scroll, a step
that reads well in a page; Ctrl-E/Y scroll one line per press, as Vim's
(`scroll line_down` / `line_up`), a count multiplying it.
`scroll_page_lines = 20` controls Ctrl-D/U where they scroll,
with Ctrl-F/B scrolling twice that, a full page; both accept integers from 1
to 1000. Where those keys move a caret or a list's selection instead
([arrows or scrolling](normal-mode.md#arrows-or-scrolling)),
`[mode] move_page_lines = 15` (1 to 200) is how many arrows Ctrl-D/U send,
and Ctrl-F/B send twice as many. `scroll_step = 60` continues to control
horizontal scroll distance in pixels.
`[mode] scroll_smooth_ms = 0` (0 to 300) spreads each of those vertical
scrolls over that many milliseconds as several smaller line events, the
larger shares first and at least a frame apart, so the content glides instead
of jumping. They stay line events, so terminals scroll the same distance. The
steps run on the click queue without blocking it, and any new scroll,
`gg` / `G` included, drops what the previous one has left; `gg` and `G` stay
instant.

`[hints] restore_pointer = false` leaves the pointer on the target after a
committed click, as a real click does. `true` puts it back where it was after
every committed hint or grid click, drag and selection and after
`mouse repeat`, with a tagged move so hover follows; `--move` and
`mouse pointer` still move it. Scrolling then stays where the pointer was,
while that is inside the focused window.

## Overlay appearance

`[overlay] hint_placement = "corner"` places each target's chip on the
target's top-left corner, centred on a target barely larger than the chip.
`"center"` centres it, `"above"` puts it on the target's top edge and
`"below"` under its bottom edge; the last two align with the target's leading
edge, or centre on a narrow target. Every chip stays on its target's display.
Only the chip moves: the click aims at the same point whatever the placement.
Grid cells and status-bar chips keep their own geometry.

[`[overlay.dark]`](config:overlay.dark) takes the colour keys of [`[overlay]`](config:overlay) (`hint_fg`,
`hint_bg_top`, `hint_bg_bottom`, `hint_border` and their `important_hint_*`
counterparts). While macOS is in dark mode each non-empty key replaces its
`[overlay]` colour, one key at a time; an empty key, or an empty table, keeps
the `[overlay]` colour. Flash follows the appearance through key-value
observation of the app's effective appearance, including the automatic
schedule, and uses it at the next draw; nothing polls.

`[overlay] click_feedback = true` draws a short ring (about 220 ms) where each
committed click lands: hint and grid clicks, `mouse pointer` clicks and
`mouse repeat`. The ring is the overlay's one deliberate animation. It is
explicit, lives on a layer of its own and starts after the click is queued, so
it never delays the click or the next key. It suits demos and screencasts.

## Screen capture

[`[app] hide_from_capture = true`](config:app.hide_from_capture) asks macOS to
leave every Flash window out of screenshots, recordings and screen sharing
(`NSWindow.sharingType = .none`): the overlay (hints, the grid, the command
line, the flashlight and alerts), the status bar and its click windows,
popups, widgets and About. One switch rather than a list of surfaces: hints,
the command line, the flashlight and alerts share one window, so a finer
choice could not be honoured, and a share is either private or not.
`[widgets.<name>] hide_from_capture` still hides a single widget.

It is a request, not a protection. Legacy window-list capture honours it,
while ScreenCaptureKit recordings and calls (QuickTime, ⇧⌘5, Zoom, Meet,
Teams) and display mirroring on macOS 15 and later still show the windows;
[privacy](privacy.md#screen-capture) has the full list. Turning it on applies
on reload; turning it off reaches Flash's open windows at the next launch,
because the window server keeps a window hidden once asked.

## Mapping examples

<!-- modes: assumed on -->

```toml
[hints]
keys = "<qwerty_homerow+qwerty_toprow>"
min_length = 1

[plugins]
disabled = []
third_party = []

[flashlight]
suggestion_count = 10

[mode.normal]
leader = "\\"

[mode.normal.mappings]
"<leader>space" = ["flash", "mode", "flashlight"]
"[a" = { command = ["flash", "app", "previous"], repeat = true }
"f" = ["flash", "mouse", "target"]
"F" = ["flash", "mouse", "grid"]
"s" = ["flash", "mouse", "bigram"]
"cf" = ["flash", "mouse", "target", "--secondary"]
"cF" = ["flash", "mouse", "grid", "--secondary"]
"cs" = ["flash", "mouse", "bigram", "--secondary"]
"df" = ["flash", "mouse", "target", "--double"]
"dF" = ["flash", "mouse", "grid", "--double"]
```

Mapping keys are characters, chords (`ctrl+e`, `cmd+shift+<lbracket>`) or
sequences of them. A key that types nothing is written `<name>`: `<escape>` or
`<esc>`, `<return>` or `<enter>` (the keypad's Enter too), `<tab>`, `<space>`,
`<delete>` or `<backspace>`, `<delete_forward>`, `<left>` / `<right>` / `<up>`
/ `<down>`, `<home>`, `<end>`, `<pageup>`, `<pagedown>`, and the function keys
`<f1>` to `<f20>` ([mappings](mappings.md#function-keys)); each pair of aliases
is the same key, so a mapping never misses its key by spelling.
Mapping values are argv arrays, or inline tables with a `command` argv array and
optional `repeat` metadata. Resolved configuration JSON reports that same argv,
in canonical form. `repeat = true` repeats a completed normal-mode
sequence whenever its final key is pressed again. Arrays beginning with `"flash"`
dispatch in-process; any other executable launches directly. Arguments receive
home/environment expansion, with no implicit shell. A Flash command is its
topic and action (`["flash", "tab", "next"]`), and a plugin command is two
words too (`["flash", "screenshot", "window"]`); a one-word name is rejected.
The queries `resident status`, `resident doctor` and `config check` cannot
be mapped; run them from a terminal or the command line. A Flash command with invalid arguments, or a name no manifest
declares, is rejected.

Entries extend the defaults layer by layer: reusing a key replaces its mapping,
and `false` removes it.

```toml
[mode.normal.mappings]
"t" = false                                   # drop the default new tab
"tf" = ["flash", "mouse", "target", "--triple"]  # now fires without a timeout
```

Layers apply in order and the last one to mention a key wins: a removal takes
out a key an earlier layer mapped, and a mapping in a later layer restores it.
A removal applies to its own table: `"t" = false` under
[`[mode.normal.mappings]`](config:mode.normal.mappings) leaves an [`[mode.all.mappings]`](config:mode.all.mappings) entry for `t` in place.
It also drops plugin mappings on that key in that table, including a chord
spelled another way (`cmd+shift+]` and `cmd+shift+}`). `true` and
`{ command = false }` are rejected.

NORMAL persists across commands and focus changes. Its unmapped keys are swallowed;
its Escape is mapped, to the app's own cancel (`app cancel`).
Holding `mode.normal.hyper` enters HYPER until the key is released. It
defaults to `<leader>`, which follows `mode.normal.leader`. `leader = false`
clears the leader; HYPER then stays off until `hyper` is a real key. Any other
single key remaps the hold (`"a"`, `"<space>"`, `"cmd+space"`). The status
pill turns purple and shows `mode.labels.hyper` (default `HYPER`). Keys
pressed during the hold come from [`[mode.hyper.mappings]`](config:mode.hyper.mappings). While the hyper
key is the leader, a key with no hyper mapping can still complete a NORMAL
`<leader>` sequence, so `<leader>w` typed fast, with `w` down before the
leader is up, still runs. A tap that presses nothing else arms that prefix on
release, so `<leader>` sequences keep working. `+` is written `<plus>`.

HOLD (`mode hold`, ⌘⌃H by default) holds a mouse button for dragging
or text selection. It reads [`[mode.hold.mappings]`](config:mode.hold.mappings) before NORMAL's and shows
`mode.labels.hold`. The [mode guide](hold-mode.md) describes
its keys.

While a field is engaged, editable text you acted in (leaving INSERT
there, a click, `gi`, `v`; never a terminal), NORMAL reads
[`[mode.text.mappings]`](config:mode.text.mappings) before its own table:
Vim's motions (`w`, `b`, `e`, `0`, `$`, `%`, `t`, …), and `H`, `L`, `t`,
`gg`, `G` and `p` with Vim's meanings, with `x`, `r` and `R` removed and
Escape (`mode leave`) ending the engagement. A field the page focused on
its own is not engaged. The table layers over NORMAL's as HOLD's does: a
key mapped there wins in an engaged field, a key there hides the NORMAL
keys it starts, `false` removes a key there (NORMAL's binding of it
included), and NORMAL's table answers every key it leaves unmapped. With
no field engaged it is not read; either way, the mode and its pill stay
NORMAL. `<leader>` keys belong to NORMAL's table only. See
[engage a field](normal-mode.md#engage-a-field).

```toml
[mode.text.mappings]
"H" = ["flash", "history", "back"]       # back, as with no field engaged
"f" = ["flash", "cursor", "next_char"]   # Vim's f in text
```

[`[mode.text] enabled = false`](config:mode.text) never engages a field:
every key keeps its page meaning, `v` and `V` do nothing, and the text
table is never read, for a kindaVim or SketchyVim user who keeps Vim inside
the field. Editors with their own modal editing or partial Accessibility
text (VS Code and its forks, the JetBrains IDEs, Zed and Sublime Text,
declared by the `defaults` plugin's manifest `own_text_editing`) are never
engaged whatever the switch says; with it on, `enabled = true` under
`[mode.apps."<bundle id>".text]` forces one of them on and `enabled = false` keeps
another app out ([app-specific mappings](#app-specific-mappings)).

`v` and `V` in NORMAL's table start VISUAL (`mode visual`, `mode visual
--line`), a selection in the focused field, which they engage; with
nothing editable focused they do nothing. VISUAL reads
[`[mode.visual.mappings]`](config:mode.visual.mappings) first, its
operators (`y`, `p`, `P`, `o`, ⌘C, ⌘V, Escape),
then the motions (`move`, `cursor`, `scroll`) of the text table and
NORMAL that it does not shadow, then `[mode.all.mappings]`; every other key
is swallowed. `false` there removes a key, an inherited motion included,
and `<leader>` keys belong to NORMAL's table only. The pill shows
`mode.labels.visual` (default `VISUAL`) for characters and
`mode.labels.visual_line` (default `V-LINE`) for whole lines, both keys of
[`[mode] labels`](config:mode.labels). See [VISUAL](visual-mode.md).

```toml
[mode.visual.mappings]
"Y" = ["flash", "selection", "copy"]   # Y copies too
"P" = false                            # only p pastes
```

A layer is a key table you name, like skhd's modes or Hammerspoon's modal
hotkeys: `[mode.layers.<name>]` declares it, with an optional `label` for the
pill (default: the name in capitals), `sticky` (default `true`; `false` leaves
after one mapping) and its `mappings`. `mode layer --name=<name>` enters it
from NORMAL, INSERT or HYPER; its keys and `[mode.all]`'s act, every other
key is swallowed, and Escape returns to the mode it came from. A name is
1–32 characters of `a-z`, `0-9`, `_` and `-` and cannot be a built-in mode
or scope (`visual` included); a mapping that enters an undeclared layer is reported. See
[layers](layers.md).

```toml
[mode.normal.mappings]
"<leader>r" = ["flash", "mode", "layer", "--name=resize"]

[mode.layers.resize]
label = "RESIZE"

[mode.layers.resize.mappings]
"h" = ["flash", "window", "move", "--position=lefthalf"]
"l" = ["flash", "window", "move", "--position=righthalf"]
```

```toml
[mode.normal]
hyper = "<leader>"

[mode.hyper.mappings]
"1" = ["flash", "key", "system", "--key=brightness_down"]
"-" = ["flash", "key", "system", "--key=volume_down"]
"=" = ["flash", "key", "system", "--key=volume_up"]
```

The built-in row is brightness, Mission Control, Spotlight, Dictation, Focus,
media, mute, and volume on `1`–`9`, `0`, `-`, and `=`. Shift plus the same
key sends F1–F12. A later mapping replaces one key.

A plugin command is the same words as the command bar, and both are required:
`flash screenshot window`, `flash tmux session main`.
Words after the subcommand are the command's arguments. A one-word plugin name,
a command with no subcommand, or a word outside `[a-z][a-z0-9_]*` (the `*`
wildcard subcommand aside) is rejected at plugin load. A command named after
another plugin's command is an error: every plugin that claims it fails to
load. A plugin command under one of Flash's topics (`tab`, `window`,
`resident`, `config`…) is not a plugin command at all but a core command the
plugin performs, and must be one Flash asks of the focused app.
Map keys to commands such as `tab new`, `app undo` or `app reload`: each
resolves in the focused app's context, through a source or the binding a
plugin declares for that app (`bindings`; the bundled `defaults` plugin
carries the macOS conventions), and does nothing where the app lacks it (see
[source commands](normal-mode.md#source-commands)). To change what an app does
for a command, declare a binding in a plugin rather than a `key send` mapping
(see the [plugin cookbook](plugin-cookbook.md)). No default maps a key to
`key send`; it remains an escape hatch for a chord no command covers. INSERT entry
lives in [INSERT](insert-mode.md#enter-insert), and complete defaults in
[normal mode](normal-mode.md).

### App-specific mappings

Add an exact bundle identifier under `mode.apps` to override a mapping only
while that app is focused:

```toml
[mode.apps."com.apple.Safari".normal.mappings]
"f" = ["flash", "mouse", "target", "--search"]
"r" = false

[mode.apps."com.apple.Safari".all.mappings]
"cmd+alt+w" = ["flash", "window", "focus", "--direction=right"]
```

App-specific entries take precedence over plugin and global mappings in the
same scope. `false` suppresses an inherited mapping for that app; other apps
keep their existing bindings. Bundle IDs match exactly and are case-sensitive.
The available scopes are `all`, `normal`, `insert`, `command`, `terminal`, `hyper`,
`hold`, `text` (`[mode.apps."<bundle-id>".text.mappings]`, NORMAL's
keys in that app's focused text) and `visual`; layers are global and have no per-app table;
COMMAND mappings still require a single modified key. Flash updates the active
mapping table when focus changes, so no config reload is needed.

An app's text table takes `enabled` beside `mappings`: `true` engages its
fields although a plugin declared the app an editor with its own text
editing, `false` never engages them
([engage a field](normal-mode.md#engage-a-field)). The switch and custom
text keys can be configured together:

```toml
[mode.apps."com.microsoft.VSCode".text]
enabled = true

[mode.apps."com.microsoft.VSCode".text.mappings]
"H" = ["flash", "history", "back"]
```

Mouse commands accept `--modifiers=cmd+ctrl+alt+shift`; presets combine with configured
magic modifiers held on the final hint key. The complete set reaches every target.
Terminal links additionally require Shift, so `f` is a plain current-context click
(Shift-click for terminal links). `F` is the keyboard-shaped mouse grid; see
[normal mode](normal-mode.md#mouse-grid).

## Existing hotkey tools

Native mappings are the simplest option, but any launcher that can execute a command can trigger flash:

```lua
-- Hammerspoon
hs.hotkey.bind({"ctrl", "alt"}, "f", function()
  hs.execute("flash mouse target")
end)
```

```text
# skhd
ctrl + alt - f : flash mouse target
```

A modal setup, an skhd mode (`:: resize @`) or an `hs.hotkey.modal`, moves
into Flash as a [layer](layers.md): a `[mode.layers.<name>]` table
that `mode layer --name=<name>` enters and Escape leaves.

Karabiner-Elements users can call `flash mouse target` from a `shell_command` manipulator.
