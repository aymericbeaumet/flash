# Coming from Neverclick

[Neverclick](https://www.neverclick.com) is a free Windows keyboard mouse that
labels whatever looks clickable from a screen capture. Flash is its macOS
counterpart with one deliberate difference: Flash never reads screen pixels.
Hints come from the Accessibility tree, the window geometry WindowServer
publishes, and the text an app exposes. That is why Flash asks for the
Accessibility permission only, has no model to download, and starts a hint
session in well under a frame on a prepared window. The price is that a canvas,
a game or a remote desktop that exposes nothing to Accessibility shows no hints;
the [grid](normal-mode.md#mouse-grid), bisect and [pointer mode](commands.md)
cover those.

Flash is MIT-licensed, built in the open, configured in one TOML file, and
ships the two features Neverclick lists as coming soon: dragging between two
hints and highlighting the text between two words.

## Key by key

| Neverclick | Flash |
| --- | --- |
| Left Click Tool (`Ctrl+Enter`) | `mouse_target`; `f` in NORMAL, or any hotkey in `[mode.all.mappings]` |
| Clairvoyance (`[`, accessibility hints) | The default. There is no other vision |
| Grid mode (`;`) | `mouse_grid`; while labels are up, `Tab` moves the same click to the grid |
| Active window / full screen (`Tab`) | `mouse_target --scope=screen`; while labels are up, `Shift-Tab` toggles it |
| Snap target to the box edges (arrows, `Shift+JILK`) | `mouse_target --adjust`, then `h` `j` `k` `l` or the arrows |
| Position target `1`–`9` | `--adjust` digits; `[hints] adjust_digits = "grid"` makes them a keypad |
| Dual Select, Multi Select (`'`, `Shift+'`, `Enter` ends) | `mouse_target --multi`: click as you pick, Escape ends |
| Path mode (`Ctrl+'`) | `mouse_target --path`: pick two labels, every target between them is clicked |
| Sticky Hints Tool | `mouse_target --sticky`: the same labels stay up after each click |
| Text detection in editors, word boundaries | `mouse_target --words`: a label on every visible word, landing on its leading edge |
| Text Highlighting Tool (coming soon) | `mouse_target --words --select`: pick two words |
| Drag tool (coming soon) | `mouse_target --drag`, `mouse_grid --drag`, `mouse_button --state=down` |
| Scroll | `ctrl+e` / `ctrl+y`, `ctrl+d` / `ctrl+u`, `gg` / `G`, `scroll_target` to pick the area |
| Move window between monitors | `window_move --screen=+1` |
| Move window between virtual desktops | Not available: macOS exposes no public API for Spaces |
| Window switching while hints are up (`Shift+WASD`) | `window_focus --direction=left|right|up|down`, then `f` |
| Cycle overlapping windows, window behind (`Shift+Q/W`, `Shift+Z`) | `window_focus --direction=next|previous|behind` |
| Center-weighted hint keys, Key Priority Map | `[hints] label_order = "center"` and `[hints] key_priority = "fjdk…"` |
| Hints use the keyboard language; Dvorak, Colemak | `[app] keyboard_layout = "auto"`, `[keyboard] layout = "colemak"` |
| Multi-monitor, 4K and 8K | Every display, at its own scale |
| Settings window with a virtual keyboard | `flash.toml`, reloaded on save; the [key mappings](help.md) page draws your bindings on your layout, one mode at a time |
| Undo a hint key (`Backspace`) | `Backspace` |

Neverclick's hint labels favour the keys at the centre of the keyboard and
hand the most convenient ones to the targets nearest the centre of the screen.
Flash's default favours the home row and reading order; `label_order =
"center"` reproduces the Neverclick rule, and `label_order = "zones"` goes one
step further and makes the first key of every label predictable from where the
target sits in the window.

## A Neverclick-shaped configuration

[`docs/examples/neverclick/flash.toml`](examples/neverclick/flash.toml) binds
the Neverclick chords to Flash verbs, keeps the centre-weighted labels, and
leaves NORMAL mode off so nothing changes about typing. Copy it into
`~/.config/flash/flash.toml` and adjust the keys:

```toml
[hints]
label_order = "center"
key_priority = "fjdkslaghrueiwotyqp"

[mode.all.mappings]
"ctrl+return" = ["flash", "mouse_target"]
"ctrl+shift+return" = ["flash", "mouse_grid"]
"ctrl+alt+return" = ["flash", "mouse_target", "--scope=screen"]
"ctrl+'" = ["flash", "mouse_target", "--path"]
"ctrl+shift+'" = ["flash", "mouse_target", "--multi"]
"ctrl+;" = ["flash", "mouse_target", "--sticky"]
"ctrl+alt+;" = ["flash", "mouse_target", "--words"]
```

`flash config_check` validates the file without starting Flash.

## What stays different

- **No pixel detection.** Hard rule, not a missing feature: Flash holds the
  Accessibility permission only and never captures the screen. Where an app
  exposes nothing, use the grid, bisect or pointer mode.
- **Idle cost.** Neverclick runs nothing until activated. Flash prepares the
  focused window's targets in the background as it changes, so activation
  draws prepared hints at once; `flash status` reports the measured latencies
  per app, and [performance](performance.md) has the method.
- **Configuration is a file.** There is no settings window. The browser help
  shows the effective bindings, the [key mappings](help.md) page draws them
  on your layout for the mode you pick, and the file reloads when saved.
