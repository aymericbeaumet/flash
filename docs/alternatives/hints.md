# Flash and hints

[hints](https://github.com/AlfredoSequeida/hints) (Alfredo Sequeida's
Linux tool, not Flash's own [hints](../hints.md)) "lets you navigate GUI
applications in Linux without your mouse by displaying 'hints' you can type
on your keyboard to interact with GUI elements". It finds targets through
AT-SPI, the Linux accessibility bus, falls back to an OpenCV backend that
screenshots the window and detects shapes, and reads modifiers on the
label: Shift right-clicks, Alt drags, Ctrl hovers. It is GPL-3.0 Python,
about 1,400 stars, 0.1.1 in June 2026, and supports X11, GNOME, KDE
Plasma, sway, Hyprland, niri and Mango. It is the closest Linux relative of
Flash's hints, which read the macOS Accessibility tree the same way.

| | hints | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free | MIT, free |
| Platforms | Linux: X11 (with a compositor) and several Wayland compositors | macOS 13+ |
| Targets from | AT-SPI, then OpenCV on a screenshot of the window | The Accessibility tree only; the keyboard grid where it is empty |
| Actions | Click, several clicks with a count, Shift right-click, Alt drag, Ctrl hover, `hjkl` move and scroll mode | Click, right, middle, double and triple click, move, drag, select, several clicks, copy a link or text, search, words |
| Beyond hints | A warm daemon, layered labels for overlapping targets | NORMAL mode, grid, bisect, pointer mode, flashlight, bar, window commands, plugins |
| Configuration | `~/.config/hints/config.json`, per-application AT-SPI rules | `flash.toml`, `[hints]` and per-app mapping tables |
| Maintenance | 0.1.1, June 2026; a spare-time project | 1.1.0, October 2026; one maintainer |

## Where hints is stronger

- **It works on Linux**, across X11, GNOME, Plasma and the wlroots-style
  compositors, which Flash never will.
- **A fallback when accessibility is empty.** The OpenCV backend finds
  buttons in a screenshot of a window that exposes nothing. Flash reads no
  pixels by design, so such a window gets the grid, not labels.
- **Tuning per application.** Its AT-SPI rules choose the roles, states and
  scale factor that count as targets for each app. Flash's walk has no
  per-app role filter.
- **Modifiers as verbs on one key.** Shift, Alt and Ctrl on the label pick
  right-click, drag and hover without a separate binding for each.
- **Overlapping targets** go on layers you switch with Space.

## Where Flash is stronger

- **macOS Accessibility is richer to work with.** Flash turns on Chromium's
  and Electron's accessibility for you and walks the window in the
  background, so most activations show labels without walking the app at all
  ([performance](../performance.md)).
- **It never takes a screenshot**, and asks for no Screen Recording grant
  to hint ([privacy](../privacy.md)).
- **A persistent NORMAL mode.** Hints are one key, `f`, among Vim keys that
  scroll, switch tabs and windows in every app; hints is summoned per use.
- **More ways to pick**: `--search` types visible text, `--words` labels
  every word, `s` jumps to a letter, `--path` and `--sticky` click several,
  and tmux panes and terminal links get labels too.
- **The surfaces outside the window**: `mouse menubar`, `mouse dock` and
  `mouse notifications`.

## Flash features you might like

- Modifiers held on the final label key ride the click, as in hints:
  Shift-label is a Shift-click, Command-label a Command-click.
- `mouse target --drag` picks a grab point and a drop point, and
  `mf` (`--move`) is hints' hover.
- `scroll target` picks the scroll area, then NORMAL's `ctrl+e` /
  `ctrl+y`, and in a page `j` / `k` and `ctrl+d` / `ctrl+u`, scroll it,
  which is hints' scroll mode; with a list or a text field focused, `j` /
  `k` and `ctrl+d` / `ctrl+u` move its selection or caret instead.
- `[hints] keys` takes your alphabet, or a layout token such as
  `<colemak>` ([hints](../hints.md#tune-labels-and-pointer-behavior)).

## Moving from hints

| hints | Flash |
| --- | --- |
| `hints` bound in the compositor | `["flash", "mouse", "target"]` on a chord, or `f` in NORMAL |
| `j` `k` (click once) | The label |
| `2` `j` `k` (click twice) | `df` double-clicks; `mouse target --multi` keeps clicking. In NORMAL a count is a finger count: `2f` right-clicks |
| Shift + label (right-click) | `cf` in NORMAL, `mouse target --secondary` |
| Alt + label (drag) | `mouse target --drag` |
| Ctrl + label (hover) | `mf`, `mouse target --move` |
| `hints -m scroll`, `hjkl` | `scroll target`, then NORMAL's scroll keys |
| `alphabet` | `[hints] keys` |
| `hint_font_size`, colours | `[overlay]` ([configuration](../configuration.md)) |
| AT-SPI `application_rules` | No per-app filter; `[mode.apps."<bundle id>"]` changes the keys per app |
| OpenCV backend | `mouse grid`, or `mouse grid --bisect` |

```toml
[hints]
keys = "asdfgqwertzxcvbhjklyuiopnm"

[mode.all.mappings]
"ctrl+alt+f" = ["flash", "mouse", "target"]
"ctrl+alt+r" = ["flash", "mouse", "target", "--secondary"]
"ctrl+alt+d" = ["flash", "mouse", "target", "--drag"]
"ctrl+alt+m" = ["flash", "mouse", "target", "--move"]
"ctrl+alt+g" = ["flash", "mouse", "grid"]
```

*Checked 2026-10-23 against the hints
[README](https://github.com/AlfredoSequeida/hints), its
[wiki](https://github.com/AlfredoSequeida/hints/wiki), releases and source
(`hints/constants.py`, `hints/backends`, `hints/window_systems`).*
