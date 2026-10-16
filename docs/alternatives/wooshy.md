# Flash and Wooshy

[Wooshy](https://wooshy.app), by the author of kindaVim, "searches the whole
macOS UI, including the Dock, the left menu bar and the right status bar,
and clicks." It is closed source Swift for macOS 14.6+, full-featured for
free "but takes some random naps", with a $3.88/month or $46.28/year
subscription to remove them. Version 51 shipped on 2026-10-08, after about
twenty releases since January 2025.

| | Wooshy | Flash |
| --- | --- | --- |
| License, price | Closed; free with naps, or subscription | MIT, free |
| Platforms | macOS 14.6+ (older builds for Ventura and Monterey) | macOS 14+ |
| Permissions | Accessibility | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot` |
| Targets | Fuzzy search over the whole UI: windows, Dock, menu bar, status bar; role search; `*` lists all | Labels over the focused window; `--scope=screen` for every app; `mouse_dock`, `mouse_menubar`, `mouse_notifications` |
| Actions | Click, Ctrl-Return right-click, Fn-Return double-click, modifier clicks, move without clicking, ⌘C copies the target's text | Click, right, double, move, drag, select, words, path, sticky, multi |
| Integration | Karabiner `WsInputStatus` variable, `wooshy://` URL scheme, distributed notifications | `flash <verb>` CLI, `[mode.apps]` per bundle |
| Beyond pointing | The Inspector shows which terms reach an element | NORMAL mode, flashlight, status bar, widgets, popups, window placement, plugins |
| Maintenance | Version 51, October 2026; monthly | 1.0.0, October 2026 |

## Where Wooshy is stronger

- **Search across the whole UI at once.** Dock, menu bar, status items and
  every window are one search space; Flash labels one surface per command.
- **Role search and `*`** list everything an app exposes, which is also a
  good debugging tool.
- **Yank the target's text or metadata** with ⌘C.
- **Designed for fast typists** and for pairing with kindaVim, by the same
  author, so Vim keys drive the result list.
- **Karabiner integration** through a shared variable.

## Where Flash is stronger

- **Labels and a grid.** Wooshy has neither (a label-mode request, #146, is
  open), so an unlabeled control or a canvas is out of reach.
- **Free, open source, no naps.**
- **A file, a CLI and per-app tables**; Wooshy configures through its GUI
  and Karabiner conditions.
- **A built-in modal layer** rather than a separate Vim app.
- **Everything after the click.**

## Flash features you might like

- `mouse_target --search` is Wooshy's input over the focused window, and
  `mouse_target --scope=screen` labels every app on the screen.
- `:flashlight @menus` finds menu items by name; `@windows` focuses by
  title; `@system.actions` lists system actions ([flashlight](../flashlight.md)).
- `mouse_target --words --select` selects text between two words, where
  Wooshy would yank one element's text.
- NORMAL's `y` copies immediately.

## Moving from Wooshy

| Wooshy | Flash |
| --- | --- |
| Open the input | `["flash", "mouse_target", "--search"]` in the focused window; `mouse_target --scope=screen` labels every app |
| Dock, menu bar, status bar targets | `mouse_dock`, `mouse_menubar`; status bar items through `mouse_menubar` |
| Ctrl-Return right-click | `mouse_bigram --secondary`, or `cf` in NORMAL |
| Shift-Cmd-Return move only | `mouse_target --move` |
| ⌘C yank | `--words --select` then `y` |
| `wooshy://openTheInput` | `flash mouse_target --search` |
| kindaVim for Vim keys | NORMAL mode ([normal mode](../normal-mode.md)) |

```toml
[mode.all.mappings]
"cmd+shift+space" = ["flash", "mouse_target", "--search"]
"cmd+shift+alt+space" = ["flash", "mouse_target", "--scope=screen"]
```

*Checked 2026-10-14 against
[wooshy.app](https://wooshy.app), its
[docs](https://docs.wooshy.app) and the
[release notes](https://github.com/godbout/Wooshy.blahblah).*
