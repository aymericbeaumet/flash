# Flash and Raycast

[Raycast](https://www.raycast.com) is "Your shortcut to everything": a
launcher with clipboard history, snippets, window management, notes, AI and
an extension store with thousands of entries. It is closed source, free for
the core, with Pro at $10/month (AI, cloud sync, custom themes). Raycast 2,
released in 2026 and updated weekly, requires macOS Tahoe and Apple Silicon
and is built on native shells around system web views. It is not a hint
tool; the overlap with Flash is the flashlight, window placement and
clipboard history.

| | Raycast | Flash |
| --- | --- | --- |
| License, price | Closed; free core, Pro $10/month | MIT, free |
| Platforms | macOS 26 on Apple Silicon, Windows, iOS | macOS 13+, Intel and Apple Silicon |
| Permissions | Accessibility for windows and menu search; Screen Recording optional for AI screen awareness | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot screen` |
| Launcher | Apps, files, calculator, extensions, AI chat | flashlight: apps, files, browser tabs, tmux windows, emoji, math, units, currency, plugin data |
| Hints, modes | None | Hints in every app, NORMAL mode |
| Windows | Built-in window management; custom commands need Pro | Named positions, proportional frames, placement rules, directional focus |
| Clipboard | History, 3 months free | Built-in history, 1000 entries by default, local |
| Extensions | TypeScript and React store, "thousands" | Plugins in any language over JSON lines, most sandboxed; a Rust SDK |
| Configuration | GUI; cloud sync in Pro | One TOML file in your dotfiles |
| Footprint | 350 to 450 MB of memory for v2, by Raycast's own figure | A resident Swift app plus plugin child processes; see [performance](../performance.md) |

## Where Raycast is stronger

- **The extension store.** Thousands of ready integrations (Jira, GitHub,
  Spotify, Notion, calendars) with a polished UI. Flash's bundled plugins
  number eleven, and third-party plugins are pinned by commit, not browsed.
- **AI, notes, snippets, quicklinks, dictation**, all in one product with
  design attention Flash does not have.
- **Window management with a GUI** and cloud-synced settings.
- **A company and a release every week.**

## Where Flash is stronger

- **It acts on what is on screen.** Raycast launches things; Flash clicks
  the button in front of you, and keeps a modal layer on top of every app.
- **Free, open source, local.** No account, no subscription, no sync, and
  every network destination listed on the [privacy page](../privacy.md).
- **Runs on macOS 13 and on Intel Macs.**
- **A bar and widgets** on the desktop, fed by the same plugins as search.
- **Dotfiles.** One file, validated in CI, instead of a GUI and a cloud.

## Flash features you might like

- `:flashlight` with `1234 euros in dollars`, `@emojis fire`,
  `@menus`, and DuckDuckGo-style bangs for browser history
  ([flashlight](../flashlight.md)).
- `window move --position=` and placement rules by app and title.
- Clipboard history with pins, searched and pasted with `!clip` in the
  flashlight and listed on the `/clipboard` help page.
- Terminal popups: a bar segment that opens btop or newsboat under it.

## Moving from Raycast

| Raycast | Flash |
| --- | --- |
| Launcher hotkey | `["flash", "mode", "flashlight"]` |
| Calculator, unit conversion | Type the expression in flashlight |
| Emoji picker | `:flashlight @emojis ` |
| Window management commands | `window move --position=<name>` mappings |
| Clipboard history | `!clip` in the flashlight ([moving over](../clipboard.md#moving-from-maccy-or-clipy)) |
| Switch windows | `:flashlight @windows`, `window focus --direction=` |
| Extensions | Bundled plugins, or write one ([cookbook](../plugin-cookbook.md)) |
| AI, notes, snippets | Keep Raycast, or another tool |

Running both is common: Raycast as the launcher, Flash for hints, modes and
the bar. Give them different hotkeys.

*Checked 2026-10-14 against
[raycast.com](https://www.raycast.com), its
[pricing](https://www.raycast.com/pricing) and
[changelog](https://www.raycast.com/changelog).*
