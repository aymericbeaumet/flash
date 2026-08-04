# Plugins

Plugins are Flash-owned child processes. Each plugin has a required
`manifest.json` with `id`, `name`, `version`, `description`, `install`, and
`start` strings. Optional `request_timeout_ms` changes only the generic RPC
deadline (2 seconds by default) for plugins that fan out to slower systems;
startup (15 seconds), `sources.snapshot` (150 ms), and `query.evaluate` (50 ms)
have fixed protocol deadlines. Optional `capabilities`
declares sensitive host surfaces: `"clipboard"` gates
`core:clipboard.changed`; `"accessibility"` gates the host AX broker
(`ax.snapshot`, `ax.perform`, `ax.set`); `"network"` opts out of the default
network-denying runtime sandbox; `"subprocess"` permits privileged helpers that
cannot run inside that sandbox; and `"app_control"` gates only
`host.normal_mode_target` and `app.activate`. Running-app and focus events are
delivered according to `listen` independently of `"app_control"`; it does not
gate observation. Omitted capabilities are default-denied.

Flash loads manifests eagerly. On plugin reload it compiles commands, mappings,
bangs, verbs, source descriptors, actions, schemes, event listeners, and active-window
selectors into indexes. Runtime dispatch should be dictionary lookup plus
selector matching against the current window context, not raw manifest walking.
Keep new protocol or SDK work aligned with that boundary: manifests declare the
static surface; plugins send runtime data over MessagePack only for dynamic
state such as candidates, targets, status values, and command results.

Third-party plugins are listed in `[plugins] third_party` as
`github:user/project@<commit-sha>` or `file:<path>`. GitHub references must pin
a full 40-character commit SHA because `install` and `start` run as the user.

Plugins communicate over length-prefixed MessagePack on stdin/stdout: a 4-byte
big-endian payload length followed by a MessagePack value. stderr is reserved
for unexpected plugin errors. Plugin log messages recorded by Flash use
`source = "plugin:<id>"`.

Runtime children receive the plugin identity/data-directory variables and the
plugin's `[plugin.<id>]` settings as a JSON object in `FLASH_PLUGIN_CONFIG`.
Flash builds a scrubbed environment containing only basic locale/path/process
keys plus its own `FLASH_PLUGIN_*` values; ambient tokens, agent sockets, and
unrelated login-shell secrets are not inherited. Put credentials in the
plugin's config table. Inspector output may show setting keys but redacts their
values.

Official plugins install their CLI tools under `FLASH_PLUGIN_DATA_DIR`, not into
global shell paths. Current bundled commands include `:spotify`, `:slack`,
`:media`, `:system`, and `:clipboard`; authentication is explicit through command
subcommands, never during install or start. The system plugin owns direct
macOS controls such as `:system lock`, `:system restart`, `:system shutdown`,
and `:system logout`, plus the explicit `@system.actions` flashlight source.

## Manifest Shape

```json
{
  "id": "example",
  "name": "Example",
  "version": "0.1.0",
  "description": "Example plugin",
  "install": "true",
  "start": "exec ./flash-plugin-example",
  "listen": ["core:flash.started", "core:apps.*"],
  "only_bundle_ids": ["org.mozilla.firefox"],
  "only_urls": ["https://mail.google.com/*"],
  "sources": [
    { "name": "example.items", "kind": "locations", "priority": "normal" }
  ],
  "queries": {
    "surfaces": ["flashlight"],
    "source": "example.answers",
    "priority": 25,
    "exclusive_prefixes": ["="]
  },
  "source_actions": ["resource_archive"],
  "hints": {},
  "commands": {
    "items": [
      { "command": "example", "subcommand": "run", "description": "Run example" }
    ]
  },
  "mappings": {
    "items": [
      {
        "key": "R",
        "command": ["flash", "send_key", "--keys=cmd+option+r"],
        "only_bundle_ids": ["com.apple.Safari"]
      }
    ]
  },
  "shebangs": {
    "command": "example",
    "items": [
      { "token": "ex", "description": "Search example" },
      { "token": "*" }
    ]
  },
  "navigation": { "schemes": ["example"] },
  "status": { "segments": ["state"] },
  "verbs": {
    "items": [
      { "name": "example_save", "inline_keystrokes": { "": "cmd+s" } }
    ]
  }
}
```

