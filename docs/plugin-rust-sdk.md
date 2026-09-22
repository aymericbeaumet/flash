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
`Scripts/new-plugin.sh <id> "<Name>" "<description>"` — it generates the
manifest, a hermetic standalone crate (path dep on the SDK, per-crate build
profiles, the canonical `clippy.toml` copy, a committed `Cargo.lock`), and a
working `:<id> ping` command, requiring zero manual edits to reach green.

## Authoring shape

```rust
use flash_plugin::{run, CommandRequest, Context, PerformResponse};

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
manifest: warm `sources` ⇒ `on_start` (runs AFTER the immediate initialize
reply; build the catalog and `ctx.publish(...)` when ready), `live: true`
sources ⇒ `on_search`, `query` ⇒ a synchronous `evaluate`, `commands` /
`bangs` / keystroke-less `verbs` ⇒ `on_command`, `actions` ⇒ `on_action`,
`navigation` ⇒ `on_navigate`, `hints` ⇒ `on_hints`. Optional: `on_event`,
`on_resolve`, `on_shutdown` (runs on stdin EOF before exit). Forgetting a
required handler is a compile error, not a runtime surprise. On the wire,
resolve/command/action/navigate all arrive as the single `perform` method —
the SDK routes kinds to your handlers, and every one of them answers with the
`PerformResponse` trichotomy: `ok()` (+ `.target_pid()` / `.navigation_url()`
/ `.message()`), `unhandled()` ("not my context" — the host may fall back),
or `fail(msg)` ("mine, but it broke" — the host must not fall back). Tests read
a built response back with `is_ok()` / `is_unhandled()` / `error_message()` /
`toast_message()`.

## Context

Handed to every handler; cheap to clone. Key surface:

- Catalog: `publish(candidates)` pushes the complete replacement row set to
  the host-owned store (rows carry a first-class `source` naming a manifest
  `sources[].name`). Publish an authoritative empty `Vec` when the source is
  truly empty; on transient failure simply don't publish — the host keeps
  the last-good catalog, across restarts.
- Dirs: `data_dir`, `home_dir()`, `config_dir()`, `cache_dir()`,
  `share_dir()`, `bin_dir()` — all under the plugin's sandboxed data dir.
  `FLASH_PLUGIN_DATA_DIR` is required; there is no cwd fallback.
- Settings: `config_str(key)` / `config_json(key)` read the user's
  `[plugin.<id>]` table.
- Events: `running_applications()` is the host-maintained app snapshot (fed
  by `core:apps.changed`, delivered right after initialize). `RefreshGate`
  serializes refresh producers against it.
- Status values: `status(segments)` takes anything `Into<StatusSegment>` —
  a plain string is ready-made markup, build `StatusValue::text(visible)`
  and attach a hover document with `.with_preview(Preview)`, or publish a
  host-rotated `StatusCarousel::new(lines, cycle).with_prefix(label)` whose
  lines each carry their own preview (the feed plugin). `Markup::text`
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
- Subprocess: `run_command(&ctx, argv, timeout)` and `run_osascript` —
  bounded capture (4 MiB stdout / 256 KiB stderr caps, process-group kill on
  timeout), cwd = data dir, scrubbed env with the plugin `bin/` on PATH.
  Use `run_command_with_slow_threshold` only when the command deliberately
  waits while sampling; it preserves timeout warnings while moving that call's
  default one-second slow warning. `.into_perform()` turns a capture into a
  `PerformResponse`.
- Managed subprocess: `spawn_managed(&ctx, argv)` returns a `ManagedChild`
  for long-lived helpers such as `/usr/bin/caffeinate`. It uses the same
  scrubbed environment/directories, null stdio, and a dedicated process
  group. Own it in explicit plugin state and call `terminate(grace).await`
  during replacement and `on_shutdown`; kill-on-drop is only a backstop.
- Host RPC: `call_host(method, params)` / `call_host_timeout` never error —
  the result object carries `{"ok": false, "error": ...}` sentinels for
  capability NAKs, timeouts, and host death. Typed wrappers exist for the
  full `host.*` surface (`fetch`, `open_url`, `open_app`, `activate_app`,
  `normal_mode_target` (pid, bundle id and the focused window's id),
  `wifi_ssid(request_authorization)`, `clipboard_write`, `notify`,
  `storage_get`/`set`, `post_media_key`, `process_table` / `process_metrics`,
  `signal`, `post_keys`,
  `post_global_key`, `ax_snapshot`/`ax_perform`/`ax_set`/`ax_select_child`,
  `ping`).
  `wifi_ssid(false)` is a passive authorized-only read; pass `true` only from
  an explicit user action. A newly started permission prompt replies `None`
  immediately, so retry after the user grants access.
- Cadences: `ctx.interval(period, callback)` does **not** start a timer in the
  plugin. It registers `period` with the host, which drives every poller in
  Flash — core watchers included — from one clock, and ticks the callback when
  the registration is due. The returned `PollHandle` can `set_period` (a retry
  backoff, an idle backend) or `cancel`; dropping it leaves the cadence
  running. A callback that overruns its period simply misses ticks. Prefer
  `on_event`: the host exposes an event for every source it can observe, and a
  cadence is the answer only when nothing else can tell you the value changed.
- Telemetry: `log` / `log_fields` ride the wire as `log` notifications
  (content-free); `status(segments)` feeds `#{flash.plugin.<id>.<segment>}`.
  A preview travels inside the segment string as a percent-encoded
  `#[popup=inline:…]` marker, so the visible text and its hover document
  publish atomically. The host rejects an encoded body above 16384 bytes
  (`MAX_INLINE_PREVIEW_ENCODED_BYTES`); `StatusValue::render` reports that
  as `PreviewTooLarge`, and `status` then logs a content-free warning
  (segment name and encoded size only) and publishes the visible text alone
  rather than losing the segment.
