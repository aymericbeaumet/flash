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
Resolving configuration again is idempotent and does not accumulate warnings.

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
an explicit path field and resolves against that file. Use an explicit shell
argv for shell syntax, such as `["/bin/sh", "-c", "cat /tmp/value"]`.

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

Mode-entry shortcuts and normal-mode passthrough are opt-in. No default
`a/A/i/I/o/O/gi` binding enters INSERT; users can explicitly bind
`enter_insert_mode` or `focus_input` when desired.
