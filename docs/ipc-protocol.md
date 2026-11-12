# IPC protocol

## Overview

The resident listens on one Unix domain socket. Everything outside Flash
that drives it goes through that socket: the `flash` command in a terminal,
a shell script, a hotkey daemon such as skhd, Hammerspoon, a launcher. The
protocol does two things:

- **Requests.** A request carries the words of a command line and runs them
  exactly as `:<words>` would: the same resolver, the same commands (the
  focused app's plugin commands included), the same runner. The reply says how
  the run ended, with the same exit status the CLI uses.
- **Events.** A subscription streams host events as they happen: mode
  changes, the focused app and window, configuration reloads, hint sessions,
  monitors rising into warning or error, tiling workspaces, sleep, displays,
  USB and more.

There are three parties. The **resident** (`Flash.app` or `Flash 🧪.app`,
whichever runs) owns the socket. The **`flash` CLI** is the client scripts
use: `flash <topic> <action>` is a request, `flash --json` prints the reply
as JSON, and `flash events watch` prints the event stream. **Your own
programs** may speak the socket directly, in any language, with the messages
below; the [JSON Schemas](#schemas) pin each one.

This is not the [plugin protocol](plugin-protocol.md). Plugins are child
processes the resident starts and talks to over their stdio; this socket is
for programs the resident did not start. Both carry the same host events,
from one catalog. The [commands](commands.md) page lists every command a
request can run.

## Quick start

With the CLI, a command, its reply as JSON, and two events:

```sh
flash mode normal                      # exit 0: it ran
flash --json tab next                  # the reply object, same exit status
# {"message":"the focused app has no tab next","status":"failed"}
flash events watch --name='core:mode.changed,core:hints.*' --count=2
# {"name":"core:mode.changed","payload":{"mode":"normal","previous":"insert"},"seq":41,"time_ms":1792759246395,"type":"event"}
# {"name":"core:hints.shown","payload":{"surface":"targets","targets":24},"seq":42,"time_ms":1792759247012,"type":"event"}
```

`flash` starts Flash when it is not running and waits for the socket (see
[limits and timeouts](#limits-and-timeouts)).

The same session over the raw socket. `>` is a line the client writes, `<` a
line the resident writes:

```text
# connect to ~/Library/Application Support/Flash/run/flash.sock
> {"type":"hello","protocol":1,"client":"my-script 1.0"}
< {"limits":{"handshake_timeout_ms":5000,"max_connections":32,"max_frame_bytes":1048576,"max_in_flight":16,"max_patterns":64,"max_queued_event_bytes":4194304,"max_queued_events":256,"max_reply_bytes":8388608},"pid":4242,"protocol":1,"server":"Flash 1.1.0 (1)","type":"welcome"}
# a command: the words after `flash`, and where relative paths resolve
> {"type":"request","id":"1","words":["mode","normal"],"cwd":"/Users/me"}
< {"id":"1","result":{"status":"succeeded"},"type":"result"}
# a subscription: event names or globs
> {"type":"subscribe","id":"2","events":["core:mode.changed","core:hints.*"]}
< {"events":["core:hints.cancelled","core:hints.committed","core:hints.shown","core:mode.changed"],"id":"2","type":"subscribed"}
< {"name":"core:mode.changed","payload":{"mode":"insert","previous":"normal"},"seq":43,"time_ms":1792759250120,"type":"event"}
< {"name":"core:hints.shown","payload":{"surface":"grid","targets":30},"seq":44,"time_ms":1792759251004,"type":"event"}
# close the connection: the subscription ends with it
```

`nc`, which ships with macOS, is enough to try it. A request, then EOF; the
resident still writes the reply before it closes:

```sh
socket="$HOME/Library/Application Support/Flash/run/flash.sock"
printf '%s\n' '{"type":"hello","protocol":1}' \
  '{"type":"request","id":"1","words":["resident","status","--json"]}' | nc -U "$socket"
```

A subscription needs its connection open; `cat` keeps it open until Control-C:

```sh
{ printf '%s\n' '{"type":"hello","protocol":1}' \
    '{"type":"subscribe","id":"s","events":["core:focus.changed"]}'; cat; } | nc -U "$socket"
```

### From other tools

A hotkey daemon runs the CLI. skhd, in `~/.config/skhd/skhdrc` (spell the
path: skhd's `PATH` may not hold `~/.local/bin`):

```text
cmd + alt - f : ~/.local/bin/flash mouse target
cmd + alt - g : ~/.local/bin/flash mouse grid
```

Hammerspoon, a command and the event stream (`hs.task` hands output over in
chunks, so lines are reassembled):

```lua
local flash = os.getenv("HOME") .. "/.local/bin/flash"
hs.hotkey.bind({"cmd", "alt"}, "f", function()
  hs.task.new(flash, nil, {"mouse", "target"}):start()
end)

local pending = ""
watcher = hs.task.new(flash, nil, function(_, out)
  pending = pending .. out
  for line in pending:gmatch("([^\n]*)\n") do
    local event = hs.json.decode(line)
    if event and event.name == "core:mode.changed" then
      hs.alert.show(event.payload.mode)
    end
  end
  pending = pending:match("[^\n]*$")
  return true
end, {"events", "watch", "--name=core:mode.changed"})
watcher:start()
```

A shell loop, with `plutil` (or `jq` where installed) reading each line:

```sh
flash events watch --name=core:focus.changed | while IFS= read -r line; do
  app=$(printf '%s' "$line" | plutil -extract payload.bundle_id raw -o - -)
  echo "now in $app"
done
```

## Transport and framing

- **Socket.** A Unix domain stream socket at
  `~/Library/Application Support/Flash/run/flash.sock`. The home directory is
  the account's, never `$HOME`. There is no TCP listener.
- **One resident, one path.** The dev bundle (`Flash 🧪.app`) and the release
  bundle (`Flash.app`) share the bundle identifier and the resident lock
  (`~/Library/Application Support/Flash/resident.lock`): a second resident
  exits before it binds, so they never run side by side and one path serves
  whichever runs. The resident binds under a staging name, makes the socket
  `0600`, starts listening and only then renames it over the path, so a
  client that finds the path can connect. A stale socket a crashed resident
  left is replaced; one another process still accepts on is never taken
  over.
- **Framing.** Newline-delimited JSON: each message is one JSON object, UTF-8,
  on one line, ending in `\n`. Blank lines are skipped. Field order does not
  matter; the resident writes keys sorted.
- **Concurrency.** A connection may have several requests running at once
  and a subscription at the same time; replies carry the request's `id`
  and may arrive in any order, interleaved with events.
- **Closing.** Either side may close at any time. A client that sends EOF
  (`shutdown(SHUT_WR)`, as `nc` does when its input ends) still receives the
  results of the requests it sent, then the resident closes; EOF ends a
  subscription at once. A command a closed connection asked for still runs
  to its end.

## Handshake and versioning

The first message is `hello`, with the one protocol version the client
speaks. The resident answers `welcome` with its version and limits, or an
`error` with code `protocol_mismatch` (carrying the version it speaks) and
closes. Anything else first, a second `hello`, or nothing within
`handshake_timeout_ms`, closes the connection with `handshake_required` or
`handshake_timeout`.

The current version is **1**. The resident speaks exactly one version; see
the [compatibility policy](#compatibility-policy).

## Message reference

| Message | Direction | Purpose |
| --- | --- | --- |
| [`hello`](#hello) | client → resident | Open the session with a protocol version |
| [`welcome`](#welcome) | resident → client | Accept it: the version, the resident, its limits |
| [`request`](#request) | client → resident | Run a command line's words |
| [`result`](#result) | resident → client | How a request's run ended |
| [`subscribe`](#subscribe) | client → resident | Replace the connection's event subscription |
| [`subscribed`](#subscribed) | resident → client | The events now subscribed |
| [`event`](#event) | resident → client | One host event |
| [`error`](#error) | resident → client | A refused line, request or connection |

Unknown fields are refused: a `hello` with one closes the connection, a
`request` or `subscribe` with one is answered `invalid_request`.

### `hello`

| Field | Type | |
| --- | --- | --- |
| `type` | `"hello"` | |
| `protocol` | integer | The version the client speaks: `1` |
| `client` | string, optional | The client's name and version, at most 128 bytes, for the resident's log |

```json
{"type":"hello","protocol":1,"client":"my-script 1.0"}
```

### `welcome`

| Field | Type | |
| --- | --- | --- |
| `type` | `"welcome"` | |
| `protocol` | integer | `1` |
| `server` | string | `Flash <version> (<build>)` |
| `pid` | integer | The resident's process id |
| `limits` | object | The [limits](#limits-and-timeouts) it applies, by name |

```json
{"limits":{"handshake_timeout_ms":5000,"max_connections":32,"max_frame_bytes":1048576,"max_in_flight":16,"max_patterns":64,"max_queued_event_bytes":4194304,"max_queued_events":256,"max_reply_bytes":8388608},"pid":4242,"protocol":1,"server":"Flash 1.1.0 (1)","type":"welcome"}
```

### `request`

| Field | Type | |
| --- | --- | --- |
| `type` | `"request"` | |
| `id` | string | 1 to 128 bytes, chosen by the client, distinct among its requests in flight |
| `words` | array of strings | The words after `flash`, 1 to 1024 of them: `["tab", "next"]`, `["window", "move", "--position=lefthalf"]`, `["#aws", "whoami"]` |
| `cwd` | string, optional | An absolute directory where relative paths in the words resolve (`open`, `:!`, `menu choose --file`) |

The words resolve exactly as on the command line: abbreviations
(`["ta", "nex"]`), vim aliases (`["q"]`), plugin commands, `open`,
`flashlight`, `!` and a leading `#` that also copies the output to the
clipboard. A script should spell commands in full: a prefix can become
ambiguous when a plugin adds a command.

```json
{"type":"request","id":"7","words":["window","move","--position=lefthalf"],"cwd":"/Users/me"}
```

### `result`

| Field | Type | |
| --- | --- | --- |
| `type` | `"result"` | |
| `id` | string | The request's |
| `result.status` | string | `succeeded` (it ran: the CLI exits 0), `failed` (it ran and failed, or found nothing to act on: exit 1), `rejected` (the words name no command, or more than one: exit 2), `local` (a query the client runs itself) |
| `result.output` | string, optional | What the command printed |
| `result.message` | string, optional | Why it failed or was rejected |
| `result.query`, `result.arguments` | string, object, optional | For `local`: the query's words and its `--name=value` arguments |

`result` is the object `flash --json` prints. A `local` result names a query
the resident leaves to its client: `config check`, which reads the client's
own files and environment, and `events watch`, which over the socket is the
`subscribe` message. A command that asks for confirmation counts as run once
the question is up.

```json
{"id":"7","result":{"message":"the focused app has no tab next","status":"failed"},"type":"result"}
```

### `subscribe`

| Field | Type | |
| --- | --- | --- |
| `type` | `"subscribe"` | |
| `id` | string | As for `request` |
| `events` | array of strings | At most 64 event names or globs (`*` is the only wildcard: `core:*`, `core:hints.*`), each naming at least one [streamed event](#events); empty unsubscribes |

Each `subscribe` replaces the connection's subscription. A pattern that names
no streamed event refuses the whole message with `unknown_event`.

```json
{"type":"subscribe","id":"s","events":["core:focus.changed","core:workspace.changed"]}
```

### `subscribed`

| Field | Type | |
| --- | --- | --- |
| `type` | `"subscribed"` | |
| `id` | string | The `subscribe`'s |
| `events` | array of strings | The event names the patterns named, sorted |

Every event emitted after `subscribed` is sent, subject to the
[subscriber's queue](#limits-and-timeouts); none emitted before it is.

```json
{"events":["core:focus.changed","core:workspace.changed"],"id":"s","type":"subscribed"}
```

### `event`

| Field | Type | |
| --- | --- | --- |
| `type` | `"event"` | |
| `seq` | integer | One sequence for all of this resident's subscribers, from 1: a gap is an event this client did not ask for, or one its queue [coalesced](#limits-and-timeouts) |
| `name` | string | One of the [events](#events) |
| `time_ms` | integer | When it was emitted, in milliseconds since 1970 |
| `payload` | object | The event's fields |

```json
{"name":"core:focus.changed","payload":{"bundle_id":"com.apple.Notes","localized_name":"Notes","pid":812},"seq":12,"time_ms":1792759246395,"type":"event"}
```

### `error`

| Field | Type | |
| --- | --- | --- |
| `type` | `"error"` | |
| `code` | string | One of the [codes](#errors) |
| `message` | string | What went wrong, for a person |
| `id` | string, optional | The `request` or `subscribe` it answers; absent for the connection's own errors |
| `protocol` | integer, optional | With `protocol_mismatch`: the version the resident speaks |

```json
{"code":"protocol_mismatch","message":"this resident speaks protocol 1, not 2","protocol":1,"type":"error"}
```

## Events

The stream carries the host events of the one catalog plugins and
[monitors](monitors.md#runs-and-events) hear too, minus the plugin plumbing
(below). An OS source behind an event runs only while something subscribes
to it, a socket client included; with no subscriber an event costs nothing.

| Event | When | Payload |
| --- | --- | --- |
| `core:mode.changed` | Flash's mode changed | `mode`, `previous`: `normal`, `insert`, `command`, `terminal`, `hyper`, `hold`, `visual` (a [VISUAL](visual-mode.md) selection, of characters or lines), `disabled`, or the active [layer](layers.md)'s name |
| `core:hints.shown` | A hint session drew its first labels | `surface` (`targets`, `screen`, `words`, `scroll`, `grid`, `bigram`, `positions`, `screens`, `mouse_dock`, `mouse_menubar`, `mouse_notifications`, `window_switcher`), `targets` |
| `core:hints.committed` | It committed a target (once per target in a `--multi` or `--sticky` session) | `surface` |
| `core:hints.cancelled` | It ended without committing | `surface` |
| `core:focus.changed` | Another app came forward | `bundle_id`, `localized_name`, `pid` |
| `core:window.focus.changed` | The focused app's focused or main window changed | `bundle_id`, `pid` |
| `core:apps.launched`, `core:apps.terminated` | An app launched or quit | `bundle_id`, `localized_name`, `pid` |
| `core:config.changed` | The configuration loaded (at launch, then on every change) | — |
| `core:monitor.triggered` | A value [monitor](monitors.md) rose into warning or error | `monitor`, `level` (`warning`, `error`) |
| `core:workspace.changed` | The focused [tiling](tiling.md) workspace changed | `workspace`, `previous` (optional), `workspaces` |
| `core:space.changed` | The active Space changed | — |
| `core:displays.changed` | A display was connected or removed | `added`, `removed`, `displays` (names) |
| `core:power.changed` | The power source or battery changed | — |
| `core:network.changed` | Interfaces, addresses, routes or DNS changed | — |
| `core:volumes.changed` | A volume mounted, unmounted or was renamed | — |
| `core:system.slept`, `core:system.woke` | The Mac went to sleep, and woke | — |
| `core:displays.slept`, `core:displays.woke` | The displays slept, and woke | — |
| `core:screen.locked`, `core:screen.unlocked` | The lock screen came up, and went away | — |
| `core:user.idle` | Nobody touched the keyboard, mouse or trackpad for 300 s | `seconds` |
| `core:user.active` | Input came back after such an episode | `idle_seconds` |
| `core:usb.attached`, `core:usb.detached` | A USB device was connected, or removed | `vendor_id`, `product_id`, `name`, each when the device reports it; never a serial number |
| `core:clock.minute` | A wall-clock minute began, in the local time zone | `time` (`"09:55"`), `weekday` (`"fri"`), `date` (`"2026-10-23"`), `late_seconds` |

Examples:

```json
{"name":"core:mode.changed","payload":{"mode":"resize","previous":"normal"},"seq":7,"time_ms":1792759246395,"type":"event"}
{"name":"core:hints.committed","payload":{"surface":"targets"},"seq":8,"time_ms":1792759247810,"type":"event"}
{"name":"core:monitor.triggered","payload":{"level":"warning","monitor":"battery"},"seq":9,"time_ms":1792759301000,"type":"event"}
{"name":"core:workspace.changed","payload":{"previous":"1","workspace":"2","workspaces":["1","2","3"]},"seq":10,"time_ms":1792759302114,"type":"event"}
{"name":"core:usb.attached","payload":{"name":"Keyboard","product_id":3,"vendor_id":1452},"seq":11,"time_ms":1792759310002,"type":"event"}
```

Not streamed, because only a plugin can use them: `core:apps.changed` (the
running-apps snapshot a plugin's catalog keys on; `core:apps.launched` and
`core:apps.terminated` report the changes), `core:ax.changed` (an observed
app's Accessibility notifications: every keystroke posts one, so its timing
alone would leak typing), `core:session.opened` and `core:status.observed`.
Subscribing to one is an `unknown_event`.

Status values (`#{…}`) are not events: Flash evaluates a value only while a
surface shows it, and a value can carry whatever a command printed. A
[monitor](monitors.md) turns a value's rise into `core:monitor.triggered`.

## Errors

| Code | Meaning | Connection | What a client should do |
| --- | --- | --- | --- |
| `malformed` | The line is not a JSON object with a known `type`, a `hello` has the wrong fields, or a `request`/`subscribe` has no usable `id` | Closed | Fix the client |
| `frame_too_large` | A line longer than `max_frame_bytes` | Closed | Send shorter lines |
| `handshake_required` | Something other than `hello` came first, or `hello` came twice | Closed | Say `hello` once, first |
| `protocol_mismatch` | `hello` named another version; `protocol` says which one this resident speaks | Closed | Use the `flash` of the running bundle, or update the client |
| `handshake_timeout` | No `hello` within `handshake_timeout_ms` | Closed | Say `hello` right after connecting |
| `too_many_connections` | `max_connections` are open | Closed | Close idle connections; retry |
| `invalid_request` | A `request` or `subscribe` whose fields are wrong, or whose `id` is already running | Open | Fix that message |
| `too_many_requests` | `max_in_flight` requests are already running here | Open | Wait for a result, or open another connection |
| `unknown_event` | A `subscribe` pattern names no streamed event | Open | Check the names against [events](#events) |
| `reply_too_large` | The result was larger than `max_reply_bytes` | Open | Ask for less output |
| `overflow` | This subscriber fell `max_queued_events` behind | Closed | Read faster; reconnect and subscribe again, then re-read the state the missed events described |
| `shutting_down` | The resident is quitting | Closed | Reconnect once Flash runs again |

A peer that does not run as the resident's user is not answered at all: the
connection closes before it is read.

## Limits and timeouts

| Limit | Value | |
| --- | --- | --- |
| `max_frame_bytes` | 1 MiB | The longest line a client may send |
| `max_reply_bytes` | 8 MiB | The longest line the resident sends; a larger result becomes `reply_too_large` |
| `max_connections` | 32 | Connections at once; more are refused with `too_many_connections` |
| `max_in_flight` | 16 | Requests one connection may run at once |
| `max_patterns` | 64 | Patterns in one `subscribe` |
| `max_queued_events`, `max_queued_event_bytes` | 256, 4 MiB | Events that may wait unread for one subscriber |
| `handshake_timeout_ms` | 5000 | The time to say `hello` |

**A slow subscriber.** Events wait in a bounded queue per connection. A
state signal (`core:mode.changed`, `core:focus.changed`,
`core:window.focus.changed`, `core:config.changed`, `core:power.changed`,
`core:network.changed`, `core:volumes.changed`, `core:space.changed`,
`core:workspace.changed`) that has not been sent yet is replaced by a newer
one of the same name, which joins the end of the queue: a reader that falls
behind still sees the latest state, in emission order, and a gap in `seq`.
When the queue still overflows, every unsent event is dropped for an
`overflow` error and the resident closes the connection once that error is
read, or one second later. Results are never dropped for events: they
leave in order with them.

**Timeouts.** The resident sets none on a request: a command runs to its end,
a confirmation waits for its answer. The `flash` CLI waits 10 s for
`welcome`, five minutes for a result and indefinitely for events. When Flash
is not running, the CLI opens the app bundle it lives in through Launch
Services (in the background, without activating it) and waits up to 15 s for
the socket, woken by each change to the socket's directory rather than by a
timer; it never starts a second resident, and it does not start one to run
`resident quit` or words Flash's own commands reject.

## Security

- **Who can connect.** The socket's directory,
  `~/Library/Application Support/Flash/run/`, is the user's own, mode
  `0700`; the resident refuses to listen in one that is a symbolic link or
  belongs to another account, and tightens a looser mode. The socket is
  `0600`. Every connection's peer is checked with `getpeereid`: a process of
  another user, `root` included, is closed before it is read. The CLI checks
  the server the same way.
- **What a connection can do.** Anything you can type after `:`, with
  Flash's permissions: click, type, read what Accessibility exposes, run
  `!` shell lines. A program running as you could already do as much, so the
  socket adds no new reach ([SECURITY.md](https://github.com/aymericbeaumet/flash/blob/main/SECURITY.md#trust-model)).
  Sandboxed plugins are the exception the resident enforces: their sandbox
  denies connecting into the socket's directory even when they may use the
  network, so a plugin cannot leave its sandbox through Flash.
- **What never crosses the wire.** Events never carry keys, typed text,
  clipboard content, window titles, a hint's target, its text or its label,
  status values, or a monitor's value. A request's words and its output are
  yours; the resident logs a request as it logs a command line
  ([observability](observability.md)).
- **No network.** The socket is local to the Mac and never a TCP port; the
  [privacy](privacy.md) page lists it with Flash's other listeners.

## Schemas

Every message has a JSON Schema (draft-07), and `IPCSchemaTests` validates
the messages the CLI and the resident really encode against them:

- [`client-message.schema.json`](schema/ipc/client-message.schema.json): any
  line a client sends
- [`server-message.schema.json`](schema/ipc/server-message.schema.json): any
  line the resident sends
- [`hello.schema.json`](schema/ipc/hello.schema.json),
  [`request.schema.json`](schema/ipc/request.schema.json),
  [`subscribe.schema.json`](schema/ipc/subscribe.schema.json)
- [`welcome.schema.json`](schema/ipc/welcome.schema.json),
  [`result.schema.json`](schema/ipc/result.schema.json),
  [`subscribed.schema.json`](schema/ipc/subscribed.schema.json),
  [`event.schema.json`](schema/ipc/event.schema.json) (each event's payload),
  [`error.schema.json`](schema/ipc/error.schema.json)

## Compatibility policy

- **One version at a time.** The resident speaks exactly one protocol version
  and refuses every other with `protocol_mismatch`. A change that alters or
  removes a message, a field or a meaning, or adds anything a client must
  send, is a new version, and the old one goes with it: no compatibility
  shims, no dual readers, no transitional accept-both period.
- **Additions are not versions.** A new event, error code, limit or a field
  the resident sends appears within the current version. Read what you know
  and ignore the rest; the schemas describe exactly what this version sends.
- **The CLI always matches.** `flash` ships in the same bundle as its
  resident and speaks its version. A program that speaks the socket directly
  reads `welcome.protocol`, and is updated with Flash's release notes.
