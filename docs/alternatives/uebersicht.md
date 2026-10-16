# Flash and Übersicht

[Übersicht](https://github.com/felixhageloh/uebersicht) lets you "Keep an
eye on what is happening on your machine and in the World": desktop
widgets written as JavaScript modules (JSX or CoffeeScript) that run a
shell command on a `refreshFrequency` and render HTML into a web view
behind your windows. It is GPL-3, macOS 12+, about 5,000 stars, and dormant:
the last release (1.6.82) and commit date from December 2023.

| | Übersicht | Flash widgets |
| --- | --- | --- |
| License, price | GPL-3, free | MIT, free |
| Definition | A JS module per widget: `command`, `refreshFrequency`, `render`, CSS | A `[widgets.<name>]` table with a tmux-format template |
| Rendering | Web view, any HTML and CSS | Native text layers: meters, sparklines, colours, no HTML |
| Data | Shell commands, polled; WebSockets via `init` | Bundled plugins, named sources and `#()` jobs on one scheduler |
| Interaction | Click events with an interaction shortcut and Accessibility access | None: widgets are click-through |
| Permissions | Accessibility for clicks | Flash's Accessibility |
| Maintenance | Dormant since December 2023 | 1.0.0, October 2026 |

## Where Übersicht is stronger

- **Anything HTML can draw**: charts, images, maps, fonts, layouts. Flash
  widgets are stacked status lines.
- **Click-able widgets** and a community collection of hundreds.
- **Live editing** of widget files with instant results.

## Where Flash is stronger

- **Cost.** A web view per widget polling every second is the pattern its
  own issue tracker warns about (one widget at `refreshFrequency: 0` took
  over 60 % CPU). Flash widgets share the bar's scheduler, pause when
  covered or when the display sleeps, and are budgeted at under 5 MB each
  ([performance](../performance.md)).
- **Maintained**, and no JavaScript or CSS to write.
- **The same values as the bar**, from the same plugins, in one file.

## Flash features you might like

- The [widget examples](../examples/widgets/README.md): a system panel, a
  clock and agenda, a dev corner.
- `screen = "all"` draws a widget on every display; anchors place it.
- `#[spark]` sparklines and `#[meter=20]` meters.

## Moving from Übersicht

| Übersicht | Flash |
| --- | --- |
| `command: "top -l 1"` + `render` | `#{flash.plugin.cpu.percent}`, `#{flash.plugin.processes.top_cpu}` |
| `refreshFrequency` | The plugin's cadence; `[statusbar.sources.<name>]` for your own command |
| CSS position | `anchor` and offsets in `[widgets.<name>]` |
| Click handlers | Not available; use a popup or a mapping |
| Charts, images | Not available |

```toml
[widgets.system]
anchor = "top_right"
template = """
CPU #[meter=20]#{flash.plugin.cpu.percent}#[nometer] #[spark]#{flash.plugin.cpu.history}#[nospark]
MEM #[meter=20]#{flash.plugin.memory.percent}#[nometer]
"""
```

*Checked 2026-10-14 against the Übersicht
[README](https://github.com/felixhageloh/uebersicht) and
[site](https://tracesof.net/uebersicht/).*
