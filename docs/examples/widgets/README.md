# Desktop widget examples

Three ready-made [desktop widgets](../../widgets.md). Each file is a set of
tables for `~/.config/flash/flash.toml`: Flash reads one configuration file,
so add a file's tables to yours and save. The widgets appear on save and
disappear when their tables are removed or set `enabled = false`.

```sh
cat docs/examples/widgets/system-panel.toml >> ~/.config/flash/flash.toml
flash config_check
```

Appending works while your file does not already define the same tables. TOML
rejects a table defined twice, so if you already have `[plugin.processes]` or
a `[statusbar.sources.<name>]` of the same name, merge the keys into your
table instead. `flash config_check` reports any problem with its line.

## `system-panel.toml`

A conky-style panel in the top-right corner: CPU, memory and disk meters with
0–100 sparklines of the last 20 samples, battery, disk and network rates, the
default-route address, uptime and load, and the five busiest processes by CPU
and by memory. It shows only bundled plugin data and runs no command. The
panel's rows are `#{E:@gauge,…}` and `#{E:@rate,…}` calls to fragments in
`[widgets.system.options]`: edit a fragment once to restyle every row.

## `clock-agenda.toml`

A 56-point clock, the date, this month's calendar (`#{flash.calendar}`) and
today's remaining events, stacked in the top-left corner. A widget has one
font size, so these are three widgets whose `gap_y` values stack them.

The agenda comes from an optional external tool. The example uses
[icalBuddy](https://hasseg.org/icalBuddy/) (`brew install ical-buddy`), which
reads macOS Calendar: its first run makes macOS ask for Calendar access on
Flash's behalf, because the tool runs as Flash's child process (see
[privacy](../../privacy.md)). A commented `command` uses
[khal](https://khal.readthedocs.io/) instead. Without either tool, the
calendar still shows and the agenda stays empty.

## `dev-corner.toml`

A bottom-left corner for development: the tmux session, window and pane of
the attached client (the bundled `tmux` plugin), the branch and number of
changed files of one repository through `#()` shell jobs, and the last five
lines of a log file through a named source. Set `@repo` in
`[widgets.dev.options]` and the log path in `[statusbar.sources.log]` first.
The shell jobs re-run every `interval = 10` seconds, and only while the widget
is visible.
