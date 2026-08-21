# Conformance probes — seven languages, one behavior

One deliberately boring plugin, implemented once per SDK
(`probes/{rust,python,ruby,typescript,go,zig,swift}/`), that exercises the
ENTIRE wire protocol deterministically. The bundled plugins each touch a
slice of the contract; the probes exist so the spec suite
(`python3 Scripts/plugin-protocol-spec.py --probes`) can drive every path in
every language and keep the 7-SDK parity scoreboard honest. Probes are test
fixtures: they never ship, never run under the host, and are invisible to
`Scripts/build-plugins.sh` and the CI cargo loop by construction (those glob
`Plugins/*/manifest.json` one level deep). `Scripts/build-probes.sh` builds
the four compiled probes; the interpreted three run in place.

This file is the NORMATIVE behavior contract all seven implementations
follow, byte-equivalent on the wire (modulo JSON key order and equivalent
escaping — specs assert with parsed-value matchers and `$contains`, never
whole-string equality). The specs under `../probe/**` run ONLY against the
probes; the shared specs run against probes and bundled plugins alike.

## Manifest

Identical `manifest.json` in every probe directory except `exec`:
id `conformance`, version `0.1.0`, warm source `conformance.items`, a `query`
evaluator, the catch-all command `conformance *`, actions
`conf_performed`/`conf_unhandled`/`conf_failed`, `hints`, navigation scheme
`conformance`, status segment `state`, `listen ["core:*"]`, `sandbox {}`, and
every host-RPC capability (`accessibility`, `app_control`, `clipboard`,
`media_keys`, `network_fetch` + the mandatory `fetch_urls` allowlist,
`notify`, `open`, `process_control`). The production decoder
(`PluginManifest.swift`) requires `network_fetch` and `fetch_urls` to be
declared together; `actions` need no `sources` coupling. Verify a manifest
edit loads with
`.build/debug/flash _plugin-sandbox-profile --root <probe dir> --data-dir $(mktemp -d)`.

## Fixed data

- `SOURCE` = `conformance.items`, `TARGET_PID` = `4242`.
- The base catalog, exactly three rows, in this order:
  1. `{"source": SOURCE, "title": "alpha", "metadata": {"k": "v1"}}`
  2. `{"source": SOURCE, "title": "béta ⚡ 名前"}`
  3. `{"source": SOURCE, "title": "gamma", "url": "https://example.com/g",
     "effect": {"type": "open", "url": "https://example.com/g"}}`
- The extra row appended by `publish-extra`: `{"source": SOURCE, "title": "delta"}`.

## Config switches

Read from the `"conformance"` key of the parsed `FLASH_PLUGIN_CONFIG` object
(all optional; the catalog below is what `on_start` publishes and what
`search`/`publish-extra` derive from):

- `{"empty_catalog": true}` — the catalog is `[]` (authoritative empty).
- `{"catalog_rows": N}` — the catalog is N generated rows titled `row-<i>`
  (i = 1..N).
- `{"row_pad": B}` — each generated title gets B bytes of `"x"` appended
  (used with `catalog_rows` to build a publish whose frame exceeds the
  10 MiB cap; the SDK must DROP the oversized notification and keep serving).
- `{"skip_publish": true}` — `on_start` publishes nothing.
- `{"init_fail": "msg"}` — NOT IMPLEMENTED. No SDK exposes an initialize
  override (the handshake lives inside every runtime by design), so a probe
  cannot script an `ok:false` initialize. Documented limitation; the
  version-mismatch terminal path is covered by the shared
  `lifecycle/protocol-mismatch` spec instead.

## Handlers

- **on_start** — publish the config-derived catalog (nothing when
  `skip_publish`). No other startup output: probes stay quiet so
  `expect_none` windows are meaningful.
- **on_evaluate** — exact-match on `query`:
  - `"conf:one"` → `[{"title": "one", "subtitle": "s",
    "effect": {"type": "copy_text", "text": "one"}}]`
  - `"conf:unicode"` → `[{"title": "héllo ⚡ 世界",
    "effect": {"type": "copy_text", "text": "héllo ⚡ 世界"}}]` (no subtitle)
  - `"conf:many"` → 17 answers titled `a1`..`a17`, each with a `copy_text`
    effect of its title (a bounds probe: the SDK transmits faithfully;
    host-side rejection of >16 answers is Swift-tested)
  - anything else → `[]`
- **on_search** — the config-derived catalog rows whose title contains the
  query (`"alpha"` → 1 row, `"zzz"` → 0).
- **on_hints** — exactly two targets, using the canonical `frame` OBJECT
  form (the host decoder `PluginWireCodec.target(from:)` also accepts flat
  `x`/`y`/`width`/`height` at the top level, but `frame {x,y,width,height}`
  is what every SDK emits and what the probes pin):
  1. `{"id": "t1", "frame": {"x": -10.5, "y": 20, "width": 30, "height": 40},
     "role": "AXLink", "label": "one"}`
  2. `{"id": "t2", "frame": {"x": 0, "y": 0, "width": 10, "height": 10},
     "role": "FlashTerminalLink", "label": "two"}`
