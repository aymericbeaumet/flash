# Flash and wofi

[wofi](https://hg.sr.ht/~scoopta/wofi) "is a rofi inspired menu program for
wlroots compositors such as sway. It is intended to be highly customizable
and flexible with the help of CSS styling and a dmenu mode that allows for
endless scriptability." It draws through GTK 3 on the wlr-layer-shell
protocol, with `run`, `drun` and `dmenu` modes, images and Pango markup in
entries, and a key-value config beside a `style.css`. It is GPL-3.0 C,
v1.5.3 in early 2026, on SourceHut, whose page now says "This project is
not being actively maintained. It does still receive some updates from time
to time"; the last commits are from October 2026. It runs on Wayland only.
For a [sway](sway.md) user moving to a Mac, Flash's [flashlight](../flashlight.md)
is the launcher and `flash menu choose` is `wofi --dmenu`.

| | wofi | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free | MIT, free |
| Platforms | wlroots Wayland compositors | macOS 13+ |
| Modes | `run`, `drun`, `dmenu` | Apps, tabs, windows, tmux windows, files, processes, menus, emoji, clipboard, plugin sources |
| Picker for scripts | `--dmenu` with prompt, images, markup, password mode | `flash menu choose`: lines in, one line out |
| Looks | CSS on every widget, a colours file | One design |
| Configuration | `~/.config/wofi/config`, `style.css`, flags | `flash.toml`, live reload |
| Maintenance | v1.5.3, early 2026; not actively maintained, by its own account | 1.1.0, October 2026 |

## Where wofi is stronger

- **CSS.** Every window, entry and image is a styleable GTK widget, and a
  theme is a stylesheet you already know how to write. The flashlight has
  one look.
- **A richer dmenu mode.** `--prompt`, `--allow-images`, `--allow-markup`,
  `--password` to hide what you type, `--matching` and `--sort-order` to
  choose the matcher, `--define` for any config key on the command line.
  `menu choose` has none of these.
- **Entry actions.** A desktop entry's extra actions (a new private
  window) show under it.
- **A dmenu by another name.** Invoked through a symlink called `dmenu`,
  wofi runs in dmenu mode without its cache, so old scripts need no edit.

## Where Flash is stronger

- **It is maintained and on your Mac.** wofi asks for wlroots; Flash
  speaks to macOS's own apps, Spaces and browsers.
- **More than a run dialog.** Browser tabs from Safari, Chrome and Firefox,
  tmux windows, every window with a hint label, inline arithmetic and
  conversions, and `!bangs`, ranked by frecency.
- **Commands as well as programs.** `:` is Flash's command line over the
  same surface; `:!cmd` runs the shell.
- **No helper scripts for the usual menus.** Clipboard history (`!clip`),
  emoji (`@emojis`), processes (`@processes`) and system actions
  (`@system`) are scopes of the same search.

## Flash features you might like

- `wofi --show drun` bound in sway becomes one chord to `mode flashlight`.
- Scripts you wrote for `wofi --dmenu` keep their shape: replace the word,
  keep the pipe ([pick from a list](../flashlight.md#pick-from-a-list)).
- `--restore-mode` returns to INSERT after a pick, so an emoji or
  clipboard picker does not interrupt typing.
- Typing `@` lists every resource type and what feeds it.

## Moving from wofi

| wofi | Flash |
| --- | --- |
| `wofi --show drun` | `["flash", "mode", "flashlight"]` |
| `wofi --show run` | `:!cmd`, or `:open -a App` |
| `… \| wofi --dmenu` | `… \| flash menu choose` |
| `--prompt`, `--lines`, `--width`, `--location` | Not available; `[flashlight] suggestion_count` sets the rows |
| `--password` | Not available: `menu choose` shows what you type |
| `--allow-images`, `--allow-markup` | Not available: rows are text |
| `--insensitive`, `--matching=fuzzy` | The flashlight's typo-tolerant scorer, always |
| `style.css`, colours file | None |
| `--cache-file` (usage ordering) | Frecency, kept by Flash |
| `cliphist list \| wofi --dmenu \| cliphist decode` | `!clip` (see [cliphist](cliphist.md)) |
| `bindsym $mod+d exec wofi --show drun` | A chord in `[mode.all.mappings]` |

```toml
[mode.all.mappings]
"alt+d" = ["flash", "mode", "flashlight"]
"alt+shift+d" = ["flash", "mode", "flashlight", "--query=@apps"]
"alt+e" = ["flash", "mode", "flashlight", "--query=@emojis", "--restore-mode"]
"alt+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]

[flashlight]
suggestion_count = 15
```

The chords are taken in every app, so Option-D, Option-E and Option-V stop
typing their characters; a `cmd+ctrl+…` prefix avoids that.

*Checked 2026-10-23 against wofi's [repository](https://hg.sr.ht/~scoopta/wofi),
its tags and its `wofi(1)` man page.*
