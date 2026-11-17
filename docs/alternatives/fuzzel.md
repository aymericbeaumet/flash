# Flash and fuzzel

[fuzzel](https://codeberg.org/dnkl/fuzzel) "is a Wayland-native application
launcher and fuzzy finder, inspired by rofi and dmenu", by the author of the
foot terminal: desktop entries with icons, a memory of what you launch
often, a dmenu mode that speaks rofi's icon protocol, a password mode,
fzf-style matching, Emacs keys and true fractional scaling. It is MIT C,
1.15.0 in September 2026, developed on Codeberg (about 960 stars there), and
runs on Wayland compositors only. On a Mac the [flashlight](../flashlight.md)
is the launcher and `flash menu choose` the dmenu mode, without fuzzel's
`--with-nth` and `--accept-nth` field handling or its password mode.

| | fuzzel | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Wayland (layer-shell) | macOS 13+ |
| Lists | Desktop entries with icons, executables in `$PATH` | Apps, browser tabs, tmux windows, windows, files, processes, menus, emoji, clipboard, plugin sources |
| Picker for scripts | `--dmenu`, `--dmenu0`, `--index`, field selection, password mode, prompt and message | `flash menu choose`: lines in, one line out |
| Matching | `exact`, `fzf` or `fuzzy`, with tunable distances | Typo-tolerant tiers and frecency |
| Configuration | `fuzzel.ini`, `--override` for any key | `flash.toml`, live reload |
| Maintenance | 1.15.0, September 2026; active | 1.1.0, October 2026 |

## Where fuzzel is stronger

- **A picker built for scripts.** `--index` returns the row number,
  `--with-nth`, `--match-nth` and `--accept-nth` show, search and return
  different fields of a line, `--dmenu0` takes NUL-separated input,
  `--select` preselects a row, `--prompt-only` asks a question with no list.
  `menu choose` takes lines and answers with one.
- **A password mode** (`--password`) that masks what you type; Flash's
  picker shows it.
- **Icons**, from your icon theme or per row through rofi's protocol; the
  flashlight's rows are text.
- **Every detail is configurable**: colours, borders, radius, padding,
  fonts, anchoring, the matcher's distances, all in one ini file.
- **Speed on Wayland**, with render and match workers and true fractional
  scaling.

## Where Flash is stronger

- **macOS apps, tabs and windows.** It lists what the Mac runs and has
  installed, the tabs of Safari, Chrome and Firefox, tmux windows, and
  every window with a hint label in the
  [window switcher](../windows.md#switch-to-any-window).
- **Answers as you type**: arithmetic, units, currencies, colours, world
  clocks, and about 14,500 `!bangs` resolved on your Mac.
- **More menus without scripts.** Clipboard history, emoji, processes,
  system actions and the frontmost app's menu items are scopes of the
  same search (`!clip`, `@emojis`, `@processes`, `@system`, `@menus`).
- **A command line in the same window**: `:` runs any Flash command and
  `:!cmd` the shell.

## Flash features you might like

- fuzzel's dmenu mode prints the input when nothing matches; so does
  `menu choose` when you press Return on no row.
- Frecency plays the part of fuzzel's frequently launched applications,
  with `[flashlight] frecency_half_life_days` as the dial.
- `--restore-mode` hands the keyboard back to the app you were typing in
  after a pick.
- `[flashlight.aliases]` turns a short token into a type or a bang.

## Moving from fuzzel

| fuzzel | Flash |
| --- | --- |
| `fuzzel` | `["flash", "mode", "flashlight"]` |
| `fuzzel --dmenu` | `flash menu choose` |
| `--index`, `--with-nth`, `--accept-nth`, `--dmenu0` | Not available; print the field you need and match it back in the script |
| `--password` | Not available |
| `--prompt`, `--placeholder`, `--mesg` | Not available |
| `--match-mode=fzf` | The flashlight's own scorer |
| `--list-executables-in-path` | `:!cmd` on the command line |
| `--launch-prefix` | Not needed: apps open through Launch Services |
| `[colors]`, `[border]` in `fuzzel.ini` | None |
| `cliphist list \| fuzzel --dmenu \| cliphist decode \| wl-copy` | `!clip` (see [cliphist](cliphist.md)) |
| Emoji with a script over `fuzzel --dmenu` | `@emojis` |

```toml
[mode.all.mappings]
"cmd+ctrl+space" = ["flash", "mode", "flashlight"]
"cmd+ctrl+e" = ["flash", "mode", "flashlight", "--query=@emojis", "--restore-mode"]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
"cmd+ctrl+k" = ["/bin/sh", "-c", "flash menu choose --file=$HOME/.config/flash/bookmarks.txt | xargs open"]

[flashlight]
frecency_half_life_days = 30.0
```

Command-Control-Space is macOS's Emoji & Symbols shortcut; the mapping
takes it over.

*Checked 2026-10-23 against fuzzel's [README](https://codeberg.org/dnkl/fuzzel),
its [releases](https://codeberg.org/dnkl/fuzzel/releases) and `fuzzel(1)`.*
