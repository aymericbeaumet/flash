# Plugin protocol

This is the complete, language-agnostic contract between Flash and a plugin:
any executable that speaks it over stdio is a valid plugin. Most plugins are
written with the [Rust SDK](plugin-rust-sdk.md), which implements all of it,
and the [cookbook](plugin-cookbook.md) builds one end to end. Read this page
to write a plugin in another language, to debug one at the wire, or to know
exactly what the SDK does for you.

## Overview

Three parties take part:

- **The host** is the Flash resident. It spawns each plugin, owns its
  lifetime, sends it requests and events, stores what it publishes, and
  performs every effect that needs the user's Mac (clicks, app activation,
  opening URLs) on its behalf.
- **The plugin** is a child process the host spawns from the plugin's
  manifest, usually sandboxed. It reads requests and events on stdin and
  writes replies and notifications on stdout. stderr is for diagnostics.
- **The manifest** (`manifest.json` at the plugin's root) declares what the
  plugin provides: flashlight sources, an evaluator, hints, commands, bangs,
  status segments, key mappings and app bindings, plus the capabilities and
  sandbox allowances it needs. The host reads it before spawning anything and
  routes the plugin only what it declares, plus the running-apps snapshot
  live plugins get at startup; `publish_then_exit` plugins receive no events.

```
 host                                          plugin
  │ spawn (scrubbed env, sandbox profile)        │
  │ ── initialize {protocol_version} ──────────▶ │
  │ ◀───────────── {ok, protocol_version} ────── │  reply at once
  │ ── event core:apps.changed ────────────────▶ │  running-apps snapshot
  │ ◀──────────────── publish / status / poll ── │  any time after spawn
  │ ── evaluate · hints · text_grid · perform ─▶ │  requests, each with a deadline
  │ ◀──────────────────────────── {ok, …} ────── │  exactly one reply each
  │ ◀──────────── host.open · host.fetch · … ─── │  host RPCs, capability-gated
  │ ── event core:… ───────────────────────────▶ │  only what `listen` matches
  │ close stdin                                  │  EOF: clean up, exit 0
```

What the host asks of a plugin depends on its manifest: a plugin with
`sources`, `query`, `hints`, `status` or `listen` runs from startup (one
with only `status` while a surface shows its segments), one that only
declares `commands`, `bangs` or `navigation` starts on first use, and a
manifest without `exec` never runs a process at all
([details](#process-model-and-lifecycle)).

## Quick start

A complete session with a small plugin whose manifest declares one source
(`example.items`), an evaluator for input starting with `=`, a command
(`example run`) and the `open` capability. `▶` lines are the host writing to
the plugin's stdin, `◀` lines the plugin writing to stdout; on the wire each
is one line of JSON with nothing before it.

```
▶ {"id":1,"method":"initialize","params":{"protocol_version":1},"deadline_ms":4999}
◀ {"id":1,"result":{"ok":true,"protocol_version":1}}
▶ {"method":"event","params":{"name":"core:apps.changed","payload":{"running_applications":[{"bundle_id":"com.apple.Safari","pid":512,"localized_name":"Safari"}]}}}
◀ {"method":"publish","params":{"source":"example.items","rows":[{"source":"example.items","title":"Example home","url":"https://example.com"}]}}
◀ {"method":"poll","params":{"registrations":{"refresh":{"every":300,"priority":"low"}}}}
▶ {"id":2,"method":"evaluate","params":{"query":"=2+2"},"trace":"k3x9","deadline_ms":49}
◀ {"id":2,"result":{"ok":true,"answers":[{"title":"4","effect":{"type":"copy_text","text":"4"}}]}}
▶ {"method":"event","params":{"name":"core:poll:refresh","payload":{}}}
◀ {"method":"log","params":{"level":"info","message":"refreshed","fields":{"rows":"1"}}}
▶ {"id":3,"method":"perform","params":{"kind":"command","command":"example","subcommand":"run","args":[]},"deadline_ms":9999}
◀ {"id":1,"method":"host.open","params":{"url":"https://example.com"}}
▶ {"id":1,"result":{"ok":true,"bundle_id":"com.apple.Safari"}}
◀ {"id":3,"result":{"ok":true,"message":"Opened"}}
```

Step by step:

1. **Handshake.** The host's first request is `initialize`. The plugin
   answers at once with its protocol version, before any startup work.
2. **Seed.** The host sends the running applications, whatever the plugin
   listens to.
3. **Publish.** The plugin pushes its catalog whenever it has one; the host
   stores it, so the flashlight never waits on the plugin. It asks the host
   to wake it every 300 s instead of arming its own timer.
4. **Evaluate.** As the user types `=2+2`, the host asks for answers, with
   49 ms left to reply and the interaction's `trace` id.
5. **Tick.** The registered cadence fires as an event.
6. **Perform.** The user runs `:example run`. While serving it, the plugin
   makes its own request to the host (`host.open`, numbered from its own
   counter, so its `id: 1` does not clash with the host's), gets the reply,
   then answers the host's request 3.

When Flash quits or the plugin is reloaded, the host closes stdin and the
plugin exits. Try it by hand: run any plugin binary in a terminal and type
these lines at it; no host is needed.

## Process model and lifecycle

Plugins are Flash-owned child processes. Official plugins ship inside the app
bundle; third-party plugins are listed in `[plugins] third_party` as
`github:user/project@<commit-sha>` (full 40-character SHA, mandatory — the
materializer fetches exactly that commit and refuses a mismatched checkout) or
`file:<path>`. The manifest's optional `install` shell string (third-party
only) runs sandboxed from the plugin root on an asynchronous install job.
The job owns a process group, drains both output pipes while it runs, retains
at most 4 MiB stdout / 256 KiB stderr, and escalates timeout or cancellation
from SIGTERM to SIGKILL after 500 ms. A stopped/replaced attempt cannot write
an install stamp or launch a child. Install attempts for the same canonical
root run in submission order across process replacements. Cancellation keeps
ownership until the old group exits; cancelled waiting attempts never spawn.
`exec` is an argv array exec'd
directly with the scrubbed plugin environment — no shell wrap. Its first
element resolves in order: absolute paths pass through, `./`-style paths
resolve against the plugin root (official Rust plugins), and bare names resolve
through `mise which` then a login-PATH walk. This keeps the protocol open to
third-party executables without adding runtime bridges to the official bundle.

Runtime children receive `FLASH_PLUGIN_ID`, `FLASH_PLUGIN_VERSION`,
`FLASH_PLUGIN_DATA_DIR`, and the plugin's
`[plugins.<id>]` settings as a JSON object in `FLASH_PLUGIN_CONFIG`: the
values its manifest [`settings`](#manifest) accept, over their defaults. Flash
builds a scrubbed environment containing only basic locale/path/process keys
plus those values; ambient tokens, agent sockets, SDK search paths, and
login-shell secrets are not inherited — put credentials in the plugin's
config table. Install CLI tools under `FLASH_PLUGIN_DATA_DIR`, never into
global shell paths. A child is spawned only once the host's login environment
has resolved, so its `PATH` is the user's; a resolution that fails keeps the
seeded one.

**Activation.** Unless it declares `publish_then_exit` (below), a plugin is
*resident* — spawned at startup and kept running — iff its manifest declares
pushed `sources`, `query`, `hints`, `status`, or `listen` without live
sources.
A plugin declaring only on-demand surfaces (`commands`, `bangs`,
`navigation`, live `sources`) is *on-demand*: it stays unspawned until its
first `perform` or `search`, which launches it, and then it stays running
normally. The `perform` deadline comfortably absorbs the startup budget. A
`search` waits for the child instead, up to the `startup` deadline, and its
own deadline starts when the request is written: the first query scoped to
a cold plugin is answered, and while the child starts only the newest query
of a source waits. Manifest-only plugins (no `exec`) never spawn at all.

A *live-bound* plugin — live `sources` with no pushed `sources`, `query`,
`hints` or `status`, its `listen` subscriptions presumed to feed those rows
— is on-demand too: nothing reads its rows until a query is scoped to them,
so the events keep no process. It hears them from its first `search` or
`perform` on, starting from the running-apps snapshot every new child gets.
The bundled `notes`, `reminders` and `contacts` plugins run this way.

An on-demand plugin is *warm* when a configured mapping (any mode or app
scope, an enabled status-bar click, or a plugin's `mappings`) runs one of
its commands. Ten seconds after each reconcile the host spawns every warm
on-demand plugin that is still idle, so the first keypress does not wait on
process creation. See
[warm plugins](plugin-performance.md#process-creation-and-warm-plugins).

A *status-bound* plugin — `status` with no pushed `sources`, `query` or `hints`, its
`listen` subscriptions presumed to feed those segments — is resident only while
the enabled status bar, one of its popups or a desktop widget
shows one of its segments; otherwise it is on-demand. A config reload that
starts showing it spawns it; one that stops showing it stops the process and
returns it to on-demand, unless it has run a `perform` or a mapping keeps it
warm: on-demand plugins stay running once a command needs them, and a child
that has run a command stays whatever started it, a surface or a mapping,
because the command may have left it holding what ends with the process (a
power assertion). Such a child stops only on `plugins reload`, a change to
its files or settings, being disabled, a crash or Flash quitting.
`:plugins show` reports the effective activation.

A *publish-then-exit* plugin (manifest `"lifecycle": "publish_then_exit"`)
provides data and nothing else: `exec` and pushed `sources`, none of the
surfaces a live child serves (`hints`, `query`, `status`, `listen`,
`commands`, `bangs`, `navigation`, a source declared `live`). It is spawned at startup like a resident plugin, but its run is
`on_start`: it publishes its catalog and exits 0 on its own. The host reads
its stdout to the end, keeps the catalog as it keeps every catalog across
restarts, reports the plugin as `published`, and counts that exit as success:
no restart, no failure budget spent, no event delivered (not even the
running-apps snapshot). A perform for it is `unhandled`, so its rows must
carry host effects (`copy_text`, `insert_text`, `open`), as the emoji rows
carry `insert_text`. A non-zero exit or a signal is still a
crash and backs off like any other. The host runs it again only when its data
can have changed: its `[plugins.<id>]` settings changed, a file named by one
of its `watch_settings` changed (an atomic save, a creation and a removal all
count; a change runs it once after 300 ms of quiet), `plugins reload`, or
its own files changed. `watch_settings` lists setting names whose string
value is the file's path — `~` expands to the home, a relative path is under
the plugin root — and needs this lifecycle. The bundled `emojis` and
`snippets` plugins run this way; a plugin that must answer a command or an
event keeps a child, so `shortcuts` (its `open` and `refresh` commands, its
focus-driven relist) does not.


A manifest for static data can declare a watched file without live surfaces:

```json
{
  "id": "catalog",
  "name": "Catalog",
  "version": "0.1.0",
  "description": "Static items from a configured file",
  "exec": ["./flash-plugin-catalog"],
  "lifecycle": "publish_then_exit",
  "settings": {
    "file": { "type": "string", "description": "The file of items to publish." }
  },
  "watch_settings": ["file"],
  "sources": [
    { "name": "catalog.items", "type": "items", "kind": "locations", "priority": "normal" }
  ]
}
```

**Lifecycle state machine.**

```
initial / idle → installing → launching → running
                   │            │          │
                   └────────────┴──────────┴── failure → backoff → installing
                                                        │
                                               budget exhausted → failed
running → exit 0 (publish_then_exit) → published (catalog kept; reload restarts)
stop → stopped (all attempt work invalidated)
```

`launching` = spawned, awaiting the initialize reply; the host dispatches no
other requests and no events until `running`. Restarts back off linearly
(1..30 s); after five retries within 300 s, another failure parks the plugin in `failed` (recover with
`:plugins reload` or a plugin-file change). Successful initialize does not
reset the rolling failure budget; even an initialize-then-crash loop parks,
and a status-bound plugin that stops being observed keeps its budget too.
Lifecycle transitions belong to attempt generations. Stop/reload invalidates
pending retries, installation completions, and transport work. Rejected
initialize replies park immediately. The published catalog survives
crashes and restarts (see `publish`) and is dropped on `failed` or unload.
A planned reload keeps the previous status values for up to ten seconds,
until each is republished, measured from the newest replacement; any other
teardown clears them. In-flight `perform`s settle as errors.
A reload restarts only what changed: an unchanged definition keeps its
catalog, a changed one is rebuilt from scratch, and an invalid replacement
keeps the last valid one running and reports its load error. The details
are under [For Flash contributors](#for-flash-contributors).

**Shutdown.** There is no shutdown method. The host closes the plugin's
stdin; **stdin EOF is the shutdown signal** — run cleanup, exit 0. The host
waits `shutdown_grace` (1 s), then SIGTERM, then (+0.5 s) SIGKILL.

**Liveness.** There is no periodic heartbeat. The process termination handler
catches child exit; a hung request is caught by its own deadline. The one residual probe: if
the host has received *no frame at all* from a plugin for `idle_before_ping`
(60 s) and has nothing in flight, it sends `ping`; one missed reply (10 s)
tears down and restarts. Any plugin frame — a publish, a log line, a response
— resets the idle clock. A blocking single-threaded plugin is fully
conformant: pings never race in-flight requests. The host checks idleness on
one shared low-priority sweep at half that threshold (registered only while a
plugin runs, held while the displays sleep), so the ping follows 60–90 s of
silence; a chatty plugin is never pinged and costs no wake-up.

## Transport and framing

NDJSON on stdin/stdout: UTF-8, one JSON object per newline-terminated line, no
envelope beyond `id`/`method`/`params`/`result` (`id`+`method` = request,
`id` alone = response, `method` alone = notification), plus the host's
optional `trace` on a request: the id (`^[0-9a-z]{1,16}$`) of the user
interaction that caused it. A `log` notification emitted while serving that
request carries it back as `params.trace` (the Rust SDK does both), so one
interaction reads end to end across processes; see
[observability](observability.md). Every request also carries `deadline_ms`,
the milliseconds the host still waits for its reply as it writes it.
`params`, `result` and an event's `payload` are JSON objects, never
positional arrays: either end refuses an array where an object belongs. Ids
are positive monotonic integers per sender. Booleans and floating-point
values are never integer IDs or protocol versions; `ok` and other Boolean
fields accept only JSON booleans. Native process IDs are checked positive
32-bit integers.
Host and plugin counters are independent and
may overlap — an inbound `id`+`method` frame is always a request, never a
reply. Exactly one reply per id'd request; responses to unknown ids are
dropped. There is **no cancellation** message: late replies are dropped and
the deadline table is the contract. A plugin may stop a handler whose answer
would come too late: the Rust SDK drops a `hints`, `text_grid` or `search`
handler still running a tenth of `deadline_ms` (at most 50 ms) before it,
which answers `{"ok": false, "error": "deadline exceeded"}` and logs a warning under the
request's trace; `evaluate` and `perform` run to completion. Lines are capped at 10 MiB in both
directions, excluding the terminating newline; an undecodable or oversized line is dropped (never fatal) and the
stream self-heals at the next newline. An outbound response that would exceed
the cap is replaced by `{"ok": false, "error": "response exceeded outbound
frame limit"}` under the same id. stderr is diagnostics only — lines are
logged but never treated as plugin failure; use the `log` notification for
structured logging (recorded with `source = "plugin:<id>"`); stderr is logged
as whole lines, each capped at 4 KiB, at most 20 per 10 s, and the rest are
counted. Geometry is
always NSScreen coordinates.

## Handshake and versioning

The host's first request to a new process is `initialize`, and nothing else
is sent until it is answered:

```
▶ {"id":1,"method":"initialize","params":{"protocol_version":1},"deadline_ms":4999}
◀ {"id":1,"result":{"ok":true,"protocol_version":1}}
```

- **Reply immediately**: no warm-catalog wait and no startup work first.
  `on_start` hooks run after the reply and publish when ready.
- **Echo your own version.** The reply always carries the plugin's own
  `protocol_version`, the stale-binary diagnostic.
- **A mismatch is terminal.** Another host version gets `{"ok": false,
  "protocol_version": 1, "error": "protocol version mismatch: host v<H>,
  plugin v1"}`, then the plugin flushes and exits 0. Any `ok: false`
  initialize reply parks the plugin in `failed`: no automatic restart, but
  file watchers stay armed so a rebuilt binary recovers.
- **Once only.** A repeated `initialize` on a healthy plugin is the one
  non-terminal protocol NAK: reply `{"ok": false, "error": "initialize may
  only be called once"}` and keep serving.
- **On time.** No reply within `startup` (5 s by default,
  `[plugins] startup_timeout`) tears the process down and
  restarts it with backoff.
- **Then the snapshot.** Right after the reply, the host delivers one
  `core:apps.changed` event to every plugin, whatever its `listen`, carrying
  the full running-applications snapshot. It seeds the SDK's running-apps
  list, so a plugin that never subscribes still starts from the current set
  (and keeps that set until it does).

The protocol has one integer version, `1`, pinned in `protocol.json`. There is
no per-feature negotiation: features are manifest declarations, so a plugin
never asks the host what it supports. See the
[compatibility policy](#compatibility-policy).

## Message reference

| Message | Direction | Kind | Purpose |
| --- | --- | --- | --- |
| `initialize` | host → plugin | request | The handshake; first and once |
| `ping` | host → plugin | request | Liveness probe after a minute of silence |
| `event` | host → plugin | notification | A system event the manifest `listen`s to, or a `core:poll:<name>` tick |
| `evaluate` | host → plugin | request | Answers for the flashlight input, per keystroke |
| `hints` | host → plugin | request | Hint targets in the focused app |
| `text_grid` | host → plugin | request | The focused app's visible text as a cell grid, for letter search |
| `search` | host → plugin | request | The rows of a live source, for the flashlight query scoped to it |
| `perform` | host → plugin | request | Run a row, a command, a bang or a navigation |
| `publish` | plugin → host | notification | Replace the catalog, or one source's rows |
| `changed` | plugin → host | notification | The rows of a live source changed |
| `status` | plugin → host | notification | Set status-bar segment values |
| `poll` | plugin → host | notification | Register the cadences and deadlines the host ticks |
| `log` | plugin → host | notification | A structured, content-free log line |
| `host.*` | plugin → host | request | Host RPCs: fetch, open, activate, post keys, the AX broker |

### Host → plugin

- `initialize` — the handshake; see [Handshake and versioning](#handshake-and-versioning).
- `ping` — `{}` → `{"ok": true}`. See Liveness.
- `event` (notification) — `{name, payload}`, filtered by manifest `listen`
  globs: `core:apps.changed` (`{running_applications: [{bundle_id, pid,
  localized_name}]}`, the complete snapshot), `core:apps.launched|terminated`,
  `core:focus.changed`, `core:window.focus.changed` (`{pid, bundle_id}`: the
  app whose focused or main window changed), `core:ax.changed`
  (`{pid, notification, bundle_id?}`: one AX notification an observed app
  posted, among `protocol.json` `host_events.ax_notifications`; every
  keystroke posts `AXValueChanged`, so match the notification rather than
  debouncing every change alike),
  `core:config.changed`, `core:power.changed`, `core:network.changed`
  (interfaces, addresses, routes or DNS changed), `core:volumes.changed` (a
  volume mounted, unmounted or was renamed), `core:calendar.changed` (the
  calendar database changed, or the user answered macOS's Calendars prompt;
  only for a plugin holding `calendar_events`),
  `core:status.observed` (which of the plugin's own status segments a
  surface shows; see [Status observation](#status-observation)), and
  `core:session.opened` (the flashlight opened; advisory — eager plugins may
  refresh, nothing is required), `core:system.slept` and `core:system.woke`,
  `core:displays.slept` and `core:displays.woke`, `core:screen.locked` and
  `core:screen.unlocked` (all payload-free), `core:displays.changed`
  (`{added, removed, displays}`: display names, when one is connected or
  removed), `core:space.changed` (the active Space), `core:user.idle`
  (`{seconds}`: nobody touched the keyboard, mouse or trackpad for one of the
  subscribers' idle thresholds, 300 s for a plugin; once per away episode
  and threshold) and `core:user.active` (`{idle_seconds}`: input came back
  after an announced episode), `core:usb.attached` and `core:usb.detached`
  (`{vendor_id?, product_id?, name?}`, never a serial number: a USB device
  connected or removed; devices already connected are not announced), and
  `core:clock.minute` (`{time, weekday, date, late_seconds}`, in the local
  time zone: `"09:55"`, `"fri"`, `"2026-10-23"`). A plugin listener hears
  every minute; after a sleep or a locked screen, only the current one, with
  how late it is. `core:workspace.changed` (`{workspace, previous?, workspaces}`)
  follows the focused [tiling](tiling.md) workspace, only while `[tiling]` is on.
  `core:mode.changed` (`{mode, previous}`, as `resident status` names modes)
  follows Flash's mode; `core:hints.shown` (`{surface, targets}`),
  `core:hints.committed` and `core:hints.cancelled` (`{surface}`) a hint
  session's labels, each committed target and an end without one, never which
  target; `core:monitor.triggered` (`{monitor, level}`) a value monitor's rise
  into warning or error, never its value.
  `protocol.json`
  `host_events` pins the list. The same events drive the user's event
  [monitors](monitors.md#runs-and-events) and reach the resident's socket
  clients ([IPC protocol](ipc-protocol.md#events)), all but the plugin
  plumbing (`core:apps.changed`, `core:ax.changed`, `core:calendar.changed`,
  `core:session.opened`, `core:status.observed`): one catalog, one fan-out.
  `core:network.changed` and `core:volumes.changed` carry an empty payload —
  no interface, address, network name or volume — and coalesce a burst of OS
  notifications into one event within 500 ms; re-read what you show instead
  of polling for it. The host observes the network (System Configuration's
  dynamic store) and volume mounts (workspace notifications) only while at
  least one plugin's `listen` matches the event. `core:calendar.changed` is
  the same kind of signal for the calendar database, one per burst within
  500 ms, and it also follows the user's answer to macOS's Calendars prompt.
  It reaches a plugin only when its manifest holds `calendar_events`,
  whatever its `listen` says, and never an event monitor or a socket client;
  the host observes the database only while such a plugin listens and macOS
  has granted Flash access.
- `evaluate` — `{query}` → `{"ok": true, "answers": [...]}`.
  The per-input evaluator: synchronous, CPU-only over state prepared earlier
  — no I/O. Unclaimed input answers `{"ok": true, "answers": []}` —
  evaluators are additive parsers, never error paths.
- `hints` — `{bundle_id, pid, front_window_frame, display_scale?}` → `{"ok": true,
  "targets": [...], "context_pid"?}`. Always a live request; there is no
  cached-discovery path. `display_scale` is physical pixels per AppKit point,
  captured with the display geometry on the main thread. It names the display
  containing the largest part of the requested window; unknown geometry or
  an equal overlap across different scales omits it. Providers that require
  pixel-exact geometry must reject an absent, non-finite or non-positive scale.
  The host owns commit: it posts the mouse event
  directly to the target app and never calls back into the plugin to
  activate a target. Use role `AXLink` for native-style semantic links (`f`
  plain; `F` Command-Shift), or
  `FlashTerminalLink` for links inside terminal content (`f` Shift, `F`
  Command-Shift). Every target preserves the requested click modifiers. Targets:
  `{id, frame{x,y,width,height}, role?, label?, url?, pid?, context_id?,
  priority?}`. The nested `frame` is required; flat
  coordinates and unknown target fields are rejected. A target carries no
  mode intent: a click on it keeps the mode, as every click does. Geometry must be finite
  with positive width/height. One malformed target rejects the entire reply.
  `context_id` is an optional non-empty opaque string identifying the live
  source context containing the target. The host requires an exact match when
  revalidating a captured hint; omitted/null means unspecified. Tmux includes
  its backend, client tty, server process, session, window and pane identities,
  so a reused pane label in another session cannot receive a captured click.
- `text_grid` — `{bundle_id, pid, front_window_frame, display_scale?}` → `{"ok": true,
  "columns": C, "rows": R, "lines": [...], "cell"?: {...}}`: the focused app's visible text
  as a `C` × `R` cell grid, row 0 at the top, for a letter search (`s`) in an
  app whose Accessibility tree has no text, such as a terminal that draws its
  own glyphs. The host asks the plugins that would provide that app's
  `hints`, in hint order, one at a time, and the first grid with a line wins;
  it never blocks a queue on the reply. Always live. Each line is exactly
  `{row, column, text}` — captured cell text, one UTF-16 unit per cell from
  `column` on, the way a terminal capture addresses it — or `{row, column,
  width, format}` — an expanded tmux-style status format (`#[…]` styles and
  alignment) the host lays out across `width` cells with its status-line
  rules, for a status line or a pane-border title. `row < rows`,
  `column < columns`, `width >= 1` and `column + width <= columns`; columns
  and rows are each at most `quotas.text_grid_dimension` (10000). One
  malformed line rejects the whole reply. The host lays the grid on the
  window `f` uses and divides it evenly by `C` and `R`, unless the reply
  carries `cell`: `{width, height, pad_x, pad_y}` in AppKit points, one
  cell's size (above zero) and the padding between the window's left and top
  edges and the grid (zero or more), for a terminal that pads or centres its
  grid. All four keys are required and a malformed `cell` rejects the whole
  reply. No lines means no grid;
  the SDK's default handler answers `{"ok": true, "columns": 0, "rows": 0,
  "lines": []}`. Tmux answers with the focused client's panes, its status line
  and each pane-border title, read over its control-mode connection, on the
  cells its hints use: Alacritty's are the pixels it reports to tmux, and an
  Alacritty layout the plugin cannot place exactly gets no grid.
- `search` — `{source, query}` → `{"ok": true, "rows": [...]}`: the rows of
  one live source (a `sources[]` entry declaring `live`), asked only while a
  flashlight query is scoped to it: `@<type>`, or a bang bound to the source.
  `query` is the text typed after the scope. A `per_query` source is asked
  again each time that text changes; a `per_scope` source is asked once per
  scope, with an empty `query`, and the host filters its rows as the user
  types. Always live: the host keeps nothing, and the rows never enter the
  catalog. Each row has the [row shape](#payloads-and-quotas) and carries the
  `source` that was asked for; the reply is bounded like a catalog (10,000
  rows, 4 MiB in the compact encoding of `rows`). One malformed row, a row of
  another source or an over-quota reply rejects it whole, and the host serves
  no rows. The flashlight drops the reply to a query the user has typed
  past, so a late reply costs nothing but its rows. Selecting a row sends
  `perform {kind: "resolve"}` with it, as for a published row. Rows that
  change after the reply are announced with [`changed`](#plugin-host-notifications).
- `perform` — the single effect method. Three kinds:

  ```json
  {"kind": "resolve",  "row": {…}, "confirmed"?: true}
  {"kind": "command",  "command": "…", "subcommand": "…", "args": […], "context"?: {"bundle_id", "pid", "front_window_frame"}, "count"?: 5, "confirmed"?: true}
  {"kind": "navigate", "url": "tmux://…"}
  ```

  A `command` is one of three things, told apart by its two words: a core
  command the manifest's `commands[]` declares under one of Flash's topics
  (`{"command": "tab", "subcommand": "select", "args": ["--index=3"],
  "context": {…}}`), the plugin's own command (`{"command": "tmux",
  "subcommand": "session", "args": ["main"]}`), or a bang (the plugin id as
  `command`, the typed token as `subcommand`, the query words as `args`).
  `args` are the argument words as a mapping writes them: `--key=value` for
  a value, `--flag` for a bool flag, bare words for a plugin's own command.
  `context` is the focused app, and it is sent exactly for a core command:
  an own command or a bang runs from any surface, the flashlight and the
  CLI included, so it has no focused app (`host.normal_mode_target` asks
  for one). `count` is the NORMAL count typed before the key of the plugin's
  own command: `5` then the key is one `perform` with `"count": 5`, never
  five, so the plugin applies it in one step (five volume ticks, one alert).
  It is an integer from 1 to 999, absent means 1, and the host leaves it out
  for 1, for a bang and for a core command, which it repeats itself.
  `confirmed` is `true` on a resolve or a command the user confirmed (see
  [confirmation](#confirmation)), and absent otherwise.
  `protocol.json` `perform_command` pins the shape.

  Uniform reply, universal trichotomy:

  ```json
  {"ok": true, "target_pid"?: 123, "navigation_url"?: "…", "message"?: "…", "alert"?: {…}}
  {"ok": false, "unhandled": true}
  {"ok": false, "error": "…"}
  ```

  `ok: true` = performed (`target_pid` raises that app; `navigation_url` is
  the route the command landed on, recorded as a stop in movement history
  at once — a tab switch names its destination, so a burst of switches
  leaves a stop per press where the catalog would show only the last).
  `unhandled` = "not my
  context" — the host MAY fall back (e.g. to a keystroke mapping). An
  `error` = "mine, but it broke" — the host MUST NOT fall back
  (double-fire protection); no reply / timeout / crash coerces to this case.
  Unknown `kind` → error. The host never dispatches `perform`
  to a plugin in `failed`/unspawnable state — it settles as `unhandled`
  without burning the deadline (nothing could have started).

  The plugin's own command or bang answers whoever ran it with `message`
  and `alert`. `message` is the command's output: the CLI prints it, the
  command line shows it, and a key shows it on a banner. `alert` is the
  centred alert Flash draws wherever the command ran, a key, the CLI and
  the command line alike; with one, a key shows no banner. It is `{"title":
  "caffeinate on"}`, a one-line message, or `{"title": "volume", "value":
  "38%", "widest_value"?: "100%"}`, a title over a one-line value.
  `widest_value` is the widest value the alert shows, so its box keeps one
  size while the value changes, and comes only with a `value`; neither holds
  a line break, while a `title` may and wraps. Every string is non-blank; `title` is at most 256 bytes, `value` and `widest_value` at
  most 64 (`quotas.alert_title_bytes`, `alert_value_bytes`). A malformed
  alert rejects the whole reply. A plugin draws no alert of its own: this is
  the one centred alert, and it replaces the one on screen. An `error` of
  such a command is logged, handed to its caller as the failure's text, and
  shown in the failure alert when it fits an alert title; a longer one
  shows the generic failure alert. The `error` of a resolve is shown the
  same way when the user picked the row in the flashlight, and stays in the
  log when movement history stepped back to it.

#### Confirmation

A plugin never asks the user a question itself: NORMAL mode's capture would
swallow the answer. It declares the question, and the host asks it through
its one confirmation alert (`[y]es / [n]o`), a phase that owns the keyboard
in every mode. `y` runs what the question gates; any other key closes it and
nothing is sent.

- A manifest `commands[]` entry carries `confirm`: the host asks before it
  dispatches that command's `perform`, whether a key, the command line or
  the CLI ran it (see [`commands`](#manifest)).
- A row carries `confirm`: the host asks before it acts on the row, which
  means before it sends the row's resolve, or before it runs its `effect`.
  A row another key would commit (`<tab>`, `<cmd+cr>`) asks the same way.
- A mapping wraps any command with `alert confirm`; its `y` counts too.

`confirm` is a non-blank question of at most 256 bytes
(`quotas.confirm_bytes`). A blank or longer one rejects the manifest, the
publish or the search reply that carries it.

A `perform` sent after the user answered `y` carries `"confirmed": true`.
The key is never `false`: a perform the user was not asked about leaves it
out, and a `navigate` never has it. The host remembers a confirmed perform
until its reply arrives or its deadline passes, and a host action that needs
the user's consent is honoured only while one is in flight for that plugin.
Each confirmed perform covers one such action: asked for twice inside one
perform, the second is refused. A plugin therefore cannot reach such an
action from an event, a timer, a search, or a perform the user was not asked
about. `protocol.json` `confirmation` states the rule.

#### Event coalescing

The replacement kinds in `protocol.json` `host_events.replacement` are state
signals: each one supersedes the earlier ones with the same coalescing key.
The key is the event name, except for `core:ax.changed`, which reports one
fact per app and notification and adds the payload `pid` and `notification`
— a keystroke's `AXValueChanged` never replaces a pending `AXTitleChanged`,
and one app's change never replaces another's.

The host queues every frame for a child's stdin in send order under the
256-frame / 20 MiB transport budget. When it queues a replacement event while
an unsent one with the same key is still waiting, it drops the older frame and
appends the newer, so a child reads a subsequence of the emitted events, in
emission order, and a child that briefly stops reading accumulates at most one
frame per key rather than overflowing on a burst of signals. Requests,
responses and every other event keep FIFO order and their budget: a child that
stops reading those is still restarted once the budget fills. A frame already
written to the pipe is delivered; the plugin's own event backlog coalesces
what it has read but not yet handled by the same keys (see the SDK's
replacement slots).

#### Status observation

`core:status.observed` tells a plugin which of its own status segments a
status surface currently shows, so work that only feeds a segment runs only
while someone can see it. The `sysinfo` plugin registers its one-second CPU
sample only while one of its cpu segments, such as `cpu_label` or
`cpu_percent`, is observed.

```json
{"method": "event", "params": {"name": "core:status.observed",
  "payload": {"segments": ["cpu_label", "cpu_percent"]}}}
```

- **Payload.** `segments` is required: the complete set of this plugin's
  observed segments as bare manifest `status` names (no
  `flash.plugin.<id>.` prefix), each nonempty and listed once. The host
  sends them sorted; order carries no meaning. `[]` is authoritative —
  nothing is observed. Names the manifest does not declare never appear,
  and no other plugin's segments do. Other payload keys are ignored.
- **Observed.** A segment is observed while a live surface would resolve
  `#{flash.plugin.<id>.<segment>}`: the enabled bar's template, its named
  popups, and desktop widgets. These are the
  references that keep a status-bound plugin resident, refined from plugin
  ids to segment names. A disabled bar or a removed widget observes nothing.
- **Delivery.** Filtered by `listen` like every other event, and not
  capability-gated: segment names are manifest data, not user content. The
  host sends the current set once right after the initialize reply (after
  the `core:apps.changed` snapshot), even when it is empty, so every
  restarted child starts from the truth. It sends it again whenever that
  plugin's set changes — a configuration reload, the bar being enabled or
  disabled, a widget appearing or disappearing — and never repeats an
  unchanged set. Observation does not change activation or residency.
- **Coalescing.** The set is a full replacement, coalesced like every
  replacement event (see [Event coalescing](#event-coalescing)), so
  intermediate sets may be skipped but the final set arrives.
- **Rejection.** A payload whose `segments` is missing, null, not an array
  of strings, or contains an empty or duplicate name is malformed. The Rust
  SDK drops it whole with a content-free warning and does not deliver it.
  The `status_observed` group in `fixtures/wire-values.fixture` pins these
  cases; host tests of the payload it builds can consume the same group.

A plugin keeps the segments it publishes correct regardless: observation
schedules work, it does not filter what the host renders. A plugin that
stops sampling for an unobserved segment should clear it (`""`), so a
surface that shows it again never reads stale figures.

### Plugin → host notifications


- `publish` — `{"rows": [...], "source"?: "<name>"}`. **The catalog is
  push-based.** Without `source`, a full replacement of the plugin's warm
  catalog; with `source`, one of the manifest `sources[].name` that every
  row carries, a replacement of that source's rows alone, every other
  source keeping the rows it last published. Either is accepted any time
  after spawn; the host validates quotas at receipt and owns the store —
  the flashlight first paint reads host memory and never waits on a plugin.
  `{"rows": []}` is an authoritative empty, of the catalog or of the named
  source. On transient refresh failure, simply don't publish — the host
  keeps the last-good catalog by construction, across crashes and restarts
  (rows must therefore be resolvable from their own content; a restarted
  plugin that cannot resolve an old row replies `{"ok": false, "error": …}`
  to its `perform` and the next publish replaces the rows). A malformed or
  over-quota publish — a row of another source under `source`, an unknown
  params key, or a merge that would take the whole catalog past its quotas
  — is rejected whole (content-free log) and the previous catalog is
  retained. **A publish is proportional to the change:** rows that change
  often (open tabs) and rows that rarely do (history, bookmarks) belong to
  different sources, each published alone, so a tab switch costs the host a
  few rows rather than thousands. The host decodes publishes on a per-plugin
  catalog queue that carries no replies: one plugin's publishes keep their
  order, but a publish and a later reply are not ordered host-side, and a
  large publish never delays the reply behind it. An open flashlight
  refreshes from the store on a coalesced ≤1/s tick — lossless, since the
  store is already current.
- `changed` — `{"source": "<name>"}`: the rows of one live source are no
  longer the ones its last `search` answered. `source` is one of the
  plugin's own `sources[].name` declaring `live`, and the only key: another
  key, an empty name, a pushed source or one the manifest does not declare
  rejects the notification (content-free log). It carries no rows. While a
  flashlight query is scoped to that source, the host sends its `search`
  again and the reply replaces the rows on screen, the typed query and the
  selected position staying as they are. With no such query, or no
  flashlight open, it does nothing and keeps nothing for later; a child
  replaced before the host heard it is ignored. One query is pulled again
  at most once per 500 ms (`protocol.json` `changed.min_interval_ms`): the
  first notification at once, those inside the interval together at its
  end. Send it when rows already answered are stale — a listing that landed
  after the reply, an access the user just granted — never on a cadence,
  and not for rows a `search` still in flight is about to answer with.
- `status` — `{"segments": {"name": value}}` for manifest-declared status
  segments, rendered as `#{flash.plugin.<id>.<segment>}`. A value is markup
  (`""` clears) or a carousel object
  `{"prefix"?: markup, "lines": [markup], "cycle_seconds": >= 1}`: the host
  rotates the lines on its own clock, only while a visible surface shows the
  segment (a republish keeps the visible line until its scheduled rotation),
  draws `prefix` still before the visible line, and
  marks that line as carousel content for the transition; a scroll over it
  steps the carousel by hand, with nothing for the plugin to handle; blank
  lines are dropped, no lines clears, and a malformed object, one with any
  other key included, is rejected whole with a content-free warning.
  Undeclared names are ignored, and params holding anything but `segments`
  reject the notification. Segments are live state: cleared on any
  teardown (unlike catalogs). Markup may carry its own hover preview as
  `#[popup=inline:<percent-encoded body>]`; the encoded body is at most
  16,384 bytes (`quotas.inline_preview_bytes`), and a larger or undecodable
  one leaves the visible markup without a preview.
- `poll` — `{"registrations": {"<name>": {"every": <seconds>, "priority": <p>}
  | {"after": <seconds>, "priority": <p>}}}`, the plugin's complete set of
  cadences (`every`) and one-shot deadlines (`after`, measured from receipt)
  it wants the host to drive; an empty set stops its polling. Plugins must not
  arm their own timers or sleep to schedule work. The host folds every
  registration in the app onto one clock (see the architecture guide) and
  delivers `event {"name": "core:poll:<name>"}` when one is due, bypassing
  manifest `listen` because the registration *is* the subscription. A
  deadline fires once and leaves the host's clock; repeating it unchanged in a
  later set neither re-arms nor re-fires it, while a new or changed entry arms
  afresh, so give each arming its own name (the Rust SDK does). `priority` is
  how late a wake-up may land, the slack that lets unrelated wake-ups
  coalesce: `high` (25 ms) for a value on screen that the user watches change,
  `normal` (100 ms) for ordinary sampling, settles and refreshes, `low` (1 s)
  for background upkeep, remote pulls, retries and backoffs; the host's
  `system` priority is core-only. Names are `[a-z0-9_-]{1,64}`; `every` is
  floored at 0.05 s, both are capped at 86400 s, and a set holds at most 64
  registrations (`protocol.json` `poll`). A malformed or over-bound frame is
  rejected whole and the previous set keeps running. Ticks are one-way and
  unacknowledged, so a plugin whose previous callback is still running drops
  the ticks it missed rather than running back-to-back to catch up. No tick is
  delivered while the displays sleep, the session is locked or switched out,
  or the system is going to sleep; when that ends, a registration that fell
  due meanwhile ticks once. Every registration ends with the plugin process.
  Reach for a cadence only when no event can tell you the value changed.
- `log` — `{"level", "message", "fields"}`. Content-free (counts, stages,
  elapsed ms, method names — never query text, candidate data, clipboard
  content, config values, or event payloads). Every `fields` value is a
  string (`"rows": "12"`): the host keeps the line and drops the fields of
  one that carries anything else.

### Host RPCs

Plugin requests to the host, capability-gated default-deny (checked per process against the
manifest; the full method↔capability table lives in `protocol.json`):
`host.ping`, `host.fetch` (`network_fetch`), `host.normal_mode_target`
(which also reports the focused window's WindowServer `window_id`, so a plugin
can name a window without asking the user to pick one) +
`host.activate` (`app_control`), `host.open` (`open`),
`host.wifi_info` (`wifi_info`), `host.applescript` (`apple_events`),
`host.audio_devices` (`audio_devices`), `host.system_action`
(`system_actions`), `host.process_signal` (`process_signal`),
`host.calendar_events` (`calendar_events`), `host.notes` (`notes`),
`host.reminders` (`reminders`), `host.contacts` (`contacts`),
`host.post_keys` + `host.ax_snapshot` /
`host.ax_perform` / `host.ax_set` / `host.ax_select_child`
(`accessibility`). A denied call answers `{"ok": false, "error": "missing
<capability> capability"}`. `host.ping` needs no capability and answers
`{"ok": true}`, nothing else: it proves the plugin's requests reach the host
and the replies come back.

Each method's `params` are closed, as its
[schema](#schemas-and-constants) spells them. A key the method does not
define, or an optional value of the wrong type, answers `{"ok": false,
"error": "invalid <method> params"}` and nothing runs; a required param that
is missing or malformed answers the method's own error (`host.activate
requires pid`). The capability is checked first, so a plugin without it reads
the denial whatever it sent.

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
some manifest declares in [`browser_engines`](#manifest): the tab operations
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

`host.wifi_info` requires `{"request_authorization": false}` for passive reads
or `true` only for an explicit user action allowed to show the host-owned
Location prompt. An undetermined request replies absent immediately after
starting the prompt; callers retry after authorization instead of holding an
RPC open. The method returns
`{"ok": true, "present": true, "ssid": "…"}` for an associated network or
`{"ok": true, "present": false}` when Wi-Fi information is unavailable.
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
`host.system_action` takes exactly `{"action"}` and asks macOS for one
machine or session action, which stays in the resident: `lock_screen` posts
macOS's Lock Screen shortcut to the session, `sleep` and `display_sleep` ask
IOKit power management, `screensaver` opens ScreenSaverEngine and
`toggle_appearance` switches dark mode through System Events. `restart`,
`shutdown` and `logout` go through System Events and `empty_trash` through
Finder, and nothing undoes them: the host honours one of these four only
inside a `perform` the user [confirmed](#confirmation), one action per
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
`host.process_signal` takes exactly `{"pid", "signal"}` and sends one signal
to one process: `kill(2)` stays in the resident. `signal` is `"term"`
(SIGTERM), the only one. `pid` is an integer above 1: `0` (the caller's
process group), a negative pid (a group, or every process) and `1`
(launchd) refuse the request as malformed, and the host refuses its own pid
(`refusing to signal Flash itself`). The host honours every signal only
inside a `perform` the user [confirmed](#confirmation), one signal per
confirmed perform; outside one it asks the kernel nothing and answers
`{"ok": false, "error": "requires a perform the user confirmed"}`. A refused
pid spends no consent. The reply is `{"ok": true}` once the kernel took the
signal, or `{"ok": false, "error"}` with the kernel's reason (`No such
process`, `Operation not permitted` for another user's process). The
plugin's sandbox gains nothing. `protocol.json` `process_signals` lists the
signals.
`host.calendar_events` reads the user's calendar: EventKit and the Calendars
grant stay in the resident, and macOS names Flash in its prompt. A request
carries `operation` and exactly the fields it takes. Every success carries
`access`, what macOS answers without asking: `"granted"`, `"denied"`
(refused, restricted or write-only) or `"undetermined"` (Flash never asked).
`{"operation": "access"}` reads it. `{"operation": "request_access"}` reads
it too and, when it is undetermined, asks macOS first and answers once the
user did. The host shows that prompt only while the user is using the
plugin: one of its performs or searches is in flight, or a status surface
shows one of its segments. Anywhere else an undetermined access answers `{"ok": false,
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
`capabilities` also includes `network` (composes
`network-outbound` into the sandbox profile, so only a sandboxed plugin
declares it) and `network_fetch` (the host
performs HTTPS GETs on the plugin's behalf via `host.fetch`, restricted to
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
show one in the app. `process_info`
grants no host RPC: like
`network` it only composes the sandbox profile, so only a sandboxed plugin
declares it. The profile lets a plugin ask the kernel about its own process
alone and denies it the pid list; with `process_info` it may list pids and
read other processes through libproc in its own process: `proc_pidinfo`
(task and BSD info, and `proc_pidpath`), a process's descriptor list and
`proc_pid_rusage` (CPU time, resident memory, disk I/O). The other
`process-info` operations (file ports, control, code signature, ledger) stay
denied for other processes. Omitted capabilities are
default-denied. The registry is
frozen: additions are allowed, renames never.

**SDK `call_host` convention:** `call_host` never
throws and never returns nil — it always yields a result object. Capability
NAKs, host death (`{"ok": false, "error": "host closed stdin"}`), and the
5 s default timeout (`{"ok": false, "error": "host call timed out"}`, per-
call override available) all arrive the same way.

## Payloads and quotas

Rows (of a `publish` and of a `search` reply) are `{"source", "title", "url"?,
"metadata"?, "effect"?, "confirm"?}` — `source` must name a manifest
`sources[].name`, a pushed one in a publish and the one asked for in a search
reply; `confirm` is the question the host asks before it acts on the row
(see [confirmation](#confirmation)), and the row comes back in its resolve
as it was sent, `confirm` included;
routing `source_id` is always host-stamped and never crosses the wire.
Catalogs are bounded to 10,000 rows / 4 MiB encoded; titles 4 KiB, URLs
16 KiB, metadata 64 entries (256-byte keys, 64-KiB values), effect text
64 KiB. `evaluate` answers use the deliberately narrower `{"answers":
[{"title", "subtitle"?, "effect"}]}` — URLs, metadata, and unknown keys are
rejected — bounded to 16 answers / 256 KiB with 16-KiB fields. `effect` runs
only after explicit selection: `{"type": "copy_text", "text"}`, `{"type":
"insert_text", "text"}`, or — **rows only** — `{"type": "open", "url"}` /
`{"type": "open", "bundle_id"}` (answers reject `open` for the same reason
they reject URLs: evaluators cannot manufacture navigation). `insert_text`
of one character (an emoji, a symbol) is typed as a key event and leaves the
clipboard alone; longer text is pasted through a borrowed clipboard. A row
with an effect is committed by `<tab>` as by `<cr>`, and is never an
`app open --name=` match. An `open` URL
is never a `file:` URL; a row carrying one is rejected, as `host.open`
refuses it. There is
deliberately no `run` effect — a host-executed argv would escape the
plugin's sandbox; side effects that run commands belong in `perform`, inside
the sandbox. Every bound rejects the complete payload atomically; nothing is
silently truncated. The catalog quotas bound the plugin's whole catalog
after a per-source merge. The catalog byte quota counts the `rows` array as
written on the wire — each row object's span in the publish frame, one
separator byte per row and the two brackets — which the host measures from
the frame it received rather than by re-encoding the rows: the compact
encoding is the floor, and a plugin pays for whitespace or escaping it adds
inside a row (the Rust SDK writes compact rows, so its count is the compact
encoding exactly; `protocol.json` `quotas` states it). A `search` reply is
bounded by the same two numbers, its bytes counted from the compact encoding
of `rows`. The `answers` byte
quota counts the compact UTF-8 JSON encoding of `answers`, including JSON
syntax and string escaping, with literal Unicode and unescaped slashes. The
surrounding request/response envelope is never counted.
Optional values may be null, but present values must have the declared type.
Perform outcomes form an exclusive union: success fields cannot accompany an
error, and `unhandled` cannot accompany success or an error string.

## Manifest

Required: `id`, `name`, `version`, `description`. `install` is optional and
third-party-only: a shell string run once per version from the plugin root,
sandboxed (writes confined to the plugin root/data dir/temp, secrets
read-denied, network and exec open), with its full output persisted for
forensics. `exec` (argv array) is required for any plugin that runs a
process; omitting it declares a **manifest-only plugin** — no child process
ever runs, and the manifest may only carry surfaces the host serves alone:
`mappings`, `help`, `bindings`, `terminal_emulators`, `own_text_editing`,
`on_demand_hints`, `browser_engines` and `query_aliases` (the bundled `defaults` plugin is the exemplar). Anything process-bound is
rejected, a core `commands[]` entry included. Loading is strict — unknown top-level or nested
keys and malformed known fields are rejected outright, and new manifest
surface only ever arrives together with a protocol change, so "unknown key"
always means "typo or stale host", never ambiguity.

```json
{
  "id": "example",
  "name": "Example",
  "version": "0.1.0",
  "description": "Example plugin",
  "exec": ["./flash-plugin-example"],
  "sandbox": { "mach": ["com.apple.PowerManagement.control"] },
  "capabilities": ["app_control"],
  "listen": ["core:apps.*"],
  "only_bundle_ids": ["org.mozilla.firefox"],
  "priority": 25,
  "sources": [
    { "name": "example.items", "type": "items", "kind": "locations", "priority": "normal" }
  ],
  "query": { "prefixes": ["="] },
  "commands": [
    { "command": "example", "subcommand": "run", "description": "Run example" },
    { "command": "resource", "subcommand": "archive", "confirm": "Archive it?" }
  ],
  "bangs": [
    { "token": "ex", "description": "Search example", "source": "example.items" },
    { "token": "*" }
  ],
  "hints": { "fallback_on_empty": true },
  "navigation": ["example"],
  "status": ["state"],
  "bindings": {
    "tab next": { "": "cmd+shift+]" },
    "clipboard copy": { "": ["cmd+a", "cmd+c"] },
    "window new": { "": { "menu": ["File", "New Window"] } },
    "app print": { "": false }
  },
  "mappings": [
    {
      "key": "ge",
      "mode": "normal",
      "command": ["flash", "resource", "archive"],
      "only_bundle_ids": ["org.mozilla.firefox"]
    }
  ],
  "help": { "topics": [] }
}
```

Section semantics:

- **`sandbox`** — every plugin process, third-party ones included, runs
  under a deny-default seatbelt profile: everything is denied except
  loading the binary, broad reads minus secrets (`~/.ssh`, `~/.aws`,
  `~/.config/gh`, keychains, other plugins' data), and writes inside the
  plugin's data dir. The process runs only its own executable (and an
  interpreter that `exec` resolves outside the plugin root). An object adds
  allowances; without `sandbox` the plugin gets none. The one allowance is
  `mach`: named mach services the plugin needs. The `network` capability
  composes `network-outbound`, which also covers local unix sockets, and
  `process_info` composes the libproc reads of other processes (see
  [Host RPCs](#host-rpcs)); an unsandboxed plugin declaring either fails to
  load, since it has no profile to widen. `"sandbox": false` runs the plugin unsandboxed for external or
  credentialed helpers, as `screenshot`, `terminals` and `aiproviders` require.
  `browsers`, `shortcuts` and `media` keep the default sandbox: their fixed
  AppleScript operations run in the host through `apple_events`. `sysinfo`
  and `caffeinate` name powerd's `com.apple.PowerManagement.control`, the one
  mach service a bundled plugin reaches. `processes` is the one bundled
  plugin declaring `process_info`. Any other sandbox value
  is rejected, and a
  manifest-only plugin cannot declare `sandbox`.
  `[plugins.<id>] sandbox = false` is the user's per-plugin fail-open kill
  switch.
- **`listen`** — event-name patterns; `*` wildcard. Declaring `listen` makes
  the plugin resident.
- **`lifecycle`** — how the run ends. Absent, the surfaces decide (see
  [Activation](#process-model-and-lifecycle)). The one value,
  `"publish_then_exit"`, declares a catalog-only plugin whose run is
  `on_start`: it needs `exec` and `sources`, allows nothing a live child
  serves (`hints`, `query`, `status`, `listen`, `commands`, `bangs`,
  `navigation` reject the manifest, naming the keys to remove), publishes,
  exits 0, and is run again only when its data can have changed. Any other
  spelling is rejected; the default has none.
- **`settings`** — the `[plugins.<id>]` keys the plugin reads, by name
  (lowercase `[a-z0-9_]`):
  `{ "type", "description", "default"?, "enum"?, "min"?, "max"? }`. `type` is
  `string`, `integer`, `number`, `boolean` or `string_array`. `description`
  is required and is the key's entry in the generated config schema. `enum`
  lists the values a `string` takes; `min` and `max` are the inclusive bounds
  of an `integer` or a `number`. `default` is what the plugin receives when
  no file sets the key, and must be a value the setting takes. Another field,
  an `enum` or a bound on the wrong type, and a declared `sandbox` (the
  host's own key, valid in every plugin's table) reject the manifest; so does
  `settings` without `exec`. `FLASH_PLUGIN_CONFIG` holds only declared keys
  whose value passes: an undeclared key and a value of the wrong type or out
  of range are left out. For a bundled plugin, `flash config check` and a
  reload report each at its file position, along with a `[plugins.<id>]`
  table that names no bundled plugin while `[plugins] third_party` is empty.
  For a third-party plugin the host logs the key, never its value, when the
  plugin loads.
- **`fetch_urls`** — HTTPS URL prefixes the plugin may request through
  `host.fetch`. A prefix admits itself and what continues it at a URL
  boundary (`/`, `?` or `#`): `https://api.example.com/v1` admits
  `https://api.example.com/v1/items`, not `https://api.example.com/v1beta`.
  Another scheme rejects the manifest.
- **`fetch_settings`** — names of declared string `settings` holding an HTTPS
  URL the user chooses, which the plugin may request like a `fetch_urls`
  prefix. `flash config check` and a reload report a value that is not an
  `https://` URL without credentials; an empty value is unset, and the
  generated config schema carries the same rule.
- **`fetch_limits`** — `{ "max_bytes"?, "timeout_ms"? }`, the bounds of one
  `host.fetch` response when they are not the standard 1 MiB and 8 seconds:
  at most 4 MiB and 30 seconds (`quotas.fetch_response_bytes_max` and
  `quotas.fetch_timeout_ms_max` in `protocol.json`), so a body at the ceiling
  still fits one frame. An object that sets neither, a bound outside the
  range, or `fetch_limits` without the `network_fetch` capability rejects the
  manifest.
- **`watch_settings`** — names of declared string `settings` whose value is
  a file path the host watches to run a `publish_then_exit` plugin again;
  needs that lifecycle. `~` expands to the home and a relative path is under
  the plugin root, as the child's working directory resolves it.
- **`sources`** — the plugin's flashlight sources. `name` is the source's
  internal name: the `source` its rows carry, what a bang's `source` binds,
  and the key ranking reads. `type` (required) is the
  [resource type](#resource-types) users narrow to with `@<type>`.
  `kind` is `"default"` (default) or `"locations"`; `priority` is the
  semantic salience enum `low | normal | high | important | urgent` and sets
  the source's precedence weight in the flashlight (see
  [flashlight ranking](flashlight.md#ranking)): it orders rows against other
  sources inside one match tier and never lifts a partial hit above an exact
  one. Bundled: `tmux.windows` is `important`, apps and browser tabs `high`.
  A source is *pushed* unless it says otherwise: a complete catalog the
  plugin publishes, which the flashlight reads from host memory. `live`
  makes it *live* instead: the plugin publishes nothing for it, it stays out
  of the default pool, and the host pulls it with [`search`](#host-plugin)
  while a query is scoped to it. `"live": "per_query"` is pulled on every
  change of the query text, for rows that depend on it (a search of a remote
  index); `"live": "per_scope"` is pulled once per scope, for a short fixed
  list the host can filter itself. A manifest's sources all declare the same
  `live`, or none does: split pushed and live sources into two plugins. A
  live source is never `kind: "locations"`, since location rows belong to
  the default pool, and a `publish_then_exit` plugin declares none.
  `protocol.json` `source_live` pins the values. The bundled `system`
  plugin's `system.actions` (`@system`) and the `menus` plugin's
  `menus.items` (`@menus`) are `per_scope`; the `processes`
  plugin's `processes.processes` (`@processes`) is `per_query`, answered
  from one read of the process table per two seconds. A `listen` beside
  live sources keeps no process (see
  [activation](#process-model-and-lifecycle)).
- **`query`** — registers the per-input evaluator. `prefixes` are exact
  literal markers (never regexes) that route matching input only to this
  evaluator; without one, evaluators are additive. Evaluator ordering is the
  manifest root `priority`, ties broken by plugin id.
- **`commands`** — `flash <command> <subcommand>` registrations, the same
  words as `:command subcommand` and the same shape as Flash's own
  `flash <topic> <action>`. Both words are required and each is
  `[a-z][a-z0-9_]*`. An empty subcommand is rejected; there is no one-word
  `flash <name>` (a `verbs` key is unknown). Every command shares the
  `perform` deadline. Declaring the same pair twice fails the load. The first
  word decides what an entry is:
  - outside Flash's topics it is one of the **plugin's own commands**
    (`tmux session`, `screenshot window`): it registers for dispatch and
    command-line completion, subcommand `"*"` consumes the remainder as args,
    and a name another plugin's own command uses fails the load of every
    plugin that claims it;
  - under one of Flash's topics (`tab`, `pane`, `scroll`, `app`, …) it is a
    **core command the plugin performs** where its root selector matches
    (`{"command": "tab", "subcommand": "close"}`), and it must name one Flash
    asks of the focused app (the list under `bindings` below, without the
    flag variant): `tab *`, `tab sideways`, `mode insert` or `resident quit`
    fail the load. Such an entry never registers as a plugin command — a
    topic word is always Flash's — and dispatches as `perform {kind:
    "command"}` with `context`, first in the source chain, before any
    binding (see **Resolution** under `bindings` below). `description` is
    allowed on a core entry but unused: the host's catalog describes its
    own commands.

  `confirm` on an entry is the question the host asks before the command
  (`{"command": "tab", "subcommand": "close", "confirm": "Close this tmux
  window?"}`): the host shows the prompt as its confirmation alert
  (`[y]es / [n]o`, keys in the hint colour) and dispatches the command only
  on `y`, marked `confirmed`; the plugin then performs it without a prompt
  of its own (see [confirmation](#confirmation)). On one of the plugin's
  own commands it gates that pair wherever it runs, a key, the command line
  and the CLI alike, and the `*` wildcard cannot carry one. On a core
  command it gates the command in the apps the root selector matches;
  across plugins, a matching selector beats an unscoped one, then the higher
  `priority`, then the plugin id. An empty prompt or one over 256 bytes
  rejects the manifest. The bundled terminals plugin gates `tab close` and
  `pane close` this way, the `system` plugin its own `system restart`,
  `system shutdown`, `system logout` and `trash empty`, and the `processes`
  plugin its `process kill`; a mapping gates any
  command the same way with
  `["flash", "alert", "confirm", "--prompt=…", "--command=<topic> <action>
  [--arg=value]"]`, and a command asked through it is not asked again.
- **`bangs`** — the list of flashlight bangs, each dispatched as
  `perform {kind: "command"}` with the plugin id as `command` and the typed
  token as `subcommand`, so no `commands` entry is needed. `token: "*"` is
  the catch-all; an entry's `source` names one of the plugin's `sources`,
  whose rows the flashlight lists once the bang is confirmed. A token Flash itself owns (`!f`, the core
  file search, and `!clip`, clipboard history) fails the load. Bangs ignore the root selector: the flashlight
  is one surface in every app, so a plugin scoped to its apps still serves
  its bangs from any other, and a `kind: "default"` source it declares stays
  reachable by name while none of its apps runs (only `locations` rows, hints
  and core commands follow the selector).
- **`hints`** — opts in as a hint provider (always live). Selection is
  exclusive; set `fallback_on_empty: true` only when applicability is
  discovered dynamically and empty means "not applicable". A hint provider
  may also answer `text_grid`; the default answers no grid.
- **`navigation`** — durable route schemes restorable from movement history,
  dispatched as `perform {kind: "navigate"}`.
- **`status`** — status-bar segment names fed by the `status` notification.
- **`permissions`** — the macOS privacy grants the plugin's work depends on,
  from a closed set: `screen_recording`. `flash resident doctor` reports one
  row per declared grant (`screen_recording`), naming the loaded plugins
  that declare it, and warns while the resident does not hold it. A
  declaration grants and asks for nothing: macOS asks when the plugin first
  uses the protected service. An unknown name fails the load, and so does
  `permissions` on a manifest without `exec`. The bundled `screenshot`
  plugin declares `screen_recording`.
- **`bindings`** — what each app does for Flash's commands: binding key →
  bundle id → binding. The key is the command line users type, with the bool
  flags that change what the app does (`"tab new"`, `"app reload --force"`);
  the bundle id `""` covers every app the root selector matches. A binding
  is one of:
  - `"cmd+t"` — a chord;
  - `["cmd+k", "cmd+w"]` — chords sent in order, `[mode]
    send_key_interval_ms` apart;
  - `{ "menu": ["File", "New Tab"] }` — the menu-bar item at that title path
    (menu, then item, then any submenu item), pressed through Accessibility
    off the main thread; a missing or disabled item fails the command with no
    fallback;
  - `false` — the app has no such command: nothing happens.

  A command with an `--index` parameter (`tab select`) may name it with
  `{index}` (`"cmd+{index}"`, `{ "menu": ["Window", "Tab {index}"] }`); a
  chord that doesn't exist for the index (`cmd+10`) sends nothing.
  Validation is strict: a key that is not one of the lines below (an
  underscore spelling, a value argument, a flag the command does not take,
  a plugin's own command, a command Flash performs itself), an unparseable
  or empty chord (`""` is not "none", write `false`), an empty array,
  `true`, a menu path shorter than two titles, an object other than
  `{"menu": [...]}`, or `{index}` outside a command with `--index` rejects
  the manifest.

  **Resolution.** A command first goes to the
  sources that perform it in the focused app (a plugin's core `commands[]`
  entries, the built-in Accessibility tab strip); a source that claims it
  and fails stops there. Otherwise one binding wins, by a pure,
  deterministic ranking: an entry for the app's bundle id beats any
  plugin-wide `""` entry; then a plugin whose root selector
  (`only_bundle_ids`, `only_terminals`) matches the app beats an unscoped one
  (a plugin whose selector doesn't match contributes nothing); then the higher
  manifest `priority`; then the plugin id, alphabetically first. With no
  binding nothing happens, except that `resource next` / `resource previous`,
  `scroll top` / `scroll bottom` and `move top` / `move bottom` fall back to
  Flash's own scrolling and `window close` tries the window's close button
  before its binding. In a terminal emulator a chord the emulator would
  type as text is refused, unless a plugin binds that chord for that
  emulator specifically (its bundle id or a matching selector); a menu press
  is never refused. The inspector's Mappings page shows the resolution for
  the focused app.

  Binding keys: `app cancel`, `app developer_tools`, `app downloads`,
  `app find`, `app find_next`, `app find_previous`, `app help`, `app look_up`,
  `app print`, `app redo`, `app reload`, `app reload --force`, `app save`,
  `app select_all`, `app settings`, `app stop`, `app undo`, `app view_source`,
  `app zoom_in`, `app zoom_out`, `app zoom_reset`, `clipboard copy`,
  `clipboard paste`, `cursor big_word_end`, `cursor column`,
  `cursor first_line`, `cursor first_nonblank`, `cursor last_line`,
  `cursor last_nonblank`, `cursor line_end`, `cursor line_nonblank`,
  `cursor line_start`, `cursor matching_bracket`, `cursor next_big_word`,
  `cursor next_line`, `cursor next_paragraph`, `cursor next_sentence`,
  `cursor next_word`, `cursor previous_big_word`,
  `cursor previous_big_word_end`, `cursor previous_line`,
  `cursor previous_paragraph`, `cursor previous_sentence`,
  `cursor previous_word`, `cursor previous_word_end`, `cursor screen_bottom`,
  `cursor screen_middle`, `cursor screen_top`, `cursor word_end`,
  `document duplicate`, `document export_pdf`, `document open`,
  `document page_setup`, `document rename`, `document revert`,
  `document save_as`, `history back`, `history forward`, `history show`,
  `input char_left`, `input char_right`, `input document_end`,
  `input document_start`, `input line_down`, `input line_end`,
  `input line_start`, `input line_up`, `input select_document_end`,
  `input select_document_start`, `input select_down`, `input select_left`,
  `input select_line_end`, `input select_line_start`, `input select_right`,
  `input select_up`, `input select_word_left`, `input select_word_right`,
  `move bottom`, `move down`, `move left`, `move right`, `move top`,
  `move up`, `pane close`, `pane next`, `pane previous`,
  `pane split_horizontal`, `pane split_vertical`, `resource archive`,
  `resource next`, `resource previous`, `scroll bottom`, `scroll top`,
  `tab close`, `tab detach`, `tab duplicate`, `tab first`, `tab last`,
  `tab move_next`, `tab move_previous`, `tab mute`, `tab new`, `tab next`,
  `tab pin`, `tab previous`, `tab reopen`, `tab select`, `url bookmark`,
  `url edit`, `window close`, `window close_all`, `window new`,
  `window new --private` and `window zoom`. Each is the Flash command
  that asks the focused app for it, as a mapping writes it (`flash tab
  next`); `app reload --force` and `window new --private` are those commands
  with their flag, the two flag variants: a browser's hard reload and its
  private window. Flash itself asks before `document revert` and
  `window close_all` wherever an app binds them, since both can lose unsaved
  work; a binding needs no `confirm` of its own. The `move` keys are what an app does in a list, table, outline
  or column browser, where NORMAL's `h` `j` `k` `l` and `gg` / `G` move the
  selection; `move half_page_down` and the other page moves are not keys,
  since they repeat the one-step binding. The `input` keys act only in
  focused editable text. An `input select_*` key is what VISUAL extends the
  app's own selection with where the focused text gives Flash nothing to
  measure, Shift and an arrow by default
  ([without the text](visual-mode.md#without-the-text)). A `cursor` key is what a Vim motion runs where the
  focused text gives Flash nothing to measure (a secure field, an app
  without Accessibility text); elsewhere Flash computes the motion from the
  text and sets the caret itself, so the binding is not asked. The
  character searches, `cursor line` and `scroll cursor_top`,
  `cursor_middle` and `cursor_bottom` are not keys. Every one but the flag
  variants is also a core command a plugin may declare in `commands[]`. The
  bundled `defaults` plugin declares the macOS conventions as `""`
  bindings; disabling it leaves those commands unbound. Manifest-only
  plugins may declare
  `bindings`. App knowledge lives here, never in the host.
- **`terminal_emulators`** — bundle ids of apps this plugin declares as
  terminal emulators. No protocol identifies one, so the host learns them as
  data: across plugins the union gets the terminal rules (an unbound Command
  chord is refused rather than typed, and pixel wheels are refused) and
  matches `only_terminals`. The bundled `terminals` plugin declares the
  common emulators.
- **`own_text_editing`** — bundle ids of apps with their own modal editing
  or partial Accessibility text: an editor with a Vim mode of its own, an
  IDE whose editor exposes no text. No protocol identifies one either, so
  the host learns them as data: across plugins the union is never engaged
  ([engage a field](normal-mode.md#engage-a-field)), so NORMAL's keys keep
  their page meaning there, `v` / `V` do nothing and the text table never
  applies, unless the user's `[mode.apps."<bundle id>".text] enabled = true` forces
  the app. The bundled `defaults` plugin declares VS Code and its forks
  (VSCodium, Cursor, Windsurf), the JetBrains IDEs, Zed and Sublime Text.
- **`on_demand_hints`** — bundle ids of apps whose accessibility tree costs
  too much to warm in the background. Across plugins, the union is walked
  only when hints are requested and observed with the reduced notification
  set that drives mode, border and focus. The bundled `defaults` plugin
  declares Notes.
- **`query_aliases`** — `{ "<token>": "<words>" }`: flashlight query tokens
  the plugin's rows are not indexed under, and the words scored in their
  place. The flashlight keeps only letters and digits of a query, so a token
  of punctuation would match nothing; the bundled `emojis` plugin declares
  the emoticons (`":)": "slightly_smiling_face"`), which is why `:)` finds 🙂.
  A whitespace-delimited token of the query that equals a declared one,
  whatever its case, is replaced; the rest of the query is scored as written,
  in every scope. A token is lowercase, without whitespace, at most 16 bytes,
  and carries a character that is neither a letter nor a digit, so no plugin
  rewrites an ordinary word; its words are lowercase letters, digits and `_`,
  at most 64 bytes; a manifest declares at most 256. Across plugins the
  tables merge and a token an earlier plugin declared keeps its words. Flash
  itself knows no emoticon: with `emojis` disabled a query is scored as
  written.
- **`browser_engines`** — the browsers this plugin declares, as bundle ids
  under their engine: `{"chromium": [...], "webkit": [...], "gecko": [...]}`.
  The host names no browser, so the engine is how it knows one: the
  `host.applescript` tab operations serve `chromium` and `webkit` browsers in
  that engine's dialect, `chat_submit` serves any declared browser, and a
  stuck secure-input hold is released by blurring a `chromium` browser's
  focused element or by focusing a `webkit` or `gecko` browser's address bar
  ([privacy](privacy.md#keyboard)). An engine outside those
  three, an entry that is not a bundle id and a browser listed twice each
  fail the load. Across plugins the tables merge, and a browser an earlier
  plugin declared keeps its engine. The bundled `defaults` plugin declares
  Chrome, Chromium, Brave, Edge, Arc, Vivaldi and Opera with their channels,
  Safari and Safari Technology Preview, and Firefox with its Developer
  Edition and Nightly; a plugin for another browser declares its own, along
  with the `apple_events_targets` its operations need.
- **`mappings`** — key bindings in any mode a config can map: `all | normal |
  insert | terminal | command | hyper | hold | text | visual` (default
  `normal`; `text` is the table NORMAL reads first in a field the user
  engaged, see
  [Vim motions in text](normal-mode.md#vim-motions-in-text), and `visual`
  the keys on a [VISUAL](visual-mode.md) selection), under the
  config's key rules (a `command` key is one modified chord); `command` is an
  argv array with config-mapping syntax; entries
  may scope with `only_bundle_ids`, and `repeat: true` repeats the sequence
  when its final key is pressed again, as in config. Map keys to commands;
  an app's own chord for one belongs in `bindings`, and no bundled mapping
  uses `key send`. Terminal mappings are local to a focused
  popup. Every global mapping registration is suspended while that view
  owns input; only winning INSERT-active `mode normal` bindings are
  inherited as terminal defaults, and explicit terminal bindings override them.
  Terminal sequences use the shared key syntax without `<leader>`, implicit
  counts, or register prefixes. See [popup input](terminal-mode.md).

`only_bundle_ids` and `only_terminals` may appear at the root and on mapping
entries; root and entry selectors compound. `only_terminals: true` scopes to
the declared terminal emulators (the union of every plugin's
`terminal_emulators`, see below) so a plugin never carries its own terminal
allowlist; the registry
instantiates such a plugin only while a known terminal runs, and its `hints`
provider is consulted only in those apps, keeping hint activation elsewhere on
the zero-hop prepared-model path. The numeric manifest `priority` (default 25) is
scheduling/collision arbitration — do not confuse it with the semantic
`sources[].priority` salience enum.

## Resource types

Users never type a source's name: they narrow the flashlight to a resource
type, one word naming what the rows are (`@tabs`, `@history`, `@emojis`),
and see every source of it together. Every `sources[]` entry declares one
`type`, and these rules hold for all of them. `protocol.json`'s
`source_types` pins them: the `plugin!` macro checks each manifest at build
time, and Flash checks again when it loads a plugin.

- A type is one lowercase word: a letter, then letters or digits
  (`^[a-z][a-z0-9]*$`). No dots: `emojis.glyphs` is a source name, `emojis`
  its type.
- Flash feeds some types itself (`apps`, `windows`, `clipboard`, `files`):
  their rows carry behaviour only the host provides. A plugin declaring one
  fails to load.
- A shared type has one contract: every source of it declares the same
  `kind`, and its rows are what the type says. A source of another kind fails
  to load.
- A plugin may introduce a new type. Every plugin declaring the same new type
  must agree on its `kind`; when they do not, each of them fails to load,
  whatever the load order.

| Shared type | `kind` | A row is |
| --- | --- | --- |
| `tabs` | `locations` | an open browser tab, with its URL; selecting it switches to the tab |
| `history` | `default` | a visited page, with its URL; selecting it opens the URL |
| `bookmarks` | `default` | a bookmark, with its URL; selecting it opens the URL |
| `emojis` | `default` | an emoji or symbol in the title; selecting it types it |
| `bangs` | `default` | a `!token` search shortcut; selecting it completes the bang |
| `snippets` | `default` | a text snippet; selecting it types its text |
| `shortcuts` | `default` | a Shortcuts app shortcut; selecting it runs it |
| `terminals` | `locations` | a terminal session (a tmux window); selecting it switches to it |
| `network` | `default` | a network address of this Mac; selecting it copies it |
| `system` | `default` | a system action (lock, sleep, restart…); selecting it runs it, after asking when nothing undoes it |
| `processes` | `default` | a running process; selecting it terminates it, after asking |
| `menus` | `default` | a menu item of the app that owns the menu bar; selecting it presses it |
| `notes` | `default` | a note in Notes; selecting it shows it in Notes |
| `reminders` | `default` | an open reminder; selecting it shows it in Reminders |
| `contacts` | `default` | a contact card; selecting it shows it in Contacts |

Prefer an existing type when your rows are what it describes: a new browser
plugin's tabs are `tabs`, so `@tabs` lists them beside Safari's. A new type
is a lowercase plural noun (`recipes`, `tickets`).

## Errors

**The response law.** Every `result` is a JSON object carrying boolean `ok`.
`ok: false` carries a non-empty, content-free `error` string — with one
deliberate exception: `perform`'s `{"ok": false, "unhandled": true}` (see
below). A failure holds those two keys and no other; only a
`host.applescript` failure may add an integer `status`, and the SDK takes
any other reply that breaks the law as `invalid host response`.
Protocol-level failures use the canonical exact strings from
`protocol.json` (`unknown method: <m>`, `protocol version mismatch: host
v<H>, plugin v1`, `initialize may only be called once`, …); domain failures
are free-form but never contain query text, candidate data, clipboard
content, or config values.

| Constant (`protocol.json` `errors`) | Exact string | When |
| --- | --- | --- |
| `unknown_method` | `unknown method: <method>` | A request names a method the receiver does not implement |
| `protocol_mismatch` | `protocol version mismatch: host v<H>, plugin v1` | `initialize` with another version; terminal |
| `initialize_repeated` | `initialize may only be called once` | A second `initialize`; the plugin keeps serving |
| `host_closed` | `host closed stdin` | A host RPC outstanding when the host went away |
| `host_call_timeout` | `host call timed out` | A host RPC without a reply in time (5 s by default in the SDK) |
| `frame_overflow` | `response exceeded outbound frame limit` | A reply larger than the 10 MiB line cap |
| `capability_denied` | `missing <capability> capability` | A host RPC the manifest's capabilities do not allow |
| `request_capacity` | `plugin request capacity exceeded` | More concurrent host requests than the plugin admits |
| `host_call_capacity` | `host call capacity exceeded` | More concurrent host RPCs than the bound allows |
| `deadline_exceeded` | `deadline exceeded` | A `hints`, `text_grid` or `search` handler dropped before its deadline |
| `confirmation_required` | `requires a perform the user confirmed` | A destructive `host.system_action` or a `host.process_signal` asked outside a confirmed perform |
| `user_request_required` | `requires the user to be using the plugin` | A `request_access` (`host.calendar_events`, `host.notes`, `host.reminders`, `host.contacts`) that would show macOS's prompt while none of the plugin's performs or searches is in flight and no surface shows its segments |

## Limits and deadlines

Every bound below rejects or drops the whole frame or payload; nothing is
silently truncated. The [payload quotas](#payloads-and-quotas) bound
catalogs and answers.

### Deadlines

One table, in `protocol.json`, that the host, the Rust SDK, and this doc
all share:

| name | value | applies to |
| --- | --- | --- |
| `startup` | 5 s (config `[plugins] startup_timeout`) | `initialize` |
| `query` | 50 ms | `evaluate` |
| `hints` | 500 ms (fixed; the activation waits on it ahead of the prepared model) | `hints` |
| `text_grid` | 500 ms (fixed; asked asynchronously, but the letter search waits on it) | `text_grid` |
| `search` | 1 s (from the request being written; a search of a cold plugin first waits for its child, up to `startup`) | `search` |
| `perform` | 10 s | `perform` |
| `ping` | 10 s | `ping` reply |
| `idle_before_ping` | 60 s | inbound silence before a ping |
| `shutdown_grace` | 1 s | stdin-close → SIGTERM (+0.5 s → SIGKILL) |

Notifications have no deadlines.

### Transport limits

Per-process admission bounds from `protocol.json` `transport_limits`:

| Bound | Value |
| --- | --- |
| Line size, both directions | 10 MiB, excluding the newline |
| Concurrent host requests a plugin admits | 16 (32 MiB) |
| Concurrent host RPCs from a plugin | 64 |
| Plugin outbound queue | 64 frames / 16 MiB |
| Plugin event backlog | 256 frames / 16 MiB, plus 256 replacement slots |
| Host pending requests per plugin | 64 |
| Host outbound queue per plugin | 256 frames / 20 MiB |
| Host inbound queue per plugin | 256 frames / 20 MiB |
| stderr | whole lines, 4 KiB each, at most 20 per 10 s |

A plugin that stops reading its stdin while requests or ordinary events fill
the host's queue is restarted; replacement events coalesce instead (see
[event coalescing](#event-coalescing)).

## Security

- **Sandbox.** Every plugin runs under a deny-default seatbelt profile unless
  its manifest says `"sandbox": false`; the user can force any plugin
  unsandboxed with `[plugins.<id>] sandbox = false`. See `sandbox` under
  [Manifest](#manifest), and [privacy](privacy.md) for the unsandboxed
  bundled plugins.
- **Capabilities.** Host RPCs are default-deny and checked per process
  against the manifest; see [Host RPCs](#host-rpcs).
- **Environment.** A plugin gets a scrubbed environment: no ambient tokens,
  agent sockets or login-shell secrets. Credentials go in its
  `[plugins.<id>]` table, delivered as `FLASH_PLUGIN_CONFIG`.
- **Content-free errors and logs.** Errors and `log` lines never carry query
  text, candidate data, clipboard content, config values or event payloads.
- **No escape through effects.** There is no `run` effect, and neither rows,
  `host.open` nor `open` effects accept `file:` URLs, so nothing a plugin
  publishes makes the host execute code outside the sandbox.
- **Third-party code.** A plugin from GitHub is pinned to a full commit SHA,
  and a third-party plugin's optional `install` step runs sandboxed.

## Schemas and constants

`Plugins/_flash_plugin_rust/protocol.json` is the machine-readable
specification: the version, the deadline table, every method, the event
catalog, the quotas, the error strings, the capability registry and the
transport limits. The host asserts its own constants against it, and the
SDK's wire and runtime tests, plus the `probe` crate, prove the behaviour.
Where this prose and `protocol.json` disagree, `protocol.json` is right and
this page has a bug.

Every frame has a JSON Schema (draft-07) under `docs/schema/plugin/`, named
after its method: `<method>.schema.json` for a request or notification and
`<method>.reply.schema.json` for its reply. A manifest is not a frame and has
no schema here.

- [`host-frame.schema.json`](schema/plugin/host-frame.schema.json): any line
  the host sends
- [`plugin-frame.schema.json`](schema/plugin/plugin-frame.schema.json): any
  line a plugin sends
- [`definitions.schema.json`](schema/plugin/definitions.schema.json): the
  shapes several frames share (ids, pids, frames, rows, targets, the context)
- Host requests and their replies:
  [`initialize`](schema/plugin/initialize.schema.json)
  ([reply](schema/plugin/initialize.reply.schema.json)),
  [`ping`](schema/plugin/ping.schema.json)
  ([reply](schema/plugin/ping.reply.schema.json)),
  [`evaluate`](schema/plugin/evaluate.schema.json)
  ([reply](schema/plugin/evaluate.reply.schema.json)),
  [`hints`](schema/plugin/hints.schema.json)
  ([reply](schema/plugin/hints.reply.schema.json)),
  [`text_grid`](schema/plugin/text_grid.schema.json)
  ([reply](schema/plugin/text_grid.reply.schema.json)),
  [`search`](schema/plugin/search.schema.json)
  ([reply](schema/plugin/search.reply.schema.json)),
  [`perform`](schema/plugin/perform.schema.json)
  ([reply](schema/plugin/perform.reply.schema.json))
- The host notification: [`event`](schema/plugin/event.schema.json), with
  each event's payload
- Plugin notifications: [`publish`](schema/plugin/publish.schema.json),
  [`status`](schema/plugin/status.schema.json),
  [`poll`](schema/plugin/poll.schema.json),
  [`log`](schema/plugin/log.schema.json)
- Host RPCs and their replies: `host.<name>.schema.json` and
  `host.<name>.reply.schema.json` for each method in
  `methods.plugin_to_host_rpcs`, from
  [`host.ping`](schema/plugin/host.ping.schema.json) to
  [`host.ax_select_child`](schema/plugin/host.ax_select_child.schema.json)

A schema describes what the sender writes. Where a shape is open on purpose
(a row's `data`, a `log` line's field names, the attributes of an
Accessibility snapshot node), a `$comment` says so. The schemas are
written by hand from the codecs; `PluginSchemaTests` fails when a method in
`protocol.json` has no schema, when a bound in a schema differs from the
quota it mirrors, or when a line of the conformance corpus meets a schema
with the wrong verdict.

## Compatibility policy

Locked while breaking is still free (the MV3 lesson); changing any of these
after external plugins exist is a migration, not an edit:

1. One integer `protocol_version`, echoed exactly at initialize; **never**
   per-feature wire negotiation — features are manifest declarations.
2. The response law and the canonical error strings in `protocol.json`.
3. Id semantics and no-cancellation (late replies dropped).
4. UTF-8 NDJSON framing, 10 MiB line cap, NSScreen geometry.
5. The quota table and the atomic-rejection doctrine.
6. The capability registry: additions allowed, renames never, granular over
   coarse.
7. The `performed / unhandled / error` trichotomy as the universal
   `perform` vocabulary, including "error must not fall back".
8. Strict manifest unknown-key rejection + new surface only with a protocol
   change.
9. Namespacing: row `source` names, storage keys, status segments, and log
   sources are plugin-id-scoped host-side.
10. Content-free logging.
11. Normativity order: `protocol.json` + the SDK's conformance tests > this
    prose > any implementation.

## For Flash contributors

### Host internals

Asynchronous host RPC replies stay attached to the child that requested them:
a replacement child can reuse an ID without receiving the old child's reply.
Queued host work carries that same transport lifetime. Every host-RPC queue
hop uses `PluginHostRequestScope.enqueue`, which checks ownership when the
work actually starts; dropping only the reply would still let a retired child
post input, activate an app or overwrite storage. A scope is required at each
handler entry. Work already running may finish, but its obsolete reply is
discarded; this adds no wire cancellation message.
Each admitted outbound frame owns a separate close-on-exec stdin descriptor
until its write completes. Teardown may close the lifecycle's stdin handle
without invalidating a write already in progress; queue retirement releases
the frame's descriptor and its transport budget together.

Explicit reload and file changes reconcile the manifest through PluginManager.
Configuration changes and restart requests update one lock-owned desired-state
value. Restarts carry only plugin IDs, so they cannot replay an older config
after a concurrent update or revive a stopped manager.
Unchanged definitions restart only the affected binaries and retain catalogs.
A changed valid definition rebuilds its registrations, authorization, adapter,
and process together and drops its previous catalog. Its requests route to
the replacement from the moment it is reconciled: they wait while the old
process stops, and the replacement starts only once it has. An invalid replacement
keeps the last validated definition running and reports its load error; fixing
the file allows reconciliation to recover without a resident-app restart.

### Conformance workflow

`Plugins/_flash_plugin_rust/protocol.json` pins the constants; the SDK's
`cargo test` suite pins the behaviour. Wire and lifecycle rules — framing,
ids, noise, the handshake, protocol mismatch, request decoding, notification
shapes, shutdown draining, host-RPC correlation — are `WireHarness` tests in
`Plugins/_flash_plugin_rust/src/runtime.rs`, driving the real serve loop over
in-memory NDJSON streams. `Plugins/_flash_plugin_rust/fixtures/wire-values.fixture`
is the malformed and boundary-value corpus the SDK and the host's XCTest
suites both consume, and the probe crate `Plugins/_flash_plugin_rust/probe`
drives a generic `plugin!`-generated plugin through every surface (catalog,
evaluate, hints, text grids, the perform trichotomy, notifications,
events, host-RPC arms) over the wire.

Whole frames are pinned by the two-way corpus in
`Plugins/_flash_plugin_rust/conformance/`: `host-frames.ndjson` holds frames
the host sends and `plugin-frames.ndjson` frames a plugin sends, each line
marked `accept` or `reject` (the `README.md` beside them gives the format and
the fixture they describe). The SDK's `src/conformance.rs` sends the host
frames through the real serve loop and decoders and requires the SDK's
encoders to write the plugin frames; the host's `PluginSchemaTests` checks
every line against the [schemas](#schemas-and-constants), runs the plugin
frames through the host's decoders and answers each `host.*` request with
the real dispatcher. Neither end has a copy of the other's expectations.

For a protocol defect, land the failing corpus line or test there before
changing the implementation.

Behaviour specific to one plugin — scripted host replies, the published
catalog, status rows — is a `cargo test` in `Plugins/<id>` written against
`flash_plugin::testing::Harness`. Real process spawning, manifest
reconciliation and shutdown are the host XCTest suites' business;
`PluginSandboxExecTests` compiles every bundled seatbelt profile and boots
every built sandboxed plugin under its resolved profile with the scrubbed
plugin environment.

The complete gate is:

```bash
mise run test:plugins
```

It formats and lints every Rust crate, runs the plugin-publication test and
every crate's unit tests (the SDK workspace includes the probe), and builds
all plugins.

### Seatbelt profile invariants

Seatbelt denies are not reopened by a later allow rule. When a denied parent
contains an allowed child, carve the child out inside the deny filter with
`require-all` and `require-not`; `PluginSandbox.secretsReadDeny` is the
canonical pattern for allowing a plugin's own data directory while denying its
siblings.

`(deny default)` does not cover every operation family. A profile with no
`process-info*` rule reads every process through libproc (measured on macOS
26), so `PluginSandbox.processInfoRules` writes that denial out: other
processes by target, the pid list by name, and under `process_info` only the
operations no reader uses, so no allow has to reopen a deny. The profile's
`sysctl-read` allowance is broad, which leaves the kernel's own process list
(`kern.proc`) and a same-user process's arguments (`kern.procargs2`)
readable by every sandboxed plugin: Seatbelt's sysctl name filters do not
match those nodes, so no rule closes them. `process_info` therefore gates
what libproc adds, the resource, task and descriptor reads and the
executable path, not the existence of other processes.

Seatbelt matches canonical vnode paths. Resolve symlinked executables before
putting them in a profile, and canonicalize temporary fixture roots
(`/var/folders/...` commonly resolves beneath `/private/var/folders/...`). A
path that looks equivalent in the shell may otherwise fail silently in the
profile. For diagnostics, `sandbox-exec` exit 65 means the profile did not
compile, while exit 71 means the target could not be executed under it.

### Debugging

Debugging is a first-class feature of this transport: run any plugin binary
in a terminal and type NDJSON at it — no host required. The SDK's
`WireHarness` does the same in-process from `cargo test`.
