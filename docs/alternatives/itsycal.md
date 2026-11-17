# Flash and Itsycal

[Itsycal](https://www.mowglii.com/itsycal/) is "a tiny calendar for your
Mac's menu bar": click the date and a month drops down, with your
Calendar.app events in an agenda beneath it, a button to join a virtual
meeting, ISO week numbers, and keys for everything, Vim motions and counts
included (`21L` is three weeks ahead). It can create and delete events, though
not edit them, and its date and time pattern can stand in for the system
clock. Mowglii publishes it free under the MIT licence, about 4,000 stars on
[GitHub](https://github.com/sfsam/Itsycal). It is very much alive: 0.27.0 to
0.27.3, a visual update for macOS 27, shipped in October 2026 (0.27.3 on the
13th), and 0.15.15 (September 2026) remains the build for macOS 11 and later.

Flash has no menu-bar calendar to drop down. It shows the next meeting in its
own bar, a three-month calendar in a text popup, and leaves the agenda and
event editing to Calendar, Fantastical or a calendar CLI.

| | Itsycal | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | macOS 27+ (0.27.3); macOS 11+ (0.15.15) | macOS 13+ |
| Permissions | Calendars, to show your events | Accessibility; Calendars only once a next-meeting value or `calendar join` reads events; the month view reads none |
| Month view | A month, or two, under the menu-bar date; week numbers on `W` | Previous, current and next month side by side with ISO weeks, plus the week, month, quarter and year progress, time zone, DST and the moon |
| Events | An agenda under the month; create (`⌘N`) and delete; join the active meeting (`⌘J`) | The next event in the bar and `calendar join`; no agenda, no event creation |
| Clock | Date and time in your own pattern, or in place of the system clock | `strftime` in `[statusbar] template`, in a bar that replaces the native one |
| Keyboard | A global shortcut; H, J, K, L with counts, Space for today, `⇧⌘T` to a date | Mappings in every mode; the popup's pager keys; no month navigation |
| Configuration | Settings window; `itsycal://date/<yyyy-MM-dd>` URL scheme | One TOML file, live reload, `flash config check` |
| Maintenance | 0.27.3, October 2026; active | 1.1.0, October 2026 |

## Where Itsycal is stronger

- **Your events on the calendar.** Itsycal's agenda puts the coming days
  under the month. Flash's three-month view shows dates only, and its
  calendar values stop at the next event.
- **Moving through time.** Days, weeks, months and years from the home row,
  with counts, today on Space, any date on `⇧⌘T`, and `#` for how far a day
  is from today. Flash's popup always shows the previous, current and next
  month and nothing else.
- **Creating events** from the keyboard. Flash creates and deletes nothing.
- **It fits the native menu bar.** One small item beside the others, a clock
  replacement if you want one, and 0.15.15 added a shortcut that brings it up
  even when a menu bar manager has hidden it. Nothing else on the Mac
  changes.
- **Small touches**: an hourly beep, two-month display, font sizes, a pinned
  window (`P`).

## Where Flash is stronger

- **The next meeting is already on screen.** `Standup in 12m` sits in the
  bar with a countdown, a click joins it, and a monitor can raise an alert or
  a notification two minutes before. Nothing has to be opened first.
- **More in the calendar view.** Progress through the ISO week, month,
  quarter and year, the next daylight-saving change, the UTC offset, and the
  moon's phase sit under the three months.
- **The calendar on the desktop.** The [clock and agenda
  example](../examples/widgets/README.md) draws a large clock, the
  three-month calendar and today's events (from icalBuddy, which reads the
  same Calendar.app data) as a desktop widget.
- **One bar for everything.** The date sits beside the mode, the system
  figures and your scripts, in one file you keep with your dotfiles.

## Flash features you might like

- `#[popup=date]…#[nopopup]` around the clock: hovering it shows the
  calendar, and a right-click pins it ([calendar popup](../calendar.md#calendar-popup)).
- `mode terminal --name=date` on a key, for Itsycal's global shortcut.
- `calendar next` puts the next event in the centred alert, title over
  `in 12m · 09:30–09:45 · Zoom`.
- If you like Itsycal's Vim keys, NORMAL mode brings the same idea to the
  whole desktop: `f` labels everything clickable, `gt` changes tabs, `:` runs
  commands ([NORMAL](../normal-mode.md)).

## Moving from Itsycal

The [calendar guide](../calendar.md#coming-from-meetingbar-or-itsycal) maps
both Itsycal and MeetingBar. For Itsycal's own features:

| Itsycal | Flash |
| --- | --- |
| The menu-bar date, in your pattern | `strftime` in the template: `%a %e %b %H:%M` |
| Click the date for the month | `#[popup=date]` around it, and `[popup.date] text = "#{flash.calendar}"` |
| Itsycal's keyboard shortcut | `["flash", "mode", "terminal", "--name=date"]` on a key |
| Pin (`P`) | Right-click the date |
| Week numbers (`W`) | Always there, ISO |
| The agenda | icalBuddy or khal in a named source, shown by a widget or a popup, as in the [example](../examples/widgets/README.md) |
| Join the active meeting (`⌘J`) | `calendar join` |
| Open the calendar app (`⌘O`) | `["flash", "app", "open", "--name=Calendar"]` |
| New event (`⌘N`) | Not available; create it in Calendar or Fantastical |
| Navigate to other months, go to a date | Not available |
| Hourly beep | A `core:clock.minute` monitor with the hours in `at`, running `afplay` |

```toml
[statusbar]
enabled = true
template = "#[align=right]#[popup=date]%a %e %b %H:%M#[nopopup]"

[popup.date]
text = "#{flash.calendar}"

[mode.all.mappings]
"cmd+ctrl+d" = ["flash", "mode", "terminal", "--name=date"]
"cmd+ctrl+j" = ["flash", "calendar", "join"]

# "Beep beep on the hour", during the working day.
[monitors.chime]
event = "core:clock.minute"
at = ["09:00", "10:00", "11:00", "12:00", "13:00", "14:00", "15:00", "16:00", "17:00", "18:00"]
run = ["afplay", "/System/Library/Sounds/Tink.aiff"]
```

The month view reads no events, so this asks for no permission. Put
`#{?flash.calendar.next,#{flash.calendar.next} · ,}` before the date to show
the next meeting as well; that is the first read that makes macOS ask whether
Flash may read your calendars.

## Using both

Itsycal is the better calendar to look things up in, and Flash the better
place to keep the next meeting in view, so both is a fine arrangement. With
Flash's status bar on, the native menu bar auto-hides and Itsycal's date goes
with it; Itsycal's own shortcut still brings it up (0.15.15 and later), its
URL scheme does too (`["open", "itsycal://date/now"]` as a Flash mapping), and
`mouse menubar` puts a hint on its item when the menu bar is revealed. If
Itsycal replaces your clock, drop the clock from one of the two.

In NORMAL, Flash swallows every key and chord it has not mapped, so
Itsycal's single keys (H, J, K, L, Space, `#`) and its global shortcut reach
it from INSERT: press `i` once the month is open, or open it through a Flash
mapping. Each app asks for Calendars on its own.

*Checked 2026-10-23 against Itsycal's [page](https://www.mowglii.com/itsycal/),
[help](https://www.mowglii.com/itsycal/help.html),
[version history](https://www.mowglii.com/itsycal/versionhistory.html) and
[repository](https://github.com/sfsam/Itsycal).*
