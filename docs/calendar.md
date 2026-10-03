# Calendar popup

The core `#{flash.calendar}` status value supplies calendar-only content for a
text popup:

```text
Wednesday, September 30, 2026                                  Europe/Paris

       August 2026              September 2026             October 2026
Wk Mo Tu We Th Fr Sa Su   Wk Mo Tu We Th Fr Sa Su   Wk Mo Tu We Th Fr Sa Su
31                 1  2   36     1  2  3  4  5  6   40           1  2  3  4
32  3  4  5  6  7  8  9   37  7  8  9 10 11 12 13   41  5  6  7  8  9 10 11
33 10 11 12 13 14 15 16   38 14 15 16 17 18 19 20   42 12 13 14 15 16 17 18
34 17 18 19 20 21 22 23   39 21 22 23 24 25 26 27   43 19 20 21 22 23 24 25
35 24 25 26 27 28 29 30   40 28 29 30               44 26 27 28 29 30 31
36 31

Week 40     ████████▋                 3/7  4 days left
September   ████████████████████    30/30  last day
Q3          ████████████████████    92/92  last day
2026        ███████████████       273/365  92 days left

Time zone   UTC+02:00 · Central European Summer Time
DST         Ends Sun Oct 25 · 03:00 → 02:00 · in 25 days
Moon        Waning gibbous · 83% lit · new Oct 10 · full Oct 26
```

```toml
[popup.date]
text = "#{flash.calendar}"
```

Keep `#[popup=date]...#[nopopup]` around the date in the status template, or
open it with `enter_terminal_mode --name=date`. Existing calendar files and
appointment/task data are untouched.

- **Header**: today's date and the timezone identifier.
- **Months**: the previous, current and next months side by side, rows
  aligned, with ISO week numbers. The current month sits in the middle with a
  bold title; today has a bold inverse highlight and its week number is bold.
  Weekends are dimmed. The rows follow the tallest of the three months.
- **Progress**: today's place in its ISO week, month, quarter and year,
  counting today, with the days left after it. The bars are status-format
  meters on a grey track.
- **Time zone**: the current UTC offset and the zone's English name.
- **DST**: the next daylight-saving transition as the wall clock sees it, or
  `Not observed` for a zone without one.
- **Moon**: today's phase, the lit fraction at local noon, and the next new
  and full moons. A principal phase names the local day its instant falls in.
  Phases come from the leading terms of the Moon's longitude (Meeus,
  *Astronomical Algorithms*), so an instant within a few minutes of midnight
  can land on the neighbouring day.

Dates use a Monday-first Gregorian calendar with ISO week numbers,
English labels, and the current local timezone. The view is 75 content
columns and at most 19 rows. Text popups size to their widest line between
`[popup] min_width` and `max_width`: the default 750-point `max_width` fits it
at the 13-point font with 10-point padding (697 points wide). A smaller
`max_width` or screen wraps it, and smaller screens scroll in the pager, which
reserves one extra footer row. Right-click the date to pin the popup and
select or copy text.

The popup runs system `less` in an owned PTY over a private snapshot file.
Hovered content refreshes when the calendar changes. Focused content and search
stay stable until reopening or Command-R. Dismissal removes the pager and its
snapshot; see [popups](popups.md).

The calendar generator performs no file access, account lookup, network or
location access. It has no appointment or todo interface. One result is cached
for the local day and timezone, and until a daylight-saving transition inside
that day, since the view shows the UTC offset; the existing status clock
refreshes it after midnight, a transition or a timezone change. Calendar
generation adds no timer or plugin; the popup host owns the display process
and snapshot file.
