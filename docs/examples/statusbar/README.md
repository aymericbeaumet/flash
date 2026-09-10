# Native status strip

The companion [Flash configuration](flash.toml) uses bundled plugin data for
all quota and system popups. No external monitoring application is required.

```text
Cld 53%↻5d Cdx 54%↻5d · CPU  9% MEM 42% DSK 68% NET 1.2M BAT 99%
```

Labels are yellow; metrics are grey. System percentages reserve two digits, capped at 99%,
plus the percent sign. Detail reports retain the true value. NET uses four cells
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
Availability depends on macOS and the hardware. These are selectable, scrollable
terminal-rendered documents, with no extra collector process or monitoring CLI.

Merge the example sections into the existing configuration, preserving personal
mappings and plugin settings. Remove any `[terminal.claude]`, `[terminal.codex]`,
`[terminal.cpu]`, `[terminal.memory]`, `[terminal.disks]`, `[terminal.network]`, and
`[terminal.battery]` definitions from the earlier external-monitor setup; named
terminal definitions take precedence over text popups.

The optional date example retains the existing calcurse calendar. Copy only
`calcurse/` to `~/.config/flash/status/` and create `status/calcurse/notes/` there
if using it. Other sections require no companion files. Paths resolve relative
to the Flash configuration file; `$XDG_CONFIG_HOME/flash` takes precedence.

Hover previews a popup. Either unbound mouse button pins it open; repeated clicks
keep it pinned. Existing left-click actions and links win, with right-click or
Option-left-click available to pin. The configuration has no separate right-click
binding. Focused documents support selection, copying, scrolling, and the shared
terminal-mode mappings. `leave_mode` restores the prior mode and app.

For named process-backed terminals, Command-W hides, Command-R restarts, and
Command-Q quits the child so automatic restart applies. Unnamed fresh shells
end permanently on quit or hide. The native
metric documents have no process to restart.

Feed headlines rotate newest first through the last 24 hours, sliding upward
every 30 seconds while the label stays still. Hover shows the cached excerpt.

See [status popups](../../status-popups.md) and [terminal lifecycle](../../terminal-popups.md).
