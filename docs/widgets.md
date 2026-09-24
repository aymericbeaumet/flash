# Desktop widgets

A desktop widget is a status format drawn as stacked lines on the desktop:
above the wallpaper, below the Finder's desktop icons and every app window, on
every Space. It is Flash's answer to conky. Widgets use the same language,
values, plugin segments, named sources and `#()` jobs as the
[status bar](status-format.md), and they work whether the bar is on or off.

Widgets are passive. Their windows are click-through, never take keyboard focus
and have no chrome or preferences UI; `link=`, `popup=` and `range=` markers do
nothing in them, and the config loader warns when a widget uses one.

## Quick start

```toml
[widgets.clock]
anchor = "top_right"
font_size = 28
template = """
#[bold]%H:%M
#[nobold,fg=#81A1C1]%A %d %B
"""
```

Each `[widgets.<name>]` table (names use letters, digits, `_` and `-`) is one
widget. Save the file and it appears; set `enabled = false` or delete the table
and it goes away.

## Lines

Every line of `template` is its own tmux status line, laid out at the widget's
width: `#[align=left|centre|right|absolute-centre]`, `fill=` and lists work per
line. Two rules connect the lines:

- colours and attributes carry over a line break, as they would in a terminal;
- alignment does not: each line starts in its left section again.

Blank lines at the top and bottom of the template are dropped; blank lines in
between are kept. `\r\n` line endings work. In a TOML `"""` string, a trailing
backslash joins the next line onto this one and drops that line's leading
whitespace, so long lines can be wrapped in the file without wrapping on
screen:

```toml
template = """
CPU #{flash.plugin.cpu.percent}%% \
 MEM #{flash.plugin.memory.percent}%%
"""
```

As in the bar, write `%%` for a literal percent sign: the template is expanded
by `strftime`.

A multi-line value — a plugin table such as `processes.top_cpu`, a source that
prints several lines — spreads over as many widget lines.

## Values

Everything the bar can show is available, plus:

| Value | Meaning |
| --- | --- |
| `#{flash.widget.name}` | The widget's table name. |
| `#{flash.widget.columns}` | Its width in cells: `columns`, or `max_columns` when the widget sizes itself. A full-width rule is `#{R:─,#{flash.widget.columns}}`. |
| `#{flash.history.<source>}` | The last N numeric outputs of a named source with `history = N`, space-separated, oldest first. |

`history` keeps between 2 and 512 samples, is filled on every successful run
and keeps only outputs that parse as a number. It survives while nothing shows
the source, so a widget that reappears still has its past; changing the
source's definition starts it afresh. It cannot combine with `cycle_interval`.

```toml
[statusbar.sources.load]
command = ["/bin/sh", "-c", "sysctl -n vm.loadavg | awk '{print $2}'"]
interval = 10
history = 30
```

The `processes` plugin publishes conky's `${top}` tables as
`#{flash.plugin.processes.top_cpu}` and `top_mem`; see
[status plugins](status-plugins.md#top-processes).

## Keys

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Show the widget. |
| `template` | — | The status format; required. |
| `screen` | `"primary"` | `"primary"` (the menu-bar display), `"all"`, or a display number counted left to right from 1. A number past the last display shows nothing until that display is connected. |
| `anchor` | `"top_left"` | `top_left`, `top_centre`, `top_right`, `centre_left`, `centre`, `centre_right`, `bottom_left`, `bottom_centre`, `bottom_right`. |
| `gap_x`, `gap_y` | `24` | Points from the anchored edges; ignored along a centred axis. |
| `columns` | `0` | Width in cells; `0` fits the widest line, up to `max_columns`. |
| `max_columns` | `120` | Cap for a widget that sizes itself. |
| `font` | `""` | An installed monospaced font; empty, unknown or proportional falls back to the system monospaced font (with a warning). |
| `font_size` | `13` | Points, 6–200. |
| `line_spacing` | `0` | Extra points between lines. |
| `fg` | `"#D8DEE9"` | Default text colour, `#RRGGBB`. |
| `bg` | `"#2E344000"` | Background, `#RRGGBB` or `#RRGGBBAA`; transparent by default. |
| `border`, `border_size` | `"#00000000"`, `0` | Border colour and width in points. |
| `corner_radius` | `8` | Points. |
| `padding` | `8` | Points between the edge and the text. |
| `interval` | `0` | Seconds between clock refreshes and `#()` re-runs; `0` follows `[statusbar] interval`. |
| `hide_from_capture` | `false` | Ask the window server to leave the widget out of screenshots, recordings and screen sharing. Best effort, as for `[overlay] screen_capture`, which also applies. |

`[widgets.<name>.options]` holds `@options` local to the widget; they override
`[statusbar.options]` of the same name for this widget only.

## Placement

A widget is placed in the part of its display Flash considers usable: the
visible frame (without the Dock) minus the Flash bar's band when the bar
reserves space on that display. It never extends past that frame; a widget
larger than it keeps its top-left corner in view. Widgets follow displays as
they are connected, removed or rearranged, and are drawn at each display's own
scale.

## Refresh and cost

Widgets are evaluated by the status bar's controller, beside the bar: one set
of sources and jobs, one clock deadline on the shared `PollScheduler`, and no
timer of their own. A source shown by the bar and a widget runs once. Each
surface is re-evaluated only when a value it read changed. A job shown by
several surfaces refreshes at the fastest of their intervals, and surfaces
with the same interval share one clock tick.

A widget whose windows are all covered — a maximized or full-screen app over
the desktop — stops refreshing: its sources, jobs and clock no longer count
until a window is visible again. macOS reports that coverage per window; a
widget whose window has never been reported visible is treated as visible, so
a display that does not report occlusion keeps its widgets live.

## Coming from conky

| conky | Flash |
| --- | --- |
| `own_window_type desktop`, `own_window_hints below` | Built in: widgets sit on the desktop below every window. |
| `alignment top_right`, `gap_x`, `gap_y` | `anchor = "top_right"`, `gap_x`, `gap_y` |
| `xinerama_head` | `screen`, a display number from 1, left to right |
| `update_interval 1` | `interval = 1` |
| `use_xft`, `font` | `font`, `font_size` (monospaced) |
| `default_color`, `own_window_colour` | `fg`, `bg` |
| `${color red}…${color}` | `#[fg=red]…#[default]` |
| `${alignr}`, `${alignc}` | `#[align=right]`, `#[align=centre]` |
| `${hr}` | `#{R:─,#{flash.widget.columns}}` |
| `${time %H:%M}` | `%H:%M` |
| `${cpu}`, `${memperc}`, `${fs_used_perc /}` | `#{flash.plugin.cpu.percent}`, `#{flash.plugin.memory.percent}`, `#{flash.plugin.disks.percent}` |
| `${loadavg 1}`, `${uptime_short}` | `#{flash.plugin.cpu.load}`, `#{flash.plugin.cpu.uptime}` |
| `${downspeed}`, `${addr}` | `#{flash.plugin.network.down_bps}`, `#{flash.plugin.network.address}` |
| `${battery_percent}` | `#{flash.plugin.power.percent}` |
| `${top name 1}` … | `#{flash.plugin.processes.top_cpu}` (`top_mem` for `${top_mem}`) |
| `${exec cmd}` | `#(cmd)` |
| `${execi 60 cmd}` | A named source with `interval = 60`, shown as `#{flash.source.<name>}` |
| `template0` (without arguments) | An `@option` fragment in `[statusbar.options]` or `[widgets.<name>.options]`, expanded with `#{E:@name}` |

Temperatures and fan speeds have no public macOS API and are not available.
