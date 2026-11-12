# Observability

Flash records one JSON object per line in `~/Library/Logs/Flash/flash.log`
(also stderr), rotated at 10 MiB with three older files kept. Each line has
`level`, `message`, `source` (`core:<file>.<function>` or `plugin:<id>`),
`pid`, `time_unix_ms`, optional structured `fields`, and optional `trace`.
`[debug] log_level` (`trace`, `debug`, `info` by default, `warn`, `error`)
sets the floor; a line below it costs nothing, since neither its message nor
its fields are built.

## Levels and names

Each line is one event, named `[area] event` in stable snake_case
(`[plugin] slow request`, `[popup] restart_scheduled`), with the values worth
filtering on in `fields` rather than only in the message. A level says who
should care:

| Level | Meaning | Examples |
| --- | --- | --- |
| `error` | Flash could not do what was asked for a reason other than the user's input (an I/O or system API failure, a broken install), or a feature stopped working until someone acts | a store that cannot write, a plugin parked after its restart loop, an update that could not install |
| `warn` | Degraded but handled: a retry, a fallback, a slow path, or a user configuration problem Flash worked around | `[plugin] slow request`, `[window] unconverged`, a config key it ignored |
| `info` | Rare state changes a user would recognize, and input Flash rejected | a plugin launched, caffeinate on, `[command] unsupported` |
| `debug` | Developer diagnostics at modest volume: one line per user command or background job | `[mappings] action=`, `[discover] pipeline` |
| `trace` | Per key, per frame, per plugin request: the detail of one interaction | `[latency] tap_to_route`, `[plugin] request done`, `[statusbar] render` |

Nothing above `trace` runs per key, per frame or per request, and nothing
logs a `warn` or `error` on every tick of a condition that persists: say it
once when it starts, and again only when it changes.

## Areas

An area is one snake_case word, one word wherever one names it: the command
topic the line serves (`window`, `app`, `input`), the hint surface it draws
(`screens`, `dock`, `words`) or the subsystem it belongs to (`tap`, `poll`,
`ipc`). What the tag loses, the event keeps (`[app] quit_focus`,
`[pointer] follows_focus`). These are the host's areas; a plugin's lines
carry its own id (`[tmux]`, `[browsers]`) or the SDK's `[plugin]`, and a
script's `logs write` any word it names (`user` by default). `LogAreaTests`
holds the sources and this table to the same set.

| Family | Areas |
| --- | --- |
| Modes and keys | `mode`, `normal`, `visual`, `pointer`, `input`, `keyboard`, `tap`, `mappings`, `command`, `history`, `macro`, `confirm`, `cursor`, `text`, `move`, `movement`, `marks`, `frecency` |
| Hints and the pointer | `activation`, `discover`, `ax`, `overlay`, `commit`, `click`, `drag`, `multi`, `words`, `screen`, `scroll`, `bigram`, `search`, `gesture`, `warp`, `step`, `repeat`, `button`, `positions`, `screens`, `dock`, `menubar`, `notifications`, `menus`, `menu`, `focus`, `capture`, `latency` |
| Apps, windows and sources | `app`, `window`, `placement`, `switcher`, `tiling`, `navigation`, `source`, `query`, `flashlight`, `files`, `apple`, `calendar`, `clipboard`, `url`, `processes`, `system`, `missioncontrol`, `surfaces`, `media`, `caffeinate` |
| Status, popups and events | `statusbar`, `widgets`, `popup`, `monitors`, `notify`, `telemetry`, `events`, `ipc` |
| Plugins | `plugin`, `plugins` |
| The resident | `resident`, `startup`, `config`, `autolaunch`, `updates`, `doctor`, `about`, `debug`, `trace`, `watchdog`, `poll` |

## Lines from scripts

