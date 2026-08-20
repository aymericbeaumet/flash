# Plugin cookbook

Graded, real exemplars — read them in order. Each one is bundled, small, and
idiomatic; copy its shape. Rust is the default for new plugins; the polyglot
section exists to keep the wire protocol honestly language-agnostic.

## Rust (the default path)

1. **Command wrapper — `Plugins/slack` (~40 LOC).** The smallest useful
   plugin: manifest `commands.items` + one `on_command` mapping subcommands
   to a CLI via `run_command`.
2. **Verbs + host RPCs + persistence — `Plugins/marks` (~200 LOC).**
   Vim-style marks: manifest `verbs`, `host.normal_mode_target` and
   `app.activate` host RPCs (the `app_control` capability), JSON state
   persisted under `share_dir()`, and `listen` events keeping it fresh.
3. **Warm catalog via native APIs — `Plugins/processes` (~300 LOC).** A
   `sources` plugin publishing with `set_locations` before `on_start`
   returns (the readiness gate), refreshed by events + a poll, backed by
   the SDK's libproc sampler — plus the golden-output test pattern.
4. **Live catalog + source actions + mappings — `Plugins/safari`
   (~440 LOC).** Browser tabs: polled osascript refreshes fanned out per
   window, `source_actions` with the `performed | failed | unhandled`
   trichotomy, and a manifest `mappings` entry scoped by
   `only_bundle_ids`.
5. **Query evaluator with background refresh — `Plugins/calculator`
   (~630 LOC).** A synchronous, CPU-only `query_evaluate` over immutable
   state; the ECB snapshot loads from disk before readiness and refreshes
   in the background through `host.fetch` (the `network_fetch` capability),
   atomically replacing state; `exclusive_prefixes = ["="]` routing.

## Polyglot (the protocol is the boundary)

Twelve official plugins are deliberately non-Rust — two per language, so
each language's shared SDK (`Plugins/_<language>_flash_plugin/`, a single
`flashplugin.*` with JSON-lines framing + v1 lifecycle and no Flash
business concepts) has real consumers:

- **Python** (mise-pinned `python3`): `Plugins/aiproviders` — `!chatgpt`-
  style bangs, `command.invoke`, subprocess (`open`, osascript);
  `Plugins/timezones` — a pure `query.evaluate` evaluator over a
  startup-warmed zone index.
- **Ruby**: `Plugins/screenshot` — osascript keystroke commands;
  `Plugins/caffeinate` — a managed `/usr/bin/caffeinate` child plus a
  `status.updated` segment.
- **TypeScript/Bun**: `Plugins/emojis` — the warm-catalog contract in an
  interpreted language (dataset files read at startup, published before
  initialize succeeds, served from memory on `sources.snapshot`);
  `Plugins/colors` — a pure hex/rgb/hsl query evaluator.
- **Go**: `Plugins/spotify` — compiled command wrapper, built by
  `build-plugins.sh` alongside the Rust crates; `Plugins/netinfo` — a
  polled warm catalog of interface addresses with
  `sources.invalidated` on change.
- **Zig**: `Plugins/searchengines` — compiled warm catalog; `@embedFile`
  replaces the old build.rs codegen for the vendored bangs.tsv;
  `Plugins/httpstatus` — the same embedded-data shape with openable MDN
  URLs.
- **Swift**: `Plugins/reminders` — the full surface in one port — warm
  catalog from an AppleScript listing, `candidate.resolve`, commands, and
  lifecycle events; heartbeat/snapshot answer on the read thread while
  handlers run on a worker queue; `Plugins/shortcuts` — the same shape
  against the faceless "Shortcuts Events" service.

`Scripts/plugin-protocol-spec.py` drives any plugin binary/runtime through
the language-agnostic JSON specs in `Plugins/_specs/` (lifecycle +
wire-noise robustness always; snapshot/query gated on the manifest) with a
PASS/FAIL exit code — the conformance suite for every SDK, Rust included,
and CI runs it across all of them.

## The loop

```bash
./Scripts/new-plugin.sh myplugin "My Plugin" "What it does"   # Rust scaffold, zero-edit green
./Scripts/build-plugins.sh dev myplugin                        # per-id hot build (any compiled language)
tail -f ~/Library/Logs/Flash/flash.log                         # watcher restart + plugin logs
cargo test --manifest-path Plugins/Cargo.toml -p flash-plugin-myplugin
```

Contracts you must not break — the full statements live in
`docs/plugin-protocol.md` and AGENTS.md: publish the canonical warm catalog
before initialize succeeds; never block the runtime; never put I/O on
`sources.snapshot` or `query_evaluate`; authoritative-empty clears,
transient failure keeps last-good; bound every refresh.
