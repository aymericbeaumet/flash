# Status strip with popups

The companion [Flash configuration](flash.toml) uses bundled plugin data for
every system popup. Every name on the bar is template markup (`#[label]`):
the feed, the quotas, and CPU/MEM/DSK/NET/BAT. Each plugin or source prints
only the value beside that name. The hover is the `[popup.*]` the template
names. The AI usage popup runs
[tokscale](https://github.com/junhoyeo/tokscale), and the feed hover runs
newsboat; you install both yourself. Every system popup needs no external
application.

```text
aggr Headline (example.com) · Cld 53%↻5d Cdx 54%↻5d Grk 9%↻1d · CPU  9% MEM 42% DSK 68% NET 1.2M BAT 99%
```

Names are yellow; values are grey. `p-3` reserves two digits for a
CPU/MEM/DSK percentage, capped at 99%, plus the percent sign. Battery charge
can reach 100% and is not padded. `p-4` reserves NET's four cells.
Detail reports retain the true value. NET is download plus upload on the
default-route interface, in decimal bytes per second.

The example metrics are unpadded and capped at 99 by the command that prints
them, because they change slowly.

Cld/Cdx/Grk, aggr, and CPU/MEM/DSK/NET/BAT use `#[label]`. The grey value
beside each one is whatever `#{flash.source.cld}` or `#{flash.plugin.cpu.label}`
prints. Declare the quota sources with
your own commands. They share one popup, tokscale's own TUI: tokens and cost
by day and model, with every subscription's session, weekly and model quotas
under its Usage tab. The popup is persistent, so hovering shows it at once and
keeps the tab you left it on; tokscale's `autoRefreshEnabled` setting keeps it
current. Left-click a label to open that provider’s usage page; right-click
pins the popup. Flash does not fetch the quotas. A source that prints an empty
string keeps its previous value.

CPU/MEM/DSK/NET/BAT hover is the popup wrapped around that name. The example
points each one at the bundled plugin’s full
`details` segment: aggregate CPU/GPU and history, memory composition/swap,
volume capacity/I/O, network traffic/routes/addresses, and battery power/health.
Availability depends on macOS and the hardware. Every popup runs in a real PTY.
The system `less` pager displays cached plugin details with selection, copying,
search, and scrolling, without another collector or monitoring CLI.

Merge the example sections into the existing configuration, preserving personal
mappings and plugin settings. Popups share one namespace: each `[popup.<name>]`
is either a text popup (`text`) or a terminal popup (`command`), so a later
file's `[popup.cpu]` replaces this one outright. To show a monitor such as
`btop` instead of the bundled details, declare it once and wrap every system
label in the same marker:

```toml
[popup.btop]
command = ["btop"]
size = "90%x85%"
persistent = true
```

The date popup shows the built-in [calendar](../../calendar.md): the previous,
current and next months side by side with ISO weeks, the day's progress through
its week, month, quarter and year, and time-zone, daylight-saving and moon
information. It has no appointments or tasks. It uses the same pager as the
metric popups.

Text popups fit their widest line between `[popup] min_width` (480 points,
50 content columns at the standard font and padding) and `max_width` (750
points, 80 columns, room for the calendar). The pager reserves one footer row.
Longer external values wrap, and taller content scrolls in the pager. Terminal
popups use their `size`.

Hover previews a popup. Either unbound mouse button pins it open; repeated clicks
keep it pinned. Existing left-click actions and links win, with right-click or
Option-left-click available to pin. The configuration has no separate right-click
binding. Hovered pagers refresh when the collected values change. Focused pagers
hold content and search stable; reopening or Command-R shows the latest collected
data. The shared terminal-mode mappings apply, and `leave_mode` restores the
prior mode and app.

Command-W dismisses a text popup and removes its private snapshot file;
Command-Q also ends it. Terminal popups retain their usual behavior:
Command-R restarts, Command-Q quits, and Command-W hides. Persistent processes
keep running while hidden and restart after exit; fresh ones end on quit or hide,
and a finished one-shot report closes on a key press.
Hidden persistent processes skip frame extraction, drawing, and cursor blinking.

Feed headlines rotate newest first through the last 24 hours, sliding upward
every 30 seconds. The `#[label]aggr` name stays still because the template
writes it. Hover runs `[popup.feed]`. Bind `#{flash.plugin.feed.summary}`
instead when a headline should carry its own excerpt popup.

See [popups](../../popups.md) for kinds, lifecycles and verbs.
