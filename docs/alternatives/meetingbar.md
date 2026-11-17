# Flash and MeetingBar

[MeetingBar](https://github.com/leits/MeetingBar) puts "Your meetings at
your fingertips in the macOS menu bar": the current or next meeting as a
menu-bar title with its countdown, today's and tomorrow's events in its menu,
and a join button that knows more than 50 meeting services. It reads every
account synced to Calendar.app, or Google Calendar directly. Andrii Leitsius
writes it in Swift under Apache-2.0; it has about 5,400 stars, runs on macOS
12 and later, and is free from the Mac App Store, Homebrew or a DMG, with
optional patronage as in-app purchases. The stable release is 4.11.6 (June
2025); 5.0 is in release candidates, the third on 22 October 2026.

Flash covers the part of MeetingBar that sits in the bar: the next meeting
and its countdown in your own template, a key or a click that joins it, and
an alert before it starts. It has no meeting menu.

| | MeetingBar | Flash |
| --- | --- | --- |
| License, price | Apache-2.0; free, optional patronage | MIT, free |
| Platforms | macOS 12+ | macOS 13+ |
| Permissions | Calendars for Calendar.app accounts, or a Google sign-in; Notifications for reminders | Accessibility; Calendars on the first read of a next-meeting value; Notifications only for a monitor with `notify = true` |
| Calendars | Calendar.app accounts, or Google Calendar directly | Calendar.app accounts through EventKit; `[calendar] calendars` picks some |
| In the bar | Title, time, countdown, icon or service of the current or next meeting; a menu of today's and tomorrow's events | `#{flash.calendar.next}` and its parts, placed in your template; no event list |
| Joining | One click or a global shortcut; 50+ services; a browser or native app per service | `calendar join` on a key, a bar click or a monitor; eleven services, then the event's URL field; Zoom and Teams open in their apps |
| Reminders | macOS notifications, an optional full-screen reminder | Flash's centred alert from a monitor, and a macOS notification with `notify = true` |
| Configuration | Preferences window, Shortcuts, AppleScript | One TOML file, live reload, `flash config check` |
| Maintenance | 4.11.6, June 2025; 5.0 RC3, October 2026; active | 1.1.0, October 2026 |

## Where MeetingBar is stronger

- **The day at a glance.** Its menu lists today's and tomorrow's events, each
  one joinable. Flash shows exactly one event, the next, and has no list.
- **Link detection.** More than 50 services, and the 5.0 candidates fix
  Outlook SafeLinks, Google redirect links and ZoomGov passcodes. Flash
  recognises eleven services (Zoom, Meet, Teams, Webex, FaceTime, Slack
  huddles and a few more), then an event's URL field or a location that is
  one web link.
- **Google Calendar without Calendar.app**, through its own sign-in.
- **A reminder you cannot miss.** The full-screen reminder covers the
  screen; Flash's alert is a centred panel that stays up ten seconds.
- **Meeting tools Flash does not have:** ad-hoc meetings on your preferred
  service, bookmarks for recurring meetings, opening the event in Calendar or
  Fantastical, a browser per service, AppleScript on join (pause the music),
  and filters for tentative, pending and linkless events. Flash filters only
  all-day and declined events.
- **It changes nothing else.** It is one item in the native menu bar; Flash's
  bar replaces that band.

## Where Flash is stronger

- **The meeting sits with everything else you watch.** The mode, CPU,
  battery and clock share one template with the countdown, and a desktop
  widget can show the same values.
- **Joining is a command.** `calendar join` runs from any mode, from a
  terminal (`flash calendar join`), from a bar click, or from a monitor that
  joins your standup at 09:58 on weekdays.
- **The reminder can act.** A monitor's `run` can join the call the moment its
  alert shows, and `notify = true` leaves the reminder in Notification Center.
- **Reads only what is shown.** Flash reads your calendars only while a bar,
  popup, widget or monitor uses a next-meeting value, re-reads when the
  calendar database changes, and polls nothing; it keeps titles, times and
  the link in memory and nothing on disk ([access and cost](../calendar.md#access-and-cost)).
- **In your dotfiles.** `[calendar]`, the template and the reminder are text
  that `flash config check` validates.

## Flash features you might like

- `calendar next` shows the next event in the centred alert, its title over
  `in 12m · 09:30–09:45 · Zoom`, and prints the same line in a terminal.
- `#{flash.calendar.next_title}`, `next_in`, `next_start`, `next_end` and
  `next_minutes` to lay out the title your way, with `#[shrink]` so a long
  title gives way first ([next meeting](../calendar.md#next-meeting)).
- A countdown test that shows the meeting only once it is two hours away.
- `#{flash.calendar}`, a three-month calendar with ISO weeks, in a text popup
  under the clock ([calendar popup](../calendar.md#calendar-popup)).
- A [time-of-day monitor](../monitors.md#runs-and-events) (`event =
  "core:clock.minute"`, `at`, `days`) for a call that never moves.

## Moving from MeetingBar

The [calendar guide](../calendar.md#coming-from-meetingbar-or-itsycal) maps
both MeetingBar and Itsycal. For MeetingBar's settings:

| MeetingBar | Flash |
| --- | --- |
| Next meeting in the status bar | `#{flash.calendar.next}` (`Standup in 12m`) in `[statusbar] template` |
| Title, time or countdown only | `#{flash.calendar.next_title}`, `next_start`, `next_in` |
| Shorten long titles | `#[shrink]…#[noshrink]` around the title |
| Click to join | `#[range=user|join]` around it, and `join = ["flash", "calendar", "join"]` in `[statusbar.click]` |
| Global join shortcut | `calendar join` in `[mode.all.mappings]` |
| Notification before the meeting | `[monitors.meeting]` on `#{flash.calendar.next_minutes}`, `direction = "below"`, with `notify = true` |
| Full-screen reminder | The centred alert; there is no full-screen one |
| Choose calendars | `[calendar] calendars = ["Work"]`, titles as Calendar shows them |
| Hide all-day and declined events | `all_day = false`, `declined = false`, the defaults |
| Hide tentative, pending or linkless events | Not available |
| Today's and tomorrow's events | Calendar or Fantastical; icalBuddy in a widget, as in the [clock and agenda example](../examples/widgets/README.md) |
| Google Calendar without Calendar.app | Not available: add the account to Calendar.app |
| Create an ad-hoc meeting | A mapping to your service's own link, such as `["open", "https://meet.new"]` |
| Pause the music on join (AppleScript) | A monitor whose `run` is a list, `[["flash", "key", "system", "--key=media_play"], ["flash", "calendar", "join"]]`; the play key toggles, so it resumes paused music too |

One paste covers MeetingBar's everyday setup: the next meeting and its
countdown at the right of the bar, a click on it that joins, a notification
two minutes before, the calendars to read and the join keys. The calendar
guide explains the [next-meeting values](../calendar.md#next-meeting) and the
[reminder](../calendar.md#an-alert-before-it-starts):

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

# The centred alert two minutes before each meeting, also left in
# Notification Center.
[monitors.meeting]
value = "#{flash.calendar.next_minutes}"
direction = "below"
warning = 2
message = "#{flash.calendar.next}"
notify = true

[calendar]
# calendars = ["Work"]  # empty reads every calendar
lookahead_hours = 24

[mode.all.mappings]
"cmd+ctrl+j" = ["flash", "calendar", "join"]
"cmd+ctrl+m" = ["open", "https://meet.new"]
```

The first save that reads a next-meeting value makes macOS ask whether Flash
may read your calendars, separately from MeetingBar's grant.

## Using both

They read the same calendars independently, so both work at once. Decide who
reminds you: two reminders two minutes apart are noise, so turn off
MeetingBar's notifications or leave out `[monitors.meeting]`.

While Flash's status bar is on, the native menu bar auto-hides, and
MeetingBar's title goes with it: it shows again at the top edge, and `mouse
menubar` puts a hint on it so its menu is one key away. A comfortable split is
the countdown and the join key in Flash, and MeetingBar's menu for the rest of
the day, its bookmarks and its ad-hoc meetings. If you would rather keep
MeetingBar's title on screen, keep Flash's bar off; `calendar join` and the
monitor work without it.

In NORMAL, Flash swallows every chord it has not mapped, MeetingBar's global
shortcut included: press it from INSERT, or let `calendar join` own the key.

*Checked 2026-10-23 against MeetingBar's
[README](https://github.com/leits/MeetingBar),
[releases](https://github.com/leits/MeetingBar/releases) and
[App Store listing](https://apps.apple.com/us/app/id1532419400).*
