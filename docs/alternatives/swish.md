# Flash and Swish

[Swish](https://highlyopinionated.co/swish/) offers "Insanely great window
management" through gestures: "Supercharge your Mac with magical trackpad
gestures". About 30 gestures on title bars, the Dock and the menu bar snap
a window into halves or a 2×2, 3×2 or 3×3 grid, pinch it closed or into full
screen, swipe it down to minimize or across to the display it points at,
and act on browser tabs; a divider between snapped windows resizes them
together. It works with the Magic Trackpad, the Magic Mouse and keyboard
shortcuts. Swish is closed source, by Christian Renninger, $16 for a
licence active on two Macs at a time with a 14-day trial, or in Setapp; it
runs on macOS 12 and later, outside the App Store because it needs
low-level system access. 1.13.3 in September 2026 added macOS 27
compatibility.

| | Swish | Flash |
| --- | --- | --- |
| License, price | Closed; $16, or Setapp | MIT, free |
| Platforms | macOS 12+ | macOS 13+ |
| Permissions | Not listed on its page; distributed outside the App Store for low-level access | Accessibility |
| Input | Trackpad and Magic Mouse gestures; arrow, WASD, IJKL and Dvorak hotkeys | The keyboard: chords, NORMAL sequences, layers; the `flash` CLI |
| Windows | Snap grids, close, full screen, minimize, move between displays and Spaces, group resize by divider | Named positions, proportional frames, display moves, focus by direction, minimize, restore, close, native full screen, placement rules, opt-in tiling |
| Beyond windows | Dock, menu bar and tab gestures | Hints, NORMAL mode, flashlight, status bar, widgets, popups, plugins |
| Configuration | Settings window with a tutorial; each gesture toggled on its icon | One TOML file, live reload, `flash config check` |
| Maintenance | 1.13.3, September 2026 | 1.1.0, October 2026 |

## Where Swish is stronger

- **Your hand is already on the trackpad.** A swipe on a title bar is
  faster than any chord when you were scrolling a moment ago, and Swish's
  gestures need no key at all. Flash is keyboard first and reads no
  gestures.
- **Direction-aware displays.** Swish moves a window to the display it is
  swiped toward, by the displays' physical arrangement. Flash's
  `--screen=+1` walks displays left to right, then top to bottom.
- **Spaces.** Swish sends windows to another Space; macOS gives Flash no
  API for it, so Flash's opt-in [tiling](../tiling.md) uses workspaces of
  its own instead.
- **Several windows at once.** Dragging the divider between snapped windows
  resizes them together; outside tiling, Flash resizes one window at a
  time.
- **A settings window that teaches.** Every gesture has an animation and a
  switch.

## Where Flash is stronger

- **No hand off the keyboard.** Every window action is a key, a NORMAL
  sequence or a layer letter, next to hints that click anything on screen.
- **Layouts that stay.** A window in a slot keeps it through docking,
  undocking and sleep, and goes back to its own display when that display
  returns ([display changes](../windows.md#display-changes)).
- **Rules and focus.** `[[window_rules]]` place an app's windows as they
  open; `window focus --direction=` and `window switch` move between
  windows rather than moving them.
- **Free, open source and in a file.**

## Flash features you might like

- NORMAL's `ctrl+w h` `j` `k` `l` move focus to the window on that side,
  and `ctrl+w q` closes the focused window.
- `mouse dock` puts a hint label on every Dock item, and `mouse menubar` on
  the menus and status items, for the gestures you made there.
- `missioncontrol toggle`, `appwindows toggle` and `desktop toggle` on keys
  ([system surfaces](../commands.md#system-surfaces)).
- Browser tabs in NORMAL: `gt` and `gT` switch, `x` closes, `X` reopens.

## Moving from Swish

| Swish | Flash |
| --- | --- |
| Swipe a title bar into a half | `window move --position=lefthalf`, `righthalf`, `tophalf`, `bottomhalf` |
| 2×2 grid corners | `--position=topleft`, `topright`, `bottomleft`, `bottomright` |
| 3×2 and 3×3 grid cells | Proportional frames: `--x=33.333% --y=0% --width=33.334% --height=50%` and so on |
| Pinch in to close | `window close` (NORMAL `ctrl+w q`) |
| Pinch out to full screen | `window fullscreen`, or `--position=maximized` |
| Swipe down to minimize | `window minimize`; `window restore` brings it back |
| Swipe to another display | `window move --screen=+1` or `--screen=-1` |
| Send to another Space | Not available; with `[tiling]` on, `workspace move_window --name=<workspace>` |
| Divider resizing several windows | `tile resize` with `[tiling]` on; not available otherwise |
| Dock gestures | `mouse dock`; `appwindows toggle`; `app quit` |
| Menu bar gestures | `missioncontrol toggle`, `desktop toggle`, `mouse menubar` |
| Tab gestures | `tab next`, `tab previous`, `tab close` (NORMAL `gt`, `gT`, `x`) |
| Arrow, WASD or IJKL hotkeys | Chords or `<leader>` sequences of your own |

The gestures you use most, as NORMAL `<leader>` sequences (the leader is
`\` by default):

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>h" = ["flash", "window", "move", "--position=lefthalf"]
"<leader>l" = ["flash", "window", "move", "--position=righthalf"]
"<leader>k" = ["flash", "window", "move", "--position=maximized"]
"<leader>j" = ["flash", "window", "minimize"]
"<leader>J" = ["flash", "window", "restore"]
"<leader>f" = ["flash", "window", "fullscreen"]
"<leader>q" = ["flash", "window", "close"]
"<leader>n" = ["flash", "window", "move", "--screen=+1"]
"<leader>m" = ["flash", "missioncontrol", "toggle"]
```

## Using both

Keep Swish: it answers the trackpad and Flash answers the keyboard, and
they do not compete for input. Use whichever is nearer your hand at the
moment; a window Swish snaps and a window Flash moves are the same
Accessibility frame. If Swish's keyboard hotkeys are on, give them chords
Flash does not use; `flash resident doctor` lists any Flash hotkey another
app holds. Leave Flash's `[tiling]` off while Swish arranges windows: a
tiled window goes back to its tile after any other tool moves it.

*Checked 2026-10-23 against [Swish's page](https://highlyopinionated.co/swish/),
its [release notes](https://github.com/chrenn/swish-dl/releases) and its
[Homebrew cask](https://formulae.brew.sh/cask/swish).*
