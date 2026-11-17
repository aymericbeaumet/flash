# Plugin performance

Flash keeps one child per resident plugin. Most run under a deny-default
sandbox built from their manifest. The process boundary is intentional: it gives each integration an explicit capability profile,
independent crash recovery, bounded requests, and deterministic lifecycle.
Official plugins are all native Rust binaries so that isolation no longer
requires six language runtimes or host-injected SDK bridges.

## Baseline and target

The pre-migration installed-app snapshot had nine resident non-Rust children
using roughly 84 MiB RSS / 117 MiB physical footprint; Flash plus all plugin
children was roughly 188–190 MiB physical. The steady-state target after the
Rust migration is at most 130 MiB physical for the same enabled plugin set.

On the maintainer's Apple Silicon machine, a post-migration `plugin-dev`
direct-process run (2026-09-02, five cold samples per plugin) measured all 32
executables at 111,424 KiB aggregate median RSS. Per-plugin cold-initialize
p95 values were 1.8–7.6 ms and settled ping p95 values were 0.12–0.35 ms. This is a
deliberately conservative aggregate—on-demand plugins do not all coexist in a
normal session—and excludes the resident host and seatbelt wrapper.

The matching installed dev app measured 126.3 MiB physical footprint for Flash
plus its 28 fully warmed resident plugin children, down from roughly 188–190
MiB before the migration. All 28 initialized concurrently in 219 ms, the
slowest handshake took 26 ms, and none timed out. Treat these figures as a
machine-specific reference, not a portable guarantee.

The five system-monitor plugins added on 2026-09-04 (cpu, memory, disks,
network and power, since merged into the one `sysinfo` plugin) measured
15,336 KiB aggregate median RSS across 20
samples each. Their cold-initialize p95 values were 2.09–2.30 ms and settled
ping p95 values were 0.19–0.22 ms. The same build's 36 direct plugin binaries
measured 121,504 KiB aggregate median RSS across five samples. The installed
dev app settled at a 126.54 MiB median physical footprint for Flash plus its
33 resident children across five measurements (127.01 MiB maximum), remaining
inside the existing 130 MiB budget.

`searchproviders` (2026-10-20) keeps about 14,500 bangs as their stored
text plus a sorted trigger index, about 4 MiB live. It publishes its
10,000-row catalog about 90 ms after start (80 ms of CPU) and settles near
17 MiB physical footprint, most of it the freed publish buffers; `publish`
serializes rows straight into the frame rather than through a JSON tree,
which took the same start from 29 MiB.

