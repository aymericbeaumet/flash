# Flash and Neverclick

[Neverclick](https://www.neverclick.com) says "Never use a mouse again": a
free Windows 10 and 11 (x64) app that labels whatever looks clickable with
"computer vision that won't melt your laptop", fully offline, with no
account. It is closed source: its
[GitHub repository](https://github.com/LazoVelko/neverclick) hosts the
README and the releases, and v0.4.2 on 21 October 2026 added a Drag Tool, a
Text Selection Tool and firmware keyboard layouts, about a month after
v0.4.1. It does not run on macOS, so this page is for someone who uses
Neverclick on a Windows machine and wants the same hands on a Mac.

Flash is the closest macOS counterpart, with one deliberate difference:
Flash never reads screen pixels. Its hints come from the Accessibility tree,
the window geometry WindowServer publishes, and the text an app exposes,
which is roughly what Neverclick's optional Clairvoyance mode does.

| | Neverclick | Flash |
| --- | --- | --- |
| License, price | Closed source; free, donations welcome | MIT, free |
| Platforms | Windows 10 and 11 (x64); no ARM, macOS or Linux | macOS 13+ |
| Permissions | Installs to Program Files to act on elevated apps | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot screen` |
| Hints from | Neverclick Vision (a screen capture, on the CPU); Clairvoyance (accessibility APIs, foreground window) | Accessibility tree; tmux panes; never pixels |
| Tools | Left click, grid, dual, multi and path select, sticky hints, drag, text selection, target snapping | The same set, plus words, search, bisect, pointer mode and HOLD |
| Beyond pointing | Scroll, move windows between monitors and virtual desktops, open apps | NORMAL mode, flashlight, status bar, widgets, popups, window placement, plugins |
| Configuration | Settings window with a virtual keyboard; no config files | One TOML file, live reload, `flash config check` |
| Maintenance | v0.4.2, October 2026; releases about monthly | 1.1.0, October 2026 |

## Where Neverclick is stronger

- **It labels pixels.** Neverclick Vision finds buttons in apps that expose
  nothing to accessibility: canvases, games, remote desktops, custom-drawn
  toolkits. Flash shows no labels there, by rule; the grid, bisect and
  pointer mode are its answer.
- **Nothing runs until you ask.** Its page puts idle CPU at 0%, about 200 MB
  of memory on a 1080p screen and 40 MB on disk. Flash keeps the focused
  window's targets prepared in the background so labels draw at once, which
  costs some work as windows change.
- **A settings window.** Keys are assigned on a virtual keyboard, and the
  Key Priority Map is edited by clicking; Flash is a text file.
- **Virtual desktops.** Neverclick moves a window to another desktop.
  macOS has no public API for Spaces, so Flash's `window move` stops at
  displays (its opt-in [tiling](../tiling.md) has workspaces of its own).

## Where Flash is stronger

- **No screen capture, ever.** Flash holds the Accessibility permission and
  nothing in the process reads pixels; the [privacy page](../privacy.md)
  lists every prompt.
- **It knows what a target is.** Accessibility says which target is a text
  field, a link or a menu, so a field wins over a button laid on it and
  `mouse target --copy-url` copies a link's address instead of clicking it.
- **Open source and a file.** The configuration lives in your dotfiles,
  reloads on save and is validated by `flash config check`.
- **Everything after the click.** A persistent NORMAL mode, the flashlight,
  a status bar, widgets and popups share the same keys.

## Flash features you might like

- `[hints] label_order = "center"` and `key_priority` reproduce Neverclick's
  centre-weighted labels; `label_order = "zones"` goes one step further and
  makes a label's first key predictable from where the target sits.
- `mouse target --adjust` with `[hints] adjust_digits = "grid"` is the
  number-row target positioning, laid out as a keypad.
- `mouse target --words --select` highlights between two words, and
  `mouse target --drag` drags between two targets.
- The [key mappings](../help.md) page in the browser help draws your
  bindings on your own keyboard layout, one mode at a time.

## Moving from Neverclick

| Neverclick | Flash |
| --- | --- |
| Left Click Tool (`Ctrl+Enter`) | `mouse target`; `f` in NORMAL, or any hotkey in [`[mode.all.mappings]`](config:mode.all.mappings) |
| Clairvoyance (`[`, accessibility hints) | The default. There is no other vision |
| Grid mode (`;`) | `mouse grid`; while labels are up, `Tab` moves the same click to the grid |
| Active window / full screen (`Tab`) | `mouse target --scope=screen`; while labels are up, `Shift-Tab` toggles it |
| Snap target to the box edges (arrows, `Shift+JILK`) | `mouse target --adjust`, then `h` `j` `k` `l` or the arrows |
| Position target `1`–`9` | `--adjust` digits; `[hints] adjust_digits = "grid"` makes them a keypad |
| Dual Select, Multi Select (`'`, `Shift+'`, `Enter` ends) | `mouse target --multi`: click as you pick, Escape ends |
| Path mode (`Ctrl+'`) | `mouse target --path`: pick two labels, every target between them is clicked |
| Sticky Hints Tool | `mouse target --sticky`: the same labels stay up after each click |
| Text detection in editors, word boundaries | `mouse target --words`: a label on every visible word, landing on its leading edge |
| Text Selection Tool | `mouse target --words --select`: pick two words |
| Drag Tool | `mouse target --drag`, `mouse grid --drag`, HOLD (`mode hold`) |
| Scroll | `ctrl+e` / `ctrl+y`, and in a page `ctrl+d` / `ctrl+u` and `gg` / `G` (in a list or a text field they move the selection or the caret); `scroll target` to pick the area |
| Move window between monitors | `window move --screen=+1` |
| Move window between virtual desktops | Not available: macOS exposes no public API for Spaces |
| Window switching while hints are up (`Shift+WASD`) | `window focus --direction=left`, `right`, `up` or `down`, then `f` |
| Cycle overlapping windows, window behind (`Shift+Q/W`, `Shift+Z`) | `window focus --direction=next`, `previous` or `behind` |
| Center-weighted hint keys, Key Priority Map | `[hints] label_order = "center"` and `[hints] key_priority = "fjdk…"` |
| Hints in the keyboard's language; Dvorak, Colemak, firmware layouts | `[app] keyboard_layout = "auto"` reads the input source; `[keyboard] layout = "colemak"` (or `dvorak`, `bepo`) places the labels |
| Multi-monitor, 4K and 8K | Every display, at its own scale |
| Undo a hint key (`Backspace`) | `Backspace` |

[`docs/examples/neverclick/flash.toml`](../examples/neverclick/flash.toml)
binds the Neverclick chords to Flash commands, keeps the centre-weighted
labels, and leaves NORMAL off so nothing changes about typing
([the example's notes](../examples/neverclick/README.md)). Its core:

```toml
[hints]
label_order = "center"
key_priority = "fjdkslaghrueiwotyqp"
adjust_digits = "grid"

[mode.all.mappings]
"ctrl+return" = ["flash", "mouse", "target"]
"ctrl+shift+return" = ["flash", "mouse", "grid"]
"ctrl+alt+return" = ["flash", "mouse", "target", "--scope=screen"]
"ctrl+'" = ["flash", "mouse", "target", "--path"]
"ctrl+shift+'" = ["flash", "mouse", "target", "--multi"]
"ctrl+;" = ["flash", "mouse", "target", "--sticky"]
"ctrl+alt+;" = ["flash", "mouse", "target", "--words"]
"ctrl+shift+z" = ["flash", "window", "focus", "--direction=behind"]
```

On a Mac keyboard, `ctrl+return` is Control-Return; Windows' Ctrl becomes
Control rather than Command, so the chords stay where your fingers expect
them.

## Using both

Neverclick and Flash never share a machine, but they share your hands: keep
Neverclick on the Windows PC and Flash on the Mac, with the same chords on
both, and the example above keeps the muscle memory. Two habits change. On
an app that exposes nothing to Accessibility, reach for the grid (`Tab`
while labels are up) instead of expecting vision to find the button. And
there is no idle-free mode: Flash prepares targets as windows change, and
`flash resident status` reports the measured latency per app if you want to
see what that buys ([performance](../performance.md)).

*Checked 2026-10-23 against [neverclick.com](https://www.neverclick.com),
the [Neverclick README](https://github.com/LazoVelko/neverclick) and the
[v0.4.2 release notes](https://github.com/LazoVelko/neverclick/releases/tag/v0.4.2).*
