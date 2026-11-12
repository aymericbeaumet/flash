# Flash and Moom

[Moom](https://manytricks.com/moom/) is Many Tricks' "Move and zoom
windows": a palette that pops up over a window's green button with up to 61
actions of your own, an on-screen grid you drag across, a keyboard mode,
snap regions, moving and resizing the window under the pointer with
modifier keys held, and saved layouts that put many windows back in place
at once, by hand, from AppleScript or when the display arrangement changes.
Moom 4.6 shipped on 19 August 2026 and needs macOS 10.13 or later. It is
closed source, $15 with a free trial, the licence valid forever with at
least a year of updates, $8 to upgrade from Moom 3; Moom Classic stays on
the Mac App Store.

| | Moom | Flash |
| --- | --- | --- |
| License, price | Closed; $15, upgrades $8 | MIT, free |
| Platforms | macOS 10.13+ | macOS 13+ |
| Permissions | Accessibility | Accessibility |
| Moving one window | Pop-up palette, grid, keyboard mode, snap regions, modifier-hover move and resize, custom actions, chains | Named positions, proportional frames, display moves, focus by direction, minimize, restore, close, native full screen |
| Many windows | Saved layouts, triggered by hand, by display count or configuration, on wake; can launch their apps and hide the others | `[[window_rules]]` place each app's windows once as they open; slots kept through display changes; opt-in tiling |
| Scripting | AppleScript: `apply layout`, `run` a custom action | `flash window move …` from any program |
| Configuration | Settings window | One TOML file, live reload, `flash config check` |
| Maintenance | 4.6, August 2026; regular releases | 1.1.0, October 2026 |

## Where Moom is stronger

- **Saved layouts.** Arrange a dozen windows across three apps once, save
  it, and one key or a display change brings it back; Moom 4 adapts a layout
  to displays of another size and can launch the apps it names. Flash moves
  the focused window. It has no saved layout of many windows, and a script
  of `flash window move` calls is a poor imitation.
- **Triggers from the displays.** "Switching to one display" applying the
  laptop layout is built in. Flash keeps each window's slot through display
  changes, which covers part of it, but it does not rearrange windows into a
  different layout per arrangement.
- **The mouse.** The palette over the green button, dragging a grid,
  snap regions, and moving or resizing any window, even one in the
  background, by holding modifiers and moving the pointer. Flash has none
  of these; modifier-drag is on [tiling's list](../tiling.md#not-yet) for
  tiled windows only.
- **Chains and a keyboard mode.** One action can run several in order, or
  cycle through them; the keyboard mode nudges and resizes with the arrows.
  A Flash mapping runs one command, and there is no window nudge.

## Where Flash is stronger

- **Free and open source**, configured in a file you can diff, share and
  check with `flash config check`.
- **Rules that respect you.** A `[[window_rules]]` entry places an app's
  window once, when it appears, and never fights you after you move it.
- **Focus as well as frames.** `window focus --direction=left`, the window
  switcher with a hint label per window, and `window last` sit next to
  placement.
- **Everything else in the same keys**: hints, NORMAL mode, the
  flashlight, the bar, widgets and popups.

## Flash features you might like

- `[[window_rules]]` with `screen = 1` send an app's new windows to the
  next display as they open, the per-app half of a Moom layout.
- A window in a slot stays in it when you dock, undock or close the lid,
  and returns to its own display when that display comes back
  ([display changes](../windows.md#display-changes)).
- A [monitor](../monitors.md#runs-and-events) on `core:displays.changed`
  runs any command when displays come or go, Moom's AppleScript included.
- A [layer](../layers.md) puts every slot on single letters behind one
  chord, which is what Moom's keyboard mode and custom actions are for.

## Moving from Moom

| Moom | Flash |
| --- | --- |
| A custom action: move and zoom to a frame | `window move --x=…% --y=…% --width=…% --height=…%` on a key |
| Halves, quarters, maximize, centre | `--position=lefthalf` …, `maximized`, `centered` (70 % by 80 %, centred) |
| Move to another display | `window move --screen=+1` or `--screen=-1` |
| Minimize, full screen | `window minimize`, `window fullscreen` |
| Saved layout applied on a display change | Each window keeps its slot through the change; for a different arrangement, keep Moom's layout |
| Saved layout of many windows on a key | Keep Moom, and bind its AppleScript in Flash, as below |
| Per-app placement | `[[window_rules]]` by `bundle_id` and `title_contains` |
| Chains | Not available; a script of `flash window move` calls for the focused window |
| Keyboard mode nudge and resize | Not available; slots and frames on single keys in a layer |
| Grid, snap regions, hover with modifiers | Not available |
| AppleScript `run "My Action"` | `flash window move …` from any shell or script |

Moom's layouts on Flash keys, and Flash's rules for the rest:

```toml
[mode.all.mappings]
"ctrl+alt+cmd+w" = ["osascript", "-e", "tell application \"Moom\" to apply layout \"Work\""]
"ctrl+alt+cmd+h" = ["osascript", "-e", "tell application \"Moom\" to apply layout \"Home\""]
"ctrl+alt+<left>" = ["flash", "window", "move", "--position=lefthalf"]
"ctrl+alt+<right>" = ["flash", "window", "move", "--position=righthalf"]

[[window_rules]]
bundle_id = "com.apple.Terminal"
position = "lefthalf"

[[window_rules]]
bundle_id = "com.apple.Safari"
position = "righthalf"
```

The first `osascript` run asks whether Flash may control Moom (Automation);
macOS attributes it to Flash because Flash starts the command.

## Using both

Moom and Flash fit together better than most pairs on these pages: keep
Moom for saved layouts, the palette, the grid and hover, and let Flash own
the keyboard, calling Moom's layouts as above. Two things need one owner
each. A chord: give a Moom shortcut and a Flash mapping different keys, and
`flash resident doctor` lists any Flash hotkey Moom holds. An app's
placement: a Moom layout that auto-applies on a display change and a
`[[window_rules]]` entry for the same app will both move its window, so
pick one per app. Leave Flash's `[tiling]` off: a tiled window goes back to
its tile after Moom moves it.

*Checked 2026-10-23 against [Moom's page](https://manytricks.com/moom/), its
[release notes](https://manytricks.com/moom/releasenotes/),
[AppleScript help](https://manytricks.com/moom/help/applescript.html) and the
[Moom 4 announcement](https://manytricks.com/blog/?p=6385).*
