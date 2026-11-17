# Flash and eww

[eww](https://github.com/elkowar/eww), Elkowars Wacky Widgets, "is a
standalone widget system made in Rust that allows you to implement your own,
custom widgets in any window manager": windows declared in yuck, a Lisp-like
language, built from GTK widgets (boxes, labels, buttons, sliders, graphs,
images, revealers), styled with SCSS and fed by `defpoll`, `deflisten` and
`defvar` variables that `eww update` can set from outside. Bars, dashboards
and power menus are all eww windows. It is MIT Rust for X11 and Wayland,
about 12,700 stars, v0.6.0 in April 2024, with commits in July 2026. It has
no macOS build. On a Mac, Flash's [bar](../statusbar.md) and
[desktop widgets](../widgets.md) share one template language and one set of
sources, which covers the dashboards made of figures; [Übersicht](uebersicht.md)
is the macOS widget engine for anything drawn.

| | eww | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | X11 and Wayland (layer shell) | macOS 13+ |
| Building blocks | GTK widgets in yuck: layout boxes, labels, buttons, sliders, inputs, images, graphs, circular progress | Text cells with colours, meters and sparklines, in a tmux format |
| Data | `defpoll`, `deflisten`, `defvar`, magic variables (`EWW_CPU`, `EWW_RAM`, `EWW_BATTERY`, `EWW_NET`, `EWW_TEMPS`) | Plugin values, named sources, `#()` jobs, pushed sources |
| Interaction | Buttons, sliders, inputs, hover events, `eww open` and `eww close` | Bar: clicks, hover and pinned popups, hints; widgets are click-through |
| Placement | Any window: anchors, monitor, stacking `fg` or `bg`, reserved space | The top bar band; widgets at desktop level with nine anchors and gaps |
| Configuration | `eww.yuck` and `eww.scss` | TOML, live reload |
| Maintenance | v0.6.0, April 2024; slow | 1.1.0, October 2026 |

## Where eww is stronger

- **Real widgets.** A volume slider, a power menu of buttons, an input that
  runs a search, images and album art: eww draws GTK controls you can use.
  Flash's widgets are text you read, deliberately below every window and
  never clickable.
- **Any shape and any window.** Nested boxes, vertical bars, a dashboard
  in the middle of the screen, opened and closed by a key with `eww open`.
  Flash has one bar band at the top and desktop-level widgets that the
  configuration turns on or off.
- **SCSS and the expression language.** Per-widget classes, transitions,
  JSON access in expressions, `for` loops over a list; Flash's template has
  tmux's conditionals, comparisons and padding, and no loops over data.
- **Temperatures** through `EWW_TEMPS`. macOS keeps them behind the SMC,
  and Flash reads no sensor.

## Where Flash is stronger

- **No daemon of your own to run.** The bar, widgets and popups live in the
  resident with your keys, from one file that reloads on save.
- **The figures come built in**: CPU, memory, disks, network and battery from
  one sandboxed plugin, and processes, calendar and the focused app from
  Flash, sampled only while a surface shows them.
- **`:run-while` is automatic.** A source nothing shows does not run, and a
  widget covered by windows stops refreshing until it is visible again.
- **Popups run programs.** A bar label opens btop, a calendar or any TUI in
  a real terminal, which is where an eww power menu or player would go.

## Flash features you might like

- `@system` in the flashlight lists lock, sleep, restart and log out, and
  asks before the destructive ones: the eww power menu, from the keyboard.
- `flash status set --name=<source> --value=<text>` is `eww update`, and
  `flash status refresh --name=<source>` is `eww poll`
  ([pushed status values](../commands.md#pushed-status-values)).
- A source whose script prints status-format markup (`#[fg=red]`, meters)
  is styled as written, the way generated yuck is in `literal`.
- `hide_from_capture = true` asks macOS to leave a widget out of
  screenshots and screen sharing.

## Moving from eww

| eww | Flash |
| --- | --- |
| `(defpoll time :interval "1s" "date +%H:%M:%S")` | `%H:%M:%S` in the template; time is never polled |
| `(defpoll updates :interval "1h" "…")` | `[statusbar.sources.updates]` with `command` and `interval = 3600` |
| `(deflisten song "…")` | A `#(command)` job, which shows the latest line it printed |
| `(defvar volume "0")`, `eww update volume=40` | A source without a command, `flash status set --name=volume --value=40` |
| `eww poll updates` | `flash status refresh --name=updates` |
| `:run-while` | Built in: only what a visible surface shows runs |
| `EWW_CPU`, `EWW_RAM`, `EWW_DISK`, `EWW_BATTERY`, `EWW_NET` | `#{flash.plugin.sysinfo.cpu_percent}`, `memory_percent`, `disks_percent`, `power_percent`, `network_down_bps` |
| `(defwindow bar :stacking "fg" :exclusive true …)` | `[statusbar]` |
| `(defwindow panel :stacking "bg" :geometry (geometry :anchor "top right" …))` | `[widgets.panel]` with `anchor = "top_right"`, `gap_x`, `gap_y` |
| `:monitor 0`, `"<primary>"` | `screen = 1`, `"primary"` or `"all"` |
| `(progress :value …)`, `(graph :value …)` | `#[meter=W]…#[nometer]`, `#[spark]` over a `history` |
| `(button :onclick "…")` on a bar | `#[range=user\|name]…#[norange]` and `[statusbar.click]` |
| `(eventbox :onhover …)` and a revealer | `#[popup=<name>]…#[nopopup]` on the bar |
| `eww.scss` colours and padding | `fg`, `bg`, `border`, `corner_radius`, `padding`, `font` per widget |
| Sliders, inputs, images, `circular-progress`, `EWW_TEMPS` | Not available |

```toml
[widgets.panel]
template = """
#[fg=#EBCB8B,bold]%A %d %B#[default]#[align=right]%H:%M
CPU #[meter=16]#{flash.plugin.sysinfo.cpu_percent}#[nometer] #{p-3:flash.plugin.sysinfo.cpu_percent}%%
MEM #[meter=16]#{flash.plugin.sysinfo.memory_percent}#[nometer] #{p-3:flash.plugin.sysinfo.memory_percent}%%
NET #[spark]#{flash.plugin.sysinfo.network_down_history}#[nospark]
#{flash.source.now_playing}
"""
anchor = "top_right"
columns = 34
bg = "#2E3440CC"

# Pushed, like a defvar: flash status set --name=now_playing --value="…"
[statusbar.sources.now_playing]
```

Each template line is a widget line; `%%` is a literal percent sign. A
script or a [monitor](../monitors.md) can push `now_playing` whenever it
learns something new, and nothing polls in between.

*Checked 2026-10-23 against the eww [README](https://github.com/elkowar/eww),
its releases, and the [configuration](https://elkowar.github.io/eww/configuration.html)
and [magic variables](https://elkowar.github.io/eww/magic-vars.html) pages.*
