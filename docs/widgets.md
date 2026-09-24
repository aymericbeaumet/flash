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

Add this to `~/.config/flash/flash.toml` and save:

```toml
[widgets.cpu]
anchor = "top_right"
font_size = 16
template = "CPU #[meter=20]#{flash.plugin.cpu.percent}#[nometer] #{flash.plugin.cpu.percent}%%"
```

```text
CPU ███████▍             37%
```

Each `[widgets.<name>]` table (names use letters, digits, `_` and `-`) is one
widget. It appears on save; set `enabled = false` or delete the table and it
goes away. Ready-made panels live in [`examples/widgets`](examples/widgets/README.md).

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
by `strftime`. So is an `#{E:@option}` fragment the template expands, once.
A conditional branch is expanded a second time, as in tmux, so a percent sign
inside `#{?…}` is written `%%%%`; putting that text in an option fragment and
writing `#{?cond,#{E:@fragment},}` avoids the doubling.

A multi-line value — a plugin table such as `processes.top_cpu`, a source that
prints several lines, `#{flash.calendar}` — spreads over as many widget lines.

## Styling

The widget's own box is set by its keys: `fg` is the default text colour,
`bg` the background and `border` the border colour. `bg` and `border` take
`#RRGGBB` or `#RRGGBBAA`, where `AA` is the alpha: `#2E3440CC` is 80% opaque,
`#2E344000` (the default background) fully transparent, so the text sits
directly on the wallpaper. `corner_radius`, `border_size` and `padding` shape
the box.

Inside the template, every tmux style works: `#[fg=…,bg=…]` with ANSI names,
`colourNNN` or `#RRGGBB`, `bold`, `dim`, `italics`, underline variants,
`reverse`, `fill=` for a whole line. A widget has one font and one size, set by
`font` (an installed monospaced font) and `font_size`; for a large clock above
small text, use two widgets and stack them with `gap_y`.

## Placement and multiple displays

`anchor` pins the widget to one of nine points of its display, and `gap_x` /
`gap_y` keep it that many points from the anchored edges (a centred axis
ignores its gap). `screen` picks the display: `"primary"` is the one with the
menu bar, a number counts displays left to right from 1, and `"all"` draws one
copy of the widget on every display. A number past the last display shows
nothing until that display is connected.

A widget is placed in the part of its display Flash considers usable: the
visible frame (without the Dock) minus the Flash bar's band when the bar
reserves space on that display. It never extends past that frame; a widget
larger than it keeps its top-left corner in view. Widgets follow displays as
they are connected, removed or rearranged, and are drawn at each display's own
scale. Two widgets at the same anchor overlap; stack them with different
`gap_y` values.

## Meters, sparklines and rules

Two Flash-only style markers turn numbers into Unicode block drawings. They
are ordinary text afterwards, so they also work in the bar and in popups.

`#[meter=W]` … `#[nometer]` draws the **first number** of the enclosed text as
a bar exactly `W` cells wide (1–200), in eighths of a cell (`▏▎▍▌▋▊▉█`).
`#[meter=W/MAX]` scales to `MAX` instead of 100. Values clamp to `0…MAX`. The
empty part of the bar is spaces, so a `bg=` in the same marker draws the track:

| Format | Draws |
| --- | --- |
| `[#[meter=10]37#[nometer]]` | `[███▊      ]` |
| `[#[meter=10/8]2.5#[nometer]]` | `[███▏      ]` |
| `#[meter=10 fg=green bg=colour236]#{flash.plugin.memory.percent}#[nometer default]` | A green bar on a grey track |

`#[spark]` … `#[nospark]` draws **every number** of the enclosed text as one
of `▁▂▃▄▅▆▇█`, scaled from 0 to the largest of them — the same scale as the
Rust SDK's `sparkline_scaled`. `#[spark=MIN/MAX]` uses a fixed scale and
clamps; with a single number it is a one-cell gauge:

| Format | Draws |
| --- | --- |
| `#[spark]0 1536 48213 20000 3000 100 0#[nospark]` | `▁▁█▃▁▁▁` |
| `#[spark=0/100]12 18 23 40 55 30 20 10 95#[nospark]` | `▁▂▂▃▄▃▂▁▇` |
| `#[spark=0/100]85#[nospark]` | `▆` |
| `#[spark]#{flash.plugin.network.down_history}#[nospark]` | The last 20 download rates |

The drawing replaces all the enclosed text, so labels and units go outside the
markers. Text without a number is left as it was, so a meter over a value that
is not published yet shows nothing rather than an empty bar. Numbers are ASCII
decimals such as `42`, `-3` or `0.75`; a `-` right after a digit is a
separator, not a sign. A value split across several fragments or restyled
inside the markers is read as one text, and the drawing takes the style of its
first part. Only `#[nometer]` ends a meter and only `#[nospark]` a sparkline
(`#[default]` does not); a new `#[meter=…]` or `#[spark…]` starts a new drawing.
A drawing never spans a line break: each line inside the markers is drawn on
its own. A malformed marker — `meter=0`, `meter=201`, `meter=10/0`,
`spark=5/5` — is ignored as a whole, like any invalid tmux style. Inside a
`#{?…}` branch or a template argument, separate style tokens with spaces
(`#[meter=10 fg=green]`), since a comma ends the branch.

