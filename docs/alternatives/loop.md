# Flash and Loop

[Loop](https://github.com/MrKai77/Loop) is "Window management made
elegant": hold a trigger key and move the pointer toward a direction on a
radial menu, watch a preview of where the window will land, and let go. The
same trigger key with another key runs any action without the mouse, and
pressing a combination again cycles through a list of actions. It is GPL-3.0
Swift by Kai, about 12,000 GitHub stars, free, for macOS 13 and later.
1.4.0 in January 2026 added focus navigation, screen switching by side and
left- or right-specific trigger keys, 1.4.2 followed the same month, and
commits continue in October 2026.

| | Loop | Flash |
| --- | --- | --- |
| License, price | GPL-3.0, free | MIT, free |
| Platforms | macOS 13+ | macOS 13+ |
| Permissions | Accessibility | Accessibility |
| How you pick a place | Hold the trigger, point at the radial menu, see a preview; or trigger plus a key; drag-to-edge snapping | A key or a NORMAL sequence per command; no pointer gesture, no preview |
| Actions | Halves, quarters, thirds, fourths, maximize, almost maximize, centre, grow and shrink by edge, move, undo, initial frame, stash, cycles, custom frames, focus by direction | Named positions, proportional frames, display moves, focus by direction, minimize, restore, close, native full screen, placement rules, opt-in tiling |
| Scripting | `loop://` URLs from a shell or AppleScript | `flash window move …` from any program; mappings run any argv |
| Configuration | Settings window; themes for the menu and preview | One TOML file, live reload, `flash config check` |
| Maintenance | 1.4.2, January 2026; active | 1.1.0, October 2026 |

## Where Loop is stronger

- **The pointer and a preview.** The radial menu turns a direction of the
  mouse into a window frame, and the preview shows it before anything
  moves. Flash moves the window the moment the key lands and has no
  preview.
- **A held trigger key.** Loop's trigger can be a single modifier, even the
  right Option or right Command alone. Flash's chords name a modifier, not
  which side of the keyboard it sits on.
- **Relative actions.** Grow or shrink one edge, move by a step, larger and
  smaller keeping the aspect ratio, undo, back to the initial frame. Flash's
  `window move` sets a frame; it has no grow, shrink, nudge or undo for a
  floating window (`tile resize` works only on tiled ones).
- **Cycles and stash.** One combination steps through several frames, and
  stashed windows wait at a screen edge until you hover. Neither exists in
  Flash.
- **Themes.** Colours, shapes and the preview's border are yours to set.

## Where Flash is stronger

- **Placement that stays.** A window in `lefthalf` keeps that layout when
  displays come and go and returns to its own display when it reconnects
  ([display changes](../windows.md#display-changes)).
- **Placement rules.** `[[window_rules]]` put an app's windows where they
  belong as they open, once, and then leave them to you.
- **No mouse needed, ever.** Every action is a key, a NORMAL sequence or a
  layer, next to hints, the window switcher and `window focus --direction`.
- **One file for windows and everything else**, in your dotfiles, with
  `flash config check` before you save.

## Flash features you might like

- A [layer](../layers.md) behind one chord gives single letters to every
  slot, which is the closest Flash comes to Loop's trigger plus a key.
- `window move --x=5% --y=5% --width=90% --height=90%` is an almost
  maximize; any proportional frame is a custom one.
- `window move --screen=+1` and `--screen=-1` walk the displays, keeping
  the window's slot.
- `window switch` (`:ls`) lists every window with a hint label, and
  `window last` flips between the two most recent.

## Moving from Loop

| Loop | Flash |
| --- | --- |
| Trigger + ← / → (left, right half) | `window move --position=lefthalf`, `--position=righthalf` |
| Top and bottom halves, quarters | `--position=tophalf`, `bottomhalf`, `topleft`, `topright`, `bottomleft`, `bottomright` |
| Thirds and two thirds | `window move --x=0% --y=0% --width=33.333% --height=100%`, `--width=66.667%` |
| Horizontal fourths | `--width=25%` with `--x=0%`, `25%`, `50%`, `75%` |
| Maximize, almost maximize | `--position=maximized`; `--x=5% --y=5% --width=90% --height=90%` |
| Centre, macOS centre | `--position=centered` resizes to 70 % by 80 % and centres; there is no centre that keeps the size |
| Fullscreen | `window fullscreen` (native) |
| Minimize, hide | `window minimize`; `window restore` brings it back. No hide command |
| Next, previous, left or right screen | `window move --screen=+1` or `--screen=-1` |
| Focus by direction | `window focus --direction=left`, `right`, `up` or `down` |
| Grow, shrink, move, larger, smaller | Not available outside [tiling](../tiling.md) (`tile resize`) |
| Undo, initial frame | Not available |
| Cycles | Not available; give each frame its own key in a layer |
| Stash | Not available |
| Radial menu, preview | Not available |
| `open "loop://direction/right"` | `flash window move --position=righthalf` |

Loop's `ctrl+alt` habits as a one-shot layer: one chord, then one letter,
and the layer is gone.

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]
"ctrl+alt+<space>" = ["flash", "mode", "layer", "--name=loop"]

[mode.layers.loop]
label = "LOOP"
sticky = false

[mode.layers.loop.mappings]
"h" = ["flash", "window", "move", "--position=lefthalf"]
"l" = ["flash", "window", "move", "--position=righthalf"]
"k" = ["flash", "window", "move", "--position=tophalf"]
"j" = ["flash", "window", "move", "--position=bottomhalf"]
"u" = ["flash", "window", "move", "--position=topleft"]
"i" = ["flash", "window", "move", "--position=topright"]
"n" = ["flash", "window", "move", "--position=bottomleft"]
"m" = ["flash", "window", "move", "--position=bottomright"]
"d" = ["flash", "window", "move", "--x=0%", "--y=0%", "--width=33.333%", "--height=100%"]
"f" = ["flash", "window", "move", "--x=33.333%", "--y=0%", "--width=33.334%", "--height=100%"]
"g" = ["flash", "window", "move", "--x=66.667%", "--y=0%", "--width=33.333%", "--height=100%"]
"<return>" = ["flash", "window", "move", "--position=maximized"]
"a" = ["flash", "window", "move", "--x=5%", "--y=5%", "--width=90%", "--height=90%"]
"<tab>" = ["flash", "window", "move", "--screen=+1"]
```

## Using both

They divide the work naturally: keep Loop for the mouse, with its radial
menu, preview, cycles and stash, and use Flash's keys for the frames you
always want. Give them different chords; Flash binds no `ctrl+alt` chord by
default, and `flash resident doctor` lists any Flash hotkey another app
holds. Both write the same window frames: Flash keeps a window that sits in
one of its slots in that layout through display changes, whoever put it
there, and lets go of one moved to any other frame
([display changes](../windows.md#display-changes)). Leave Flash's `[tiling]` off while Loop arranges windows: a
tiled window goes back to its tile after any other tool moves it.

*Checked 2026-10-23 against the Loop
[README](https://github.com/MrKai77/Loop),
[releases](https://github.com/MrKai77/Loop/releases) and
[commit history](https://github.com/MrKai77/Loop/commits/develop), and its
[Homebrew cask](https://formulae.brew.sh/cask/loop).*
