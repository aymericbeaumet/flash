# Status strip with popups

The companion [Flash configuration](flash.toml) uses bundled plugin data for
the quota labels and every system popup. The AI usage popup runs
[ccusage](https://ccusage.com), which you install yourself, for example with
`npm i -g ccusage`; every other popup needs no external application.

```text
Cld 53%↻5d Cdx 54%↻5d · CPU  9% MEM 42% DSK 68% NET 1.2M BAT 99%
```

Labels are yellow; metrics are grey. CPU/MEM/DSK percentages reserve two digits,
capped at 99%, plus the percent sign; battery charge can reach 100%.
Detail reports retain the true value. NET uses four cells
for download + upload on the default-route interface, in decimal bytes/second.

AI percentages also cap at 99, with no padding because they change slowly.

Cld/Cdx show the remaining weekly quota and the weekly reset delay. They share
one popup, `ccusage daily --last 3`: the last three days of tokens and cost,
per agent. It is a one-shot report, so each showing runs it afresh and keeps
its table on screen until the popup closes; see
[lifecycles](../../popups.md#lifecycles). Left-click a label to open that
provider’s usage page; right-click pins the popup. A stale badge becomes a
dash (Claude: 20 minutes; Codex: 4 minutes). An empty Claude Code credential
requires `/login` in Claude Code before live quotas can return.

CPU/MEM/DSK/NET/BAT hover displays the corresponding bundled plugin’s full
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

The date popup shows the built-in [calendar](../../calendar.md): current and adjacent
months, ISO weeks, date, quarter, and day-of-year information. It has no
appointments or tasks. It uses the same pager as the metric popups.

The 480-point popup width fits 50 content columns at the standard font and
padding. The pager reserves one footer row. Longer external values wrap, and
taller content scrolls in the pager. Terminal popups use their `size`;
`[popup] max_width` limits text popups.

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
and a finished report such as the AI usage table closes on a key press.
Hidden persistent processes skip frame extraction, drawing, and cursor blinking.

Feed headlines rotate newest first through the last 24 hours, sliding upward
every 30 seconds while the label stays still. Hover shows the cached excerpt.

See [popups](../../popups.md) for kinds, lifecycles and verbs.
