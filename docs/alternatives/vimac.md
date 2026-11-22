# Flash and Vimac

[Vimac](https://github.com/nchudleigh/vimac) was "Productive macOS
keyboard-driven navigation": hint mode and scroll mode over the
Accessibility tree, triggered by holding Space, written in Swift under
GPL-3. Its README now says "Vimac is now Homerow"; the last code commit was
in April 2021, there are no GitHub releases, no Homebrew cask, and the
project website did not answer when checked. It matters as the open-source ancestor of
[Homerow](homerow.md).

| | Vimac | Flash |
| --- | --- | --- |
| License, price | GPL-3, free, discontinued | MIT, free |
| Platforms | macOS 10.14+ | macOS 13+ |
| Permissions | Accessibility | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot screen` |
| Hints from | Accessibility tree: frontmost window, menu bar, extras, Notification Center | Accessibility tree; tmux panes |
| Pointer modes | Hint mode (click, Shift right-click, Cmd double-click, Option move), scroll mode | Hints, search, grid, bisect, pointer mode, drag, select, words, path, sticky |
| Configuration | Preferences window | One TOML file, live reload, CLI |
| Maintenance | None since 2021 | 1.0.0, October 2026 |

## Where Vimac was stronger

- **Runs on macOS 10.14 to 12** machines that cannot install Flash.
- **GPL source** of a complete, once-popular hint implementation, including
  its "Electron Support" and "Emulate VoiceOver" switches, is useful reading
  for anyone building such a tool.

## Where Flash is stronger

- It is maintained.
- Grid, search, drag, selection, per-app mappings, a persistent NORMAL mode,
  terminal hints, flashlight, bar, widgets, popups and plugins.
- A file instead of preferences, so a setup survives a reinstall.

## Flash features you might like

- Hold-to-activate is not how Flash works, but a single hotkey does the same
  job: `mouse target` shows labels, Escape dismisses.
- Vimac's modifier clicks map to NORMAL prefixes: `cf` right-click, `df`
  double-click, `mf` move the pointer ([normal mode](../normal-mode.md)).
- `mouse menubar` and `mouse notifications` cover the menu bar extras and
  Notification Center surfaces Vimac labelled.

## Moving from Vimac

| Vimac | Flash |
| --- | --- |
| Hold Space for hints | `"cmd+shift+space" = ["flash", "mouse", "target"]` |
| Scroll mode, HJKL | NORMAL mode scroll keys, `scroll target` to choose the area |
| Shift right-click, Cmd double-click, Option move | `cf`, `df`, `mf` in NORMAL; or hold the modifier while typing a label |
| Hint characters, text size | `[hints] keys`, hint appearance keys in `config.default.toml` |
| Forced keyboard layout | `[app] keyboard_layout` |

*Checked 2026-10-14 against the Vimac
[repository](https://github.com/nchudleigh/vimac).*
