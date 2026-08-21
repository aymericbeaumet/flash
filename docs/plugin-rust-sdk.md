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
use flash_plugin::{run, CommandRequest, CommandResponse, Context};

struct MyPlugin;

flash_plugin::plugin!(MyPlugin); // reads manifest.json at compile time

impl FlashPlugin for MyPlugin {
    async fn on_command(&self, ctx: Context, command: CommandRequest) -> CommandResponse {
        match command.subcommand.as_str() {
            "ping" => CommandResponse::toast("pong"),
            other => CommandResponse::error(format!("unknown subcommand: {other}")),
        }
    }
}

fn main() {
    run(MyPlugin);
}
```

`plugin!` generates a `FlashPlugin` trait whose *required* methods follow the
manifest: `sources` ⇒ `on_start` (must publish the warm catalog before
returning), `commands`/`shebangs` ⇒ `on_command`, `queries` ⇒ a synchronous
`query_evaluate`. Everything else has default implementations. Forgetting a
required handler is a compile error, not a runtime surprise.

## Context

Handed to every handler; cheap to clone. Key surface:

- Dirs: `data_dir`, `home_dir()`, `config_dir()`, `cache_dir()`,
  `share_dir()`, `bin_dir()` — all under the plugin's sandboxed data dir.
- Settings: `config_str(key)` / `config_json(key)` read the user's
  `[plugin.<id>]` table.
- Warm catalog: `set_locations("plugin:<id>", candidates)` swaps the complete
  in-memory snapshot the SDK serves for `sources.snapshot` — plugin code can
  never put I/O on that path. Publish an authoritative empty `Vec` when the
  source is truly empty; on transient failure keep the last-good snapshot
  instead. `warm_locations()` / `has_locations()` read it back.
- Events: `running_applications()` is the host-maintained app snapshot,
  atomically replaced before each `core:apps.changed` delivery. `RefreshGate`
  serializes refresh producers against it.
- Subprocess: `run_command(&ctx, argv, timeout)` and `run_osascript` —
  bounded capture (4 MiB stdout / 256 KiB stderr caps, process-group kill on
  timeout), cwd = data dir, scrubbed env with the plugin `bin/` on PATH.
  For invocation shapes those can't express, `flash_plugin::process::capture`
  is the underlying public layer with configurable limits and env.
- Host RPC: `normal_mode_target()` and `call_host(method, params)` for the
  capability-gated host surface (see `docs/plugin-protocol.md`).
- Telemetry: `log` / `log_fields` route through the wire as `flash.log`;
  `emit_status_segments` feeds `#{plugin:<id>.<segment>}`.
- Timers: `interval(period, cb)` — non-overlapping ticks; plugins may also
  `tokio::spawn` freely.

## Async rules (enforced)

Plugins share a small 2-worker tokio runtime; one blocking syscall stalls
every in-flight operation. Blocking I/O is banned outright by
`Plugins/clippy.toml` (`std::fs::*`, `std::process::Command`) with no
`#[allow]` escape: use `tokio::fs`, `tokio::process`, `tokio::time`. The SDK
builds the runtime in `run()` — never build your own. Do async startup work in
`on_start`; resolve lazily with `tokio::sync::OnceCell` when needed.

The SDK owns the bounds: event queue capacity 256 (wire order, 15 s handler
watchdog), control lane 64 (backpressured, prioritized), telemetry lane 128
(droppable, 256 KiB frames), 10 MiB wire frames, and the catalog/query quota
validation described in the protocol doc. A `query_evaluate` body over 10 ms
logs a slow-evaluator warning — treat that as a bug.

## Testing

`flash_plugin::testing::Harness` drives handlers with no host process, no
binaries, and no framing:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::testing::Harness;

    #[tokio::test]
    async fn refresh_populates_the_warm_store() {
        let harness = Harness::new("processes");
        let ctx = harness.context();
        assert!(refresh_candidates(&ctx).await);
        assert!(ctx.has_locations(SOURCE_ID));
    }
}
```

`Harness::with_config` injects a `[plugin.<id>]` settings object;
`drain_control()` / `drain_telemetry()` return the emitted JSON frames
decoded to JSON values; `set_running_applications` seeds the app snapshot.
Add tokio to `[dev-dependencies]` for async tests.

## Iteration loop

```bash
./Scripts/build-plugins.sh dev <id>   # build + sign + stage just this plugin
```

The staged `mv -f` lands as a rename; the host's file watcher restarts only
that plugin (~300 ms debounce) while the other plugins keep their warm
catalogs. If watching is disabled, run `:plugins reload`.
`CARGO_TARGET_DIR=build/plugin-target cargo test --manifest-path
Plugins/<id>/Cargo.toml` needs no built binaries at all (always set
`CARGO_TARGET_DIR` for manual cargo runs — a bare run creates a watched
`Plugins/<id>/target/`).