A horizontal rule needs no marker: tmux's repeat operator draws
`#{R:─,#{flash.widget.columns}}`, a line of `─` as wide as the widget.

## Template arguments

`#{E:@name,arg1,arg2,…}` expands the option `@name` as a format with its
arguments bound as `#{@1}` … `#{@9}`. It is conky's `templateN` for status
formats: write a row once, call it for each value.

```toml
[widgets.system]
template = """
#{E:@row,CPU,#{flash.plugin.cpu.percent}}
#{E:@row,MEM,#{flash.plugin.memory.percent}}
"""

[widgets.system.options]
"@row" = "#[fg=#88C0D0]#{@1}#[default] #[meter=20]#{@2}#[nometer] #{p-3:@2}%%"
```

Each argument is expanded where the call is written, then bound as text: a
value is never re-expanded inside the template. Arguments split at top-level
commas; a comma inside a nested `#{…}` stays in its argument, and `#,` is a
literal comma. Arguments past the ninth are ignored. Inside a call, `@1`…`@9`
are only that call's arguments — one it was not given is empty — so templates
nest without seeing their caller's. `#{T:@name,…}` also expands `strftime`
codes, as `T:` does. Templates can live in `[statusbar.options]`, shared with
the bar, or in `[widgets.<name>.options]`.

