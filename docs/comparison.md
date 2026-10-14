# How Flash compares, and FAQ

| | License | Hints from | Also has | Flash adds |
| --- | --- | --- | --- | --- |
| [Neru](https://github.com/y3owk1n/neru) | MIT | Accessibility, optional OCR and contour detection | Grid, bisect, scroll mode, Linux and Windows | Accessibility only, normal mode with per-app actions, search, status bar, widgets, popups, plugins |
| [Homerow](https://www.homerow.app) | Paid, closed | Accessibility | Scroll, search | Free, configured in a file, everything past clicking |
| [Shortcat](https://shortcat.app) | Closed | Accessibility, by typing visible text | | `mouse_target --search` does that, next to labels |
| [Scoot](https://github.com/mjrusso/scoot) | BSD-3 | Accessibility | Grid | Normal mode, terminal hints, search, plugins |
| [Vimac](https://github.com/nchudleigh/vimac) | GPL, unmaintained | Accessibility | Scroll | Homerow's open-source predecessor; Flash is maintained |
| Wooshy, Mouseless, Superkey | Paid | Accessibility or text seek | | Superkey's text seek needs Screen Recording; Flash does not |
| [Vimium](https://github.com/philc/vimium), Surfingkeys | MIT | The DOM, in the browser | | Every app, no extension |
| [Hammerspoon](https://www.hammerspoon.org) | MIT | | Lua automation of everything | A ready-made keyboard layer in TOML; see the [migration guide](hammerspoon.md). Hammerspoon can drive Flash with `flash <verb>` |
| [SketchyBar](https://github.com/FelixKratz/SketchyBar) | GPL | | Scriptable bar | tmux formats, and one plugin feeds the bar, hints, search and widgets |
| [Übersicht](https://github.com/felixhageloh/uebersicht), conky | GPL | | Web-view widgets; conky needs XQuartz | Native text widgets fed by the bar's collectors |
| Raycast, Alfred | Closed | | Launchers | flashlight covers apps, tabs, emoji and quick math; Flash's focus is acting on what is on screen, and it runs fine next to them |

Window managers are not on the list on purpose: Flash moves and focuses
windows but does not tile. It runs next to AeroSpace, yabai or Rectangle.

Flash only sees what an app exposes to Accessibility. Canvas-drawn interfaces
and some games show no hints; use the grid there.

## Performance

Flash prepares each focused window's targets in the background as it changes,
so most activations draw hints without walking the app. Every activation logs
its latency from the keypress to the frame that shows the hints;
[performance](performance.md) has the method, the benchmark script, and
measurements.

## FAQ

**Is it Vim?** No. NORMAL, INSERT and COMMAND are borrowed from Vim because
they are a good way to make one keyboard do two jobs; the bindings are
Vimium's and your own, not an editor's.

**Does it work in Electron apps and Chrome?** Yes, through the Accessibility
tree Chromium exposes once an assistive client asks for it. Flash prepares a
window's targets in the background as it changes; a prepared window shows
hints in a fraction of a millisecond, and a cold walk of a small page takes
10 to 25 ms on an M4 Pro. A canvas, a game or a remote desktop exposes
nothing; use the grid.

**Is the key tap a keylogger?** It runs only while Flash owns input, decides
swallow or pass for each key, and never stores anything. The tap lives in one
file, `KeyboardCaptureTap.swift`, and a guardrail rejects any other tap or
global key monitor.

**What does it cost at idle?** Hints follow Accessibility events and tmux
follows its control client, so nothing polls for them. Whatever must poll
(CPU, battery, a feed) ticks on the one scheduler in the process, which
coalesces wake-ups and pauses when the display sleeps. The budget and the
script that measures it are in [performance](performance.md).

**Why not Hammerspoon, Karabiner, SketchyBar and a tiler?** You can keep
them. Flash is the part that wants a single modal layer and a single file:
hints, modes and the bar sharing one set of plugins. It does not tile, remap
hardware keys or run Lua.

**Non-QWERTY keyboard?** Labels, grid keys and mappings are read by key
position, so AZERTY, Dvorak and non-Latin input sources work without
configuration (`[app] keyboard_layout`).

**Several displays?** Hints cover the focused window; `--scope=screen` labels
every app on the screen. Tab moves the grid to the next display. The bar sits
on the display you choose, and each widget can sit on one display or all of
them.

