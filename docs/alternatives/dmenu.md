# Flash and dmenu

[dmenu](https://tools.suckless.org/dmenu/) "is a dynamic menu for X, which
reads a list of newline-separated items from stdin. When the user selects an
item and presses Return, their choice is printed to stdout and dmenu
terminates." Written for dwm and kept deliberately small, it is configured by
editing `config.h` and recompiling, extended by the patches on the suckless
site, and its stdin-to-stdout contract is the one rofi, wofi and fuzzel
imitate in their dmenu modes. It is MIT/X C, 5.4 in August 2025, with commits in October 2026. It needs an X
server: Homebrew builds it for macOS against libX11, where it runs under
XQuartz and sees nothing native. What a dmenu user carries to a Mac is
the pipe, and Flash keeps its shape: `flash menu choose` reads lines on
standard input, shows them in the [flashlight](../flashlight.md#pick-from-a-list)
and prints the one you pick.

| | dmenu | Flash |
| --- | --- | --- |
| License, price | MIT/X, free | MIT, free |
| Platforms | X11 on Linux and the BSDs | macOS 13+ |
| Input, output | Lines on stdin, the choice on stdout, exit 1 on Escape | The same, or `--file=<path>`; up to 10,000 lines and 4 MB |
| Matching | Tokens, `-i` for case-insensitive; patches for fuzzy | Typo-tolerant tiers, as every flashlight search |
| Options | `-b`, `-l`, `-p`, `-m`, `-fn`, colours, `-w` | None; one look |
| Launcher | `dmenu_run` over `$PATH` | The flashlight's apps, tabs and windows; `:!cmd` for the shell |
| Configuration | `config.h`, recompiled; patches | `flash.toml`, live reload |
| Maintenance | 5.4, August 2025; commits in October 2026 | 1.1.0, October 2026 |

## Where dmenu is stronger

- **Small enough to read.** One C program with no daemon, depending only on
  Xlib, Xft and Xinerama. Flash is a resident app with plugin processes.
- **It is a building block for any menu.** `-p` prompts, `-l` vertical
  lists, `-b` at the bottom, `-m` per monitor, `-w` embedded in another
  window, Ctrl-Return to print several items and keep going, Shift-Return to
  print the typed text. `menu choose` has no prompt and returns one line.
- **Patches.** [fuzzymatch](https://tools.suckless.org/dmenu/patches/fuzzymatch/),
  centring, mouse support, a password mode: each a small diff you choose,
  in code you own.
- **Any amount of input.** dmenu reads whatever you pipe in;
  `menu choose` stops at 10,000 lines and 4 MB.

## Where Flash is stronger

- **Native on macOS.** No X server, and the menu sits over Mac apps with
  the keyboard focus it needs.
- **Ranking without patches.** The picker uses the flashlight's scorer:
  typos, word starts and out-of-order words find the line.
- **The launcher is not a script.** `dmenu_run` lists `$PATH`; the
  flashlight lists installed and running apps, browser tabs, tmux windows
  and every window, answers `1+1` inline, and ranks by frecency.
- **Commands and the shell from the same keys.** `:` runs any Flash command
  with completion, and `:!cmd` runs a shell command and shows its output.

## Flash features you might like

- `flash menu choose --file=~/projects.txt` reads a file instead of a pipe,
  and `:menu choose --file=…` opens it from the command line.
- Escape exits 1, so `choice=$(… | flash menu choose) || exit 1` stops a
  script exactly where dmenu would.
- Return with no matching line answers with what you typed, dmenu's
  Shift-Return behaviour, so a picker can also take new input.
- `@<type>` scopes give the menus you used to script for free: `@processes`,
  `@system`, `@menus`, `@emojis`.

## Moving from dmenu

| dmenu | Flash |
| --- | --- |
| `… \| dmenu` | `… \| flash menu choose` |
| `dmenu -i` | Matching already ignores typos and order |
| `dmenu -p "Open:"`, `-l 10`, `-b`, colours | Not available; `[flashlight] suggestion_count` sets the rows |
| Ctrl-Return (several items) | Not available: one pick per call |
| `dmenu_run` | `["flash", "mode", "flashlight"]` for apps; `:!cmd` for the shell |
| `passmenu` | Keep a password manager's own picker: text a script copies lands in Flash's clipboard history unless the app marks it concealed ([privacy](../privacy.md#data-stored-on-your-mac)) |
| A dwm binding to a script | A mapping whose argv is the script |

A dmenu script moves over by changing one word:

```sh
#!/bin/sh
# ~/bin/open-project: open a checkout in VS Code.
project=$(ls ~/src | flash menu choose) || exit 1
open -a "Visual Studio Code" ~/src/"$project"
```

and the dwm binding becomes a mapping:

```toml
[mode.all.mappings]
"cmd+ctrl+p" = ["~/bin/open-project"]
"cmd+ctrl+space" = ["flash", "mode", "flashlight"]
```

*Checked 2026-10-23 against the dmenu [site](https://tools.suckless.org/dmenu/),
its [man page](https://git.suckless.org/dmenu/file/dmenu.1.html),
[repository log](https://git.suckless.org/dmenu/log.html) and the Homebrew
formula.*

Add `--prompt='Choose branch'` to label a pick. The label stays beside the
editable query and is not part of the selected value or its filtering. Labels
are single lines of up to 120 characters.
