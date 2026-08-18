# Plugin cookbook

Graded, real exemplars — read them in order. Each one is bundled, small, and
idiomatic; copy its shape.

## 1. Command wrapper — `Plugins/spotify` (~50 LOC)

The smallest useful plugin: manifest `commands.items` + one `on_command`
mapping subcommands to a CLI via `run_command`, with per-plugin config/cache
dirs under the sandboxed data dir. No state, no events.

## 2. Warm catalog from embedded data — `Plugins/emojis` (~90 LOC + test)

A `sources` plugin: `include_str!` datasets parsed once in `on_start`,
published with `set_locations` before returning (the readiness gate). Shows
candidate builders (`kind`, `source`, `subtitle`, `payload`, `aliases`) and
the harness-based test that drives `on_start` from `cargo test`.

## 3. Verbs + host RPCs + persistence — `Plugins/marks` (~200 LOC)

Vim-style marks: manifest `verbs`, `host.normal_mode_target` and
`app.activate` host RPCs (the `app_control` capability), JSON state persisted
under `share_dir()`, and `listen` events keeping it fresh.

## 4. Live catalog + source actions + mappings — `Plugins/safari` (~440 LOC)

Browser tabs: polled osascript refreshes fanned out per window, an
aggregate warm catalog under the canonical `plugin:safari` key,
`source_actions` (`tab_select`, `tab_new`, `tab_close`) with the
`performed | failed | unhandled` trichotomy, and a manifest `mappings` entry
scoped by `only_bundle_ids`.

## 5. Query evaluator with background refresh — `Plugins/calculator` (~630 LOC)

The `queries` pattern done right: a synchronous, CPU-only `query_evaluate`
over immutable state; the ECB currency snapshot loads from disk before
readiness and refreshes in the background, atomically replacing state without
ever delaying evaluation; `exclusive_prefixes = ["="]` routing.

## The loop

```bash
./Scripts/new-plugin.sh myplugin "My Plugin" "What it does"   # zero-edit scaffold
./Scripts/build-plugins.sh dev myplugin                        # 2-4s hot build
tail -f ~/Library/Logs/Flash/flash.log                         # watcher restart + plugin logs
cargo test --manifest-path Plugins/Cargo.toml -p flash-plugin-myplugin
```

Contracts you must not break — the full statements live in
`docs/plugin-protocol.md` and AGENTS.md: publish the canonical warm catalog
before `on_start` returns; never block the runtime (clippy enforces it);
never put I/O on `sources.snapshot` or `query_evaluate`; authoritative-empty
clears, transient failure keeps last-good; bound every refresh.
