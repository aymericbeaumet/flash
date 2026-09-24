# Configuration and command boundaries

`config.default.toml` is the canonical configuration reference. Loading applies
the bundled default file, then the selected user file, then supported environment
overrides. `FLASH_CONFIG` selects a file; otherwise Flash uses
`$XDG_CONFIG_HOME/flash/flash.toml` or `~/.config/flash/flash.toml`.
The resident watches these configuration files for changes. CLI arguments invoke
verbs; they do not configure the resident's startup.

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
  US-ANSI; `flash doctor` reports it.

The table is rebuilt when the selected input source changes and on every
config load, never on a keypress; the keyboard tap's swallow decision does not
read it. `--search` still matches the text you actually type, since it filters
by visible text. `flash status` shows the selected source and the reference
layout.

## Environment overrides

Supported names are the uppercased field path with dots replaced by underscores,
prefixed by `FLASH_`. The inventory is `ConfigEnvironment.environmentFields`:

- `hints.keys`, `hints.min_length`, `hints.magic_modifiers`.
- `open.ignored_apps`.
- `overlay.font_size`, `overlay.hint_fg`, `overlay.hint_bg_top`,
  `overlay.hint_bg_bottom`, `overlay.hint_border`, and their `important_hint_*`
  counterparts.
- `flashlight.suggestion_count`.
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

Named sources and terminals can set `working_directory = "."` when their
arguments refer to files beside the defining TOML file. A working directory is
an explicit path field and resolves against that file, including `.`, `..`, and
hidden directories such as `.cache`. It does not depend on Flash's launch
directory. Use an explicit shell argv for shell syntax, such as
`["/bin/sh", "-c", "cat /tmp/value"]`.

## Verbs and mappings

CLI and mapping verb arguments share `CommandArguments`: `--flag` or
`--name=value`, with hyphens normalized to underscores. Positional entries,
empty names, duplicate names and malformed argument keys are rejected.
Each `VerbDefinition` declares parameter names/types and supplies its parser.
Unknown parameters and conflicting actions are rejected. A recognized builtin
with invalid arguments cannot fall through to a plugin of the same name.

CLI usage and terminal-command completion syntax derive from those definitions.
Colon-command descriptions live beside their command specifications. When adding
a command, update its definition, canonical configuration examples and contract
tests together rather than adding a second parser or help inventory.

Mode-entry shortcuts are opt-in. No default
`a/A/i/I/o/O/gi` binding enters INSERT; users can explicitly bind
`enter_insert_mode` when desired. NORMAL persists across commands and focus
changes; `focus_input` only focuses an input without changing mode.

Vertical NORMAL scrolling sends mouse-wheel events at the pointer in every app.
`[mode] scroll_step_lines = 3` controls Ctrl-E/Y and `scroll_page_lines = 20`
controls Ctrl-D/U; both accept integers from 1 to 1000. `scroll_step = 60`
continues to control horizontal scroll distance in pixels.

## Mapping examples

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
"<leader>space" = ["flash", "enter_command_mode", "--input=:flashlight "]
"[a" = { command = ["flash", "app_previous"], repeat = true }
"f" = ["flash", "mouse_target"]
"F" = ["flash", "mouse_grid"]
"df" = ["flash", "mouse_target", "--double"]
"dF" = ["flash", "mouse_grid", "--double"]
```

Mapping values are argv arrays, or inline tables with a `command` argv array and
optional `repeat` metadata. `repeat = true` repeats a completed normal-mode
sequence whenever its final key is pressed again. Arrays beginning with `"flash"`
dispatch in-process; any other executable launches directly. Arguments receive
home/environment expansion, with no implicit shell. The CLI queries
`status`, `doctor` and `config_check` are not verbs and cannot be mapped.

Entries extend the defaults layer by layer: reusing a key replaces its mapping,
and `false` removes it.

```toml
[mode.normal.mappings]
"t" = false                                   # drop the default Cmd-T
"tf" = ["flash", "mouse_target", "--triple"]  # now fires without a timeout
```

Layers apply in order and the last one to mention a key wins: a removal takes
out a key an earlier layer mapped, and a mapping in a later layer restores it.
A removal applies to its own table: `"t" = false` under
`[mode.normal.mappings]` leaves an `[mode.all.mappings]` entry for `t` in place.
It also drops plugin mappings on that key in that table, including a chord
spelled another way (`cmd+shift+]` and `cmd+shift+}`). `true` and
`{ command = false }` are rejected.

NORMAL persists across commands and focus changes. Its unmapped keys are swallowed;
use `send_key` to pass a chosen chord to the app. INSERT entry rules and complete
defaults live in [normal mode](normal-mode.md).

Mouse verbs accept `--modifiers=cmd+ctrl+alt+shift`; presets combine with configured
magic modifiers held on the final hint key. The complete set reaches every target.
Terminal links additionally require Shift, so `f` is a plain current-context click
(Shift-click for terminal links). `F` is the keyboard-shaped mouse grid; see
[normal mode](normal-mode.md#mouse-grid).

## Existing hotkey tools

Native mappings are the simplest option, but any launcher that can execute a command can trigger flash:

```lua
-- Hammerspoon
hs.hotkey.bind({"ctrl", "alt"}, "f", function()
  hs.execute("flash mouse_target")
end)
```

```text
# skhd
ctrl + alt - f : flash mouse_target
```

Karabiner-Elements users can call `flash mouse_target` from a `shell_command` manipulator.