## Selectors

`only_bundle_ids` and `only_urls` are active-window selectors. They may appear at
the manifest root and on command, mapping, shebang, and verb entries. Root and
entry selectors are compounded. A selector matches only when every populated
axis matches; `only_urls` supports `*` wildcards.

Specificity is CSS-like: a scoped entry outranks an unscoped entry at the same
declared priority, and a bundle+URL selector outranks a bundle-only selector.
The host compiles selectors on plugin load. It only reads the focused document
URL at runtime when some loaded selector declares `only_urls`.

The manifest's numeric `priority` defaults to `25`; provider sections such as
`queries` may override that numeric arbitration priority, and mapping selector
specificity is added before collision resolution. Built-in/default mappings sit
at priority `0`. Do not confuse those scheduling/collision numbers with
`sources[].priority`, which is the semantic `low` / `normal` / `high` /
`important` / `urgent` row-salience enum.

## Sections

- **`listen`** — string array of event-name patterns. `*` is the wildcard.
  Event payload filtering belongs to the core capability gate, not per-listener
  manifest objects.
- **`hints`** — opts the plugin in as a hints provider. Hint selection is
  exclusive: the highest-priority provider supporting the focused context owns
  `f` for that context.
- **`sources`** — root array of source descriptors the plugin owns for
  `@<source>` completion, source-scoped flashlight queries, and default source
  ranking. Each item is
  `{ "name": "<source.label>", "kind": "<kind>", "priority": "<salience>" }`.
  `kind` is optional and defaults to `"default"`; supported kinds are
  `"default"` and `"locations"`. `priority` is optional and defaults to
  `"normal"`.
- **`queries`** — registers a pure per-input evaluator. `surfaces` defaults to
  `["flashlight"]`; `source` defaults to the plugin id. Optional literal
  `exclusive_prefixes` route matching input only to that evaluator; they are
  exact markers, never regexes. Without a marker, evaluators are additive. The
  generated `query_evaluate` hook is synchronous and receives no `Context`.
- **`commands`** — `items[]` are command-line `:` registrations. The host
  indexes them by `(command, subcommand)` on load; wildcard subcommand `"*"`
  consumes the remainder as args.
- **`mappings`** — `items[]` are `all`, `normal`, or `insert` key bindings
  (omitted item mode defaults to `normal`). `command` is an argv array using
  the same syntax as config mappings.
- **`shebangs`** — `items[]` are flashlight bangs. `command` folds into entries;
  an entry may override it. `token = "*"` is the catch-all provider.
- **`source_actions`** — root string array of source-owned normal-mode actions
  such as `tab_new`, `app_reload`, or `resource_archive`.
- **`navigation`** — `schemes[]` declares durable route URL schemes the plugin
  can restore through movement history.
- **`status`** — `segments[]` declares status-bar segment names. Runtime values
  arrive via `status.updated` and render as `#{plugin:<id>.<segment>}`.
- **`verbs`** — `items[]` registers CLI/mapping verbs. `inline_keystrokes`
  lets the host handle fixed keystroke verbs without a plugin RPC.

## Runtime Data

Candidates and targets are dynamic and travel over MessagePack. Every candidate
provider owns one canonical, complete catalog snapshot and keeps it warm through
bounded `on_start`, `on_event`, and plugin-owned polling refreshes. A plugin
whose manifest declares `sources` must publish
`set_locations("plugin:<manifest-id>", candidates)` before `on_start` returns,
including an authoritative empty vector when appropriate. The SDK does not
acknowledge initialization before that publication, and the host accepts
readiness only when `published_sources` is exactly the canonical singleton
`["plugin:<manifest-id>"]`.

The host pulls scope-free, query-free snapshots via the SDK-owned
`sources.snapshot` method. There is no plugin catalog-query hook:
`sources.snapshot` synchronously clones the current atomic in-memory store in
O(memory) time and performs no filesystem, subprocess, AX, AppleScript,
database, or network I/O. Lifecycle events remain serialized in wire order, but
warm reads never wait behind them. Refreshers build complete replacements off
to the side and expose the aggregate only by replacing the same canonical
`plugin:<manifest-id>` entry; user-facing source labels stay in candidate
metadata, not extra warm-store keys. Transient failure preserves the last-good
snapshot, while a successful empty result clears it.

