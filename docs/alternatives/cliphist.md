# Flash and cliphist

[cliphist](https://github.com/sentriz/cliphist) is a "clipboard history
'manager' for Wayland" with "no concept of a picker, only pipes":
`wl-paste --watch cliphist store` writes every copy to a database, and
`cliphist list | dmenu | cliphist decode | wl-copy` brings one back through
whatever picker you like (dmenu, rofi, wofi, fuzzel, fzf). Text and images
are preserved byte for byte, so Vim's linewise and block yanks survive the
round trip, and `delete`, `delete-query` and `wipe` prune it. It is GPL-3.0
Go, about 1,600 stars, v0.7.0 in October 2025, with commits on its main
branch in October 2026. It depends on wl-clipboard and does not run on
macOS. On a Mac, Flash records the pasteboard itself and puts the history
in its flashlight; [clipboard managers](README.md#clipboard-managers) compares the
Mac apps.

| | cliphist | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free | MIT, free |
| Platforms | Wayland, with wl-clipboard | macOS 13+ |
| Shape | A store and a decoder, glued by pipes to any picker | Built into the resident, listed by the flashlight |
| Keeps | Text and images, byte for byte, with their MIME types | Text, formatted text, images up to 4 MiB, file copies |
| Limits | `max-items` (750 by default), `max-store-size`, a minimum length | `[clipboard] history_size` (1000 by default, up to 10,000); pins never trimmed |
| Pruning | `delete`, `delete-query "secret"`, `wipe` | The Clipboard page, `clipboard delete --id=` |
| Configuration | Flags, `CLIPHIST_*` variables or `~/.config/cliphist/config` | `flash.toml` |
| Maintenance | v0.7.0, October 2025; active | 1.1.0, October 2026 |

## Where cliphist is stronger

- **Pipes all the way down.** `list` prints TSV, `decode` prints the bytes,
  and anything that reads lines can be the picker, including a terminal
  fzf with sixel previews. Flash's history is read through its own
  flashlight, or as JSON pages from `flash clipboard show --offset=`.
- **Exact bytes.** cliphist hands back what was copied, whatever the MIME
  type, and you choose the types to watch (`wl-paste --type image --watch`).
  Flash keeps text, HTML, the common image formats and file paths, with
  size limits listed on the [privacy page](../privacy.md#data-stored-on-your-mac).
- **Delete by query** in one command: `cliphist delete-query "token"`.
  Flash deletes one entry at a time, by id or from the Clipboard page.
- **You choose what records.** Recording is a `wl-paste --watch` line you
  can leave out of a session or a workspace. Flash records whenever it
  runs, skipping only what apps mark concealed or transient.

## Where Flash is stronger

- **One step from pick to paste.** cliphist's last stage is `wl-copy`; the
  paste is still yours to do. `<cr>` in `!clip` returns to the app and
  pastes; `<shift-cr>` pastes the plain text; `<alt-cr>` only copies.
- **Pins and registers.** `<cmd-p>` keeps an entry first for good, and
  NORMAL's `"a`–`"z` registers sit in the same `@clipboard` list.
- **No session plumbing.** Nothing to start per session, no watcher per
  MIME type.
- **A page to browse it.** `:clipboard show` opens the full history with
  previews, search, pin and delete.

## Flash features you might like

- `menu choose` keeps the pipe habit for everything else: `… | flash menu
  choose` prints the line you pick ([pick from a list](../flashlight.md#pick-from-a-list)).
- `clipboard restore --id=<id> --paste --plain` from a script pastes one
  entry's text.
- `--restore-mode` on the `!clip` mapping returns to INSERT after pasting,
  so the history works in the middle of typing.

## Moving from cliphist

| cliphist | Flash |
| --- | --- |
| `exec wl-paste --watch cliphist store` | Nothing: Flash records while it runs |
| `cliphist list \| fuzzel --dmenu \| cliphist decode \| wl-copy` | `["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]`, Return pastes |
| `cliphist list -fields id,mime,preview` | `flash clipboard show --offset=0` (JSON) |
| `cliphist delete-query "secret"` | Find it on the Clipboard page and delete it |
| `cliphist wipe` | Delete rows on the Clipboard page; `[clipboard] history_size` caps what is kept |
| `max-items 1000` | `[clipboard] history_size = 1000` |
| `wl-paste --type image --watch cliphist store` | Images are recorded with the rest |
| A primary-selection watcher | Not applicable: macOS has no PRIMARY selection |

```toml
[clipboard]
history_size = 750

[mode.all.mappings]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
"cmd+ctrl+shift+v" = ["flash", "clipboard", "show"]
```

Run one recorder: stop any other Mac clipboard manager once Flash keeps
your copies.

*Checked 2026-10-23 against the cliphist
[README](https://github.com/sentriz/cliphist) and its releases.*
