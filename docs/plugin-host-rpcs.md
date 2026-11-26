# Plugin host RPCs

The requests a plugin makes of the host: what each method takes, what it
answers and what bounds it. The [plugin protocol](plugin-protocol.md#host-rpcs)
has the envelope, the capability gate and the rule for malformed params;
`protocol.json` and the [schemas](plugin-protocol.md#schemas-and-constants)
pin every name and number here.

## AppleScript

`host.applescript` accepts a named `operation`, data fields and optional
`timeout_ms`; it returns `{ok: true, result}` or `{ok: false, error, status?}`.
It accepts no `script` field or executable source. The fixed operations are
`browser_tabs` (`bundle_id`), `browser_select` (`bundle_id`, optional `url`,
`title`, paired positive `window`/`tab`), `browser_tab_index` (`bundle_id`,
positive `index`), `browser_tab_move` (Safari `bundle_id`, boolean `forward`),
`shortcuts_list`, `shortcut_run` (`name`), `chat_submit` (`bundle_id` of the
browser that must still be frontmost, Firefox included), and `now_playing`
(`bundle_id` of a media player, boolean `artist`). `now_playing` answers the
player state, a line feed and the current track's name, followed by its
artist after an em dash when `artist` is true (`playing\nOne More Time —
Daft Punk`); a stopped player answers its state alone, and an app that is
not running answers an empty result and is never launched. A browser is an app
some manifest declares in [`browser_engines`](plugin-protocol.md#manifest): the tab operations
serve `chromium` and `webkit` browsers, each in its engine's dialect
(`browser_tab_move` is `webkit` alone), and `chat_submit` serves any engine.
Unknown fields, non-browser chat destinations and undeclared browsers are
rejected.
Each operation selects a host-owned template; every supplied string becomes
an escaped literal. Declare `apple_events` with nonempty
`apple_events_targets`: declared browser IDs, `com.apple.shortcuts.events`
for shortcut operations, `com.apple.systemevents` for chat submit, or the
players `now_playing` asks.
Templates run in the resident off its main thread, so plugin senders retain
their sandbox and Automation belongs to Flash. `protocol.json` bounds source
to 64 KiB, result to 1 MiB and concurrency to four per plugin. Timeout defaults
to 10 seconds and must be an integer from 1 to 30000 ms. Operation data and
result contents never enter plugin diagnostics.

## Wi-Fi

`host.wifi_info` requires `{"request_authorization": false}` for passive reads
or `true` only for an explicit user action allowed to show the host-owned
Location prompt. An undetermined request replies absent immediately after
starting the prompt; callers retry after authorization instead of holding an
RPC open. The method returns
`{"ok": true, "present": true, "ssid": "…"}` for an associated network or
`{"ok": true, "present": false}` when Wi-Fi information is unavailable.

## Audio devices

`host.audio_devices` is CoreAudio, which stays in the resident. It takes an
`operation` and exactly the fields that operation names:
`{"operation": "list", "direction": "input" | "output"}` answers `{"ok":
true, "devices": [{"uid", "name", "default"}]}`, sorted by name, `default`
marking the direction's default device; `{"operation": "select",
"direction", "uid"}` makes the device with that UID the default;
`{"operation": "step_volume", "ticks": N}` moves the default output `N`
macOS volume-key ticks (a sixteenth each, up when positive, down when
negative, never zero, at most 16 either way), clears its mute and answers
`{"ok": true, "percent"}`, the percent the bezel would show;
`{"operation": "toggle_mute"}` answers `{"ok": true, "muted"}`; and
`{"operation": "volume"}` reads `{"ok": true, "percent", "muted"}`. A
CoreAudio failure, an unknown UID or a device without the control answers
`{"ok": false, "error"}`. The calls of every plugin run one at a time, off
the main thread.

## System actions

`host.system_action` takes exactly `{"action"}` and asks macOS for one
machine or session action, which stays in the resident: `lock_screen` posts
macOS's Lock Screen shortcut to the session, `sleep` and `display_sleep` ask
IOKit power management, `screensaver` opens ScreenSaverEngine and
`toggle_appearance` switches dark mode through System Events. `restart`,
`shutdown` and `logout` go through System Events and `empty_trash` through
Finder, and nothing undoes them: the host honours one of these four only
inside a `perform` the user [confirmed](plugin-protocol.md#confirmation), one action per
confirmed perform. Outside one — from an event, a poll tick, a search, a
perform the user was not asked about, or after that perform's one action —
it asks macOS for nothing and answers `{"ok": false, "error": "requires a
perform the user confirmed"}`. A plugin cannot grant itself that consent: the
request has no key for it, and only the user's `y` marks a perform. The
reply is `{"ok": true}` once macOS took the request, or `{"ok": false,
"error"}` with why it did not. The Apple Events are the host's own fixed
scripts, so the plugin needs neither `apple_events` nor a target list and
its sandbox gains nothing; macOS attributes the Automation request to
Flash. The actions run one at a time, off the main thread except the lock
chord. `protocol.json` `system_actions` lists them.

## Process signals

`host.process_signal` takes exactly `{"pid", "signal"}` and sends one signal
to one process: `kill(2)` stays in the resident. `signal` is `"term"`
(SIGTERM), the only one. `pid` is an integer above 1: `0` (the caller's
process group), a negative pid (a group, or every process) and `1`
(launchd) refuse the request as malformed, and the host refuses its own pid
(`refusing to signal Flash itself`). The host honours every signal only
inside a `perform` the user [confirmed](plugin-protocol.md#confirmation), one signal per
confirmed perform; outside one it asks the kernel nothing and answers
`{"ok": false, "error": "requires a perform the user confirmed"}`. A refused
pid spends no consent. The reply is `{"ok": true}` once the kernel took the
signal, or `{"ok": false, "error"}` with the kernel's reason (`No such
process`, `Operation not permitted` for another user's process). The
plugin's sandbox gains nothing. `protocol.json` `process_signals` lists the
signals.

## Process table

`host.process_table` reads the process table: libproc stays in the
resident, on its own queue, and no sandbox profile lets a plugin read
another process. A request carries `operation` and exactly the fields it
takes. Every success carries `at`, the host's monotonic clock in nanoseconds
when it read: the CPU share between two reads is the CPU time gained over
the difference of their `at`.

`{"operation": "list"}` reads every process the user may measure, in the
kernel's order, as its figures:

```json
{"pid": 4242, "start": 77000, "cpu_ns": 1500000000,
 "resident_bytes": 268435456}
```

`start` is when the process started, in Mach absolute time: with the pid,
the identity of one process, which a reused pid does not share. `cpu_ns` is
its cumulative user and system CPU time and `resident_bytes` its resident
memory. `{"operation": "list", "pids": [4300, 4301]}`, at most 4,096
distinct pids above 0, reads only those, in the order asked, and adds each
one's `name`, the last component of its executable's path. A name costs the
kernel a path lookup per process, which a sweep of the whole table does not
pay: a reader names a process once, by pid. A pid that is gone, or not the
user's to measure, is left out.

`{"operation": "tree", "pid"}` reads that process and every descendant
reachable from it now, breadth first, the process itself first. Each carries
its `name` and four more keys: `threads`, `sockets` (its open socket
descriptors, unix-domain ones included, counted from the descriptor list
alone), `disk_read_bytes` and `disk_write_bytes`, both cumulative. The reply
also carries the root's `path`, its executable, and `started_at`, its start
in Unix seconds, each when the kernel answers. `processes` is empty when the
process is gone or not the user's to measure.

Nothing else of a process crosses the wire. The host never reads a process's
arguments or its environment, so no reply can carry them. A reply holds at
most 4,096 processes and 1 MiB of them; later ones are left out and
`truncated` is `true`. `protocol.json` `process_table` and `process` pin the
operations, the bounds and the shape. The bundled `processes` plugin is its
reader: one list every two seconds while a table is shown, a second one by
pid, 150 ms later, for the processes it has not met, and one tree every ten
seconds for the focused app.

## Calendar events

`host.calendar_events` reads the user's calendar: EventKit and the Calendars
grant stay in the resident, and macOS names Flash in its prompt. A request
carries `operation` and exactly the fields it takes. Every success carries
`access`, what macOS answers without asking: `"granted"`, `"denied"`
(refused, restricted or write-only) or `"undetermined"` (Flash never asked).
`{"operation": "access"}` reads it. `{"operation": "request_access"}` reads
it too and, when it is undetermined, asks macOS first and answers once the
user did. The host shows that prompt only while the user is using the
plugin: one of its performs or searches is in flight, or a status surface
shows one of its segments now ([observed](plugin-protocol.md#status-observation)). Anywhere else an undetermined access answers `{"ok": false,
"error": "requires the user to be using the plugin"}` and nothing is shown,
so a plugin never raises a prompt from a background refresh. Requests made
while the prompt is open share its answer, and the host sends
`core:calendar.changed` once the user answered, so a caller that stopped
waiting still hears of it.
`{"operation": "list", "start", "end", "calendars"?}` reads the occurrences
overlapping `start..<end`, both whole Unix seconds, `start` before `end` and
at most 1,209,600 seconds (14 days) apart. `calendars` is at most 64
calendar titles as Calendar shows them; absent or empty, every event
calendar is read. A list never asks: without the grant its reply is the
`access` alone. With it, `events` holds the occurrences in start order:

```json
{"id": "8C1F…@1800000720", "title": "Standup", "start": 1800000720,
 "end": 1800002520, "all_day": false, "calendar": "Work", "declined": false,
 "canceled": false, "url": "https://example.com/standup",
 "location": "Room 4", "links": ["https://zoom.us/j/123?pwd=abc"]}
```

`id` is the event's identifier and the occurrence's start, `declined` says
the user is an attendee who declined it, and `url` and `location` are present
only when the event has them. The event's notes never cross the wire:
`links` holds the link-shaped runs found in them, in order (a URL scheme,
`:/` and the characters up to the next whitespace, quote or bracket), at
most 32, and is absent when there is none. Which of them is a meeting link
is the plugin's to decide. A title is cut at a character boundary to 4 KiB;
a URL, a location or a link over 16 KiB is left out whole, never cut. A
reply holds at most 1,000 events and 1 MiB of them; later ones are left out
and `truncated` is `true`. An EventKit failure answers `{"ok": false,
"error"}`. `protocol.json` `calendar_events` and `calendar_event` pin the
operations, the bounds and the shape. The bundled `calendar` plugin is its
reader: it lists from now to twice its look-ahead while one of its segments
is observed, again on `core:calendar.changed`, and for each of its commands.

## Notes, Reminders and Contacts

`host.notes`, `host.reminders` and `host.contacts` read the items of an
Apple app whose grant Flash holds (Automation of Notes, Reminders,
Contacts), each behind the capability of its name. The three take the same
requests and answer `access` as `host.calendar_events` does:
`{"operation": "access"}` reads it, and `{"operation": "request_access"}`
asks macOS first when it is undetermined, under the same rule (only while
the user is using the plugin, one shared answer per prompt). Notes answers
an Automation request only while it runs, so its access reads
`"undetermined"` while it does not, and nothing is asked then.
`{"operation": "list"}` reads every item in the app's own order: every note
of every account, every open reminder, every contact card. It never asks
and never launches Notes; without the grant its reply is the `access`
alone. With it, `items` holds one object per item:

```json
{"id": "5F8A…", "title": "Buy milk", "list": "Inbox", "list_index": 0,
 "created": 1800000000}
```

`id` selects the item again and `title` is a note's name, a reminder's
title or the name Contacts shows a card by, cut at a character boundary to
4 KiB. A reminder adds its list's title, that list's position among
Reminders' lists (absent once Reminders no longer names it) and its
creation time in Unix seconds; a note and a contact carry `id` and `title`
alone. Nothing else of an item crosses the wire: no note text, no due date,
no phone number or address. Which rows these make, and in what order, is
the plugin's to decide. A reply holds at most 10,000 items and 2 MiB of
them; later ones are left out and `truncated` is `true`.
`{"operation": "show", "id"}` brings the app forward on an item a list
returned (`id` is 1 to 1,024 bytes without control characters); without the
grant it answers `{"ok": false, "error"}` and asks nothing. Notes is read
and shown by the host's own fixed AppleScript, the `id` an escaped literal.
`protocol.json` `app_items` and `app_item` pin the operations, the bounds
and the shape. The bundled `notes`, `reminders` and `contacts` plugins are
their readers, one each.

## Opening URLs and apps

`host.open` takes `{"url"}` or `{"bundle_id"}`, never both; a URL's reply also
names the app LaunchServices handed it to (`bundle_id`, when resolvable), so a
plugin can confirm that app still has focus before acting on it. A `file:` URL
is refused (`host.open does not open local files`): a sandboxed plugin could
otherwise write a `.command`, a script or an app into its data directory and
have LaunchServices run it outside the sandbox. `{"url", "if_handled": true}`
opens the URL only when an application is registered for it, and otherwise
hands LaunchServices nothing and answers `{"ok": false, "error": "no
application opens the URL"}`: a plugin tries an app's own link (`zoommtg:`)
before the web one.

## Accessibility

The AX broker exists because `AXUIElement` cannot
cross a process boundary: `host.ax_snapshot` BFS-walks one tree (default cap
3000 nodes) and returns flat nodes with opaque handles. `root` names the
tree. `"windows"`, the default, is the windows of the app `pid` names.
`"menu_bar"` is the menu bar of the app that owns it: the host names that
app, the one whose menus are installed, so the request takes no `pid` (one
beside it is refused) and the reply carries the app's `pid` beside `nodes`.
Its one root is the app's `AXMenuBar`: the first node is the bar, its
children the bar items in bar order, the Apple menu first, and a boolean
attribute such as `AXEnabled` arrives as `"1"` or `"0"`. The host never walks
its own menus: when no app but Flash owns the bar the reply is `{"ok": true,
"nodes": []}`, without a `pid`. Each element costs one Accessibility round
trip, which reads `collect` and `follow` together, so name only what you
read: a menu bar of 2,500 elements, read for its roles, titles, enabled
flags and children, is a reply of about 310 KB.
A snapshot supersedes the handles the plugin held for that app, and a
menu-bar snapshot its menu-bar handles for every app, since one app owns the
bar at a time; a quit app's handles go with it. A call on a handle that is
gone answers `stale ax handle` and touches nothing.
The two trees have separate host queues, and a call on a handle runs on the
queue of the snapshot that returned it: a menu bar never waits on a
browser's window walk, nor a hint provider's window snapshot on a menu bar.
The menu bar is AppKit's own in a Gecko app too, so reading or pressing it
takes no part in Gecko's process lock.
`protocol.json` `ax_snapshot` pins the roots, the default cap and the budget.
The bundled `menus` plugin is the menu bar's reader: one snapshot per
`@menus` scope, and a row's handle pressed when the row is picked.
Snapshots have a host-side five-second budget including queue admission.
An app with no windows, including one that does not support `AXWindows`,
returns an empty window snapshot. A window-list read that fails or times out
fails the snapshot, so catalog plugins can keep their last successful rows.
Expiry, a revoked child, or an unresponsive AX batch fails the whole snapshot;
it never returns partial nodes or leaves their handles actionable. The budget
is checked between AX reads and after acquiring Gecko's process lock; it cannot
preempt synchronous AX calls or an operation already holding that lock.
An AX timeout is not retried once per requested attribute: the broker shares Gecko's process
lock with hint discovery, and abandoned snapshots must release it promptly.
`host.ax_set` takes `{handle, attribute, value}` and sets a boolean
attribute such as `AXFocused`; a non-boolean value is rejected.
`host.post_keys` takes `{pid, keys, interval_ms?}`: 1 to 32 chords of
`{key_code, modifiers}`, each under at least one of `command`, `control`,
`option` and `shift`, spelled exactly so. It cannot type text.

## Capabilities

A method is open to a plugin whose manifest `capabilities` name its
capability. `network` opens no method: it composes
`network-outbound` into the sandbox profile, so only a sandboxed plugin
declares it. With `network_fetch` the host
performs HTTPS GETs on the plugin's behalf (`host.fetch`, restricted to
the manifest's `fetch_urls` prefixes and the URLs its `fetch_settings` hold,
answering UTF-8 text within its `fetch_limits` — the plugin keeps a fully
network-denied sandbox; the capability comes with `fetch_urls` or
`fetch_settings`, and only with them). `host.fetch` answers
`{ok, status, body}` whatever the HTTP status; the Rust SDK's `fetch`
returns the body of a 2xx response alone. A redirect is followed only to a
URL the allowlist admits. `open` hands URLs/bundle ids to LaunchServices
host-side.
`wifi_info` exposes only the current SSID after host-owned Location
authorization. `audio_devices` lists the audio devices and changes the
default device, the output volume and its mute. `system_actions` locks the
screen, sleeps the Mac or its displays, starts the screen saver, toggles
dark mode and, inside a perform the user confirmed, restarts, shuts down,
logs out or empties the Trash. `process_signal` sends SIGTERM to one
process, only inside a perform the user confirmed. `calendar_events` reads
the access macOS grants Flash to the user's calendars, asks for it while the
user is using the plugin, lists the events of a window of at most 14 days
without their notes, and delivers `core:calendar.changed`. `notes`,
`reminders` and `contacts` each read one app's access, ask for it while the
user is using the plugin, list its items as an identifier and one line, and
show one in the app. `process_table` reads the process table through the
host: every process the user may measure as its pid, start, CPU time and
resident memory, its executable's name, and one process's tree with thread
and socket counts, disk I/O and the root's path, never a process's
arguments or environment. No capability opens another process to a plugin's
own reads: the sandbox profile lets a plugin ask the kernel about its own
process alone, and denies it the pid list and every other process
([profile invariants](plugin-protocol.md#seatbelt-profile-invariants)).
Omitted capabilities are default-denied. The registry is frozen: additions
are allowed, renames never.

## SDK convention

The Rust SDK's `call_host` never
throws and never returns nil — it always yields a result object. Capability
NAKs, host death (`{"ok": false, "error": "host closed stdin"}`), and the
5 s default timeout (`{"ok": false, "error": "host call timed out"}`, per-
call override available) all arrive the same way.
