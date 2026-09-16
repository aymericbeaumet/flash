# Status detail popups

Every status popup runs in a real PTY terminal. Flash-generated calendar, feed,
and plugin details use the system `less` pager over a private snapshot file
owned by the terminal registry. The existing collectors supply the content;
opening a popup adds no collector or authentication store. See the
[example configuration](examples/statusbar/README.md).

Cld and Cdx have separate `claude` and `codex` popups using
`aiproviders.claude_details` and `aiproviders.codex_details` respectively. They show the
available session/week/model quotas, remaining bars, reset delays, and cache age.
Missing data is marked unavailable; stale data is marked cached. Each provider
keeps its own usage-page link for left-click; right-click pins the corresponding view.

The system regions use `cpu.details`, `memory.details`, `disks.details`,
`network.details`, and `power.details`. Their collection remains in Flash-managed
plugins. Detail values keep their actual precision. CPU/MEM/DSK status percentages
reserve two digits capped at 99, battery charge can reach 100%, and NET uses a
compact four-cell byte rate. AI quota values have no padding.

Configured `[terminal.<name>]` commands use the same terminal backend and take
precedence over a text popup with the same name. They keep their configured
process, grid, and persistence behavior.

The date popup uses the built-in [calendar](calendar.md), with current and adjacent
months, ISO weeks, and date details. It has no appointments or tasks.
See [status plugin ownership](status-plugins.md) and
[terminal popup behavior](terminal-popups.md).

## Attach a popup

Wrap the visible label in a named popup span, then define its rich text:

```toml
[statusbar]
enabled = true
popup_max_width = 480
template = "#[align=right]#[popup=date]#{flash.date}#[nopopup]"

[statusbar.popup]
date = "#{flash.calendar}"
```

Bodies preserve newlines and support the [status format](status-format.md),
including colors, bold, italics, underline, dim, and reverse. Popup colors,
padding, border, and offset are documented in
[config.default.toml](../config.default.toml). `#[popup=inline:<percent-encoded-body>]`
lets dynamic rows carry their own body alongside the visible label.

Hover previews the content beneath the pointer and refreshes it as collected
values change. Click to pin it for selection, copying, search, and scrolling.
A focused pager holds its content and search state stable; reopen it or press
Command-R to use the latest collected data. Links retain their left-click
behavior, with right-click or Option-click available to pin the associated popup.
Command-W closes it.

The standard 480-point width fits 50 content columns with a 13-point font,
10-point padding, and a one-point border. The pager reserves one footer row;
long values wrap and taller content scrolls in the pager.

Dismissing a generated popup stops its pager and removes its snapshot file.
Persistent configured terminal jobs continue while hidden, with frame extraction,
drawing, and cursor blinking paused. Nonpersistent configured jobs stop on dismissal.
