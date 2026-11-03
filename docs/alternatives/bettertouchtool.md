# Flash and BetterTouchTool

[BetterTouchTool](https://folivora.ai) is the Swiss Army knife of macOS
input: trackpad, Magic Mouse and mouse-button gestures, keyboard shortcuts
and key sequences, a Hyper key, window snapping, a clipboard manager, a
screenshot tool, floating menus and widgets, a launcher, menu bar
customization, Stream Deck and game-pad support, conditional automations and
scripting, all configured in its preferences window. A standard licence is
$15 with two years of updates, a lifetime licence $25, and it is also in
Setapp; the trial lasts 45 days.

Flash overlaps with it on the keyboard side: shortcuts and sequences, window
placement, clipboard history, a launcher and widgets. It has nothing for
trackpad or mouse gestures, and it reads no device but the keyboard.

| | BetterTouchTool | Flash |
| --- | --- | --- |
| Price | $15 (two years of updates) or $25 lifetime; Setapp | Free, MIT |
| Configuration | Preferences window | One TOML file, live reload |
| Input | Trackpad, Magic Mouse, mouse buttons, keyboard, Stream Deck, game pads | Keyboard |
| Keyboard | Shortcuts, press variants, key sequences, Hyper key | Modes, sequences, layers, HYPER, per-app tables |
| Windows | Snapping areas, resize and move actions | Named slots and percentages, focus by direction, a switcher, placement rules, layouts kept through display changes |
| Clipboard | Clipboard manager | History with pins and images, `!clip` |
| Launcher | Spotlight-style search over apps, files, windows and calendar events | The flashlight: apps, tabs, windows, plugins, bangs, answers |
| On-screen UI | Floating menus, HUDs, desktop widgets, menu bar items | Hints, the status bar, desktop widgets, popups |
| Clicking without the mouse | No element hints | Hints on every Accessibility element, the grid, pointer mode |

## Where BetterTouchTool is stronger

- **Every input device.** Gestures, mouse chords, drawn shapes, Stream Deck
  and game pads. Flash only reads keys.
- **Floating menus and HUDs** you design yourself, in a GUI.
- **Conditional automations** across hundreds of predefined actions, without
  writing code.
- **Its Hyper key** remaps Caps Lock below the apps, which Flash does not do.

## Where Flash is stronger

- **Hints.** Click any button, link or field by its label, in every app;
  BetterTouchTool has no equivalent.
- **Modes.** A NORMAL layer of plain keys, entered and left on purpose, with
  INSERT giving every key back to the app.
- **Text configuration.** One file to version, diff and share, and a CLI
  that runs every action.
- **Free and open source.**

## Moving over

Keep BetterTouchTool for gestures and devices; move the keyboard part.

| BetterTouchTool | Flash |
| --- | --- |
| Keyboard shortcut → action | `[mode.all.mappings]` chord, or a NORMAL key |
| Key sequence | A NORMAL sequence (`"gt"`), or a one-shot layer from a chord |
| Window snap actions | `window move --position=…` |
| Clipboard manager | `!clip` ([clipboard](../clipboard.md)) |
| Launcher | `mode flashlight` |
| Floating menu of actions | A [layer](../layers.md) whose label shows in the bar |
| Run a shell script | Any argv as a mapping value, or `:!cmd` |

```toml
[mode.all.mappings]
"cmd+ctrl+v" = ["flash", "mode", "flashlight", "--query=!clip", "--restore-mode"]
"cmd+ctrl+space" = ["flash", "mode", "flashlight"]
"cmd+ctrl+left" = ["flash", "window", "move", "--position=lefthalf"]
"cmd+ctrl+right" = ["flash", "window", "move", "--position=righthalf"]
```

*Checked 2026-10-23 against [folivora.ai](https://folivora.ai) and its
[pricing](https://folivora.ai/buy).*
