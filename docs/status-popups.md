# Native status detail popups

Flash renders bundled plugin data directly in selectable, scrollable terminal
surfaces. The [example configuration](examples/statusbar/README.md) requires no
external monitoring CLI, dashboard service, or additional authentication store.

Cld and Cdx have separate `claude` and `codex` popups using
`aiproviders.claude_details` and `aiproviders.codex_details` respectively. They show the
available session/week/model quotas, remaining bars, reset delays, and cache age.
Missing data is marked unavailable; stale data is marked cached. Each provider
keeps its own usage-page link for left-click; right-click pins the corresponding view.

The system regions use `cpu.details`, `memory.details`, `disks.details`,
`network.details`, and `power.details`. Their collection remains in Flash-managed
plugins. Detail values keep their actual precision, while system status percentages
reserve two digits capped at 99 and NET uses a compact four-cell byte rate.
AI quota values have no padding.

These documents support text interaction through Flash’s existing terminal
surface. They do not launch a shell or external TUI. Showing less information
when macOS does not expose a metric is preferable to introducing another monitor
or privileged helper. The independent configured terminal feature remains
available for workflows that need a real interactive process.

The optional existing calcurse date popup is separate from the monitoring views.
See [status plugin ownership](status-plugins.md) and
[terminal popup behavior](terminal-popups.md).
