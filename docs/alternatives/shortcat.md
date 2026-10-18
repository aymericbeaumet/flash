# Flash and Shortcat

[Shortcat](https://shortcat.app) is "The universal command palette for your
Mac": type what you see, fuzzy-matched over the Accessibility tree, and
labels appear after a configurable delay. It is closed source by chendo,
free while in beta (the expiry was pushed to 2030 in v0.12.1), needs macOS
13+, and had one release in 2025 (v0.12.2, July) after a two-year gap.

| | Shortcat | Flash |
| --- | --- | --- |
| License, price | Closed; free beta | MIT, free |
| Platforms | macOS 13+ | macOS 14+ |
| Permissions | Accessibility | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot` |
| Hints from | Accessibility tree, search first | Accessibility tree, labels first, search as an option |
| Pointer modes | Search, labels after a delay, click/right/double/modifier click, continuous mode (alpha), arrows and scrolling (alpha) | Hints, search, grid, bisect, pointer mode, drag, select, words, path, sticky, multi |
| Beyond pointing | Menu-command search, window switching, emoji with `:` | NORMAL mode, flashlight, status bar, widgets, popups, window placement, plugins |
| Configuration | Settings window | One TOML file, live reload, CLI |
| Maintenance | v0.12.2, July 2025; sparse | 1.0.0, October 2026 |

## Where Shortcat is stronger

- **Search as the primary interaction.** One palette finds buttons, menu
  items, windows (including minimized ones) and emoji. For people who would
  rather type a word than read labels, it is the more direct tool.
- **Minimized and background windows** are reachable from the same palette.
- **Zero configuration** and a lower macOS floor.

## Where Flash is stronger

- **Labels first, search second.** Flash shows labels immediately;
  `--search` types visible text. Shortcat shows labels only after a delay
  (two seconds by default). A 2023 HN comment put it as "It takes a full
  second with Shortcat"; Flash's cold activations measure 9 to 26 ms on an
  M4 Pro ([performance](../performance.md)).
- **Open source, actively released, documented privacy.** Shortcat users
  complained in 2022 that diagnostics collection had no opt-out.
- **A file, a CLI and a modal layer.** Shortcat has no file, CLI, API or
  per-app configuration documented.
- **Grid, pointer mode, drag and selection** for what search cannot reach.
- **Everything after the click** (bar, widgets, popups, plugins).

## Flash features you might like

- `:flashlight @menus print` runs the frontmost app's menu items by search,
  and `@windows` focuses a window by title ([flashlight](../flashlight.md)).
- `:flashlight @emojis.glyphs fire` replaces the `:` emoji search.
- `mouse_target --search` is the seek-and-click, `mouse_bigram` types one
  visible character then a short label.
- `--multi` keeps hints up for several clicks, the continuous mode Shortcat
  marks alpha.

## Moving from Shortcat

| Shortcat | Flash |
| --- | --- |
| Palette hotkey | `["flash", "mouse_target", "--search"]` |
| Labels | `["flash", "mouse_target"]` |
| Menu commands | `["flash", "enter_command_mode", "--input=:flashlight @menus "]` |
| Window switching | `["flash", "enter_command_mode", "--input=:flashlight @windows "]` |
| Emoji `:` | `:flashlight @emojis.glyphs <name>` |
| Continuous mode | `mouse_target --multi` |
| Scrolling (alpha) | NORMAL mode scroll keys |

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target", "--search"]
"cmd+ctrl+alt+space" = ["flash", "enter_command_mode", "--input=:flashlight "]
```

*Checked 2026-10-14 against
[shortcat.app](https://shortcat.app), its
[docs](https://shortcat.app/docs) and
[changelog](https://shortcat.app/changelog-raw).*
