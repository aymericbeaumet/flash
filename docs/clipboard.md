# Clipboard history and registers

Flash records eligible copies while it runs. Open the [Clipboard](/clipboard)
page with `flash clipboard show` or `:clipboard show`. Delete a row there, or
run `flash clipboard delete --id=<id>`. The history keeps up to 1000 entries
by default; set `[clipboard] history_size` to 1–10000 to change that limit.
Concealed, transient and automatically generated pasteboard items are
excluded. [Privacy](privacy.md#data-stored-on-your-mac) lists what is stored
and where.

The same page shows the text registers NORMAL yanks into: the unnamed
register (the system clipboard), `"0` for the latest bare yank and the named
buffers `"a`–`"z` and `"0`–`"9`. Press `"` and a register name before `y` or
`p` to use one; a named yank writes its register alone and leaves the
clipboard as it was, as Vim's does with `clipboard=unnamedplus`.
[Normal mode](normal-mode.md) covers registers in full, and `:reg` or Vim's
`:di` opens this page.

The prefix works on a [VISUAL](visual-mode.md#registers) selection too:
`"ay` writes the selected text into register `a`, leaving the clipboard
alone, and `"ap` pastes register `a` over the selection. `"+` and `"*` are
the system clipboard. Where the app gives Flash no text, as in a password
field, a named register falls back to the app's own copy, onto the
clipboard.

⌘C and ⌘V keep working in NORMAL: they are mapped to `clipboard copy` and
`clipboard paste`, the app's own copy and paste of whatever it has selected
or focused, so a selection made with the mouse copies as it would outside
NORMAL. Each runs the app's `clipboard` binding, so a terminal gets the
Cmd-C and Cmd-V every emulator binds. In VISUAL they are its operators: ⌘C
copies the selection and ⌘V pastes over it, as `y` and `p` do, then VISUAL
ends. Copies made this way are recorded like any other. Flash has no cut:
⌘X is unmapped in NORMAL and VISUAL, so it is swallowed there, and reaches
the app in INSERT as every key does
([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)).

## Paste from the flashlight

`!clip` in the [flashlight](flashlight.md) lists the history: pinned entries
first, then the rest newest first, then the named registers. Type to narrow
it: an entry's first line is its title, and the next 120 characters are
searched too. A row reads `Image 1280×800 PNG` for an image, the file name
for a file copy, and the first line for text. The flashlight lists every
pinned entry and the newest 1000 others, so a keystroke stays fast however
large `history_size` is; the Clipboard page searches every entry.

Map a key to open the list from any mode; `--restore-mode` returns to INSERT
after a paste made while typing:

```toml
[mode.all.mappings]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
```

| Key | Does |
| --- | --- |
| `<cr>`, `<cmd-cr>` | Paste the entry into the app the command line covered, in the formats it was copied with |
| `<shift-cr>` | Paste its plain text only |
| `<alt-cr>` | Put it back on the clipboard without pasting |
| `<cmd-p>` | Pin or unpin it; the list stays open |

Flash gives the keyboard back to that app, puts the entry on the clipboard
and runs the app's own `clipboard paste`, so a terminal receives its paste
shortcut rather than typed text, and the mode does not change. The entry
moves to the top of the history instead of being recorded a second time. A
register row borrows the clipboard for one paste, as `register paste` does:
Flash puts the register's text on it, marked transient so no clipboard
history records it, runs the app's paste, and puts your copy back 400 ms
later unless you copied something else meanwhile. Snippets and inserted
flashlight answers paste the same way, so they never replace your clipboard
or land in its history.

`@clipboard` lists the same rows: pinned entries, the history and the named
registers are three sources of the one `clipboard` resource type.

## Pins

A pinned entry lists first, in the flashlight and on the Clipboard page, and
trimming never drops it. Pins count toward `history_size`; they may fill all
but one of its entries, so a new copy always has room, and a lower
`history_size` trims only unpinned entries. Pin with `<cmd-p>` in the
flashlight, with `p` or the pin button on the Clipboard page, or by id:

```sh
flash clipboard pin --id=<id>
flash clipboard unpin --id=<id>
flash clipboard restore --id=<id> --paste   # paste it; --plain for its text only
```

`clipboard show --offset=0` prints a page of entries and their ids as JSON,
pinned entries first.

## Moving from Maccy or Clipy

Flash's history covers the everyday part of a clipboard manager: it keeps
text, formatted copies, images and file copies, skips what password managers
mark, and searches and pastes from the keyboard. Quit the other manager once
you have moved over, so that only one of them records your copies.

| Maccy or Clipy | Flash |
| --- | --- |
| Open the history (Shift-Command-C in Maccy, the history menu in Clipy) | A mapping to `:flashlight !clip `, as above |
| Type to search | The same |
| Return copies, Option-Return pastes | `<cr>` pastes, `<alt-cr>` only copies |
| Option-Shift-Return pastes without formatting | `<shift-cr>` |
| Option-P pins or unpins | `<cmd-p>`, or `p` on the Clipboard page |
| Option-Delete deletes an item | `⌫` on the Clipboard page, or `clipboard delete --id=` |
| History size | `[clipboard] history_size` |
| Ignore password managers | Built in: concealed, transient and auto-generated items are never recorded |
| Clipy snippets | The snippets plugin, or a pinned entry |
