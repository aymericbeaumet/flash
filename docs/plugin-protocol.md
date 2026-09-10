# Plugin wire protocol

This is the complete, language-agnostic contract between Flash and a plugin.
Any executable that speaks it over stdio is a valid plugin. The maintained
Rust SDK (`docs/plugin-rust-sdk.md`) is the blessed implementation, not a wall.

Normativity order: `Plugins/_flash_plugin_specs/protocol.json` (the
machine-readable constants: version, deadlines, quotas, error strings,
capability registry) plus the conformance scenarios in
`Plugins/_flash_plugin_specs/` **are** the specification. This prose explains
them; the Rust SDK implements them; any divergence is a bug in the derived
artifact, never in the spec. `Scripts/plugin-protocol-spec.py` runs the
scenarios against any plugin process, host-free, and CI runs the full matrix
against every bundled plugin and the Rust SDK conformance probe.

## Process model

Plugins are Flash-owned child processes. Official plugins ship inside the app
bundle; third-party plugins are listed in `[plugins] third_party` as
`github:user/project@<commit-sha>` (full 40-character SHA, mandatory — the
materializer fetches exactly that commit and refuses a mismatched checkout) or
`file:<path>`. The manifest's optional `install` shell string (third-party
only) runs sandboxed from the plugin root on an asynchronous install job.
The job owns a process group, drains both output pipes while it runs, retains
at most 4 MiB stdout / 256 KiB stderr, and escalates timeout or cancellation
from SIGTERM to SIGKILL after 500 ms. A stopped/replaced attempt cannot write
an install stamp or launch a child. Install attempts for the same canonical
root run in submission order across process replacements. Cancellation keeps
ownership until the old group exits; cancelled waiting attempts never spawn.
`exec` is an argv array exec'd
directly with the scrubbed plugin environment — no shell wrap. Its first
element resolves in order: absolute paths pass through, `./`-style paths
resolve against the plugin root (official Rust plugins), and bare names resolve
through `mise which` then a login-PATH walk. This keeps the protocol open to
third-party executables without adding runtime bridges to the official bundle.

Runtime children receive `FLASH_PLUGIN_ID`, `FLASH_PLUGIN_VERSION`,
`FLASH_PLUGIN_DATA_DIR`, `FLASH_PLUGIN_PARENT_PID`, and the plugin's
`[plugin.<id>]` settings as a JSON object in `FLASH_PLUGIN_CONFIG`. Flash
builds a scrubbed environment containing only basic locale/path/process keys
plus those values; ambient tokens, agent sockets, SDK search paths, and
login-shell secrets are not inherited — put credentials in the plugin's
config table. Install CLI tools under `FLASH_PLUGIN_DATA_DIR`, never into
global shell paths.

**Activation.** A plugin is *resident* — spawned at startup and kept running —
iff its manifest declares `sources`, `query`, `hints`, `status`, or `listen`.
A plugin declaring only on-demand surfaces (`commands`, `bangs`, `verbs`,
`navigation`) is *on-demand*: it stays unspawned until its first `perform`,
which launches it (the `perform` deadline comfortably absorbs the startup
budget) and then it stays running normally. Manifest-only plugins (no `exec`)
never spawn at all.

**Lifecycle state machine.**

```
initial / idle → installing → launching → running
                   │            │          │
                   └────────────┴──────────┴── failure → backoff → installing
                                                        │
                                               budget exhausted → failed
stop → stopped (all attempt work invalidated)
```

`launching` = spawned, awaiting the initialize reply; the host dispatches no
other requests and no events until `running`. Restarts back off linearly
(1..30 s); after five retries within 300 s, another failure parks the plugin in `failed` (recover with
`:plugins reload` or a plugin-file change). Successful initialize does not
reset the rolling failure budget; even an initialize-then-crash loop parks.
Lifecycle transitions belong to attempt generations. Stop/reload invalidates
pending retries, installation completions, and transport work. Rejected
initialize replies park immediately. The published catalog survives
crashes and restarts (see `publish`) and is dropped on `failed` or unload;
status segments clear on any teardown; in-flight `perform`s settle as errors.
Asynchronous host RPC replies stay attached to the child that requested them:
a replacement child can reuse an ID without receiving the old child's reply.