`flash logs write` (typed in full: `flash logs` alone shows the page)
writes a line through the same serial writer at the level its flag names,
tagged `[area]` (`user` by default) with `--fields` as fields and `user` as
its source, which tells it apart from `core:…` and `plugin:…` lines. A message
is one line of at most 4096 characters; line breaks become spaces. See
[notifications, logs and metrics](commands.md#notifications-logs-and-metrics).

## Following one interaction

Every user interaction gets a trace id when it starts: a key the keyboard tap
routes (`origin=key`), a native hotkey (`hotkey`), a physical click Flash acts
on (`pointer`), a `flash` CLI command (`cli`) or a submitted command line
(`command_line`). At `debug` a `[trace] begin` line records the origin.

The id rides along as the interaction dispatches: mapping and command lines,
the source-command chain and its outcome (including a plugin's failure
reason), the keys Flash sends, and each plugin request, whose envelope carries
the id (`trace`). A plugin line logged while serving that request comes back
with the same id, so

```sh
rg '"trace":"<id>"' ~/Library/Logs/Flash/flash.log
```

reassembles the whole interaction across the host and its plugins. Timers,
AX notifications and background refreshes belong to no interaction and carry
no id.

Logs, these traces and Flash's latency and plugin metrics can also be sent
to an OpenTelemetry collector; see [telemetry](telemetry.md#the-exporter).

## Latency

Every hint activation logs `[latency] hints_visible` at `info`: milliseconds
from its trigger to the Core Animation commit that shows the hints, with the
origin, whether the prepared model served it, the target count, the app
class, the app's bundle identifier, the discovery outcome (`hit`, `miss`,
`retried`, `empty`, `none`) and, for a miss, why the prepared model could not
serve it (`miss_reason`). An activation that ends with nothing to draw
stays silent on screen and logs `[latency] hints_empty` at `info` instead,
with the time Flash took to give up and the discovery path where it did.
`mise run bench:hints` aggregates these lines,
`mise run bench:hints-summary -- --by-bundle` summarizes a log per app, and
`mise run bench:log-summary` reports every latency, walk, plugin, border and
warning distribution of a log at once; see [performance](performance.md). `flash resident status --json` carries the same
per-app summary for the running resident (`hints`), and `flash resident doctor` warns
about apps whose hints are often empty or slow. At `trace`, each inspector
snapshot logs `[latency] inspector_snapshot ms=…` with the sections it
rebuilt and its clipboard, plugin and mapping counts — the cost of building
`/api/state` on the main thread,
which the watchdog's `main_busy` report also names as `inspector_snapshot`.

Repairs of a degenerate walk log `[discover] retry` and
`[discover] retry_result` at `info` (`repair=retry|readiness`, the ladder
`steps` taken and `waited_ms`). At `debug`, `[discover] complete` carries `retried`, and
`[ax] readiness_ready` / `[ax] readiness_rewalk` follow background readiness
ladders. `[ax] model_refresh_gated` is logged once, at `info`, when an app
whose volatile provider owns its hints stops being warmed.

## HTTP inspector

`[debug] http_inspector_enabled = true` serves a loopback-only inspector
(default `http://127.0.0.1:4242`). It answers only requests whose `Host` names
the listener itself, so a web page rebinding its own hostname to 127.0.0.1
can't read it. Its log view receives what the log file does, at the
configured level.

The same server hosts [browser help](help.md): `:help` opens its homepage,
`?` / `:mappings` opens the effective mapping reference, and `:help <topic>`
opens that page of the documentation. Those commands start the server on demand even when the
launch-time inspector is disabled. Every endpoint below but the UI and
`/api/docs` answers only the access token, as
`Authorization: Bearer <token>` or `?token=`; a script reads it from
`~/Library/Application Support/Flash/help-token`
([routes](help-internals.md#routes-and-ownership)).

| Endpoint | Content |
| --- | --- |
| `/`, `/docs/<page>`, `/mappings`, … | the help and runtime UI ([routes](help-internals.md#routes-and-ownership)) |
| `/api/docs`, `/api/docs/search` | the bundled documentation and its search sections |
| `/api/state` | snapshot time, version/build, start time, Accessibility/capture state, config path and diagnostics, redacted config, configured/effective mappings (each row names its origin: `default`, `config` or `config:<file>`, or `plugin:<name>`), focused app, current hints, windows, plugins (state, start time, restarts, last error and log line, CPU time, memory); `?refresh=1` takes a fresh snapshot |
| `/api/logs` | the last 2,000 lines; `/api/logs?trace=<id>` returns one interaction's lines |
| `/api/traces` | recent interactions, newest first: origin, start, duration, line count, worst level, and which host and plugin sources took part |
| `/api/events` | server-sent events: the whole `state` once, then a `patch` of the sections that changed per snapshot; `logs`, then each `log` line |
| `/api/clipboard/<id>` | `GET` one history image; `DELETE` that entry. The id is 32 lowercase hex characters |

The state snapshot follows the app's changes and has no clock: mode and
input routing, focus and mappings, hints and activation, input capture and
the Accessibility grant, clipboard history, plugin state, configuration, the
status bar, popups and widgets, and Flash's own windows each push one
(`AppDelegate.debugStateJSON` maps every field to its change). The first change
arms a 100 ms window that the rest of its burst joins, so a burst is one
snapshot. Snapshots are taken only while a browser holds `/api/events`;
otherwise a change only marks the cached one stale, and the next request or
stream takes a fresh one. Uptimes are derived in the page from the start times
the state carries. A status bar, popup or widget change rebuilds only its
own sections over the last snapshot (`sections=` on the `[latency]` line);
any other change rebuilds the whole state. Plugin CPU time and memory have
no change notification: they are sampled with each whole snapshot, and the
page's Refresh and Resample buttons (`/api/state?refresh=1`) take one on
request. Log records stream as
they are written. Opening a page waits for the listener's ready state, not a
retry loop.

## Stalls

The keyboard tap, AX observers and all mode logic share the main thread, so a
busy main thread is felt as dropped or late keys. A run-loop observer reports
every busy stretch over 250 ms as `[watchdog] main_busy ms=…` at any log
level, and every one from 50 ms — three frames, felt on a fast keystroke —
as `[watchdog] main_hitch ms=…` at `info`, each with the last activity labels
main recorded. Nothing pings the main thread to find them: the run loop's own
wake and sleep reports bound each stretch.

The resident also holds one user-initiated activity for its whole life, so
App Nap never throttles it for looking idle (an agent with no visible window
is a candidate) while the Mac and its displays still sleep. It leaves timer
coalescing on: the slack every `PollScheduler` registration declares still
lets wake-ups share a tick.

## Plugins

- Every request completion logs its id, method, elapsed time and outcome at
  `trace`; a request over one second (other than `initialize`) is a `warn`
  `[plugin] slow request`. Timeouts, replies after their deadline and late
  replies name the request id.
- A malformed reply fails the request it answers at once.
- stderr is logged as whole lines, each capped at 4 KiB, at most 20 per 10 s;
  the rest are counted in `[plugin] stderr suppressed`.
- An exit records whether the process exited or died of a signal, and its
  status.
- A failed source command logs the claiming source and the reason it gave.
- Rust SDK plugins warn `[plugin] subprocess slow` for a program run past
  its slow threshold or timing out (host-run AppleScript reports as
  `executable=applescript`), and `[plugin] applescript failed` with the
  AppleScript error number (`-1743`: not authorized to send Apple events),
  never its message. Each kind logs once a minute at most; `suppressed`
  counts the ones held back.
- A `search` or `hints` handler that runs out of its request's `deadline_ms`
  logs `[plugin] <method> exceeded its deadline` under the request's trace.
- Per-plugin CPU time (`/api/state`, `:plugins show`) is the process's user plus
  system time; rusage reports Mach ticks, converted to nanoseconds.

## Privacy

Logs never record what the user typed in other apps: no key codes or
characters from the keyboard tap or NORMAL's interpreter, no on-screen text of
hint targets, no candidate data, clipboard content or config values. Two
exceptions are deliberate. Flash's own command line: a command it cannot run
is logged with its text at `info` (`[command] unsupported`), and `trace` logs
every submitted command line. And `[startup] run`: each startup command is
logged at `info` with its text as your file wrote it, and one that fails at
`warn` with the end of its output, an audit of what ran on the system at
launch. Plugins follow the same rule for their `log` lines.