- Timers: `interval(period, cb)` — non-overlapping ticks; plugins may also
  `tokio::spawn` freely.

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
escape: use `tokio::fs`, `tokio::process`, `tokio::time`. The SDK builds the
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
  `clipboard.changed`, `config.changed`, `power.changed`, and `space.changed`
  (all prefixed `core:`) retains one latest replacement slot, each bounded by
  the frame cap. Intermediate replacements can coalesce; the final value,
  including an empty app list, reaches the serialized event handler. This
  avoids blocking the stdin reader while a handler awaits a host RPC.

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
        let harness = Harness::new("processes");
        let ctx = harness.context();
        assert!(refresh_candidates(&ctx).await);
        assert!(!harness.drain_published_rows().is_empty());
    }
}
```

`Harness::with_config` injects a `[plugin.<id>]` settings object; `drain()`
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
corpus at `Plugins/_flash_plugin_rust/fixtures/wire-values.fixture`;
`Plugins/_flash_plugin_rust/protocol.json` pins the constants both assert
against.

If a plugin will not load, run `:plugins doctor`. It checks manifest loading,
runtime state, executable resolution, and whether the generated Seatbelt
profile compiles. Use `:plugins reload` after correcting the problem or to
restart a process parked by its restart budget.

## Iteration loop

```bash
./Scripts/build-plugins.sh dev <id>   # build + sign + stage just this plugin
```

The staged `mv -f` lands as a rename in the plugin root; the host watches only
that root directory (`manifest.json` and the binary live there — source edits
under `src/` change nothing the host loads) and restarts only that plugin
(~300 ms debounce) while the other plugins keep their published catalogs. If
watching is disabled, run `:plugins reload`.
`CARGO_TARGET_DIR=build/plugin-target cargo test --manifest-path
Plugins/<id>/Cargo.toml` needs no built binaries at all (always set
`CARGO_TARGET_DIR` for manual cargo runs so no `Plugins/<id>/target/` tree
appears in the checkout). Debug any plugin by running its binary in a
terminal and typing NDJSON at it — no host required.
