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

## HTTP inspector

`[debug] http_inspector_enabled = true` serves a loopback-only inspector
(default `http://127.0.0.1:4242`). It answers only requests whose `Host` names
the listener itself, so a web page rebinding its own hostname to 127.0.0.1
can't read it. Its log view receives what the log file does, at the
configured level.

| Endpoint | Content |
| --- | --- |
| `/` | the inspector UI |
| `/state` | config, mappings, focused app, current hints, windows, plugins (state, restarts, last error and log line, CPU %, memory) |
| `/logs` | the last 2,000 lines; `/logs?trace=<id>` returns one interaction's lines |
| `/traces` | recent interactions, newest first: origin, start, duration, line count, worst level, and which host and plugin sources took part |
| `/events` | server-sent `state`, `logs` and `log` events |

## Stalls

The keyboard tap, AX observers and all mode logic share the main thread, so a
busy main thread is felt as dropped or late keys. A run-loop observer reports
every busy stretch over 250 ms as `[watchdog] main_busy ms=…` at any log
level, with the last activity labels main recorded. At `debug`, a ping
watchdog also reports stalls while they are still in progress
(`[watchdog] main_thread_stall`).

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
- Per-plugin CPU % (`/state`, `:plugins`) is computed from real CPU time;
  rusage reports Mach ticks, converted to nanoseconds.

## Privacy

Logs never record what the user typed: no key codes or characters from the
keyboard tap or NORMAL's interpreter, no on-screen text of hint targets, no
query text, candidate data, clipboard content or config values. Plugins
follow the same rule for their `log` lines.
