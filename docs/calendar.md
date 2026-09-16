# Calendar popup

The core `#{flash.calendar}` status value supplies calendar-only content for the
status popup terminal. It shows today's weekday and date, ISO week, day of year,
quarter, the current month with week numbers, and the previous and next months.
Today has a bold inverse highlight; weekends are dimmed.

```toml
[statusbar.popup]
date = "#{flash.calendar}"
```

Keep `#[popup=date]...#[nopopup]` around the date in the status template. A
`[terminal.date]` declaration takes precedence over the built-in popup, so remove
that declaration when switching to the built-in calendar. Existing calendar
files and appointment/task data are untouched.

Dates use a Monday-first Gregorian calendar with ISO week numbers,
English labels, and the current local timezone. The view is at most 43 content
columns and 20 rows. The standard 480-point popup fits it at the 13-point font with
10-point padding; the pager reserves one extra footer row. Smaller screens
scroll in the pager. Right-click the date to pin the popup and select or copy text.

The popup runs system `less` in an owned PTY over a private snapshot file.
Hovered content refreshes when the calendar changes. Focused content and search
stay stable until reopening or Command-R. Dismissal removes the pager and its
snapshot; see [terminal popups](terminal-popups.md).

The calendar generator performs no file access or account lookup. It has no
appointment or todo interface. One result is cached for the local day and
timezone; the existing status clock refreshes it after midnight or a timezone
change. Calendar generation adds no timer or plugin; the popup host owns the
display process and snapshot file.
