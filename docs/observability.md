# Observability

Flash records one JSON object per line in `~/Library/Logs/Flash/flash.log`
(also stderr), rotated at 10 MiB with three older files kept. Each line has
`level`, `message`, `source` (`core:<file>.<function>` or `plugin:<id>`),
`pid`, `time_unix_ms`, optional structured `fields`, and optional `trace`.
`[debug] log_level` (`trace`, `debug`, `info` by default, `warn`, `error`)
sets the floor; a line below it costs nothing, since neither its message nor
its fields are built.

## Following one interaction

Every user interaction gets a trace id when it starts: a key the keyboard tap
routes (`origin=key`), a native hotkey (`hotkey`), a physical click Flash acts
on (`pointer`), a `flash` CLI verb (`cli`) or a submitted command line
(`command_line`). At `debug` a `[trace] begin` line records the origin.

The id rides along as the interaction dispatches: mapping and command lines,
the source-action chain and its outcome (including a plugin's failure
reason), the keys Flash sends, and each plugin request, whose envelope carries
the id (`trace`). A plugin line logged while serving that request comes back
with the same id, so

```sh
rg '"trace":"<id>"' ~/Library/Logs/Flash/flash.log
```

reassembles the whole interaction across the host and its plugins. Timers,
AX notifications and background refreshes belong to no interaction and carry
no id.

## Latency

Every hint activation logs `[latency] hints_visible` at `info`: milliseconds
from its trigger to the Core Animation commit that shows the hints, with the
origin, whether the prepared model served it, the target count, the app
class, the app's bundle identifier and the discovery outcome (`hit`, `miss`,
`retried`, `empty`, `none`). An activation that ends with nothing to draw
stays silent on screen and logs `[latency] hints_empty` at `info` instead,
with the time Flash took to give up and the discovery path where it did.
`Scripts/benchmark-hints.sh` aggregates these lines, and
`Scripts/hints-latency-summary.py --by-bundle` summarizes a log per app; see
[performance](performance.md). `flash status --json` carries the same
per-app summary for the running resident (`hints`), and `flash doctor` warns
about apps whose hints are often empty or slow.

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
opens a guide. Those commands start the server on demand even when the
launch-time inspector is disabled.

| Endpoint | Content |
| --- | --- |
| `/`, `/docs/<topic>`, `/mappings`, … | the help and runtime UI ([routes](help.md#routes-and-ownership)) |
| `/api/state` | snapshot time, version/build, start time, Accessibility/capture state, config path and diagnostics, redacted config, configured/effective mappings, focused app, current hints, windows, plugins (state, start time, restarts, last error and log line, CPU time, memory); `?refresh=1` takes a fresh snapshot |
| `/api/logs` | the last 2,000 lines; `/api/logs?trace=<id>` returns one interaction's lines |
| `/api/traces` | recent interactions, newest first: origin, start, duration, line count, worst level, and which host and plugin sources took part |
| `/api/events` | server-sent `state`, `logs` and `log` events |

The state snapshot follows the app's changes and has no clock: mode and
input routing, focus and mappings, hints and activation, input capture and
the Accessibility grant, clipboard history, plugin state, configuration, the
status bar, popups and widgets, and Flash's own windows each push one
(`AppDelegate.debugStateJSON` maps every field to its change). The first change
arms a 100 ms window that the rest of its burst joins, so a burst is one
snapshot. Snapshots are taken only while a browser holds `/api/events`;
otherwise a change only marks the cached one stale, and the next request or
stream takes a fresh one. Uptimes are derived in the page from the start times
the state carries. Plugin CPU time and memory have no change notification:
they are sampled with each snapshot, and the page's Refresh and Resample
buttons (`/api/state?refresh=1`) take one on request. Log records stream as
they are written. Opening a page waits for the listener's ready state, not a
retry loop.

## Stalls

The keyboard tap, AX observers and all mode logic share the main thread, so a
busy main thread is felt as dropped or late keys. A run-loop observer reports
every busy stretch over 250 ms as `[watchdog] main_busy ms=…` at any log
level, with the last activity labels main recorded. Nothing pings the main
thread to find them: the run loop's own wake and sleep reports bound each
stretch.

## Plugins

- Every request completion logs its id, method, elapsed time and outcome at
  `debug`; a request over one second (other than `initialize`) is a `warn`
  `[plugin] slow request`. Timeouts, replies after their deadline and late
  replies name the request id.
- A malformed reply fails the request it answers at once.
- stderr is logged as whole lines, each capped at 4 KiB, at most 20 per 10 s;
  the rest are counted in `[plugin] stderr suppressed`.
- An exit records whether the process exited or died of a signal, and its
  status.
- A failed source action logs the claiming source and the reason it gave.
- Rust SDK plugins warn `[plugin] subprocess slow` for a program run past
  its slow threshold or timing out, and `[plugin] osascript failed` with the
  AppleScript error number (`-1743`: not authorized to send Apple events),
  never its message. Each kind logs once a minute at most; `suppressed`
  counts the ones held back.
- A `search` or `hints` handler that runs out of its request's `deadline_ms`
  logs `[plugin] <method> exceeded its deadline` under the request's trace.
- Per-plugin CPU time (`/api/state`, `:plugins`) is the process's user plus
  system time; rusage reports Mach ticks, converted to nanoseconds.

## Privacy

Logs never record what the user typed in other apps: no key codes or
characters from the keyboard tap or NORMAL's interpreter, no on-screen text of
hint targets, no candidate data, clipboard content or config values. The one
exception is Flash's own command line: a command it cannot run is logged with
its text at `warn`, and `trace` logs every submitted command line. Plugins
follow the same rule for their `log` lines.
