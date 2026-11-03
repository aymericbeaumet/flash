# Calendar

Flash leaves your calendar to the apps and tools that keep it (Calendar,
Fantastical, [calcurse](https://calcurse.org) or khal in a terminal
[popup](popups.md)) and adds what they cannot: the next meeting in the
status bar, an alert before it starts, and a key that joins it. A
three-month calendar view is a status value too.

## Next meeting

`#{flash.calendar.next}` reads `Standup in 12m`, then `Standup now` once it
began. Its parts compose a template of your own:

| Value | Example | What it is |
| --- | --- | --- |
| `#{flash.calendar.next}` | `Standup in 12m`, `Standup now` | The title and when |
| `#{flash.calendar.next_title}` | `Standup` | The title, on one line |
| `#{flash.calendar.next_in}` | `in 12m`, `in 1h 5m`, `now` | When it starts |
| `#{flash.calendar.next_minutes}` | `12` | Whole minutes until it starts, rounded up; `0` once it began |
| `#{flash.calendar.next_start}`, `#{flash.calendar.next_end}` | `09:30` | Its times, 24-hour, local |
| `#{flash.calendar.next_ongoing}` | `1` | `1` once it began, empty before |
| `#{flash.calendar.next_link}` | `https://meet.google.com/abc-defg-hij` | Its meeting link as the event writes it; empty without one |

Every value is empty while no event is next, which a
[monitor](monitors.md) reads as unknown. A title is text: a `#` in it never
starts a style or a link.

The next event is the one that began within the last ten minutes and has not
ended (the latest to begin, if several did), long enough to join it late;
otherwise the first to start within the look-ahead, 24 hours by default. At
equal starts, one with a meeting link comes first. Cancelled events never
count; all-day and declined ones count only when [`[calendar]`](config:calendar) says so.

```toml
[statusbar]
enabled = true
template = """
#[align=left]#[pill]#{flash.mode}#[nopill]
#[align=right]#{?flash.calendar.next,#[range=user|join]#[shrink]#{flash.calendar.next_title}#[noshrink] #{flash.calendar.next_in}#[norange] · ,}%H:%M
"""

# A click on the meeting joins it.
[statusbar.click]
join = ["flash", "calendar", "join"]
```

`#[shrink]` lets a long title give way first ([overflow](status-format.md#overflow-and-shrink)).
To show a meeting only once it is two hours away, test the countdown:
`#{?#{&&:#{flash.calendar.next},#{e|<=:#{flash.calendar.next_minutes},120}},#{flash.calendar.next} · ,}`.

### An alert before it starts

A monitor on the countdown raises the centred alert two minutes before each
meeting, whether the bar is on or not:

```toml
[monitors.meeting]
value = "#{flash.calendar.next_minutes}"
direction = "below"
warning = 2
message = "#{flash.calendar.next}"
# Join it as well, the moment the alert shows:
# run = ["flash", "calendar", "join"]
```

The alert reads `Standup in 2m` over `2`. As with every monitor it rises
once: back-to-back meetings that keep the countdown under the threshold
alert for the first only.

### Joining

`calendar join` opens the meeting link of the event about to start (within
ten minutes) or just started; otherwise of the meeting in progress, to
rejoin it; otherwise of the next event, however far ahead. Links are found
in the event's URL, then its location, then its notes: Zoom, Google Meet,
Microsoft Teams, Webex, Around, Whereby, FaceTime, Slack huddles, Jitsi
Meet, GoTo Meeting and Amazon Chime, and otherwise a URL field or a location
that is one web link. A Zoom or Teams link opens straight in the app when it
is installed (`zoommtg:`, `msteams:`), any other in its default handler.

`calendar next` shows the next event in the centred alert, its title over
`in 12m · 09:30–09:45 · Zoom`; from the CLI it prints that line. Both exit 1
and say why when no event is in the look-ahead, when the event has no link
(`calendar join`) or when Flash may not read your calendars. Bind either
like any command:

```toml
[mode.all.mappings]
"cmd+ctrl+j" = ["flash", "calendar", "join"]
```

### Settings

```toml
[calendar]
calendars = ["Work"]   # titles as Calendar shows them; empty reads every calendar
all_day = false        # count all-day events
declined = false       # count events you declined
lookahead_hours = 24   # how far ahead the next event may start, 1-168
```

### Access and cost

Flash reads your calendars through EventKit, in process, only while a status
format — the bar, a text popup, a desktop widget or a monitor — reads one of
these values, and when `calendar join` or `calendar next` runs. The first
such read asks macOS for Calendars access; the default configuration reads
none of these values, so it never asks. A refusal leaves the values empty and
the commands exit 1 until you allow Flash in System Settings › Privacy &
Security › Calendars; then run `calendar next` once to read them. Reminders
are never read here.

A read covers events from now to twice the look-ahead and keeps, in memory
only, each event's title, times, all-day, declined and cancelled flags, its
calendar's title and the meeting link found in it; the location and notes
are scanned for that link and not kept ([privacy](privacy.md)). Flash reads
again when the calendar database changes (half a second after a burst of
changes settles) and once one look-ahead has passed, and stops when no
surface reads a value. The values change at instants of their own — the
countdown's next minute, an event starting, ending or leaving its first ten
minutes — and the status controller wakes for exactly those on the shared
clock, at monitor priority when only a monitor reads them. Nothing polls.

### Coming from MeetingBar or Itsycal

| MeetingBar, Itsycal | Flash |
| --- | --- |
| The next meeting and its countdown in the menu bar | `#{flash.calendar.next}` in `[statusbar] template` |
| Join the next meeting (MeetingBar's shortcut) | `calendar join` on a key, or a `#[range]` click on the bar |
| Notification or full-screen reminder before a meeting | A `[monitors.meeting]` on `#{flash.calendar.next_minutes}`, and its centred alert |
| Joining as it starts | That monitor's `run = ["flash", "calendar", "join"]` |
| Month calendar dropdown (Itsycal) | `#{flash.calendar}` in a text popup, below |
| Agenda and event editing | Calendar, Fantastical, or calcurse or khal in a terminal popup |
| Hide calendars, all-day and declined events | `[calendar] calendars`, `all_day`, `declined` |

## Calendar popup

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
open it with `mode terminal --name=date`. Existing calendar files and
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
location access, and shows no events or todos: the
[next-meeting values](#next-meeting) are what read your calendars. One result is cached
for the local day and timezone, and until a daylight-saving transition inside
that day, since the view shows the UTC offset; the existing status clock
refreshes it after midnight, a transition or a timezone change. A timezone
change also re-renders the bar's clock and the next meeting's start and end
in the new zone at once, and `calendar next` and `calendar join` read the new
zone too. Calendar
generation adds no timer or plugin; the popup host owns the display process
and snapshot file.
