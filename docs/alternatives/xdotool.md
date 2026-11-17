# Flash and xdotool

[xdotool](https://github.com/jordansissel/xdotool) "lets you simulate
keyboard input and mouse activity, move and resize windows, etc. It does
this using X11's XTEST extension and other Xlib functions", with `libxdo`
as a C library beside it. It is BSD-3 C, about 3,900 stars, v4.20260303.1
in March 2026, and the glue of countless X11 scripts: `search`, then
`windowactivate`, then `key` or `type`, chained on one line. Its README
warns that on Wayland it "will not work correctly". Homebrew and MacPorts
package it for macOS, where it needs an X server such as XQuartz and so
reaches X11 programs only, not native apps. On a Mac, the jobs an xdotool
line did split between Flash's commands, which act on the focused app by
meaning, and [cliclick](https://github.com/BlueM/cliclick) for raw
coordinates and typed text.

| | xdotool | Flash |
| --- | --- | --- |
| License, price | BSD-3, free | MIT, free |
| Platforms | X11 (Linux, BSDs; macOS under XQuartz) | macOS 13+ |
| Keys | `key`, `keydown`, `keyup`, `type` any text, to the focused or a given window | `key send`, `key sequence`, `key arrow`, `key system` to the focused app; commands that resolve per app |
| Pointer | `mousemove` to coordinates or relative, `click`, `mousedown`, `getmouselocation` | `mouse target`, `grid`, `pointer`, `warp`, `nudge`, `button`, `repeat`; no raw coordinates |
| Windows | `search` by name, class or pid; activate, move, resize, minimize; desktops; `behave` on events | `window …` on the focused window, `app open`, `window switch`, workspaces with `[tiling]`, event monitors |
| Interface | A CLI and `libxdo` | The `flash` CLI over a versioned Unix socket ([IPC protocol](../ipc-protocol.md)), exit codes 0, 1 and 2 |
| Maintenance | v4.20260303.1, March 2026; active | 1.1.0, October 2026 |

## Where xdotool is stronger

- **It types any text.** `xdotool type "…"` sends a whole Unicode string.
  Flash has no command that types a string given on its command line; it
  types saved text (`@snippets`, a register), nothing ad hoc.
- **Coordinates and queries.** `mousemove 500 300`, `getmouselocation`,
  `getactivewindow getwindowname` give scripts numbers and names. Flash
  moves to targets and edges, and reports the focused app's bundle ID, not
  window titles or the pointer position.
- **Any window, not just the focused one.** `search --class` with a regex,
  `--window` to send keys to a background window, `behave` to run on focus
  or mouse-enter events, all composed on one line.
- **Accessibility-free.** XTEST works on any X11 client, whatever it
  exposes. macOS has no such layer: input synthesis needs the
  Accessibility grant, and windows are reached through the Accessibility
  tree.

## Where Flash is stronger

- **Meaning instead of chords.** `xdotool key ctrl+Tab` assumes the app
  binds Control-Tab. `flash tab next` asks the focused app: the browser's
  tab, Finder's, or the tmux window inside a terminal, through plugin
  bindings. A terminal never receives a Command chord it would type as text.
- **Elements instead of pixels.** A label, or `mouse target --search` and
  the text on it, finds the button by what it is, so a moved window or a
  resized sidebar does not break the habit.
- **One grant, held by Flash.** The resident posts the events, so the
  terminal running your script needs no Accessibility grant of its own, as
  cliclick's README says Terminal does.
- **Exit codes that mean something**: 0 when it ran, 1 when there was
  nothing to act on, 2 when the words name no command
  ([commands](../commands.md)).

## Flash features you might like

- `flash normal 3gt` presses a NORMAL mapping by its keys from a script,
  plugin and per-app mappings included ([`:normal`](../commands.md#normal-and)).
- `printf '%s' "$text" | pbcopy && flash clipboard paste` types a string
  through the app's own paste, terminals included; it replaces the
  clipboard, which [clipboard history](../clipboard.md) keeps.
- [Monitors](../monitors.md#runs-and-events) on `core:focus.changed` (with
  `app = "<bundle id>"`) do what `xdotool behave` did on focus.
- `:!cmd` runs a shell line from Flash's command line and shows its output.

## Moving from xdotool

| xdotool | Flash |
| --- | --- |
| `key ctrl+Tab`, `key ctrl+w`, `key F5` | `flash tab next`, `flash tab close`, `flash app reload` |
| `key super+l` | `flash screen lock` |
| `key ctrl+l` (no command for it) | `flash key send --keys=cmd+l`, the escape hatch |
| `key --delay 50 a b c` | `flash key sequence --keys=a,b,c`; `[mode] send_key_interval_ms` sets the gap |
| `type "text"` | `pbcopy` then `flash clipboard paste`; saved text through `@snippets` |
| `mousemove 500 300 click 1` | `flash mouse target` and a label; `flash mouse warp --area=screen --edge=center` |
| `mousemove_relative 10 0` | `flash mouse nudge --direction=right --distance=10` |
| `mousedown 1` … `mouseup 1` | `flash mouse button --state=down` … `--state=up` |
| `click --repeat 2 1` | `flash mouse target --double` |
| `search --name Firefox windowactivate` | `flash app open --name=Firefox`; by title, `window switch` or `@windows` |
| `getactivewindow windowmove 0 0 windowsize 50% 100%` | `flash window move --position=lefthalf` |
| `windowminimize` | `flash window minimize` |
| `set_desktop 1` | `flash workspace switch --name=2` with `[tiling]` on |
| `getactivewindow getwindowname` | `flash resident status --json`: `focused_app` is the bundle ID |
| `behave … focus exec` | A monitor on `core:focus.changed` |

Bindings that used to call xdotool from a hotkey daemon:

```toml
[plugins.snippets]
file = "~/.config/flash/snippets.toml"  # name = "text" lines

[mode.all.mappings]
"ctrl+alt+<right>" = ["flash", "tab", "next"]
"ctrl+alt+<left>" = ["flash", "tab", "previous"]
"ctrl+alt+h" = ["flash", "window", "move", "--position=lefthalf"]
"ctrl+alt+s" = ["flash", "mode", "flashlight", "--query=@snippets", "--restore-mode"]
"ctrl+alt+l" = ["flash", "key", "send", "--keys=cmd+l"]
```

Flash's own defaults bind commands, never chords; `key send` is there for
the chord no command covers.

*Checked 2026-10-23 against the xdotool
[README](https://github.com/jordansissel/xdotool),
[xdotool.pod](https://github.com/jordansissel/xdotool/blob/master/xdotool.pod)
and releases, and the [cliclick README](https://github.com/BlueM/cliclick).*
