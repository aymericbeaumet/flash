# Rust plugin SDK (`flash_plugin`)

The blessed way to write a Flash plugin. One crate, one dependency line:

```toml
# Bundled plugins (in this repo):
flash_plugin = { path = "../_flash_plugin_rust" }

# External plugins — pin a rev, same as every third-party surface in Flash:
flash_plugin = { git = "https://github.com/aymericbeaumet/flash", rev = "<sha>" }
```

The proc-macro crate and the bounded-subprocess layer are internal details of
`flash_plugin`; never name them. Scaffold a new bundled plugin with
`mise run new:plugin -- <id> "<Name>" "<description>"` — it generates the
manifest, a hermetic standalone crate (path dep on the SDK, per-crate build
profiles, the canonical `clippy.toml` copy, a committed `Cargo.lock`), and a
working `:<id> ping` command, requiring zero manual edits to reach green.
No Cargo workspace keeps those crates aligned, so the plugin gate does: its
`lint` lane rejects build profiles, shared dependency requirements or locked
versions that differ between crates, and
`mise run update:plugin-dependency -- <dependency> <requirement>` changes one
dependency in every crate that declares it
([dependency updates](development.md#dependency-updates)).

## Authoring shape

```rust
use flash_plugin::{CommandRequest, Context, PerformResponse, run};

struct MyPlugin;

flash_plugin::plugin!(MyPlugin); // reads manifest.json at compile time

impl FlashPlugin for MyPlugin {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> PerformResponse {
        match command.subcommand.as_str() {
            "ping" => PerformResponse::ok().message("pong"),
            other => PerformResponse::fail(format!("unknown subcommand: {other}")),
        }
    }
}

fn main() {
    run(MyPlugin);
}
```

`plugin!` generates a `FlashPlugin` trait whose *required* methods follow the
manifest: pushed `sources` ⇒ `on_start` (runs AFTER the immediate initialize
reply; build the catalog and `ctx.publish(...)` when ready), live `sources`
(`"live": "per_query"` or `"per_scope"`) ⇒ `on_search` (a `SearchRequest`
naming the `source` and the `query` typed after its scope, answered with
`SearchResponse::rows(...)`; publish nothing for a live source), `query` ⇒ a
synchronous `evaluate`, `commands` / `bangs` ⇒ `on_command`, which also
receives the core commands the manifest declares under Flash's topics (a
`CommandRequest` whose `context` is then the focused app; match on
`(command.command, command.subcommand)` and read its arguments by name and
type: `integer("index")` for `--index=3`, `value("device")` for a string or
an enum, `flag("force")` for a flag, `positional()` for an own command's
one bare word, a `_` in a name written `-`. An own command's are the `args`
its `commands[]` entry declares: the host has already held the words to
that declaration and `plugin!` checks its shape at build time, so a handler
parses nothing and answers `usage:` only for what the host cannot know;
`query()` is a bang's words. An own
command's `count` is the NORMAL count typed before its key, 1 without one,
and `confirmed` says the user answered a question before the command: the
`confirm` its manifest entry declares, or an `alert confirm` around it),
`navigation` ⇒ `on_navigate`, `hints` ⇒ `on_hints`. Optional: `on_event`,
`on_resolve`, `on_text_grid` (a hint provider's visible text as a
`TextGridResponse` of `TextGridLine::text` / `TextGridLine::format` lines,
for letter search, with `.cell(TextGridCell { .. })` when the terminal pads
or centres its grid; the default is no grid), `on_shutdown` (runs on stdin EOF
before exit). Forgetting a required handler is a compile error, not a runtime
surprise. A manifest `"lifecycle": "publish_then_exit"` makes `on_start` the
whole run: publish from it and return, and the runtime runs `on_shutdown`,
writes every frame the run emitted and exits 0 on its own, without waiting
for stdin to close; the host keeps the catalog and spawns the plugin again
only when its settings, a `watch_settings` file or its plugin definition
change, or you run `plugins reload`. The macro rejects
that lifecycle beside any surface a live child serves, as the host does
([process model](plugin-protocol.md#process-model-and-lifecycle)), and holds
`live` to the host's rules: one of its two values, the same on every source
of the manifest or on none, never on a `locations` source. The
`emojis` and `snippets` plugins are the examples. On the wire,
resolve/command/navigate all arrive as the single `perform` method —
the SDK routes kinds to your handlers, and every one of them answers with the
`PerformResponse` trichotomy: `ok()` (+ `.target_pid()` / `.navigation_url()`
/ `.message()` / `.alert()`), `unhandled()` ("not my context" — the host may
fall back), or `fail(msg)` ("mine, but it broke" — the host must not fall
back; a command's caller reads `msg`). `.message()` is a command's output and
`.alert(PerformAlert::message("caffeinate on"))` or
`.alert(PerformAlert::value("volume", "38%").widest_value("100%"))` the
centred alert Flash shows wherever the command ran. Tests read
a built response back with `is_ok()` / `is_unhandled()` / `error_message()` /
`toast_message()`.

## Context

Handed to every handler; cheap to clone. Key surface:

- Catalog: `publish(candidates)` pushes the complete replacement row set to
  the host-owned store (rows carry a first-class `source` naming a manifest
  `sources[].name`; `Candidate::confirm("Restart this Mac?")` makes the
  host ask before it acts on the row, so its `on_resolve` runs only once the
  user answered `y`, and a plugin never asks itself); `publish_source(name, candidates)` replaces that one
  source's rows and leaves the others as last published, so rows that
  change often and rows that rarely do live in separate sources and a
  publish stays proportional to the change. Publish an authoritative empty
  `Vec` when the source is truly empty; on transient failure simply don't
  publish — the host keeps the last-good catalog, across restarts. The
  testing `Harness` reads them back with `drain_published_rows()` (the last
  catalog) and `drain_publishes()` (every publish as `(source, rows)`).
- Live rows: a live source publishes nothing, so the host shows what its
  last `search` answered. `source_changed(name)` (the `changed`
  notification) says those rows are stale; the host then searches again if
  a flashlight query still shows the source, at most twice a second, and
  does nothing otherwise. Call it when rows change after a reply, never on
  a cadence.
- Dirs: `data_dir`, `home_dir()`, `config_dir()`, `cache_dir()`,
  `share_dir()`, `bin_dir()` — all under the plugin's own data dir.
  `FLASH_PLUGIN_DATA_DIR` is required; there is no cwd fallback.
- Network: `fetch(url)` has the host GET an HTTPS URL the manifest allows
  (`fetch_urls`, `fetch_settings`) and returns the body of a 2xx response;
  any other status is `Err("HTTP <status>")`, and a refusal or a transport
  failure is the host's message. The plugin needs the `network_fetch`
  capability and no network access.
- Settings: `config_str(key)` / `config_json(key)` read the plugin's
  `[plugins.<id>]` table as the host resolved it against the manifest's
  `settings`: a value of the declared type, or the declared default when no
  file sets the key. A plugin repeats neither the check nor the default; a
  key that is absent has no default and is not set.
- Events: `running_applications()` is the host-maintained app snapshot (fed
  by `core:apps.changed`, delivered right after initialize). `RefreshGate`
  serializes refresh producers against it. A `static AppWatch` answers whether an event
  can change what the plugin reads from its apps — focus into, within or out
  of one, one launching or quitting, their running instances changing, a
  flashlight session opening — so an app-scripting plugin refreshes on those
  alone (the browsers plugin). `core:ax.changed` carries
  `Event::notification`, one of `flash_plugin::ax_notifications`; match it
  with `Event::is_ax_change(&[…])` so a refresh follows only the
  notifications that can change what you read (`AXTitleChanged`,
  `AXWindowCreated`, …) and never a keystroke's `AXValueChanged`. A
  `static Settle<K>` coalesces a burst of such events into one refresh:
  `Settle::new(settle, max_wait, priority)` and `schedule(&ctx, key,
  refresh)` run `refresh` with every key the burst named (the apps whose
  windows changed) once it has been quiet for its settle period, or at its
  ceiling when it never is. The wait is one host deadline at `priority`,
  re-armed for the remainder when later events extended the burst, and it
  costs nothing between bursts (the browsers and terminals plugins). With `settle == max_wait` it is a plain window: the first event
  opens it and the rest join one refresh.
  `core:status.observed` carries
  `Event::segments`: the complete set of this plugin's status segments a
  surface shows, possibly empty (the protocol's
  [status observation](plugin-protocol.md#status-observation)). Listen for it
  to scope work that only feeds a segment to the time it is shown:
  `ObservedCadences::interval(&ctx, period, priority, tick)` registers
  cadences that tick only while a segment is
  observed — `observe(segments)` cancels or re-arms them and returns true
  when they were just re-armed, so you sample at once; `observed()` tells a
  command to sample first, since nothing sampled meanwhile (the `sysinfo`
  plugin's cpu, memory and disks domains, each over its own segments).
- Status values: `status(segments)` takes anything `Into<StatusSegment>` —
  a plain string is ready-made markup, build `StatusValue::text(visible)`
  and attach a hover document with `.with_preview(Preview)`, or publish a
  host-rotated `StatusCarousel::new(lines, cycle)` whose
  lines each carry their own preview (the feed plugin). `with_prefix` pins
  markup that does not rotate; a status-bar name belongs in the template
  (`#[label]`), not in that prefix. `Markup::text`
  is the only entry for externally sourced text (it doubles literal `#`);
  `Markup::raw` inserts intentional markup, `Markup::colored`/`styled`
  wrap content in a `Style` (`Color::TITLE`, `MUTED`, `ACCENT`, `ALERT`,
  `WARN`, `INBOUND`, `OUTBOUND`, or any palette/RGB value), `Markup::link`
  escapes marker delimiters in URLs, and `Markup::plain` strips markers for
  command replies. `Preview` is a line builder — `title`, `note`, `section`,
  `row(label, value)` (label padded to 14 visible characters, muted),
  `blank`, `table(Table)`, `raw` — or `Preview::from_markup` for a
  preformatted body; `render`/`render_plain` produce the document. The
  `status` module also carries the shared formatters (`bytes_iec`,
  `bytes_iec_compact`, `rate_iec`, `rate_cells4`, `percent2`,
  `sparkline_percent`, `sparkline_scaled`, `sparkline_padded`,
  `duration_hours_minutes`, `duration_compact`, `duration_uptime`,
  `progress_bar`), the `Published<T>` publish-if-changed gate, and the
  bounded `History<N>` sample window.
- Subprocess: `run_command(&ctx, argv, timeout)` —
  bounded capture (4 MiB stdout / 256 KiB stderr caps, process-group kill on
  timeout), cwd = data dir, scrubbed env with the plugin `bin/` on PATH.
  Use `run_command_with_slow_threshold` only when the command deliberately
  waits while sampling; it preserves timeout warnings while moving that call's
  default one-second slow warning. `.into_perform()` turns a capture into a
  `PerformResponse`.
- Process table: `ctx.processes(None)` reads the figures of every process
  the user may measure (`ProcessEntry`: pid, start, CPU time, resident
  memory), `ctx.processes(Some(&pids))` those of at most
  `MAX_PROCESS_PIDS` pids with their names, and `ctx.process_tree(pid)` one
  process and its descendants with their thread and socket counts, disk
  I/O and the root's path and start (`host.process_table`, the
  `process_table` capability). Each reply carries `at`, the host's
  monotonic clock: a CPU share is the CPU time gained between two reads
  over the difference of their `at`. The host never reads a process's
  arguments or environment. No sandbox profile opens another process, so a
  sandboxed plugin has no other way to one.
- Process tree, unsandboxed plugins only: `flash_plugin::sys::process_parents()`
  lists every `(pid, ppid)` through libproc, so `terminals` forks no `ps`
  to map a terminal to its tmux client. Under a sandbox profile it answers
  an error. The SDK carries only the native bindings more than one plugin
  needs; a reader one plugin uses lives in that plugin (the `sysinfo`
  monitors' Mach, sysctl and IOKit samplers are `Plugins/sysinfo/src/sys/`).
- AppleScript: `ctx.applescript(&AppleScriptOperation::…, timeout)` returns
  `Result<String, String>` through `host.applescript`. Named operations cover
  browser tab listing/selection/moves, listing/running shortcuts, sending
  Return to a chat's focused browser and asking a running media player what
  it plays (`NowPlaying`). The host owns every script template and
  escapes string values; no plugin-supplied source is accepted. Declare
  `apple_events` together with `apple_events_targets`: supported browser IDs
  for browser operations, `com.apple.shortcuts.events` for shortcuts,
  `com.apple.systemevents` for chat submit, or the players asked. The resident owns the OSA runtime,
  so plugin senders can remain sandboxed. Generated source is limited to
  64 KiB, results to 1 MiB, timeouts to 30 seconds, and outstanding requests
  to four per plugin. Complete OSA lifetimes execute one at a time in the
  resident, with queueing included in the request deadline. The returned text
  has no trailing newline; diagnostics record counts,
  durations and error numbers, never operation values or results. An open
  Automation prompt can hold an execution slot after its caller's deadline.
- Host RPC: `call_host(method, params)` / `call_host_timeout` never error —
  the result object carries `{"ok": false, "error": ...}` sentinels for
  capability NAKs, timeouts, and host death. Typed wrappers exist for the
  full `host.*` surface (`fetch`, `open_url` (`Ok` names the app the URL
  went to, when the host can tell; `Err` carries the host's error),
  `open_url_if_handled` (the same, but a URL no application is registered
  for opens nothing and is an `Err`: try an app's own link before the web
  one), `open_app`, `activate`,
  `normal_mode_target` (pid, bundle id and the focused window's id),
  `wifi_ssid(request_authorization)`, `post_keys`,
  `ax_snapshot`/`ax_perform`/`ax_set`/`ax_select_child`, `ping`).
  `post_keys` and `ax_snapshot` take their params as the protocol spells
  them, and so does a bare `call_host`: the host refuses a key the method
  does not define (`invalid host.post_keys params`). A snapshot walks an
  app's windows (`{"pid": …}`) or, with `"root":
  ax_snapshot_roots::MENU_BAR` and no `pid`, the menu bar of the app that
  owns it, whose `pid` the result then carries beside `nodes` (the `menus`
  plugin, `Plugins/menus/src/bar.rs`). `ax_perform`
  answers whether the action ran; call `call_host("host.ax_perform", …)`
  to read why it did not (`stale ax handle`).
  `wifi_ssid(false)` is a passive authorized-only read; pass `true` only from
  an explicit user action. A newly started permission prompt replies `None`
  immediately, so retry after the user grants access.
  The `audio_devices` capability has its own typed calls, each a `Result`
  whose `Err` is the host's error: `audio_devices(AudioDirection::Output)`
  lists `AudioDevice { uid, name, is_default }`, `select_audio_device(direction,
  uid)` changes the default, `step_output_volume(ticks)` moves the output
  that many volume-key ticks (clamped to `MAX_VOLUME_TICKS` either way) and
  answers the percent, `toggle_output_mute()` answers whether it is muted,
  and `output_volume()` reads `OutputVolume { percent, muted }`.
  The `system_actions` capability has `system_action(SystemAction::Sleep)`:
  the host asks macOS for the action and the call answers
  `Ok(SystemActionOutcome::Done)`, `Ok(Pending)` when macOS has not
  answered within eight seconds and the host is still at it (a full Trash,
  an Automation prompt left open), or `Err` with the host's reason. A
  destructive action (`SystemAction::is_destructive`: restart, shut down,
  log out, empty the Trash) is honoured only inside a perform the user
  confirmed, once: call it from the `on_command` or `on_resolve` of a
  command or row that declares `confirm`. Anywhere else it fails with
  `CONFIRMATION_REQUIRED_ERROR`.
  The `process_signal` capability has `signal_process(pid,
  ProcessSignal::Term)`: the host sends SIGTERM to that process and the call
  answers `Ok(())`, or `Err` with the kernel's reason (`No such process`,
  `Operation not permitted`) or the host's refusal. Every signal needs a
  perform the user confirmed, once, like a destructive system action, and
  the host never signals itself, launchd or a process group.
  The `calendar_events` capability reads the user's calendar through the
  host, which keeps EventKit and the Calendars grant: `calendar_access()`
  answers `GrantAccess::Granted`, `Denied` or `Undetermined` without
  asking; `request_calendar_access(timeout)` asks macOS first when Flash
  never asked, and the host shows that prompt only while the user is using
  the plugin (a perform or a search in flight, or a surface showing one of
  its segments), answering `USER_REQUEST_REQUIRED_ERROR` anywhere else: call
  it from `on_command`, or when `core:status.observed` first lists a segment.
  `calendar_events(start, end, &calendars)` lists the occurrences of a
  window of whole Unix seconds, at most `MAX_CALENDAR_WINDOW_SECONDS` (14
  days) long, in the calendars titled so (none: every calendar), and never
  asks: it answers `CalendarListing::NoAccess(access)` without the grant,
  else `Events { events, truncated }` in start order. A `CalendarEvent`
  carries its id, title, `start` and `end` in Unix seconds, `all_day`, its
  calendar's title, `declined`, `canceled`, its `url` and `location`, and
  `links`, the link-shaped runs of its notes: the notes themselves never
  reach a plugin. Listen for `host_events::CALENDAR_CHANGED` to read again
  when the database changes or the user answers the prompt.
  The `notes`, `reminders` and `contacts` capabilities read one Apple app
  each through the host, which keeps the app's grant, under the same
  `GrantAccess` and the same asking rule: `app_items_access(app)`,
  `request_app_items_access(app, timeout)` (call it from `on_search` or
  `on_command`), `app_items(app)` and `show_app_item(app, id)`, with `app`
  one of `AppItems::Notes`, `Reminders` or `Contacts`. A listing never asks:
  it answers `AppItemListing::NoAccess(access)` without the grant, else
  `Items { items, truncated }` in the app's own order. An `AppItem` is an
  `id` and a `title` (a note's name, a reminder's title, the name Contacts
  shows a card by), plus a reminder's `list`, `list_index` and `created`:
  nothing else of an item reaches a plugin.
- `ItemCatalog` keeps such a listing as flashlight rows: one per plugin,
  built from an `ItemCatalogSpec` (the app, its bundle id, the source name,
  the row kind and the function that shapes and orders the rows), and handed
  `on_event`, `on_search` (`search`), `on_resolve` (`resolve`) and
  `on_command` (`command`: `open` and `refresh`). It answers a search from
  its last good rows, lists only while the app runs, and relists when the
  app launches, when focus leaves it, when the flashlight opens (the app
  focused, or the listing a minute old) and on `refresh`. An event relists
  what Flash may already read; only a query or `refresh` has the host ask
  macOS. Rows that change after a search answered (a slow listing landing,
  the one that follows the user's answer to macOS's prompt, the app
  quitting) are announced with `source_changed`, so the scope on screen
  redraws; rows a waiting search is about to answer with are not. The
  manifest declares one live `per_scope` source and listens to
  `core:apps.launched`, `core:apps.terminated`, `core:focus.changed` and
  `core:session.opened`: events beside live sources keep no process, so
  nothing runs until the first query or command (`Plugins/notes`).
- Host clock: a plugin never arms a timer or sleeps to schedule work.
  `ctx.interval(period, priority, callback)` registers a cadence with the
  host, which drives every poller in Flash — core watchers included — from one
  clock, and runs the callback when it is due; `ctx.after(delay, priority,
  callback)` registers a one-shot deadline (a debounce, a backoff, an expiry)
  and returns a `Deadline` you can `cancel`; `ctx.wait(delay, priority).await`
  is the awaitable form, for a wait inside one piece of work (a retry
  backoff in a loop, a measurement window, a beat for another app to react),
  and dropping it releases its deadline. Every registration republishes the
  plugin's whole `poll` set. `PollPriority` is how late the host may deliver:
  `High` (25 ms) for a value on screen that the user watches change, `Normal`
  (100 ms) for ordinary sampling, settles and refreshes, `Low` (1 s) for
  remote pulls, retries and backoffs; pick the loosest one nobody would
  notice, since slack is what lets wake-ups coalesce. A period outside the
  protocol bounds (a cadence under 50 ms, anything over a day, a 65th
  registration) is refused with a warning before it reaches the host. The
  `PollHandle` an `interval` returns can `set_period` (a retry backoff, an
  idle backend) or `cancel`; dropping it leaves the cadence running. A
  cancelled handle re-arms with `set_period`, so keep one handle to toggle a
  cadence with observation instead of registering a new one each time: the
  `sysinfo` plugin arms its network traffic sample when `core:status.observed`
  first lists a rate segment such as `network_down_bps`, cancels it when none
  is listed, and
  clears the rates nobody shows. A callback that overruns its period simply misses
  ticks, and no tick arrives while the displays sleep or the session is
  locked (one catch-up tick follows). Tests play the host with
  `Harness::drain_poll_registrations` and `Harness::deliver_poll_tick`.
  Prefer `on_event`: the host exposes an event for every source
  it can observe (`flash_plugin::host_events` names them all; for example
  `NETWORK_CHANGED` for interface, address and route changes and
  `VOLUMES_CHANGED` for mounts), and a cadence is the answer only when nothing
  else can tell you the value changed.
- Telemetry: `log` / `log_fields` ride the wire as `log` notifications
  (content-free); a line logged while serving a request carries that
  request's `trace` id automatically (tasks the handler spawns itself don't); `status(segments)` feeds `#{flash.plugin.<id>.<segment>}`.
  A preview travels inside the segment string as a percent-encoded
  `#[popup=inline:…]` marker, so the visible text and its hover document
  publish atomically. The host rejects an encoded body above 16384 bytes
  (`MAX_INLINE_PREVIEW_ENCODED_BYTES`, the contract's
  `quotas.inline_preview_bytes`); `StatusValue::render` reports that
  as `PreviewTooLarge`, and `status` then logs a content-free warning
  (segment name and encoded size only) and publishes the visible text alone
  rather than losing the segment.
- Deadlines: an `on_hints` / `on_text_grid` / `on_search` handler still
  running a tenth of the request's `deadline_ms` (at most 50 ms) before it is
  dropped, with
  the subprocesses and host calls it awaits, and the request answers
  `deadline exceeded`. Bound inner waits below that budget (for host calls,
  `call_host_timeout`) to answer partially instead.
- Timers: none of your own — `interval`, `after` and `wait` above, all on
  the host clock; plugins may `tokio::spawn` freely.

## Async rules (enforced)

Each plugin uses one current-thread Tokio executor. Events preserve wire order
and each `interval` callback is non-overlapping, but startup and request
callbacks are independent tasks and may overlap; coordinate shared refreshes
explicitly (`RefreshGate::try_run` keeps an interactive request from queueing
behind slow background work). Async I/O and `spawn_blocking` still make
progress without multiplying resident worker threads across every plugin
process. One blocking syscall stalls every in-flight operation. Blocking I/O is banned
outright by each crate's
`clippy.toml` (`std::fs::*`, `std::process::Command`) with no `#[allow]`
escape: use `tokio::fs`, `tokio::process`, and `tokio::time::timeout` to
bound one awaited operation. Scheduling is the host's: `tokio::time::sleep`,
`sleep_until` and `interval` are rejected by the guardrails (`mise run guardrails`)
outside test code, along with any `interval`/`after`/`wait`/`Settle::new`
call that does not name its `PollPriority`. The SDK builds the
runtime in `run()` — never build your own. Do async startup work in
`on_start` (it runs after the initialize reply, so nothing you do there can
slow the handshake); resolve lazily with `tokio::sync::OnceCell` when
needed. A synchronous `evaluate` body over 10 ms is a bug — the host warns
at 40 ms round-trip against the 50 ms deadline.

The runtime owns finite admission queues, pinned in `protocol.json`:

- Input collects at most 10 MiB before a newline. Oversized records are
  discarded through the next newline; EOF discards partial JSON and shuts down.
- At most 16 request handlers retain at most 32 MiB of encoded input between
  them. Excess requests receive `plugin request capacity exceeded`; ping and
  host-RPC response intake continue. Cancellation releases pending host calls;
  at most 64 host calls may await a response.
- Output holds at most 64 frames and 16 MiB, including the frame currently
  being written. Async responses wait for capacity before allocating their
  encoded buffer. Synchronous notifications may be dropped with a content-free
  diagnostic. Reader-owned control replies never wait for stdout: if their
  queue is exhausted the transport closes so the host can recover.
- Ordinary events have a 256-frame/16-MiB backlog. Under overload, each of
  `apps.changed`, `focus.changed`, `window.focus.changed`, `ax.changed`,
  `config.changed`, `power.changed`, `network.changed`,
  `volumes.changed`, and `status.observed` (all prefixed
  `core:`; `protocol.json` `host_events.replacement`) retains one latest
  replacement slot per coalescing key — the event name, plus the app and
  notification for `ax.changed` — each bounded by the frame cap, at most 256
  keys at once. Intermediate replacements can coalesce; the final value,
  including an empty app list or an empty observed set, reaches the
  serialized event handler. This avoids blocking the stdin reader while a
  handler awaits a host RPC.

EOF cancels request/event workers and gives shutdown callbacks plus output
draining one shared 750-ms deadline. Handlers must still avoid blocking the
executor. Wire PIDs are positive signed 32-bit integers; booleans and floating
JSON numbers never stand in for integer identifiers. Perform failures emit
only their failure outcome, even when success-only builder methods were chained.
Optional wire fields accept null as absent. Hint targets require a nonempty
`id`, the canonical nested frame, finite frame edges, and declared fields only.
Perform navigation URLs must be absolute; invalid builder values become errors.

## Testing

`flash_plugin::testing::Harness` drives handlers with no host process, no
binaries, and no framing:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;

    #[tokio::test]
    async fn refresh_publishes_the_catalog() {
        let harness = Harness::new("shortcuts");
        let ctx = harness.context();
        assert!(refresh_candidates(&ctx).await);
        assert!(!harness.drain_published_rows().is_empty());
    }
}
```

`Harness::with_config` injects a `[plugins.<id>]` settings object; `drain()`
returns every emitted frame decoded to JSON (publishes, status, logs);
`drain_published_rows()` shortcuts to the last catalog; `drain_status()`
returns each status notification's rendered segment map in order;
`set_running_applications` seeds the app snapshot. Script the host side of
an RPC with `next_host_request()`, which yields `(id, method, params)` of the
plugin's next `host.*` call, and `reply_host(id, result)`, which wakes the
awaiting handler with that result — spawn the handler as a task first so the
test can answer while it waits. Add tokio to `[dev-dependencies]` for async
tests.

`flash_plugin::testing::WireHarness` runs the real serve loop over in-memory
NDJSON streams, so a test speaks to the plugin exactly as the host does:
`WireHarness::new(plugin)` (or `with_config`), `send(json!({…}))`, `recv()`
for the next frame, `recv_response(id)` / `recv_notification(method)` to skip
past unrelated frames, `close_stdin()` for the EOF shutdown signal, and
`finished()` to await the loop and collect what it still wrote (shutdown logs
included). Use `Harness` for plugin behaviour and `WireHarness` only where
framing, request routing or shutdown ordering is what the test is about: the
SDK's own runtime tests and the probe crate (`Plugins/_flash_plugin_rust/probe`)
hold the protocol conformance suite, so a plugin crate rarely needs one.

The SDK and the host XCTest suites consume the shared malformed and boundary
corpus at `Plugins/_flash_plugin_rust/fixtures/wire-values.fixture` and the
whole-frame corpus in `Plugins/_flash_plugin_rust/conformance/`
([how both ends read it](plugin-protocol.md#conformance-workflow));
`Plugins/_flash_plugin_rust/protocol.json` pins the constants both assert
against.

If a plugin will not load, run `:doctor`. It checks manifest loading,
runtime state, executable resolution, and whether the generated Seatbelt
profile compiles. Use `:plugins reload` after correcting the problem or to
restart a process parked by its restart budget.

## Iteration loop

```bash
mise run build:plugins -- <id>   # build + sign + stage just this plugin
```

The staged `mv -f` lands as a rename in the plugin root; the host watches only
that root directory (`manifest.json` and the binary live there — source edits
under `src/` change nothing the host loads) and restarts only that plugin
(~300 ms debounce) while the other plugins keep their published catalogs. If
watching is disabled, run `:plugins reload`.
`mise run test:plugin <id>` needs no built binaries at all. mise points
`CARGO_TARGET_DIR` at `build/plugin-target` for every task, so no
`Plugins/<id>/target/` tree appears in the checkout; set it yourself for a
cargo run outside mise. Debug any plugin by running its binary in a
terminal and typing NDJSON at it — no host required.