Explicit reload and file changes reconcile the manifest through PluginManager.
Unchanged definitions restart only the affected binaries and retain catalogs.
A changed valid definition rebuilds its registrations, authorization, adapter,
and process together and drops its previous catalog. An invalid replacement
keeps the last validated definition running and reports its load error; fixing
the file allows reconciliation to recover without a resident-app restart.
A plugin should also exit when `FLASH_PLUGIN_PARENT_PID` dies.

**Shutdown.** There is no shutdown method. The host closes the plugin's
stdin; **stdin EOF is the shutdown signal** — run cleanup, exit 0. The host
waits `shutdown_grace` (1 s), then SIGTERM, then (+0.5 s) SIGKILL.

**Liveness.** There is no periodic heartbeat. The process termination handler
catches child exit; a hung request is caught by its own deadline. The one residual probe: if
the host has received *no frame at all* from a plugin for `idle_before_ping`
(60 s) and has nothing in flight, it sends `ping`; one missed reply (10 s)
tears down and restarts. Any plugin frame — a publish, a log line, a response
— resets the idle clock. A blocking single-threaded plugin is fully
conformant: pings never race in-flight requests.

## Framing

NDJSON on stdin/stdout: UTF-8, one JSON object per newline-terminated line, no
envelope beyond `id`/`method`/`params`/`result` (`id`+`method` = request,
`id` alone = response, `method` alone = notification). Ids are positive
monotonic integers per sender. Booleans and floating-point values are never
integer IDs or protocol versions; `ok` and other Boolean fields accept only
JSON booleans. Native process IDs are checked positive 32-bit integers.
Host and plugin counters are independent and
may overlap — an inbound `id`+`method` frame is always a request, never a
reply. Exactly one reply per id'd request; responses to unknown ids are
dropped. There is **no cancellation**: late replies are dropped and the
deadline table is the contract. Lines are capped at 10 MiB in both
directions, excluding the terminating newline; an undecodable or oversized line is dropped (never fatal) and the
stream self-heals at the next newline. An outbound response that would exceed
the cap is replaced by `{"ok": false, "error": "response exceeded outbound
frame limit"}` under the same id. stderr is diagnostics only — lines are
logged but never treated as plugin failure; use the `log` notification for
structured logging (recorded with `source = "plugin:<id>"`). Geometry is
always NSScreen coordinates.

**The response law.** Every `result` is a JSON object carrying boolean `ok`.
`ok: false` carries a non-empty, content-free `error` string — with one
deliberate exception: `perform`'s `{"ok": false, "unhandled": true}` (see
below). Protocol-level failures use the canonical exact strings from
`protocol.json` (`unknown method: <m>`, `protocol version mismatch: host
v<H>, plugin v1`, `initialize may only be called once`, …); domain failures
are free-form but never contain query text, candidate data, clipboard
content, or config values.

## Deadlines

One table, in `protocol.json`, that the host, Rust SDK, runner, and this
doc all share:

| name | value | applies to |
| --- | --- | --- |
| `startup` | 5 s (config `[plugins] startup_timeout`) | `initialize` |
| `query` | 50 ms | `evaluate` |
| `live` | 1000 ms (config `[flashlight] live_query_timeout_ms`) | `search` |
| `hints` | 500 ms (fixed; blocks the AX queue ahead of the prepared model) | `hints` |
| `perform` | 10 s (per-entry `commands[].timeout_ms` overrides) | `perform` |
| `ping` | 10 s | `ping` reply |
| `idle_before_ping` | 60 s | inbound silence before a ping |
| `shutdown_grace` | 1 s | stdin-close → SIGTERM (+0.5 s → SIGKILL) |