- **on_resolve** — row title `"alpha"` → ok + `target_pid` 4242; anything
  else → unhandled.
- **on_action** — `conf_performed` → ok + `target_pid` 4242;
  `conf_unhandled` → unhandled; `conf_failed` →
  `fail("conformance failure probe")`; any other name → unhandled.
- **on_navigate** — url `"conformance://ok"` → ok; anything else → unhandled.
- **on_event** — remember the last event name (read back by `state`).
- **on_shutdown** — emit one `log` notification whose message is
  `"conformance shutdown"` (the EOF-hook proof).

## Command subcommands

`perform {kind: "command"}` routes on `subcommand`. Data-bearing replies put
a COMPACT JSON string in the reply `message` field (the perform envelope is
closed; specs assert with `$contains`). "J(x)" below = minified JSON with
non-ASCII kept raw where the probe controls the encoder (Python passes
`ensure_ascii=False`); languages may escape `/` (Swift) or `<`/`>`/`&` (Go),
so specs never `$contains` those characters inside `message`.

| subcommand | behavior |
| --- | --- |
| `echo <args…>` | ok, message = `J({"args": args, "raw": raw})` |
| `env` | ok, message = `J(full child environment map)` |
| `env-has <NAME>` | ok, message = `"present"` if NAME is set (even empty) else `"absent"` |
| `config` | ok, message = `J(parsed FLASH_PLUGIN_CONFIG object)` |
| `state` | ok, message = last event name (`""` before any event) |
| `target-pid` | ok + `target_pid` 4242 |
| `toast` | ok, message = `"hello from conformance"` |
| `sleep <ms>` | block/await that long, then ok |
| `crash <code>` | `exit(code)` immediately, NO reply |
| `exit-after-reply <code>` | reply ok now, `exit(code)` ~250 ms later |
| `stderr <kib>` | write kib KiB of `"x"` to stderr, then ok |
| `log <level> <msg…>` | emit `log` (level, msg words joined by `" "`), then ok |
| `status <seg> <val>` | emit `status {seg: val}`, then ok |
| `publish-extra` | publish(catalog + delta row), then ok |
| _unknown_ | `fail("unsupported subcommand: <s>")` |

One subcommand per host RPC; each calls `call_host` with the fixed canonical
params below and replies ok with message = `J(verbatim host result)` —
`call_host` never throws, so capability NAKs, the runner's default
`"not available in spec runner"` NAK, `"host call timed out"` (5 s default),
and `"host closed stdin"` all surface verbatim through `message`:

| subcommand | RPC | params |
| --- | --- | --- |
| `ping` | `host.ping` | `{}` |
| `fetch <url>` | `host.fetch` | `{"url": <url>}` |
| `open <url>` | `host.open` | `{"url": <url>}` |
| `clipboard <text>` | `host.clipboard_write` | `{"text": <text>}` |
| `notify <msg>` | `host.notify` | `{"message": <msg>}` |
| `storage-set <k> <v>` | `host.storage_set` | `{"key": <k>, "value": <v>}` |
| `storage-get <k>` | `host.storage_get` | `{"key": <k>}` |
| `media [code]` | `host.post_media_key` | `{"key_code": int(code) or 16}` |
| `ps` | `host.process_table` | `{}` |
| `signal [pid]` | `host.signal` | `{"pid": int(pid) or 4242}` |
| `keys` | `host.post_keys` | `{"pid": 4242, "keys": [{"key_code": 4, "modifiers": ["command"]}]}` |
| `global-key` | `host.post_global_key` | `{"key_code": 4, "modifiers": ["command"]}` |
| `ax-snapshot` | `host.ax_snapshot` | `{"pid": 4242, "roots": "app"}` |
| `activate` | `host.activate` | `{"pid": 4242}` (production shape; any arg is ignored) |
| `normal-mode-target` | `host.normal_mode_target` | `{}` |

Missing/unparsable numeric args fall back to the documented defaults;
missing string args fall back to `""`.

## Implementation notes

- Single file per language, hooks in SDK-idiomatic form
  (`docs/plugin-sdks.md` naming map); no I/O beyond the contract above.
- Rust is a hermetic crate (path dep `../../../_flash_plugin_rust`, the
  standard per-crate `plugin-dev`/`release` profiles, committed `Cargo.lock`,
  the canonical `clippy.toml` copy). Go pins the SDK with a `go.mod`
  `replace`; Zig links `-Mflashplugin`; Swift compiles alongside
  `flashplugin.swift`; Python/Ruby/TS import the SDK by bare name via the
  runner-injected `PYTHONPATH`/`RUBYLIB`/`NODE_PATH`.
- `state` is only asserted after a `sleep_ms` settle step in specs: SDKs may
  deliver events on a different thread/queue than perform.
