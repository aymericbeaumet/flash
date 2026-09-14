# Plugin cookbook

Graded, real Rust exemplars — read them in order. Each one is bundled, small,
and idiomatic; copy its shape. The stdio protocol remains language-neutral,
but Rust is the sole maintained SDK and implementation language for official
plugins.

## Rust (the default path)

1. **Command wrapper — `Plugins/spotify` (~85 LOC + unit tests).** The
   smallest useful plugin: manifest `commands` + one `on_command` hook mapping
   subcommands to a CLI via `run_command`, with the argv plan kept pure and
   unit-tested. Command-only plugins are on-demand: the host spawns them at
   first use, not at startup.
2. **Verbs + host RPCs + persistence — `Plugins/marks` (~200 LOC).**
   Vim-style marks: manifest `verbs`, `host.normal_mode_target` and
   `host.activate` host RPCs (the `app_control` capability), JSON state
   persisted under `share_dir()`, and `listen` events keeping it fresh.
3. **Push catalog via native APIs — `Plugins/processes` (~300 LOC).** A
   `sources` plugin building its complete row set and pushing it with
   `publish` from `on_start`, refreshed by events + a poll, backed by the
   SDK's libproc sampler — plus the golden-output test pattern. No readiness
   dance: initialize replies immediately and the catalog lands when ready.
4. **Event-driven catalog + actions + mappings — `Plugins/browsers`
   (~640 LOC).** Browser tabs for Chromium-family browsers and Safari: one
   shared skeleton driven by a per-bundle AppleScript dialect table, polled
   osascript refreshes fanned out per browser that publish on change,
   manifest `actions` handled by `on_action` with the performed / unhandled /
   error trichotomy, and a `mappings` entry scoped by `only_bundle_ids`.
5. **Query evaluator with background refresh — `Plugins/answers`
   (~1270 LOC).** Three synchronous, CPU-only answer engines (calculator,
   colors, timezones) behind one `evaluate` via an ordered engine table;
   the ECB snapshot loads from disk in `on_start` and refreshes in the
   background through `host.fetch` (the `network_fetch` capability),
   atomically replacing state; `query.prefixes = ["="]` routing sends `=`
   input to the calculator engine alone.

Protocol conformance lives in the SDK workspace:
`Plugins/_flash_plugin_rust/protocol.json` pins the wire constants, the
`wire`/`runtime` test suites pin the framing and lifecycle behaviour, and the
`probe` workspace member exercises them end to end over real stdio.
`./Scripts/test-plugins.sh --lane all` is the one-command gate.

## The loop

```bash
./Scripts/new-plugin.sh myplugin "My Plugin" "What it does"   # Rust scaffold, zero-edit green
./Scripts/build-plugins.sh dev myplugin                        # per-id Rust hot build
tail -f ~/Library/Logs/Flash/flash.log                         # watcher restart + plugin logs
CARGO_TARGET_DIR=build/plugin-target cargo test --manifest-path Plugins/myplugin/Cargo.toml
```

Debugging is a first-class feature of the transport: run the plugin binary in
a terminal and type NDJSON at it — `{"id":1,"method":"initialize","params":
{"protocol_version":1}}` — no host required.

Contracts you must not break — the full statements live in
`docs/plugin-protocol.md` and AGENTS.md: publish complete replacement
catalogs, never deltas; on transient failure don't publish (the host keeps
last-good) and publish an authoritative `[]` only when the source is truly
empty; keep `evaluate` synchronous and I/O-free; bound every refresh; reply
to `initialize` immediately — startup work belongs in `on_start`.
