# Flash and Mouseless

[Mouseless](https://mouseless.click) promises "Lightning-fast mouse control
with the keyboard": a coordinate grid overlay you type into, a free mode for
continuous movement, and since October 2026 a label mode in beta that places
a label on each clickable element of the frontmost app. It is closed source
with a public issue tracker, sold as a lifetime or subscription licence for
five machines across macOS, Windows and Linux, with a 14-day trial. Version
1.0.0 shipped in July 2026; previews follow every few weeks.

| | Mouseless | Flash |
| --- | --- | --- |
| License, price | Closed; lifetime or subscription (price shown only in the app's checkout) | MIT, free |
| Platforms | macOS 12+, Windows, Linux (X11, Wayland via Flatpak) | macOS 13+ |
| Permissions | Accessibility, for a low-level keyboard hook and clicks | Accessibility; Automation per browser for tab lists; Screen Recording only for `:screenshot screen` |
| Pointer modes | Coordinate grid with presets and subgrids, free mode, label mode (beta); left/right/middle/back/forward, drag, scroll, double and triple click | Hints, search, keyboard-shaped grid, bisect, pointer mode, drag, select, words, path, sticky |
| Configuration | GUI editor over `config.yaml`; `mouseless://` deep links | One TOML file, live reload, `flash <topic> <action>` CLI |
| Beyond pointing | A browser training app | NORMAL mode, flashlight, status bar, widgets, popups, window placement, plugins |
| Maintenance | 1.0.0, July 2026; previews every 2 to 6 weeks; 325 open issues | 1.0.0, October 2026 |

## Where Mouseless is stronger

- **Cross-platform.** One licence and one config on three operating
  systems.
- **The grid is the product.** Years of work on coordinate entry, presets,
  subgrids and multi-monitor layout; Flash's grid is one of many modes.
- **Free mode** with wheel scrolling and jump-to-edge of a scroll area.
- **Back and forward mouse buttons** are click actions. Flash clicks
  double, triple and middle, and its `history back` and `history forward`
  ask the focused app instead.
- **Licensing is explicit** about offline use and the five-machine limit.

## Where Flash is stronger

- **Labels are the default, not a beta.** Flash has labelled Accessibility
  elements from the start, with search, words, paths and drag on top.
- **Free and open source.**
- **A persistent modal layer** and per-app mappings; Mouseless has modes
  but no per-app configuration documented.
- **Everything after the click.**
- **No licence server.** Mouseless revalidates licences at least every 30
  days; Flash makes no network requests from its core.

## Flash features you might like

- The keyboard-shaped grid: the screen is split like the left half of your
  keyboard, so you press the key where you want to go, then refine
  ([getting started](../getting-started.md)).
- `mouse grid --zoom-to-depth=2` starts two levels deep under the pointer.
- `mouse pointer` is free mode: `hjkl` move, `v` drags, `m` `,` `.` click.
- `mouse position --action=save` and `--action=hints` for saved positions.

## Moving from Mouseless

| Mouseless | Flash |
| --- | --- |
| Overlay (grid) | `["flash", "mouse", "grid"]` |
| Subgrid | Each grid key zooms; `--bisect` for halves |
| Free mode | `["flash", "mouse", "pointer"]` |
| Label mode | `["flash", "mouse", "target"]` |
| Drag, drop | `mouse grid --drag`, `mouse target --drag`, `mouse button --state=down` |
| Right, middle click | `cf` in NORMAL; `mouse button --state=toggle --secondary` or `--middle` |
| `mouseless://toggle-overlay` | `flash mouse grid` from any script |
| `config.yaml` | `~/.config/flash/flash.toml` |

```toml
[mode.all.mappings]
"cmd+shift+alt+space" = ["flash", "mouse", "grid"]
"cmd+shift+space" = ["flash", "mouse", "target"]
```

*Checked 2026-10-14 against
[mouseless.click](https://mouseless.click), its
[FAQ](https://mouseless.click/faq) and
[releases](https://github.com/cymian/mouseless).*