This is a Flash extension. tmux reads `@name,arg1,…` as one option name, and
Flash keeps that reading when `@name` is not set; see
[status format](status-format.md#flash-extensions).

## Data

Everything the bar can show is available. These values suit widgets:

| Value | Meaning |
| --- | --- |
| `#{flash.plugin.cpu.percent}` | Total CPU, integer 0–100. |
| `#{flash.plugin.cpu.history}` | The last 20 CPU totals, oldest first, space-separated. |
| `#{flash.plugin.cpu.load}` | One-minute load average, `3.47`. |
| `#{flash.plugin.cpu.uptime}` | Time since boot, sleep included, `3d 4h`. |
| `#{flash.plugin.memory.percent}`, `history` | Used memory 0–100, and its last 20 samples. |
| `#{flash.plugin.disks.percent}` | Startup-volume usage 0–100. |
| `#{flash.plugin.disks.read_bps}`, `write_bps` | Disk rates in whole bytes per second. |
| `#{flash.plugin.disks.read}`, `write` | The same rates in binary units, `1.5 MiB/s`. |
| `#{flash.plugin.network.down_bps}`, `up_bps` | Default-route rates in whole bytes per second. |
| `#{flash.plugin.network.down_history}`, `up_history` | Their last 20 samples. |
| `#{flash.plugin.network.address}` | First IPv4 address of the default-route interface. |
| `#{flash.plugin.power.percent}` | Battery charge 0–100; empty without a battery. |
| `#{flash.plugin.power.state}` | `charging`, `discharging`, `charged` or `ac`. |
| `#{flash.plugin.processes.top_cpu}`, `top_mem` | The busiest processes by CPU or resident memory, one row each. |
| `#{flash.plugin.tmux.session}`, `window`, `pane` | The attached local tmux client's session, window and pane; empty without one. |
| `#{flash.calendar}` | Today's date, ISO week, day of year and a three-month calendar. |
| `#{flash.source.<name>}` | The output of a [named source](status-format.md#jobs-sources-and-flash-styles). |
| `#{flash.history.<name>}` | The last N numeric outputs of a source with `history = N`, oldest first. |
| `#(command)` | A tmux shell job, re-run every widget `interval`. |
| `#{flash.widget.name}` | The widget's table name. |
| `#{flash.widget.columns}` | Its width in cells: `columns`, or `max_columns` when the widget sizes itself. |

The plugin values are described in
[status plugins](status-plugins.md#raw-numeric-segments); an empty value means
unknown, not zero, so a meter over it draws nothing. `[plugin.processes]
top_count = 5` sets the rows of each process table (1–20); the plugin samples
processes only while a surface shows one of the tables
([top processes](status-plugins.md#top-processes)).

A named source runs a command on its own cadence. `history = N` (2–512) keeps
the last N outputs that parse as a number; it survives while nothing shows
the source, so a widget that reappears still has its past, and changing the
source's definition starts it afresh. It cannot combine with `cycle_interval`.

```toml
[statusbar.sources.load]
command = ["/bin/sh", "-c", "sysctl -n vm.loadavg | awk '{print $2}'"]
interval = 10
history = 30
```

```text
load #[spark]#{flash.history.load}#[nospark] #{flash.source.load}
```

## Keys

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Show the widget. |
| `template` | — | The status format; required. |
| `screen` | `"primary"` | `"primary"` (the menu-bar display), `"all"`, or a display number counted left to right from 1. |
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

## Refresh and cost

Widgets are evaluated by the status bar's controller, beside the bar: one set
of sources and jobs, one clock deadline on the shared `PollScheduler`, and no
timer of their own. A source shown by the bar and a widget runs once. Each
surface is re-evaluated only when a value it read changed. A job shown by
several surfaces refreshes at the fastest of their intervals, and surfaces
with the same interval share one clock tick. Meters and sparklines are drawn
while the document is parsed, with no extra evaluation.

A widget whose windows are all covered — a maximized or full-screen app over
the desktop — stops refreshing: its sources, jobs and clock no longer count
until a window is visible again. macOS reports that coverage per window; a
widget whose window has never been reported visible is treated as visible, so
a display that does not report occlusion keeps its widgets live. The budget
and how to measure it are in [performance](performance.md#widgets-budget).

## Coming from conky

| conky | Flash |
| --- | --- |
| `own_window_type desktop`, `own_window_hints below` | Built in: widgets sit on the desktop below every window. |
| `alignment top_right`, `gap_x`, `gap_y` | `anchor = "top_right"`, `gap_x`, `gap_y` |
| `xinerama_head` | `screen`, a display number from 1, left to right |
| `update_interval 1` | `interval = 1` (plugin values update as they are published) |
| `use_xft`, `font` | `font`, `font_size` (monospaced; one per widget) |
| `default_color`, `own_window_colour`, `own_window_argb_value` | `fg`, `bg = "#RRGGBBAA"` |
| `${color red}…${color}` | `#[fg=red]…#[default]` |
| `${alignr}`, `${alignc}` | `#[align=right]`, `#[align=centre]` |
| `${hr}` | `#{R:─,#{flash.widget.columns}}` |
| `${time %H:%M}` | `%H:%M` in the template (it is `strftime`-expanded), or `#{T:@clock}` for an option fragment |
| `${cpu}` | `#{flash.plugin.cpu.percent}` |
| `${cpubar}` | `#[meter=20]#{flash.plugin.cpu.percent}#[nometer]` |
| `${cpugraph}` | `#[spark]#{flash.plugin.cpu.history}#[nospark]` |
| `${memperc}`, `${membar}` | `#{flash.plugin.memory.percent}`, `#[meter=20]#{flash.plugin.memory.percent}#[nometer]` |
| `${fs_used_perc /}`, `${fs_bar /}` | `#{flash.plugin.disks.percent}`, `#[meter=20]#{flash.plugin.disks.percent}#[nometer]` |
| `${diskio_read}`, `${diskio_write}` | `#{flash.plugin.disks.read}`, `#{flash.plugin.disks.write}` |
| `${loadavg 1}`, `${uptime_short}` | `#{flash.plugin.cpu.load}`, `#{flash.plugin.cpu.uptime}` |
| `${downspeed}`, `${downspeedgraph}` | `#{flash.plugin.network.down_bps}`, `#[spark]#{flash.plugin.network.down_history}#[nospark]` |
| `${addr}` | `#{flash.plugin.network.address}` |
| `${battery_percent}`, `${battery_bar}` | `#{flash.plugin.power.percent}`, `#[meter=20]#{flash.plugin.power.percent}#[nometer]` |
| `${top name 1}` … | `#{flash.plugin.processes.top_cpu}` (`top_mem` for `${top_mem}`), `[plugin.processes] top_count` rows |
| `${exec cmd}` | `#(cmd)` |
| `${execi 60 cmd}` | `[statusbar.sources.x]` with `command = [...]` and `interval = 60`, shown as `#{flash.source.x}` |
| `${execgraph …}` | A source with `history = N`, drawn with `#[spark]#{flash.history.x}#[nospark]` |
| `${tail f 5}` | A source with `command = ["tail", "-n5", "f"]` |
| `${if_…}…${else}…${endif}` | `#{?condition,then,else}`, with `#{==:…}`, `#{>:…}` and `#{m:…}` comparisons |
| `template0` … `${template0 a b}` | An `@option` fragment called as `#{E:@t,a,b}`, reading `#{@1}` and `#{@2}` |

## Out of scope

- **Lua and Cairo drawing.** Widgets draw text in cells. For anything computed,
  write a source script that prints status format markup: colours, meters and
  sparklines included.
- **Several fonts or sizes in one widget.** Use one widget per font size and
  stack them with `gap_y`.
- **Mouse input.** Widgets are click-through; links, popups and ranges do
  nothing.
- **Images and pixel reads.** Flash never reads the screen and draws no
  images.
- **Temperatures and fan speeds.** macOS has no public API for them.