Manifest loading is strict: unknown top-level or nested provider/item keys and
malformed known fields are rejected, with no legacy aliases or silent defaults.
Mapping entries use only `all`, `normal`, or `insert` scopes.

The SDK event-maintenance queue is bounded at 256 entries. Queue overflow is
rejected and logged immediately instead of growing memory without limit. Each
event records queue and handler latency; either reaching 1 second warns, and a
15-second watchdog cancels a stuck handler so later events can proceed.
Outbound control and telemetry use separate bounded lanes (64 and 128 slots);
control is prioritized, telemetry is capped at 256 KiB and may be dropped with
content-free warnings, and every wire frame is capped at 10 MiB.
Plugin-private worker queues must also be bounded and should coalesce redundant
refresh triggers. Every background scan/call needs explicit time, count, and
byte limits; none of that work may migrate to `sources.snapshot`.

Input-derived rows use `query.evaluate` instead. Evaluators are typed additive
answer producers: each plugin parses bare input itself, the host never accepts
manifest regexes or gives a plugin exclusive ownership, and explicit `!bang` /
`@source` intent bypasses the evaluator lane. The generated hook is synchronous
and must be CPU-only, reading only immutable state prepared before the request —
no filesystem, subprocess, network, AppleScript, AX, or other I/O. The host
combines replies once behind a fixed 50-ms deadline, orders providers
deterministically, prepends answers above fuzzy catalog rows, drops stale query
generations, and accepts at most 16 answers per evaluator. Crossing any count,
field, or aggregate payload boundary rejects the complete response rather than
silently truncating it.

On flashlight open the command prompt is focused immediately, but candidate
rows stay hidden until every default location snapshot (including the
asynchronously prewarmed `core.apps` index) settles or the 150-ms end-to-end
budget expires. Rows are revealed exactly once and the initial catalog remains
frozen for the session; late replies are logged, discarded for that session,
and visible only on the next open. Every plugin state except `ready` and
`degraded` settles immediately rather than holding the barrier. Per-input query
answers and explicitly requested warm source lanes may change with the input;
they do not mutate the frozen initial catalog.

Catalog wire rows use `{ title, url?, metadata, effect? }`.
`metadata.source` must match a manifest `sources[].name`, routing `source_id` is
always host-owned, and one malformed row rejects the atomic snapshot. Catalogs
are limited to 10,000 rows / 4 MiB encoded; titles to 4 KiB, URLs to 16 KiB,
metadata to 64 entries (256-byte keys and 64-KiB values), and effect text to
64 KiB. Query
evaluators have the deliberately narrower
`{ answers: [{ title, subtitle?, effect }] }` response: URLs, metadata, pids,
priorities, routing fields, and unknown keys are rejected, while the host stamps
the registered query source and ownership. A query response is limited to 16
answers / 256 KiB, with each title, subtitle, and effect text limited to 16 KiB.
In both shapes, `effect` is exactly
`{ "type": "copy_text", "text": "..." }`; it runs only after explicit
selection.

The bundled calculator demonstrates the pattern with arithmetic (`1+1`), units
(`2 km to m`), and currency expressions (`10 euros`,
`10 euros + 10 euros`). Before reporting ready it loads the last-good daily ECB
snapshot from disk into immutable evaluator state. Network refresh happens only
in the background and atomically replaces that state, so currency I/O never
delays arithmetic readiness or query evaluation. Target conversions default to
USD and can be set with:

```toml
[plugin.calculator]
target_currencies = ["USD", "EUR"]
```

Latency logs are content-free. The SDK warns when an evaluator body exceeds
10 ms; the host separately warns when its end-to-end query RPC reaches 40 ms,
before the 50-ms deadline. It also warns for snapshots at or above 100 ms,
startup over 1 second, event queue/handler latency at or above 1 second, the
15-second event watchdog, queue overflow, host-issued RPC timeouts, plugin-to-host
RPC timeouts (method and elapsed/timeout only), and successful generic RPCs over
1 second. The shared subprocess runner warns at 1 second or timeout with the
executable, status, elapsed, and timeout. Refreshers report only
`ok`/`partial`/`failed`/authoritative `empty`, counts, stages, and elapsed
milliseconds—never query text, candidate data, clipboard text, config values,
or event payloads.
