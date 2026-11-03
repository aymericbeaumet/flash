# COMMAND

COMMAND is the command line: a `:` prompt where you type a
[command](commands.md), a Vim ex command, or a [flashlight](flashlight.md)
search. The pill reads `mode.labels.command` (default `COMMAND`) in mauve.

## Open it

- `:` in NORMAL, which runs `mode command`.
- `mode command --input=<text>` opens it pre-filled. Leading colons are
  stripped, one `:` is prepended, and the rest, trailing spaces included,
  is kept as written.
- `mode flashlight [--query=<text>]` opens the [flashlight](flashlight.md#open-it),
  pre-filled with a `@type`, a `!bang` or text.
- `flash mode command` and `flash mode flashlight` do the same from a
  terminal.

With `--restore-mode`, closing the command line returns to the mode it
opened from, INSERT included, so an emoji picker or the clipboard history
can be called up while typing. Without it, closing returns to NORMAL, or to
no mode at all while [advanced mode](modes.md#advanced-mode) is off.

```toml
[mode.all.mappings]
"cmd+ctrl+space" = ["flash", "mode", "flashlight", "--query=@emojis", "--restore-mode"]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
```

## Keys on the command line

| Key | Does |
| --- | --- |
| Return | Run the line, or the highlighted row of the list under it |
| Tab | Insert the highlighted completion: the topic, then its action |
| Shift-Tab, Up, Down | Move through the list |
| Up, Down, Control-P, Control-N on an empty prompt | Recall earlier commands, newest first, only those that start with what you had typed (`:tab` then Up skips `:q`); Down past the newest returns what you had typed |
| Control-W | Delete the word before the caret, as Vim's |
| Control-U, Command-Delete | Delete everything between the `:` and the caret |
| Control-R, then a register name | Insert that register at the caret: `a`–`z`, `0`–`9`, `"` or `+` the clipboard, `:` the last command line |
| Escape, or Backspace on the lone `:` | Close it |
| Shift-Return, Option-Return | On a clipboard row: paste plain text, or copy without pasting ([clipboard](clipboard.md#paste-from-the-flashlight)) |

The other text-editing keys work as in any macOS text field (Control-A,
Control-E, Option-arrows). Up from the top row of a list steps into the
history too, with the same filter. A register's line breaks go in as
spaces, and a character that names no register inserts nothing. Flash keeps the 200 most recent commands across restarts, in
`~/Library/Application Support/Flash/command-history.json`.

## What it runs

The line takes every command, cut to a unique prefix
([abbreviations](commands.md#command-line-abbreviations)), Vim's ex commands
([aliases](commands.md#vim-command-line-aliases)), `:!<shell command>`,
`:open <args>` and `:flashlight <query>`. `:42` and `:$` go to line 42 and
the last line of the field you engaged in NORMAL, which the command line
keeps engaged. A topic alone runs its only action when that action just
shows something (`:logs`), never one that changes something (`:screen`
waits for `lock`), and `:display` is Vim's `:di`, the registers. A one-line
answer shows on a banner and a longer one in the pager; `#` before a command
also copies its output (`:#aws whoami`). `@:` in NORMAL runs the last line
again.

## Keys while it is open

Chords in [`[mode.command.mappings]`](config:mode.command.mappings), empty by
default, and in [`[mode.all.mappings]`](config:mode.all.mappings) act while
the command line is open; a chord in the first overrides the same chord in
the second. Every other key edits the line.

Command surfaces try the configured mapping matcher before native editing or
finder navigation. Their local `performKeyEquivalent` path uses the same
precedence as Carbon. The global tap still passes command typing.
