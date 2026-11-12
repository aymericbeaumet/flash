# Flash and greenclip

[greenclip](https://github.com/erebe/greenclip) is a "simple clipboard
manager to be integrated with rofi": `greenclip daemon` records the X
clipboard, and `rofi -modi "clipboard:greenclip print" -show clipboard`
picks an entry back. Its `greenclip.toml` sets the history length, a list
of blacklisted applications, small-image support, a `static_history` of
entries always offered, and whether the PRIMARY selection joins the
history. It is BSD-3-Clause Haskell, shipped as a static binary, about
1,500 stars, v4.3 in March 2025. It is an X11 tool and does not run on
macOS. Flash records copies itself and lists them in its flashlight, which
is the rofi half of greenclip; [clipboard managers](README.md#clipboard-managers)
compares the Mac apps that do the same.

| | greenclip | Flash |
| --- | --- | --- |
| License, price | BSD-3-Clause, free | MIT, free |
| Platforms | X11 on Linux | macOS 13+ |
| Records | Text, small images (about 500 KB at most), PRIMARY optionally | Text, formatted text, images up to 4 MiB, file copies |
| Picker | rofi, through a script mode | The flashlight: `!clip` or `@clipboard` |
| After picking | The entry is on the clipboard; you paste | `<cr>` pastes into the app you were in; `<alt-cr>` only copies |
| Exclusions | `blacklisted_applications` by name | Items an app marks concealed, transient or auto-generated |
| Kept forever | `static_history` | Pins, which trimming never drops |
| Configuration | `~/.config/greenclip.toml` | `[clipboard] history_size` |
| Maintenance | v4.3, March 2025 | 1.1.0, October 2026 |

## Where greenclip is stronger

- **Ignoring an app by name.** `blacklisted_applications` drops whatever a
  named program copies. Flash skips only what apps mark as concealed or
  transient, as password managers do; it has no list of apps to ignore.
- **PRIMARY.** greenclip can fold the X selection you paste with the middle
  button into its history. macOS has one pasteboard and no PRIMARY
  selection, so that habit has nowhere to go.
- **`static_history` in a file.** A fixed list of snippets, kept in your
  dotfiles. Flash's pins live in its history store, set from the keyboard
  or the Clipboard page; text you type often belongs in the snippets
  plugin's file instead.
- **It is rofi.** Theme, keys and layout are your rofi configuration, the
  same as every other menu on the desktop.
- **A single static binary** you drop on `$PATH`.

## Where Flash is stronger

- **It pastes.** greenclip's FAQ says pasting right after picking "is not
  possible" because rofi took focus, and suggests an `xdotool type`
  workaround. `!clip` gives the keyboard back to the app first and runs its
  own paste, so a terminal gets its paste shortcut, not typed keys.
- **Plain text on demand.** `<shift-cr>` pastes only the text of a
  formatted copy.
- **Images and files.** Screenshots, pictures and Finder copies are kept
  with a preview row (`Image 1280×800 PNG`), not only small images.
- **Nothing to start.** Recording is part of the resident; there is no
  daemon to launch from `.xinitrc` and no second manager to stop first.

## Flash features you might like

- `<cmd-p>` pins the selected entry, the keyboard way to keep a
  `static_history`.
- `--restore-mode` on the mapping returns you to INSERT after a paste, so
  the history works mid-sentence.
- Named registers (`"ay`, `"ap`) in NORMAL keep a few texts apart from the
  history ([clipboard](../clipboard.md)).
- The Clipboard page (`:clipboard show`) searches every entry, deletes and
  pins.

## Moving from greenclip

| greenclip | Flash |
| --- | --- |
| `greenclip daemon` | Nothing: Flash records while it runs |
| `rofi -modi "clipboard:greenclip print" -show clipboard` | `["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]` |
| `max_history_length = 50` | `[clipboard] history_size = 50` (1–10000, 1000 by default) |
| `static_history = [...]` | Pins (`<cmd-p>`), or a snippets file for typed text |
| `enable_image_support = true` | Always on |
| `blacklisted_applications = [...]` | Not available; concealed and transient items are never recorded |
| `use_primary_selection_as_input` | Not applicable: macOS has no PRIMARY selection |
| `greenclip clear` | Delete rows on the Clipboard page, or `flash clipboard delete --id=…` |
| The `xdotool type` paste workaround | `<cr>` in `!clip` |

```toml
[clipboard]
history_size = 50

[mode.all.mappings]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]

[plugins.snippets]
file = "~/.config/flash/snippets.toml"
```

`snippets.toml` holds `name = "text"` lines, typed into the app from
`@snippets`. Quit any other clipboard manager once Flash records, so only
one of them keeps your copies.

*Checked 2026-10-23 against the greenclip
[README](https://github.com/erebe/greenclip) and its releases.*
