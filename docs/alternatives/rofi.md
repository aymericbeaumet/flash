# Flash and rofi

[rofi](https://github.com/davatorium/rofi) is "A window switcher,
Application launcher and dmenu replacement": built-in modes (`drun`, `run`,
`window`, `ssh`, `filebrowser`, `keys`, `combi`), script modes, a
drop-in `-dmenu`, fuzzy, regex and glob matching, and the rasi theme
language. It is MIT C, about 16,500 stars, 2.0.0 in September 2025, which merged lbonn's
Wayland port so both X11 and Wayland are official backends, with commits
in October 2026. It is "known to work on Linux and BSD". Homebrew builds it
for macOS against XCB, so there it needs an X server such as XQuartz and
lists only what runs under X. On a Mac, Flash's [flashlight](../flashlight.md)
plays rofi's launcher and switcher roles and `menu choose` its dmenu mode;
[Raycast](raycast.md) and [Alfred](alfred.md) are the dedicated macOS
launchers.

| | rofi | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Linux and the BSDs, X11 and Wayland | macOS 13+ |
| Lists | Desktop entries, `$PATH`, EWMH windows, ssh hosts, files, any script | Apps, browser tabs, tmux windows, windows, files by name, processes, menus, emoji, clipboard, plugin data |
| Picker for scripts | `-dmenu` with prompts, multi-select, `-format`, icons, custom keys | `flash menu choose`: lines in, the picked line out |
| Matching | Fuzzy, regex, glob, prefix; history or fzf-style sorting | Typo-tolerant tiers, frecency |
| Extending | Script modes, C plugins | Plugins in any language over JSON lines |
| Looks | rasi themes | One look; `suggestion_count` rows |
| Configuration | `config.rasi`, command-line flags | `flash.toml`, live reload |
| Maintenance | 2.0.0, September 2025; active | 1.1.0, October 2026 |

## Where rofi is stronger

- **The picker is a toolkit.** `-dmenu` takes a prompt, a message line,
  Pango markup, icons per row, `-multi-select`, `-format i` for an index,
  and `-kb-custom-1` keys that return their own exit codes, so one script
  can offer several actions on a row. `menu choose` returns one line, or
  exits 1.
- **Script modes keep state.** A script becomes a mode that rofi calls
  again with the selection (`ROFI_RETV`), which is how nested menus and
  rofi-calc-style tools are written in a few lines of shell. A Flash source
  is a plugin process speaking JSON lines.
- **Themes.** The rasi language styles every element; Flash's flashlight
  has one design.
- **ssh and file browsing** are modes of their own; Flash finds files by
  name through Spotlight and lists ssh hosts only through a script.
- **Any window manager, two display servers, the BSDs.**

## Where Flash is stronger

- **It sees the Mac.** Installed and running apps, Safari, Chrome and
  Firefox tabs, tmux windows, and every window Flash has seen on any Space,
  minimized and hidden ones included, with a hint label per row in the
  [window switcher](../windows.md#switch-to-any-window). rofi under XQuartz
  sees X clients only.
- **Answers without a plugin**: `1+1`, `2 km to m`, `10 euros`,
  `time in tokyo` answer inline, and about 14,500 `!bangs` resolve on your
  Mac ([bangs](../flashlight.md#bangs)).
- **Commands, not only launches.** `:` opens Flash's command line over the
  same surface, with completion, Vim's ex aliases and `:!cmd` for the shell.
- **The hotkey lives with everything else.** rofi starts from a binding in
  your window manager's config; Flash's launcher chord sits in the same
  `flash.toml` as its hints, bar and window commands.

## Flash features you might like

- `mode flashlight --query=@windows` on its own chord is `rofi -show window`;
  `--query=@emojis` is rofi-emoji, `--query=!clip` is rofi with greenclip.
- `@<type>` narrows like `-show <mode>`, and `@` alone lists the types and
  what feeds each ([resource types](../flashlight.md#narrow-to-a-resource-type)).
- `menu choose` reads standard input like `rofi -dmenu`, and Escape exits 1,
  so `|| exit` keeps working in your scripts ([pick from a list](../flashlight.md#pick-from-a-list)).
- `[flashlight.aliases]` turns `@w` into `@windows` as your fingers expect.

## Moving from rofi

| rofi | Flash |
| --- | --- |
| `rofi -show drun` | `["flash", "mode", "flashlight"]`; apps lead the default rows |
| `rofi -show window` | `["flash", "window", "switch"]`, or `--query=@windows` to type a title |
| `rofi -show run` | `:!cmd` on the command line; `:open -a App` |
| `rofi -show ssh` | `menu choose` over your ssh config (below); `@terminals` for tmux windows |
| `rofi -show filebrowser` | `!f <name>` or `@files`, by name through Spotlight |
| `-show combi -combi-modi window,drun` | The default rows: apps, tabs, tmux windows, plugin locations |
| `rofi -show keys` | `?` in NORMAL, or `flash mappings show` |
| `-modi "clipboard:greenclip print"` | `!clip` ([clipboard](../clipboard.md#paste-from-the-flashlight)) |
| `rofi -dmenu -i -p "Branch"` | `flash menu choose`, filtered by the flashlight's typo-tolerant scorer; no prompt text |
| `-multi-select`, `-format i`, `-kb-custom-1` | Not available |
| A script mode | A plugin that publishes a source ([cookbook](../plugin-cookbook.md)) |
| `config.rasi`, `@theme` | `[flashlight] suggestion_count`; no themes |
| History-based sorting | Frecency, tuned by `frecency_half_life_days` |

```toml
[mode.all.mappings]
"alt+d" = ["flash", "mode", "flashlight"]
"alt+w" = ["flash", "window", "switch"]
"alt+e" = ["flash", "mode", "flashlight", "--query=@emojis", "--restore-mode"]
"alt+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
"alt+s" = ["/bin/sh", "-c", "grep '^Host ' ~/.ssh/config | awk '{print $2}' | flash menu choose | xargs -I{} open ssh://{}"]

[flashlight]
suggestion_count = 12

[flashlight.aliases]
"@w" = "@windows"
"@f" = "@files"
```

`open ssh://<host>` hands the host to your ssh link handler. Every chord above is taken
system-wide, so Option-D no longer types its character in any app;
`cmd+ctrl+…` leaves them alone.

*Checked 2026-10-23 against the rofi [README](https://github.com/davatorium/rofi),
its [2.0.0 release notes](https://github.com/davatorium/rofi/releases/tag/2.0.0)
and the Homebrew formula.*