Notifications have no deadlines.

## Host → plugin

- `initialize` — `{"protocol_version": 1}` → `{"ok": true,
  "protocol_version": 1}`. Reply **immediately** — no warm-catalog wait, no
  startup work first; `on_start` hooks run after the reply and publish when
  ready. The reply always echoes the plugin's own protocol version (the
  stale-binary diagnostic). A version mismatch → `{"ok": false,
  "protocol_version": 1, "error": "protocol version mismatch: host v<H>,
  plugin v1"}`, then flush and exit 0; any `ok: false` initialize reply is
  terminal and parks the plugin in `failed` (no auto-restart; file watchers
  stay armed so a rebuilt binary recovers). A repeated `initialize` on a
  healthy plugin is the one non-terminal protocol NAK: reply `{"ok": false,
  "error": "initialize may only be called once"}` and keep serving. No reply
  within `startup` → teardown + backoff restart. Immediately after the
  reply, the host delivers one `core:apps.changed` event (to plugins whose
  `listen` matches) carrying the full running-applications snapshot.
- `ping` — `{}` → `{"ok": true}`. See Liveness.
- `event` (notification) — `{name, payload}`, filtered by manifest `listen`
  globs: `core:flash.started`, `core:apps.changed|launched|terminated`,
  `core:focus.changed`, `core:window.focus.changed`, `core:ax.changed`,
  `core:clipboard.changed` (requires the `clipboard` capability),
  `core:config.changed`, `core:power.changed`, `core:space.changed`, and
  `core:session.opened` (the flashlight opened; advisory — eager plugins may
  refresh, nothing is required).
- `evaluate` — `{query, scope, surface}` → `{"ok": true, "answers": [...]}`.
  The per-input evaluator: synchronous, CPU-only over state prepared earlier
  — no I/O. Unclaimed input answers `{"ok": true, "answers": []}` —
  evaluators are additive parsers, never error paths.
