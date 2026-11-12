# Monitors

A monitor watches one value Flash already has — battery charge, startup-disk
usage, memory pressure, plugin health, a source you own, any metric a program
sends Flash over OpenTelemetry — and shows the
centred alert when that value crosses a threshold. With a `run`, it also calls
a command when it rises, or on every change of a value it has no thresholds
for. A monitor can watch a host event instead of a value — the Mac waking, an
app quitting, a display connected, the screen unlocking — and run a command
each time: the same table is Flash's "when X happens, do Y". Every monitor,
with its current value and state, is listed on the help's live
[monitors page](/monitors): `flash monitors show` opens it.

Monitors are not the `sysinfo` [status plugin](status-plugins.md) (CPU,
memory, disks, power, network), though they often read what it publishes, nor
`[statusbar] monitor`, which picks the displays the bar is drawn on.

## Quick start

Five monitors are built in and on. To add your own, write a
`[monitors.<name>]` table in `~/.config/flash/flash.toml` and save:

```toml
[statusbar.sources.load]
command = ["/bin/sh", "-c", "sysctl -n vm.loadavg | awk '{print $2}'"]
interval = 30

[monitors.load]
value = "#{flash.source.load}"
warning = 8
error = 16
message = "Load average high"
```

When the one-minute load reaches 8, Flash shows an amber alert reading
*Load average high* over the value; at 16 a red one. Names use letters,
digits, `_` and `-`.

### Any OpenTelemetry metric

With the [OpenTelemetry receiver](telemetry.md) on, any metric a program
exports to Flash is a value, `#{flash.otel.<field>:<metric>[<filter>]}`:

```toml
[telemetry.receiver]
enabled = true

[monitors.claude_spend]
value = "#{e|+|f|2:#{flash.otel.total:claude_code.cost.usage},0}"
message = "Claude Code spend"
warning = 10
error = 25

[monitors.api_latency]
value = "#{flash.otel.p95:http.server.request.duration[service.name=api]}"
warning = 0.5
error = 2
```

