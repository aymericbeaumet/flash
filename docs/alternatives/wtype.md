# Flash and wtype

[wtype](https://github.com/atx/wtype) is "xdotool type for wayland": a
small C program that types text, Unicode included (`wtype ∇⋅∇ψ = ρ`), and
presses keys and modifiers (`wtype -M ctrl c -m ctrl`) through the Wayland
virtual-keyboard protocol, so the compositor must offer that protocol. It
is MIT, about 560 stars, and v0.5 shipped on 2026-10-20, the first release
since v0.4 in January 2022. It is the last step of many Wayland pipelines: an
emoji picker, a snippet menu or a password menu piping its pick into
`wtype -`. Linux-only. On a Mac, Flash's pickers type their own picks, and
its key commands cover the chords; ad hoc text from a script goes through
the clipboard.

| | wtype | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Wayland compositors with the virtual-keyboard protocol | macOS 13+ |
| Text | Any string, from arguments or stdin, `-d` between keystrokes | The pick of `@emojis`, `@snippets`, `!clip` or a register; no string from the command line |
| Keys | `-M`/`-m` modifiers, `-P`/`-p` press and release, `-k` press-and-release, `-s` sleep | `key send --keys=…`, `key sequence --keys=…`, `key arrow`, `key system`; commands that resolve per app |
| Setup | None beyond the compositor's protocol | The Accessibility grant Flash already holds |
| Maintenance | v0.5, October 2026 | 1.1.0, October 2026 |

## Where wtype is stronger

- **Any text, from anywhere.** One argument or a pipe types a whole string
  in any script. Flash has no command that types a string given on its
  command line; it types only what it lists itself.
- **Exact key timing.** `-P right -s 1000 -p right` holds a key for a
  second; `-d` paces typed text. Flash sends whole chords, with
  `[mode] send_key_interval_ms` between the chords of a sequence.
- **The Unix shape.** No daemon, no resident, no configuration: it does one
  thing at the end of a pipe, which is exactly what the pickers want.

## Where Flash is stronger

- **The picker and the typing are one step.** `@emojis` types the emoji you
  pick, `@snippets` types a saved text, and `!clip` pastes a history entry,
  so there is no `| wtype -` to wire up.
- **Chords by meaning.** `wtype -M ctrl c -m ctrl` assumes the app copies on
  Control-C; `flash clipboard copy` asks the focused app for its own copy,
  and a terminal never gets a Command chord it would type as text.
- **Terminal-aware paste.** `!clip` and `clipboard paste` send the
  terminal's paste shortcut instead of synthesized characters, so a long
  text arrives whole.

## Flash features you might like

- `["flash", "mode", "flashlight", "--query=@emojis", "--restore-mode"]`
  on a chord is the emoji picker that types into the field you were in.
- The snippets plugin reads a file of `name = "text"` lines and lists them
  under `@snippets`; picking one types it.
- `"ay` then `"ap` in NORMAL yank into and type from a named register
  ([clipboard](../clipboard.md)).
- `printf '%s' "$text" | pbcopy && flash clipboard paste` is the closest
  thing to `wtype "$text"` from a script; it replaces the clipboard, which
  the history keeps.

## Moving from wtype

| wtype | Flash |
| --- | --- |
| `wtype "text"`, `… \| wtype -` | `pbcopy` then `flash clipboard paste`; or pick it in `@snippets` |
| An emoji menu piped to `wtype -` | `mode flashlight --query=@emojis` |
| A clipboard menu piped to `wtype -` | `mode flashlight --query=!clip` |
| `wtype -M ctrl c -m ctrl` | `flash clipboard copy`; `flash key send --keys=cmd+c` for a raw chord |
| `wtype -k Return`, `-P left -p left` | `flash key send --keys=<return>`, `flash key arrow --direction=left` |
| `wtype -M ctrl -k l -m ctrl -k Tab` | `flash key sequence --keys=cmd+l,<tab>` |
| `-d 12` | `[mode] send_key_interval_ms`, between chords only |
| `-P right -s 1000 -p right` | No held keys |

```toml
[plugins.snippets]
file = "~/.config/flash/snippets.toml"  # name = "text" lines

[mode.all.mappings]
"cmd+ctrl+space" = ["flash", "mode", "flashlight", "--query=@emojis", "--restore-mode"]
"cmd+ctrl+s" = ["flash", "mode", "flashlight", "--query=@snippets", "--restore-mode"]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
```

Flash does not expand abbreviations as you type; macOS's own Text
Replacements, in Keyboard settings, do.

*Checked 2026-10-23 against the wtype
[README](https://github.com/atx/wtype), its
[man page](https://github.com/atx/wtype/blob/master/man/wtype.1) and the
v0.5 release.*