Those figures predate status-bound activation. A status-only plugin such as
`feed` now spawns only while the enabled status bar shows one of its
segments, so with the bar off (the default) it does not run until its command
does, unless a mapping keeps it warm (see
[warm plugins](#process-creation-and-warm-plugins)). `sysinfo` publishes the
`network.addresses` catalog, so it stays resident, but each of its domains
samples only while a surface shows one of that domain's segments.

Use these regression budgets when changing the runtime or an official plugin:

| Metric | Budget |
| --- | ---: |
| direct cold initialize, p95 | 100 ms |
| idle ping round trip, p95 | 5 ms |
| synchronous query evaluator round trip | 50 ms protocol deadline |
| catalog decode/store | warn at 50 ms |
| host queued outbound transport | 256 frames / 20 MiB |
| host queued raw input / decoded frames | 256 entries / 20 MiB each |
| host outstanding requests / host RPCs | 64 / 64 |
| plugin outbound transport | 64 frames / 16 MiB |
| full installed steady-state footprint | 130 MiB physical |

The transport and outstanding-call limits are enforced admission caps, mirrored
in the shared protocol specification. The timing and footprint budgets are
regression tripwires. Hardware, signing,
seatbelt compilation, TCC state, and debug versus release builds all affect
absolute startup numbers.

## Process creation and warm plugins

Starting a child costs more than its initialize handshake. The host execs
`sandbox-exec`, which execs the plugin, and a bare runtime name resolves
through `mise which` first. While `syspolicyd` is saturated each of those
execs can stall for seconds, so an on-demand plugin used to make the
keypress that first needed it wait for every one of them, sometimes past its
perform deadline.

- **Resolution is remembered.** `PluginSandbox.resolveExecutable` keeps each
  bare-name answer (the plugin's own runtime, the tmux grid capture's
  `tmux`) for the life of the resident. The key is the
  name, the directory `mise which` runs in and the login `PATH` the fallback
  walk reads. A remembered path is served only while it is still an
  executable file; otherwise it is dropped and resolved again. A failed
  resolution is never remembered, so a tool installed later is found on the
  next lookup. A miss still spawns `mise`, so callers stay off the main
  thread (a guardrail allowlists them).
- **Mapped plugins are warm.** A plugin is warm when a configured mapping can
  run one of its commands. That covers every mode and app scope, an enabled
  status-bar click and a plugin's own `mappings`. A command reference
  resolves the way dispatch does: the exact `(command, subcommand)` owner,
  else the command's `*` wildcard. App selectors are ignored. Ten seconds
  after each reconcile (`core:plugin_prewarm`, priority `low`), every warm
  on-demand plugin that is still idle is spawned. That includes a
  status-bound one that no surface shows. A warm status-bound plugin then
  keeps its child when its segments go off screen, and so does one a command
  started. Unobserved, a monitor that follows `core:status.observed` stops
  its cadences and only answers commands.
  `PluginWarmPolicy` holds these rules as pure, unit-tested functions.
- **Everything else is unchanged.** A command that no mapping runs, whether
  typed on the command line, sent with `flash <command> <subcommand>` or
  given as a bang, still spawns its plugin on first use. The plugin then
  stays running. A status plugin that nothing maps still follows its
  surfaces. A configuration with no plugin mappings starts no extra process.

A warm plugin costs an idle child, about 2–4 MiB RSS for an official Rust
plugin, from launch instead of from first use. Its one-time startup work,
such as a status monitor's first sample, also moves to launch. Remove the
mapping, or disable the plugin, to give that back.

## Publish-then-exit plugins

A plugin that only provides data has no reason to stay resident. With
`"lifecycle": "publish_then_exit"` in its manifest
([process model](plugin-protocol.md#process-model-and-lifecycle)) the child
answers initialize, publishes its catalog from `on_start` and exits 0; the
host reads its stdout to the end before resting the plugin as `published`,
keeps the catalog in its store as it does across every restart, and counts
the exit as success: no restart, no failure budget, no liveness ping, no
event delivery. It spawns the child again only when the data can have
changed — the plugin's `[plugins.<id>]` settings, a file one of its
`watch_settings` names (snippets' `file`), its own binary or manifest, or
`plugins reload` — and the run costs what a start costs, a few milliseconds
of CPU, after which the process is gone.

`emojis` and `snippets` run this way, which gives back the 2–4 MiB each idle
Rust child held (the emoji catalog's own copy of its 2,037 rows included) and
two of the resident processes the steady-state footprint counted. A catalog
plugin that must also answer a command, a bang or an event keeps its child:
`shortcuts` has commands and relists on focus changes, `searchproviders`
answers bangs. The flashlight never notices the difference: its rows are a
host-memory read either way, and a published plugin's performs are
`unhandled` because its rows carry host effects.

## Measuring

The benchmark builds the native-architecture binaries it measures, then
reports:

```bash
mise run bench:plugins -- --samples 5
mise run bench:plugins -- --samples 10 --json > plugin-benchmark.json
mise run bench:plugins -- --plugin browsers --samples 20
```

`mise run bench:footprint -- [sample-seconds] [log-window-minutes]` is the
whole-system counterpart: it samples the running resident and every child
(CPU, idle wakeups, memory, descriptors, threads) and summarises watchdog
stalls, tap re-enables, and log lines per minute over the window. It is
read-only and expects one installed Flash to be running.

The plugin benchmark launches each official executable from a clean data directory, measures
the protocol initialize round trip, lets post-initialize startup settle,
measures an idle ping, samples RSS/thread count, then
shuts the child down through stdin EOF. It does not enforce thresholds in CI;
compare like-for-like builds and machines. The installed-app measurement is
the final authority for total footprint because it includes real seatbelt
profiles, resident/on-demand policy, catalogs, and host state.

Host logs provide phase data for real launches: `install_ms`,
`resolution_ms`, `sandbox_ms`, `spawn_ms`, initialize `elapsed_ms`, and
`startup_total_ms`. Catalog publication logs only when decode/store takes at
least 50 ms.

## Hot-path rules

- Plugin stdout framing, JSON parsing, catalog publication decoding, and stdin
  writes stay off the lifecycle queue. Input and output queues are bounded;
  a stalled or flooding child is restarted instead of
  freezing every lifecycle operation. An unsent replacement event is
  superseded by the next one with its coalescing key, so a burst of state
  signals such as `core:ax.changed` never exhausts a briefly stalled child's
  outbound budget (see [event coalescing](plugin-protocol.md#event-coalescing)). Deadlines include time spent awaiting
  queue admission, and teardown invalidates work from the old child generation.
  Stderr drains on its pipe callback without scheduling lifecycle work.
- Host → plugin fan-out resolves the listeners of an event name once per
  published plugin set, and derives an event's frame and coalescing key once
  for every listener. `core:ax.changed` carries the bundle id the observer
  recorded at install, never a LaunchServices lookup per notification. A
  `status` that restates every segment unchanged schedules no re-evaluation.
  The Rust runtime moves `params` out of the envelope instead of cloning it,
  encodes each outbound frame once, and flushes frames queued together with
  one write.
- Third-party installation drains stdout/stderr concurrently on its own job
  queue; output retention is capped at 4 MiB / 256 KiB. Stop/reload never waits
  on an install script, and its process group receives bounded TERM/KILL
  escalation even when a descendant keeps an output pipe open. Replacements
  wait asynchronously for the preceding install to release the same root.
- The shared SDK uses one current-thread Tokio executor per child. Accepted
  events keep wire order, with pending application snapshots coalesced to the
  newest state; interval callbacks do not overlap themselves. Startup and
  request callbacks may overlap and must coordinate shared refresh state.
  Async I/O and `spawn_blocking` retain concurrency without multiplying idle
  worker threads.
- A publish is proportional to the change. The host decodes every publish in
  full, so volatile and static rows are separate sources, each published
  alone with `publish_source` ([protocol](plugin-protocol.md#plugin-host-notifications)):
  `browsers` publishes a browser's tab source on a tab change (tens of rows)
  and its history and bookmark sources only on their own refresh (thousands
  of rows, at most once a minute), where one publish used to carry all of
  them on every tab switch — 788 times a day at 700 KB, 61 s of decode. The
  byte quota is read off the frame the reader already holds (each row's span
  on the wire), never by serializing the rows a second time.
- The host decodes catalogs on a per-plugin `.utility` catalog queue that
  carries no replies, so a reply frame behind a large publish is not delayed
  by its decode; the plugin's lifecycle, reader and writer queues run
  `.userInitiated`, because `hints`, `evaluate`, `perform` and `ping` replies
  are waited on and a utility-class thread is what the kernel starves first
  under load. The store compares a publish against what it holds outside
  its lock, so the flashlight's reads never wait on a comparison.
- Catalog replacements that are semantically unchanged, whole or per
  source, do not advance the store generation, timestamp, or subscriber
  notifications.
- Browser refreshes are single-flight, publish only the sources whose rows
  changed, and log state transitions or rate-limited warnings instead of
  every refresh.
- Catalog plugins do not poll the apps they mirror. `browsers` refreshes on
  app lifecycle and focus events and on the `core:ax.changed` notifications
  that can change its rows, ignoring the rest — every keystroke's
  `AXValueChanged` among them: a window retitled or created (web content
  posts element creation and destruction on every DOM update). Relevant bursts —
  a shell retitling around each command, a closing window's subtree — refresh
  once quiet for 300 ms, and at most ten seconds after they began. The host
  observes an app's AX only once it has been focused; changes it cannot see
  catch up when focus or the flashlight next touches the app.
- `terminals` never re-reads its local tmux servers on a timer. Each server a user's
  client is attached to is followed by one control-mode client (`no-output`,
  `ignore-size`; it never starts a server or applies `update-environment`),
  and one inventory read follows each burst of the notifications that can
  change it — sessions and windows created, closed, renamed (automatic-rename
  included) or selected, panes selected, added or closed, clients attaching,
  switching or detaching — settled for 100 ms, at most a second after the
  burst began. What tmux never notifies — a window's working directory, its
  command once automatic-rename is off, which client was used last — is
  re-read on focus changes, app termination and flashlight opens. A client
  attaching to a server nobody is attached to reaches no observer, so while
  such a server runs, settled window retitles and creations
  (`core:ax.changed`) refresh too; a kqueue watch on the `tmux-$UID` socket
  directory catches servers starting or exiting. A socket whose probe fails
  transiently is retried once per backoff step (5, 15, then 60 s). Remote
  hosts in `ssh_hosts`, which no local notification reaches, keep a
  five-second refresh.
- `terminals` sends its local tmux commands — `]t` and the other actions, hint and
  letter-search (`text_grid`) captures, inventory reads — as lines to that
  same control-mode client instead of spawning a `tmux` client per command. On a busy Mac, every
  fork/exec can wait seconds on the system's exec policy daemon
  (`syspolicyd`), while a line on an open connection runs as fast as a tmux
  key binding. Each request ends with a marker command, and every reply block
  tmux flags as answering that client up to the marker's belongs to the
  request, so hook output never leaks in. A spawned client runs a command
  only where no observer is attached yet, and a written request that goes
  unanswered fails and reattaches the observer rather than running twice.
  The process tree that maps a terminal to its tmux client comes from libproc
  (`flash_plugin::sys::process_parents`), not `ps`.
- Plugin AppleScript runs in the resident through `ctx.applescript` and
  `host.applescript`: browser tab listing, selection, moves and route
  restores, Shortcuts, and AI-provider autosend share the host's OSA runtime.
  No plugin loads its own AppleScript runtime or spawns `osascript`.
  Capability and target checks run before execution; at most four requests
  per plugin may wait or run, with bounded scripts, results and deadlines.
  The host serializes complete OSA lifetimes off the main thread to keep
  compiler work and runtime teardown from overlapping. Queueing uses
  the request's original deadline; a timed-out running script retains the
  runtime until its component closes and its autorelease pool drains. `browsers` and
  `shortcuts` now keep their default-deny sandboxes; `aiproviders` remains
  unsandboxed for its credentialed quota helpers.
- Debug plugin logs remain available in the log file but do not invalidate
  status/inspector snapshots.
- The NDJSON frame collector scans appended bytes once and compacts the
  consumed prefix once per append.

Do not trade the child-process boundary for an in-process ABI or shared
daemon merely to reduce memory. That would collapse the sandbox and crash
containment guarantees and create a second plugin architecture.