The monitor re-evaluates when one of its metric's series receives a point or
goes quiet, never on a timer; see
[reading metrics](telemetry.md#reading-metrics-in-a-status-format) for every
field. Give such a monitor a `run` only with
[`[telemetry.receiver] token`](telemetry.md#the-receiver) set: the receiver
listens on loopback, which every program on the Mac shares, and
`flash resident doctor` warns while a monitor runs commands from a received
metric without one.

## Keys

| Key | Default | Meaning |
| --- | --- | --- |
| `value` | — | A [status format](status-format.md) whose expanded text starts with a number; required. |
| `warning` | — | The threshold for a warning. |
| `error` | — | The threshold for an error. At least one of the two is required. |
| `direction` | `"above"` | `"above"` when a high value is bad (usage), `"below"` when a low one is (charge). |
| `message` | `""` | The alert's title, a status format. Empty derives one from the name and the threshold crossed: `Battery below 20`. |
| `detail` | `""` | What is failing, a status format the alert shows under the title in place of the value: the plugins a count counts. Empty, or empty once expanded, shows the value. |
| `interval` | `60` | Seconds between reads of the `#()` jobs and kernel values the monitor shows, 1–86400. |
| `enabled` | `true` | `false` turns the monitor off; it stays listed on the page. |
| `run` | — | What to call when the monitor fires: one command, `["flash", "<topic>", "<action>", …]` or an executable with its arguments, as a [mapping](mappings.md) takes, or a list of them run in order, `[["bonsai", "clean", "--all", "--force"], ["mo", "clean"]]`. `false` removes one an earlier layer set. See [running commands](#running-commands). |
| `timeout` | `600` | Seconds the whole run may take, every step included, 1–86400. |
| `cooldown` | `0` | Seconds after a run starts before the monitor may run again, 0–604800; kept across restarts. |
| `alert` | `true` | `false` keeps a rise's `run` and drops its alert. |
| `notify` | `false` | `true` also posts the rise, or an event monitor's `message`, as a macOS notification that stays in Notification Center; each monitor's newest replaces its last. The first asks for permission; see [notifications](commands.md#notifications-logs-and-metrics). |
| `event` | — | Host events to watch instead of a value: a name or glob, or a list, as a plugin's `listen` takes. |
| `app` | — | Narrows app events (`core:apps.*`, `core:focus.changed`) to one bundle identifier. |
| `usb` | — | Narrows `core:usb.attached` and `core:usb.detached` to one device: `{ vendor_id = 0x05ac, product_id = 0x024f, name = "Keyboard" }`, any subset. The ids match exactly, `name` a part of the product name, ignoring case. See [USB devices](#usb-devices). |
| `idle` | `300` | Seconds of no input at which `core:user.idle` fires for this monitor, and the least an away episode lasted for its `core:user.active`, 1–86400. |
| `at` | — | The times of day `core:clock.minute` fires this monitor at: `"HH:MM"`, 24-hour, in the Mac's time zone, or a list, `["09:55", "13:55"]`. |
| `days` | every day | Narrows `at` to days of the week: `"mon"` through `"sun"`, or a list. |

A value monitor needs a threshold or a `run`; one without thresholds is a
hook on its value: `run` is called on every change of the expanded text,
from its second known value on (the first is where it starts), and it never
alerts. An event monitor takes `event`, `app`, `usb`, `message` and `run` alone —
no `value`, no thresholds — and needs a `run` or a `message`.

The value is expanded exactly as the bar would expand it — plugin segments,
`#{flash.source.<name>}`, `#()` jobs, conditionals, `strftime` — and its
styles are dropped. The text must then start with a number, read like a
meter's: `42`, `-3`, `0.75`, `.5`. Anything after the number is kept for
display, so `"#{flash.plugin.sysinfo.disks_percent}%%"` reads `93` and shows `93%`.
As in the bar, `%%` is a literal percent sign. A value that is empty or
starts with anything else is *unknown*: no alert, and no recovery either.

A threshold counts once the value reaches it: with `direction = "above"`,
`warning = 90` means 90 or more; with `"below"`, `warning = 20` means 20 or
less. The error threshold is checked first, so it must be the more extreme
one: below `error` for `above`, above it for `below`. An enabled monitor with
no value, no threshold or thresholds in the wrong order is reported at load
and does not run.

A later configuration layer overrides only the keys it sets, so retuning or
disabling a built-in monitor takes one line. `false` removes a threshold an
earlier layer set:

```toml
[monitors.disk]
warning = 80
error = false

[monitors.battery]
enabled = false
```

## Runs and events

```toml
# A value with thresholds: alert on a rise, and run something too.
[monitors.battery]
run = ["flash", "caffeinate", "off"]

# A value without thresholds: run on every change.
[statusbar.sources.wifi]
command = ["/usr/sbin/ipconfig", "getsummary", "en0"]
[monitors.wifi]
value = "#{flash.source.wifi}"
run = ["~/bin/on-network-change"]

# Events: when the Mac wakes, when Slack comes forward, when a display
# is connected or removed.
[monitors.wake]
event = "core:system.woke"
run = ["flash", "app", "open", "--name=Calendar"]

[monitors.slack]
event = "core:focus.changed"
app = "com.tinyspeck.slackmacgap"
run = ["flash", "caffeinate", "on"]

[monitors.docking]
event = "core:displays.changed"
message = "Displays changed"
run = ["~/bin/arrange-windows"]

# When one keyboard is plugged in, and only that one.
[monitors.keyboard]
event = "core:usb.attached"
usb = { vendor_id = 0x05ac, product_id = 0x024f }
run = ["flash", "caffeinate", "on"]
```

A Flash command runs in process, as a mapping's would. An executable starts
with Flash's login environment plus what says why it ran: `FLASH_MONITOR`
always; for a value monitor `FLASH_VALUE` (the expanded text) and
`FLASH_STATE` (`ok`, `warning`, `error`, `unknown`); for an event
`FLASH_EVENT` and each payload field as `FLASH_EVENT_<FIELD>`
(`FLASH_EVENT_BUNDLE_ID`, `FLASH_EVENT_PID`, `FLASH_EVENT_LOCALIZED_NAME`;
a list joins with newlines). An event monitor's `message` shows as the
centred alert as written.

The events are the host events plugins subscribe to, one catalog for both
([protocol](plugin-protocol.md)), which `flash events watch` also streams to
scripts ([IPC protocol](ipc-protocol.md#events)):

| Event | When | Payload |
| --- | --- | --- |
| `core:apps.launched`, `core:apps.terminated` | An app launched or quit | `bundle_id`, `localized_name`, `pid` |
| `core:focus.changed` | Another app came forward | `bundle_id`, `localized_name`, `pid` |
| `core:window.focus.changed` | The focused app's focused or main window changed | `bundle_id`, `pid` |
| `core:apps.changed` | The running apps changed | `running_applications` |
| `core:power.changed` | The power source or battery changed | — |
| `core:network.changed` | Interfaces, addresses, routes or DNS changed | — |
| `core:volumes.changed` | A volume mounted, unmounted or was renamed | — |
| `core:displays.changed` | A display was connected or removed | `added`, `removed`, `displays` |
| `core:space.changed` | The active Space changed | — |
| `core:workspace.changed` | The focused [tiling](tiling.md) workspace changed | `workspace`, `previous`, `workspaces` |
| `core:system.slept`, `core:system.woke` | The Mac went to sleep, and woke | — |
| `core:displays.slept`, `core:displays.woke` | The displays slept, and woke | — |
| `core:screen.locked`, `core:screen.unlocked` | The lock screen came up, and went away | — |
| `core:user.idle` | Nobody touched the keyboard, mouse or trackpad for the monitor's `idle` seconds | `seconds` |
| `core:user.active` | Input came back after an away episode that reached the monitor's `idle` seconds | `idle_seconds` |
| `core:clock.minute` | A minute began that is one of the monitor's `at` times | `time`, `weekday`, `date`, `late_seconds` |
| `core:usb.attached`, `core:usb.detached` | A USB device was connected, or removed; devices already connected are not announced | `vendor_id`, `product_id`, `name` |
| `core:config.changed` | The configuration loaded (at launch, then on every change) | — |
| `core:mode.changed` | Flash's mode changed | `mode`, `previous` (as `resident status` names them) |
| `core:hints.shown`, `core:hints.committed`, `core:hints.cancelled` | A hint session drew its labels, committed a target, or ended without one | `surface`; `targets` when shown |
| `core:monitor.triggered` | A value monitor rose into warning or error | `monitor`, `level` |
| `core:ax.changed`, `core:session.opened`, `core:status.observed` | Plugin plumbing: an AX notification, the flashlight opening, a plugin's segments shown | see the protocol |

An event monitor costs nothing between events: they are workspace and system
notifications, never a poll, and network and volume changes are observed only
while a plugin or a monitor listens. The monitors page lists each with its
events, how often it ran and when last.

`core:user.idle` fires once per away episode when the time since the last
keyboard, mouse, trackpad or scroll input reaches the monitor's `idle`
(seconds, default 300); `core:user.active` fires once input comes back after
such an episode. A monitor listening to both runs on leaving and on coming
back; `FLASH_EVENT` says which. Flash reads only how long the input has been
idle, never what it was, and only while such a monitor or a plugin listens:
it samples at the next threshold, then every two seconds while you are away,
because no event tap sees the pointer.

```toml
# Away for 10 minutes: pause what plays and lock the screen.
[monitors.away]
event = "core:user.idle"
idle = 600
run = [
  ["flash", "key", "system", "--key=media_play"],
  ["flash", "screen", "lock"],
]
```

`core:clock.minute` runs a monitor at times of day, the way cron, launchd's
`StartCalendarInterval`, Hammerspoon's `hs.timer.doAt` and Keyboard
Maestro's time triggers do. The monitor names its times in `at`, and `days`
narrows them. Flash reads the clock only at those minutes and when the
system clock or time zone changes. A time the Mac slept or sat locked
through runs once at the next wake or unlock the same day, and
`FLASH_EVENT_LATE_SECONDS` says how late; a time missed on an earlier day
does not run.

```toml
# Weekdays at 09:58: join the standup.
[monitors.standup]
event = "core:clock.minute"
at = "09:58"
days = ["mon", "tue", "wed", "thu", "fri"]
run = ["flash", "calendar", "join"]
```

### USB devices

`core:usb.attached` and `core:usb.detached` announce every device; `usb`
narrows a monitor to one. It names the device by any of its vendor id, its
product id and its product name, and every field it sets must match: the
ids exactly, the name as a part of the reported name, ignoring case
(`"keyboard"` matches `Apple Keyboard`). A device that reports no name
matches no `name`. The ids are the payload's `vendor_id` and `product_id`,
the numbers System Information shows under USB, written in hex or decimal
as you like (`0x05ac`, `1452`); `flash events watch` prints them as each
device comes and goes. A serial number is never read, so none can be
filtered on. An empty `usb = {}` is reported, as is a `usb` on a monitor
whose `event` names no USB event.

```toml
# The dock at the desk: show the desk workspace when it is plugged in,
# whatever its serial number.
[monitors.dock]
event = "core:usb.attached"
usb = { name = "CalDigit" }
run = ["flash", "workspace", "switch", "--name=desk"]

# One keyboard, by both ids, written as a table of its own.
[monitors.keyboard]
event = ["core:usb.attached", "core:usb.detached"]
run = ["~/bin/keyboard-changed"]
[monitors.keyboard.usb]
vendor_id = 0x05ac
product_id = 0x024f
```

## Running commands

A `run` with several commands runs them in order, each once the previous
succeeded; the first that fails ends the run. A monitor runs one at a time:
a fire while its run is still going is skipped, as is one within `cooldown`
seconds of the last start, so a value that rises again an hour later can run
the commands again, but one that flaps does not. A value that stays past its
threshold fires once, on the rise (see [alerts](#alerts)), and a value already
past it when Flash starts counts as a rise: `cooldown` is what keeps a restart
from running the commands again, which is why Flash keeps the last start in
`~/Library/Application Support/Flash/monitor-runs.json`.

```toml
# When the startup disk reaches 90%: delete the worktrees bonsai knows are
# merged, then Mole's caches, logs and leftovers. At most every six hours.
[monitors.disk_cleanup]
value = "#{flash.plugin.sysinfo.disks_percent}"
warning = 90
alert = false
timeout = 1800
cooldown = 21600
run = [
  ["bonsai", "clean", "--all", "--force"],
  ["mo", "clean"],
]
```

The built-in `disk` monitor still raises its alert at 90; this one, with
`alert = false`, only runs.

An executable step starts in your home directory with the login environment
(the `PATH` your shell sets, so `bonsai`, `mo` and other tools resolve as in
a terminal) plus `FLASH_MONITOR`, `FLASH_VALUE` and `FLASH_STATE` (or the
`FLASH_EVENT` variables), and reads `/dev/null`: it has no terminal, so a
tool that would ask a question takes its non-interactive path or stops.
Flash waits for each step and keeps the last 16 KiB of what it printed. A
step runs in its own process group: when `timeout` runs out, the step and
every process it started get `SIGTERM` and, five seconds later, `SIGKILL`, so
a helper that ignores `SIGTERM` does not outlive the run. Quitting Flash
stops a step still running the same way, and so does a configuration save
that removes or disables its monitor or changes its `run` (*was stopped: the
monitor changed*). A step that ends on its own may leave a process in the
background; Flash lets it go. A step that exits non-zero, cannot start, times
out or is stopped fails the run: Flash shows one alert naming the step and why (*Disk cleanup run failed:
mo clean exited 1*), logs the step's output (`[monitors] run_failed`) and
shows it on the [monitors page](/monitors), with each step and how the last
run went. A Flash command step fails when it did not perform (no focused app
to act in, or the app has no such command). A run outlives Flash quitting.

Two tools need their unattended flags:

| Tool | Command | Without a terminal |
| --- | --- | --- |
| [bonsai](https://github.com/aymericbeaumet/bonsai) | `bonsai clean --all --force` | `--all` cleans every project; `--force` (an alias of `--yes`) skips the confirmation. Dirty and locked worktrees, the main checkout and branches with unpushed commits are never touched. `bonsai trim --all --yes` frees build output and dependencies instead, keeping the worktrees. |
| [Mole](https://github.com/tw93/Mole) | `mo clean` | Needs no flag: without a terminal it runs every user-level category (caches, logs, temporary files, leftovers of uninstalled apps). System caches need `sudo`; they are skipped unless a sudo session is already cached. `mo purge --yes` also deletes old build artifacts in your project folders. `mo installer` only works in a terminal. |

## Built-in monitors

| Name | Value | Thresholds | Reads |
| --- | --- | --- | --- |
| `battery` | `#{flash.plugin.sysinfo.power_percent}%%` | below 20, 10 | The `sysinfo` plugin's battery charge; unknown on a Mac without a battery |
| `disk` | `#{flash.plugin.sysinfo.disks_percent}%%` | above 90, 97 | The `sysinfo` plugin's startup-volume usage |
| `memory` | `#{flash.memory_pressure}%%` | above 85, 95 | Memory pressure, read from the kernel once per interval |
| `plugin_errors` | `#{flash.plugin.error_count}` | warning at 1 | Plugins whose last launch, exit or handshake failed, crash loops included; the alert names them (`flash.plugin.errors`) |
| `plugin_spawn` | `#{flash.plugin.spawn_ms} ms` | above 1000, 5000 | How long the latest plugin launch took to spawn its process; the alert names the plugin (`flash.plugin.spawn_id`) |

`flash.memory_pressure` is the share of memory the kernel does not count as
available, 0–100: `100 − kern.memorystatus_level`, the free percentage
`memory_pressure` prints. It is not the `sysinfo` plugin's `memory_percent`,
which counts file cache as used and sits near 100 on a healthy Mac.

`flash.plugin.errors` lists the plugins `flash.plugin.error_count` counts,
sorted and comma-separated (`media, tmux`), and is empty when none fails.
`flash.plugin.spawn_ms` is the time `posix_spawn` took for the most recent
plugin launch, rounded to milliseconds, and `flash.plugin.spawn_id` the
plugin it started; both are unknown until a plugin has started. macOS can hold an exec for seconds while `syspolicyd` assesses it;
this monitor is how that shows up.

## Alerts

A monitor's state is `unknown`, `ok`, `warning` or `error`. The alert is
Flash's one centred alert: the message over the value, amber
for a warning and red for an error, up for ten seconds and kept through a
mode change or an app switch. It is raised only on a rise:

- into warning or error from ok or from the first known value, and from
  warning to error;
- never again while the state persists, however often the value changes;
- never for a recovery: back to ok is silent, and error to warning is too;
- never for a value that blinks out and back, such as a plugin restarting:
  `unknown` does not forget the state the monitor last reported;
- at most once per level every five minutes, so a value flapping across a
  threshold does not alert on every crossing.

Thresholds have no hysteresis; the alert rules above are what keep a
borderline value quiet. While a confirmation asks its question, a monitor's
alert waits for the answer instead of replacing it. Every alert is also
logged (`[monitors] alert`), and every state change at debug level.

## The monitors page

The help's monitors page (`/monitors`, opened by `flash monitors show`) lists
every monitor — built-in and your own, enabled or not — with its value as
shown, state, thresholds, direction, interval, message, when its state last
changed and when it last alerted. It follows the resident over the help's
event stream like every other page, so a crossing appears as it happens.

The same data is the `monitors` array of `/api/state`:

```json
{
  "id": "disk",
  "name": "Disk",
  "origin": "default",
  "enabled": true,
  "value": 93,
  "display": "93%",
  "state": "warning",
  "direction": "above",
  "warning": 90,
  "error": 97,
  "interval_s": 60,
  "message": "Startup disk almost full",
  "since_ms": 1800000100000,
  "last_alert_ms": 1800000100000,
  "expression": "#{flash.plugin.sysinfo.disks_percent}%%"
}
```

`origin` is `default` for a built-in monitor, retuned or not, and `config` for
one your file declares. `value` is null while the state is unknown, and
`display` is the expanded text as it is (`%` for a battery percentage nobody
published); both are empty for a disabled monitor, whose `message` is the
format as written. `since_ms` and `last_alert_ms` are Unix milliseconds;
`last_alert_ms` is null until the first alert.

## Evaluation and cost

Monitors are evaluated by the status controller beside the bar and the
desktop widgets: one set of sources and jobs, one deadline on the shared
clock, no timer of their own. They run whether the bar is on or off. A source
shown by the bar and read by a monitor runs once.

- A monitor is re-evaluated whenever a value it read changed: a plugin
  publish, a source's output, a job's line. A battery crossing 20 alerts as
  soon as the `sysinfo` plugin publishes it.
- The plugin segments an enabled monitor reads count as observed, so their
  plugins run and publish them (`core:status.observed`) as they would for a
  visible bar. The built-ins keep the `sysinfo` plugin's battery figures
  (event-driven) and disk figures (a three-second I/O sample) sampled.
- Its `#()` jobs re-run every `interval`; a named source keeps its own
  interval. Kernel values such as `flash.memory_pressure` are read once per
  `interval`, one `sysctl` each.
- What only monitors require wakes at `low` priority, the slack of background
  upkeep; nothing a monitor reads ticks the clock, so `%H:%M` in a message is
  read when the monitor is evaluated, not every minute.

Set `enabled = false` on a monitor to drop everything only it required.
