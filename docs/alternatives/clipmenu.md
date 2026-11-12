# Flash and clipmenu

[clipmenu](https://github.com/cdown/clipmenu) is "a simple clipboard
manager using dmenu, rofi or similar": `clipmenud` watches the X selections
(CLIPBOARD and PRIMARY by default, SECONDARY on request) through XFixes,
with no polling, and stores each clip under a hash; `clipmenu` passes its
arguments straight to dmenu, or to any `launcher` you name, and puts the
pick back on the selections. `clipdel`, `clipdelmenu` and `clipctl
enable`/`disable` complete it. It is MIT C, rewritten from shell, about
1,250 stars; the default branch reports version 7 and was last changed in
April 2026, while the last tag is 6.2.0 from 2020. It is X11-only and does
not run on macOS. Flash's clipboard history is the same idea inside the
resident, with its flashlight as the launcher;
[clipboard managers](README.md#clipboard-managers) covers the Mac-native apps.

| | clipmenu | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | X11 | macOS 13+ |
| Watches | CLIPBOARD, PRIMARY, SECONDARY, through XFixes events | The macOS pasteboard |
| Picker | dmenu by default, or rofi, fzf, any dmenu-compatible `launcher` | The flashlight, with the same scorer as every other search |
| History | `max_clips` 1000 by default, deduplication optional | `[clipboard] history_size`, 1000 by default, up to 10,000; pins |
| Pausing, excluding | `clipctl disable`; `ignore_window` by window title | Concealed, transient and auto-generated items are never recorded |
| Deleting | `clipdel`, `clipdelmenu` | The Clipboard page, `clipboard delete --id=` |
| Configuration | `~/.config/clipmenu/clipmenu.conf` | `flash.toml` |
| Maintenance | Untagged since 2020; commits until April 2026 | 1.1.0, October 2026 |

## Where clipmenu is stronger

- **Pause on demand.** `clipctl disable` before typing a secret, `enable`
  after. Flash records whenever it runs and relies on apps marking
  sensitive copies, as password managers do; it has no pause and no
  `ignore_window` pattern.
- **Every X selection.** Selected text (PRIMARY) joins the history next to
  copies. macOS has only the one pasteboard.
- **Any launcher.** Your dmenu flags, colours and patches carry over, and
  `launcher fzf` makes it a terminal tool. Flash's history is listed in
  Flash's own flashlight.
- **Unix pieces.** Clips are files in a directory you choose (`cm_dir`),
  each tool does one job, and a script can drive all of them.
- **Owning the selection** (`own_clipboard`, served by `clipserve`) keeps a
  clip pasteable after the X client that made it exits, since an X
  selection otherwise dies with its owner.

## Where Flash is stronger

- **Picking pastes.** `<cr>` in `!clip` returns to the app you were in and
  pastes there, in the formats the copy had; `<shift-cr>` pastes its text
  only. clipmenu sets the selection and leaves the paste to you.
- **More than text.** Images, formatted text and Finder file copies are
  kept and searchable by their row titles.
- **Pins** keep an entry first and out of trimming.
- **Nothing to start.** No daemon unit to enable and no `DISPLAY` to import
  into the systemd user environment.

## Flash features you might like

- `@clipboard` lists pinned entries, the history and NORMAL's named
  registers together, so `"a` texts are one search away.
- `flash clipboard show --offset=0` prints a page of entries as JSON, and
  `clipboard restore --id=<id> --paste` pastes one, for a picker script of
  your own.
- `menu choose` turns the flashlight into a dmenu for any other list
  ([pick from a list](../flashlight.md#pick-from-a-list)).
- [Privacy](../privacy.md#data-stored-on-your-mac) lists exactly what the
  history keeps, how much, and where.

## Moving from clipmenu

| clipmenu | Flash |
| --- | --- |
| `clipmenud` (systemd user unit) | Nothing to run |
| `clipmenu`, bound in your WM | `["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]` |
| `clipmenu -i -fn … -nb …` | The flashlight's look is Flash's; matching ignores case |
| `max_clips 1000` | `[clipboard] history_size = 1000` |
| `deduplicate 1` | Built in: copying what the history already holds moves that entry to the top |
| `selections clipboard primary` | Only the pasteboard exists |
| `ignore_window`, `clipctl disable` | Not available |
| `clipdel -d <pattern>`, `clipdelmenu` | `flash clipboard delete --id=…`, or the Clipboard page |
| `launcher fzf` | `flash clipboard show --offset=0` and a script |

```toml
[clipboard]
history_size = 1000

[mode.all.mappings]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
"cmd+ctrl+shift+v" = ["flash", "clipboard", "show"]
```

*Checked 2026-10-23 against the clipmenu
[README](https://github.com/cdown/clipmenu), its
[clipmenu.conf(5)](https://github.com/cdown/clipmenu/blob/develop/man/clipmenu.conf.5)
man page and its repository history.*
