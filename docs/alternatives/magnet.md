# Flash and Magnet

[Magnet](https://magnet.crowdcafe.com) promises to "Organize Your
Workspace": drag a window to a corner for a quarter, to a side for a half,
to the top to maximize and to the bottom for thirds, or press a
`ctrl+option` shortcut for the same tiles. It has been "Improving
workspaces since 2012", is sold only on the Mac App Store by Bootcode
(Crowd Cafe) for $4.99, with a perpetual licence, no subscription and no
in-app purchases, and supports up to six external displays and vertical
ones. Version 3.0.7 shipped in April 2025 and needs macOS 13 or later. It is
closed source.

| | Magnet | Flash |
| --- | --- | --- |
| License, price | Closed; $4.99 on the App Store, perpetual | MIT, free |
| Platforms | macOS 13+ | macOS 13+ |
| Permissions | Accessibility | Accessibility |
| Triggers | Drag to trigger areas, `ctrl+option` shortcuts, the green button menu, the menu bar icon | Keys, NORMAL sequences and layers; the `flash` CLI |
| Tiles | Halves, quarters, thirds, two thirds, maximize, centre, restore, next and previous display, custom commands | Halves, quarters, maximize, centred, any proportional frame, display moves, minimize, restore, close, native full screen, placement rules, opt-in tiling |
| Sync | iCloud, optional | Your dotfiles |
| Configuration | Settings window | One TOML file, live reload, `flash config check` |
| Maintenance | 3.0.7, April 2025 | 1.1.0, October 2026 |

## Where Magnet is stronger

- **Dragging works.** Drop a window on an edge or a corner and it snaps;
  Flash has no snap areas, and a window you drag stays where you drop it.
- **The green button and the menu bar.** Every command is a click away for
  the times your hands are on the mouse.
- **Restore.** `ctrl+option+delete` puts back a window Magnet moved.
  Flash's `window restore` unminimizes a window; no command returns a window
  to its previous frame.
- **iCloud sync** of your settings, and nothing to learn: the defaults are
  sensible on the first day.

## Where Flash is stronger

- **Free and open source**, with the configuration in a file you can keep
  in your dotfiles and check with `flash config check`.
- **Layouts that survive the dock.** A window in `lefthalf` stays in the
  left half of whatever display macOS moves it to, and goes back to its own
  display when it reconnects
  ([display changes](../windows.md#display-changes)).
- **Rules and focus.** `[[window_rules]]` place an app's windows as they
  open, and `window focus --direction=left` moves between windows, which
  Magnet does not do.
- **Everything else on the same keys**: hints, NORMAL mode, the window
  switcher, the bar.

## Flash features you might like

- `window move --x=0% --y=0% --width=66.667% --height=100%` and any other
  proportional frame, so the tile you always wanted needs no custom command
  window.
- `window move --screen=+1` sends a window to the next display and keeps
  its slot there.
- NORMAL's `ctrl+w h` `j` `k` `l` move focus between windows, Vim-style,
  and `window switch` (`:ls`) lists every window with a hint label.
- `window minimize`, `window restore` and `window fullscreen` on keys of
  your own.

## Moving from Magnet

Magnet's default shortcuts, one by one:

| Magnet | Flash |
| --- | --- |
| `ctrl+option+←` / `→`, left and right half | `window move --position=lefthalf`, `--position=righthalf` |
| `ctrl+option+↑` / `↓`, top and bottom half | `--position=tophalf`, `--position=bottomhalf` |
| `ctrl+option+U` / `I` / `J` / `K`, quarters | `--position=topleft`, `topright`, `bottomleft`, `bottomright` |
| `ctrl+option+D` / `F` / `G`, thirds | `--x=0%`, `33.333%` or `66.667%` with `--y=0% --width=33.333% --height=100%` |
| `ctrl+option+E` / `T`, two thirds | `--x=0%` or `33.333%` with `--y=0% --width=66.667% --height=100%` |
| `ctrl+option+return`, maximize | `--position=maximized` |
| `ctrl+option+C`, centre | `--position=centered` (resizes to 70 % by 80 %) |
| `ctrl+option+delete`, restore | Not available |
| `ctrl+option+cmd+←` / `→`, previous and next display | `window move --screen=-1`, `--screen=+1` |
| Trigger areas, the green button menu | Not available |
| Custom commands | A proportional frame on a key of your own |
| iCloud sync | Keep `flash.toml` in your dotfiles |

The same chords, so your hands do not have to relearn them:

```toml
[mode.all.mappings]
"ctrl+alt+<left>" = ["flash", "window", "move", "--position=lefthalf"]
"ctrl+alt+<right>" = ["flash", "window", "move", "--position=righthalf"]
"ctrl+alt+<up>" = ["flash", "window", "move", "--position=tophalf"]
"ctrl+alt+<down>" = ["flash", "window", "move", "--position=bottomhalf"]
"ctrl+alt+u" = ["flash", "window", "move", "--position=topleft"]
"ctrl+alt+i" = ["flash", "window", "move", "--position=topright"]
"ctrl+alt+j" = ["flash", "window", "move", "--position=bottomleft"]
"ctrl+alt+k" = ["flash", "window", "move", "--position=bottomright"]
"ctrl+alt+d" = ["flash", "window", "move", "--x=0%", "--y=0%", "--width=33.333%", "--height=100%"]
"ctrl+alt+f" = ["flash", "window", "move", "--x=33.333%", "--y=0%", "--width=33.334%", "--height=100%"]
"ctrl+alt+g" = ["flash", "window", "move", "--x=66.667%", "--y=0%", "--width=33.333%", "--height=100%"]
"ctrl+alt+e" = ["flash", "window", "move", "--x=0%", "--y=0%", "--width=66.667%", "--height=100%"]
"ctrl+alt+t" = ["flash", "window", "move", "--x=33.333%", "--y=0%", "--width=66.667%", "--height=100%"]
"ctrl+alt+<return>" = ["flash", "window", "move", "--position=maximized"]
"ctrl+alt+c" = ["flash", "window", "move", "--position=centered"]
"ctrl+alt+cmd+<left>" = ["flash", "window", "move", "--screen=-1"]
"ctrl+alt+cmd+<right>" = ["flash", "window", "move", "--screen=+1"]
```

Turn the matching Magnet shortcuts off (or record new ones) before you save
this, so each chord has one owner; `flash resident doctor` lists any Flash
hotkey another app still holds.

## Using both

Many people will want both: Magnet for dragging, the green button and
restore, Flash for the keyboard. Clear Magnet's shortcuts and keep its
trigger areas, or keep Magnet's shortcuts and give Flash a layer instead of
the `ctrl+option` chords. Leave Flash's `[tiling]` off: a tiled window goes back to its tile
after Magnet moves it.

*Checked 2026-10-23 against [magnet.crowdcafe.com](https://magnet.crowdcafe.com)
and Magnet's [App Store listing](https://apps.apple.com/us/app/magnet/id441258766);
the default shortcuts against [The Sweet Setup](https://thesweetsetup.com/magnet-brings-windows-10-style-window-management-to-macos/)
and [DefKey](https://defkey.com/magnet-macos-shortcuts).*
