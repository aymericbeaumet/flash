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
or `fail(msg)` ("mine, but it broke" — the host must not fall back).

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
- Subprocess: `run_command(&ctx, argv, timeout)` and `run_osascript` —
  bounded capture (4 MiB stdout / 256 KiB stderr caps, process-group kill on
  timeout), cwd = data dir, scrubbed env with the plugin `bin/` on PATH.
  `.into_perform()` turns a capture into a `PerformResponse`.
- Managed subprocess: `spawn_managed(&ctx, argv)` returns a `ManagedChild`
  for long-lived helpers such as `/usr/bin/caffeinate`. It uses the same
  scrubbed environment/directories, null stdio, and a dedicated process
  group. Own it in explicit plugin state and call `terminate(grace).await`
  during replacement and `on_shutdown`; kill-on-drop is only a backstop.
- Host RPC: `call_host(method, params)` / `call_host_timeout` never error —
  the result object carries `{"ok": false, "error": ...}` sentinels for
  capability NAKs, timeouts, and host death. Typed wrappers exist for the
  full `host.*` surface (`fetch`, `open_url`, `open_app`, `activate_app`,
  `normal_mode_target`, `clipboard_write`, `notify`, `storage_get`/`set`,
  `post_media_key`, `process_table` / `process_metrics`, `signal`, `post_keys`,
  `post_global_key`, `ax_snapshot`/`ax_perform`/`ax_set`/`ax_select_child`,
  `ping`).
- Telemetry: `log` / `log_fields` ride the wire as `log` notifications
  (content-free); `status(segments)` feeds `#{plugin:<id>.<segment>}`.
- Timers: `interval(period, cb)` — non-overlapping ticks; plugins may also
  `tokio::spawn` freely.

## Async rules (enforced)

Each plugin uses one current-thread Tokio executor because callbacks are
serialized by contract; async I/O and `spawn_blocking` still make progress
without multiplying resident worker threads across every plugin process. One
blocking syscall stalls every in-flight operation. Blocking I/O is banned
outright by each crate's
`clippy.toml` (`std::fs::*`, `std::process::Command`) with no `#[allow]`
escape: use `tokio::fs`, `tokio::process`, `tokio::time`. The SDK builds the
runtime in `run()` — never build your own. Do async startup work in
`on_start` (it runs after the initialize reply, so nothing you do there can
slow the handshake); resolve lazily with `tokio::sync::OnceCell` when
needed. A synchronous `evaluate` body over 10 ms is a bug — the host warns
at 40 ms round-trip against the 50 ms deadline.

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
`drain_published_rows()` shortcuts to the last catalog;
`set_running_applications` seeds the app snapshot. Add tokio to
`[dev-dependencies]` for async tests.

## Iteration loop

```bash
./Scripts/build-plugins.sh dev <id>   # build + sign + stage just this plugin
```

The staged `mv -f` lands as a rename; the host's file watcher restarts only
that plugin (~300 ms debounce) while the other plugins keep their published
catalogs. If watching is disabled, run `:plugins reload`.
`CARGO_TARGET_DIR=build/plugin-target cargo test --manifest-path
Plugins/<id>/Cargo.toml` needs no built binaries at all (always set
`CARGO_TARGET_DIR` for manual cargo runs — a bare run creates a watched
`Plugins/<id>/target/`). Debug any plugin by running its binary in a
terminal and typing NDJSON at it — no host required.
