# Status strip with terminal popups

The companion [Flash configuration](flash.toml) uses bundled plugin data for
all quota and system popups. No external monitoring application is required.

```text
Cld 53%↻5d Cdx 54%↻5d · CPU  9% MEM 42% DSK 68% NET 1.2M BAT 99%
```

Labels are yellow; metrics are grey. CPU/MEM/DSK percentages reserve two digits,
capped at 99%, plus the percent sign; battery charge can reach 100%.
Detail reports retain the true value. NET uses four cells
for download + upload on the default-route interface, in decimal bytes/second.

AI percentages also cap at 99, with no padding because they change slowly.

Cld/Cdx show the remaining weekly quota and the weekly reset delay. Each has its own popup showing that provider’s session,
weekly, and available model quotas, remaining bars, reset times, and cache age.
Left-click opens that provider’s usage page; right-click pins its popup.
A stale badge becomes a dash (Claude: 20 minutes; Codex: 4 minutes), while
the dashboard explicitly marks retained data as cached. An empty Claude Code
credential requires `/login` in Claude Code before live quotas can return.

CPU/MEM/DSK/NET/BAT hover displays the corresponding bundled plugin’s full
`details` segment: aggregate CPU/GPU and history, memory composition/swap,
volume capacity/I/O, network traffic/routes/addresses, and battery power/health.
Availability depends on macOS and the hardware. Every popup runs in a real PTY.
The system `less` pager displays cached plugin details with selection, copying,
search, and scrolling, without another collector or monitoring CLI.

Merge the example sections into the existing configuration, preserving personal
mappings and plugin settings. Remove any `[terminal.claude]`, `[terminal.codex]`,
`[terminal.cpu]`, `[terminal.memory]`, `[terminal.disks]`, `[terminal.network]`, and
`[terminal.battery]` definitions from the earlier external-monitor setup; named
terminal definitions take precedence over text popups.

The date popup shows the built-in [calendar](../../calendar.md): current and adjacent
months, ISO weeks, date, quarter, and day-of-year information. It has no
appointments or tasks. It uses the same pager as the metric popups. Remove a
`[terminal.date]` definition when using the built-in calendar, because named
terminals take precedence.

The 480-point popup width fits 50 content columns at the standard font and
padding. The pager reserves one footer row. Longer external values wrap, and
taller content scrolls in the pager. Configured commands use their terminal's
`columns` and `rows`; `popup_max_width` limits generated text popups.

Hover previews a popup. Either unbound mouse button pins it open; repeated clicks
keep it pinned. Existing left-click actions and links win, with right-click or
Option-left-click available to pin. The configuration has no separate right-click
binding. Hovered pagers refresh when the collected values change. Focused pagers
hold content and search stable; reopening or Command-R shows the latest collected
data. The shared terminal-mode mappings apply, and `leave_mode` restores the
prior mode and app.

Command-W dismisses a generated pager and removes its private snapshot file;
Command-Q also ends it. Configured commands retain their usual behavior:
Command-R restarts, Command-Q quits, and Command-W hides. Persistent jobs keep
running while hidden and restart after exit; temporary jobs end on quit or hide.
Hidden persistent jobs skip frame extraction, drawing, and cursor blinking.

Feed headlines rotate newest first through the last 24 hours, sliding upward
every 30 seconds while the label stays still. Hover shows the cached excerpt.

See [status popups](../../status-popups.md) and [terminal lifecycle](../../terminal-popups.md).