- `search` — `{query, scope}` → `{"ok": true, "rows": [...]}` in catalog row
  shape. Live-source pull for manifests whose `sources[]` declare
  `live: true`, dispatched per flashlight keystroke but ONLY when the query
  is explicitly scoped to the source (`@source` filter or a bang's `source`)
  — live sources never join the default pool or the first paint. The handler
  may do real work (subprocess, disk); late replies are dropped, not fatal.
  `live` cannot combine with `kind: "locations"`, and one plugin's sources
  are all-warm or all-live.
- `hints` — `{bundle_id, pid, front_window_frame}` → `{"ok": true,
  "targets": [...], "context_pid"?}`. Always a live request; there is no
  cached-discovery path. The host owns commit: it posts the mouse event
  directly to the target app and never calls back into the plugin to
  activate a target. Use role `AXLink` for native-style semantic links (`f`
  plain; `F` Command-Shift), or
  `FlashTerminalLink` for links inside terminal content (`f` Shift, `F`
  Command-Shift). Every target preserves the requested click modifiers. Targets:
  `{id, frame{x,y,width,height}, role?, label?, url?, pid?,
  enters_insert_mode?, priority?}`. The nested `frame` is required; flat
  coordinates and unknown target fields are rejected. Geometry must be finite
  with positive width/height. One malformed target rejects the entire reply.
- `perform` — the single effect method. Four kinds:

  ```json
  {"kind": "resolve",  "row": {…}}
  {"kind": "command",  "command": "…", "subcommand": "…", "args": […], "raw": "…"}
  {"kind": "action",   "name": "tab_select", "context": {"bundle_id", "pid", "front_window_frame"}, "args"?: {…}}
  {"kind": "navigate", "url": "tmux://…"}
  ```

  Uniform reply, universal trichotomy:

  ```json
  {"ok": true, "target_pid"?: 123, "navigation_url"?: "…", "message"?: "…"}
  {"ok": false, "unhandled": true}
  {"ok": false, "error": "…"}
  ```

  `ok: true` = performed (`target_pid` raises that app and records the jump
  in movement history; `message` shows as a toast). `unhandled` = "not my
  context" — the host MAY fall back (e.g. to a keystroke mapping). An
  `error` = "mine, but it broke" — the host MUST NOT fall back
  (double-fire protection); no reply / timeout / crash coerces to this case.
  Bang dispatch arrives as `kind: "command"` with the bang token as
  subcommand. Unknown `kind` → error. The host never dispatches `perform`
  to a plugin in `failed`/unspawnable state — it settles as `unhandled`
  without burning the deadline (nothing could have started).

## Plugin → host

Notifications:

- `publish` — `{"rows": [...]}`. **The catalog is push-based.** A full
  replacement of the plugin's warm catalog, accepted any time after spawn;
  the host validates quotas at receipt (on the plugin's own reader queue)
  and owns the store — the flashlight first paint reads host memory and
  never waits on a plugin. `{"rows": []}` is an authoritative empty. On
  transient refresh failure, simply don't publish — the host keeps the
  last-good catalog by construction, across crashes and restarts (rows must
  therefore be resolvable from their own content; a restarted plugin that
  cannot resolve an old row replies `{"ok": false, "error": …}` to its
  `perform` and the next publish replaces the rows). A malformed or
  over-quota publish is rejected whole (content-free log) and the previous
  catalog is retained. An open flashlight refreshes from the store on a
  coalesced ≤1/s tick — lossless, since the store is already current.
- `status` — `{"segments": {"name": "value"}}` for manifest-declared status
  segments, rendered as `#{flash.plugin.<id>.<segment>}`; `""` clears a segment;
  undeclared names are ignored. Segments are live state: cleared on any
  teardown (unlike catalogs).
- `log` — `{"level", "message", "fields"}`. Content-free (counts, stages,
  elapsed ms, method names — never query text, candidate data, clipboard
  content, config values, or event payloads).

Host RPCs, capability-gated default-deny (checked per process against the
manifest; the full method↔capability table lives in `protocol.json`):
`host.ping`, `host.fetch` (`network_fetch`), `host.normal_mode_target` +
`host.activate` (`app_control`), `host.open` (`open`), `host.post_media_key`
(`media_keys`), `host.process_table` + `host.signal` (`process_control`),
`host.clipboard_write` (`clipboard`), `host.notify` (`notify`),
`host.wifi_info` (`wifi_info`),
`host.storage_get`/`host.storage_set` (no capability — plugin-data-dir
scoped), `host.post_keys` + `host.post_global_key` + `host.ax_snapshot` /
`host.ax_perform` / `host.ax_set` / `host.ax_select_child`
(`accessibility`). A denied call answers `{"ok": false, "error": "missing
<capability> capability"}`.

`host.clipboard_write` replaces the clipboard with `{"text"}` (≤ 1 MiB).
`host.wifi_info` requires `{"request_authorization": false}` for passive reads
or `true` only for an explicit user action allowed to show the host-owned
Location prompt. An undetermined request replies absent immediately after
starting the prompt; callers retry after authorization instead of holding an
RPC open. The method returns
`{"ok": true, "present": true, "ssid": "…"}` for an associated network or
`{"ok": true, "present": false}` when Wi-Fi information is unavailable.
`host.notify` shows a transient banner from `{"message", "duration_ms"?}`
(message ≤ 1 KiB, duration clamped 500–10000 ms, one accepted call per
plugin per second). `host.storage_get`/`host.storage_set` are a host-managed
KV store persisted to `storage.json` in the plugin's data dir (`{"key"}` /
`{"key", "value" | null}`; keys ≤ 128 B, values ≤ 64 KiB, 256 entries; null
deletes). `host.post_global_key` accepts one `{key_code, modifiers}` chord
posted through the host's session event stream for macOS-owned shortcuts and
rejects unmodified input. The AX broker exists because `AXUIElement` cannot
cross a process boundary: `host.ax_snapshot` BFS-walks a subtree (default
cap 3000 nodes) and returns flat nodes with opaque handles; geometry in
NSScreen coordinates. `capabilities` also includes `network` (composes
`network-outbound` into the sandbox profile), `network_fetch` (the host
performs HTTPS GETs on the plugin's behalf via `host.fetch`, restricted to
the manifest's `fetch_urls` prefixes, 8 s timeout, 1 MiB UTF-8 cap — the
plugin keeps a fully network-denied sandbox; the two must be declared
together), and `subprocess` (permits helpers that cannot run inside the
profile). `open` hands URLs/bundle ids to LaunchServices host-side,
`media_keys` posts NX_SYSTEM_DEFINED keys host-side, `process_control`
reads the process table and SIGTERMs pids host-side. `wifi_info` exposes only
the current SSID after host-owned Location authorization. Omitted capabilities
are default-denied. The registry is frozen: additions are allowed, renames
never.

**SDK `call_host` convention:** `call_host` never
throws and never returns nil — it always yields a result object. Capability
NAKs, host death (`{"ok": false, "error": "host closed stdin"}`), and the
5 s default timeout (`{"ok": false, "error": "host call timed out"}`, per-
call override available) all arrive the same way.

## Payload shapes and quotas

Catalog rows (for `publish` and `search`) are `{"source", "title", "url"?,
"metadata"?, "effect"?}` — `source` must name a manifest `sources[].name`;
routing `source_id` is always host-stamped and never crosses the wire.
Catalogs are bounded to 10,000 rows / 4 MiB encoded; titles 4 KiB, URLs
16 KiB, metadata 64 entries (256-byte keys, 64-KiB values), effect text
64 KiB. `evaluate` answers use the deliberately narrower `{"answers":
[{"title", "subtitle"?, "effect"}]}` — URLs, metadata, and unknown keys are
rejected — bounded to 16 answers / 256 KiB with 16-KiB fields. `effect` runs
only after explicit selection: `{"type": "copy_text", "text"}`, `{"type":
"insert_text", "text"}`, or — **rows only** — `{"type": "open", "url"}` /
`{"type": "open", "bundle_id"}` (answers reject `open` for the same reason
they reject URLs: evaluators cannot manufacture navigation). There is
deliberately no `run` effect — a host-executed argv would escape the
plugin's sandbox; side effects that run commands belong in `perform`, inside
the sandbox. Every bound rejects the complete payload atomically; nothing is
silently truncated. Array byte quotas count the compact UTF-8 JSON encoding
of `rows` or `answers`, including JSON syntax and string escaping, with literal
Unicode and unescaped slashes; the surrounding request/response envelope is
excluded. Publish and search apply the same catalog decoder and byte boundary.
Optional values may be null, but present values must have the declared type.
Perform outcomes form an exclusive union: success fields cannot accompany an
error, and `unhandled` cannot accompany success or an error string.

## Manifest

Required: `id`, `name`, `version`, `description`. `install` is optional and
third-party-only: a shell string run once per version from the plugin root,
sandboxed (writes confined to the plugin root/data dir/temp, secrets
read-denied, network and exec open), with its full output persisted for
forensics. `exec` (argv array) is required for any plugin that runs a
process; omitting it declares a **manifest-only plugin** — no child process
ever runs, and the manifest may only carry surfaces the host serves alone:
`mappings`, `help`, and `verbs` whose every entry declares a keystroke (the
bundled `defaults` plugin is the exemplar). Anything process-bound is
rejected. Loading is strict — unknown top-level or nested keys and malformed
known fields are rejected outright, and new manifest surface only ever
arrives together with a protocol change, so "unknown key" always means "typo
or stale host", never ambiguity.

```json
{
  "id": "example",
  "name": "Example",
  "version": "0.1.0",
  "description": "Example plugin",
  "exec": ["./flash-plugin-example"],
  "sandbox": { "exec": ["/usr/bin/osascript"], "appleevents": true },
  "capabilities": ["app_control"],
  "listen": ["core:flash.started", "core:apps.*"],
  "only_bundle_ids": ["org.mozilla.firefox"],
  "priority": 25,
  "sources": [
    { "name": "example.items", "kind": "locations", "priority": "normal", "live": false }
  ],
  "query": { "prefixes": ["="] },
  "commands": [
    { "command": "example", "subcommand": "run", "description": "Run example", "timeout_ms": 300000 }
  ],
  "bangs": {
    "command": "example",
    "items": [
      { "token": "ex", "description": "Search example", "source": "example.items" },
      { "token": "*" }
    ]
  },
  "actions": ["resource_archive"],
  "hints": { "fallback_on_empty": true },
  "navigation": ["example"],
  "status": ["state"],
  "verbs": [
    { "name": "example_save", "keystrokes": { "": "cmd+s" } }
  ],
  "mappings": [
    {
      "key": "R",
      "mode": "normal",
      "command": ["flash", "send_key", "--keys=cmd+option+r"],
      "only_bundle_ids": ["com.apple.Safari"]
    }
  ],
  "help": { "topics": [] }
}
```

Section semantics:

- **`sandbox`** — deny-default seatbelt opt-in (even `{}`): everything is
  denied except loading the binary, broad reads minus secrets (`~/.ssh`,
  `~/.aws`, keychains, other plugins' data), and writes inside the plugin's
  data dir. Allowances: `exec` (absolute paths or bare tool names resolved
  through `mise which`/login-PATH at spawn), `appleevents`, `signal`, `mach`.
  The `network` capability composes `network-outbound`.
  `[plugin.<id>] sandbox = false` is the per-plugin fail-open kill switch;
  `[plugin.<id>] exec_paths` appends machine-specific tool paths. Spec-less
  plugins keep the legacy network-deny-only profile.
- **`listen`** — event-name patterns; `*` wildcard. Declaring `listen` makes
  the plugin resident.
- **`sources`** — source descriptors for `@<source>` completion and ranking.
  `kind` is `"default"` (default) or `"locations"`; `priority` is the
  semantic salience enum `low | normal | high | important | urgent`;
  `live: true` marks a live (pull) source served by `search`.
- **`query`** — registers the per-input evaluator. `prefixes` are exact
  literal markers (never regexes) that route matching input only to this
  evaluator; without one, evaluators are additive. Evaluator ordering is the
  manifest root `priority`, ties broken by plugin id.
- **`commands`** — `:command subcommand` registrations; subcommand `"*"`
  consumes the remainder as args; per-entry `timeout_ms` overrides the
  `perform` deadline for interactive commands.
- **`bangs`** — flashlight bangs; `token: "*"` is the catch-all; an entry's
  `source` scopes live-source completion to that bang.
- **`actions`** — source-owned normal-mode action names, dispatched as
  `perform {kind: "action"}`.
- **`hints`** — opts in as a hint provider (always live). Selection is
  exclusive; set `fallback_on_empty: true` only when applicability is
  discovered dynamically and empty means "not applicable".
- **`navigation`** — durable route schemes restorable from movement history,
  dispatched as `perform {kind: "navigate"}`.
- **`status`** — status-bar segment names fed by the `status` notification.
- **`verbs`** — CLI/mapping verbs; `keystrokes` lets the host handle fixed
  keystroke verbs without any plugin RPC.
- **`mappings`** — key bindings scoped `all | normal | insert | terminal` (default
  `normal`); `command` is an argv array with config-mapping syntax; entries
  may scope with `only_bundle_ids`. Terminal mappings are local to a focused
  status popup. Every global mapping registration is suspended while that view
  owns input; only winning INSERT-active `enter_normal_mode` bindings are
  inherited as terminal defaults, and explicit terminal bindings override them.
  Terminal sequences use the shared key syntax without `<leader>`, implicit
  counts, or register prefixes. See [terminal popup input](normal-mode.md#terminal-popup-input).

`only_bundle_ids` and `only_terminals` may appear at the root and on mapping
entries; root and entry selectors compound. `only_terminals: true` scopes to
the host-owned terminal emulator list (`TerminalBundles`, which includes
Ghostty) so a plugin never carries its own terminal allowlist; the registry
instantiates such a plugin only while a known terminal runs, and its `hints`
provider is consulted only in those apps, keeping hint activation elsewhere on
the zero-hop prepared-model path. The numeric manifest `priority` (default 25) is
scheduling/collision arbitration — do not confuse it with the semantic
`sources[].priority` salience enum.

## Conformance workflow

Shared protocol scenarios live under `Plugins/_flash_plugin_specs/` and are
selected by the capabilities declared in each manifest. Put behavior that is
specific to one plugin process in `Plugins/<id>/specs/*.json`; put a host/Rust
SDK wire-contract regression in `Plugins/_flash_plugin_specs/regressions/`.
For a protocol defect, land the smallest shared reproduction before changing
the implementation. `fixtures/wire-values.fixture` is the shared malformed and
boundary-value corpus consumed by Swift host tests, the Rust SDK, and runner
tests. The subprocess runner supplies a scripted host; real host generation,
manifest reconciliation, and shutdown behavior are covered separately by the
plugin XCTest suites.

`Plugins/_flash_plugin_specs/overrides.json` is the only skip/xfail escape
hatch. Every entry needs a concrete reason. An expected failure that starts
passing is reported as XPASS and fails the run, so remove the override as soon
as the implementation catches up.

The complete gate is:

```bash
./Scripts/test-plugins.sh --lane all
```

It validates the scenario schema, formats and lints every Rust crate, runs unit
tests, builds all plugins and the generic Rust probe, and exercises the full
wire matrix. Its sandbox lane separately runs the lifecycle/handshake and
sources/publish scenarios under the real generated Seatbelt profiles.

### Seatbelt profile invariants

Seatbelt denies are not reopened by a later allow rule. When a denied parent
contains an allowed child, carve the child out inside the deny filter with
`require-all` and `require-not`; `PluginSandbox.secretsReadDeny` is the
canonical pattern for allowing a plugin's own data directory while denying its
siblings.

Seatbelt matches canonical vnode paths. Resolve symlinked executables before
putting them in a profile, and canonicalize temporary fixture roots
(`/var/folders/...` commonly resolves beneath `/private/var/folders/...`). A
path that looks equivalent in the shell may otherwise fail silently in the
profile. For diagnostics, `sandbox-exec` exit 65 means the profile did not
compile, while exit 71 means the target could not be executed under it.

## Frozen decisions

Locked while breaking is still free (the MV3 lesson); changing any of these
after external plugins exist is a migration, not an edit:

1. One integer `protocol_version`, echoed exactly at initialize; **never**
   per-feature wire negotiation — features are manifest declarations.
2. The response law and the canonical error strings in `protocol.json`.
3. Id semantics and no-cancellation (late replies dropped).
4. UTF-8 NDJSON framing, 10 MiB line cap, NSScreen geometry.
5. The quota table and the atomic-rejection doctrine.
6. The capability registry: additions allowed, renames never, granular over
   coarse.
7. The `performed / unhandled / error` trichotomy as the universal action
   vocabulary, including "error must not fall back".
8. Strict manifest unknown-key rejection + new surface only with a protocol
   change.
9. Namespacing: row `source` names, storage keys, status segments, and log
   sources are plugin-id-scoped host-side.
10. Content-free logging.
11. Normativity order: `protocol.json` + conformance specs > this prose >
    the Rust SDK.

Debugging is a first-class feature of this transport: run any plugin binary
in a terminal and type NDJSON at it — no host required. The conformance
runner does exactly that, and `Plugins/_flash_plugin_specs/schema.json`
documents the scenario language for writing new specs.
