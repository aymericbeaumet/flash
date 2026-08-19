# Plugin wire protocol

This is the complete, language-agnostic contract between Flash and a plugin.
Any executable that speaks it over stdio is a valid plugin — the Rust SDK
(`docs/plugin-rust-sdk.md`) is the blessed implementation, not a wall.

## Process model

Plugins are Flash-owned child processes. Official plugins ship inside the app
bundle; third-party plugins are listed in `[plugins] third_party` as
`github:user/project@<commit-sha>` (full 40-character SHA, mandatory — the
materializer fetches exactly that commit and refuses a mismatched checkout) or
`file:<path>`. The manifest's optional `install` shell string (third-party
only) runs sandboxed from the plugin root; `exec` is an argv array exec'd
directly with the scrubbed plugin environment — no shell wrap. Its first
element resolves in order: absolute paths pass through, `./`-style paths
resolve against the plugin root (compiled plugins), and bare names resolve
through `mise which` (the repo's mise.toml pins interpreter versions) then
a login-PATH walk — interpreted plugins declare `["python3", "main.py"]`
without hardcoding machine paths.

Runtime children receive `FLASH_PLUGIN_ID`, `FLASH_PLUGIN_VERSION`,
`FLASH_PLUGIN_DATA_DIR`, `FLASH_PLUGIN_PARENT_PID`, and the plugin's
`[plugin.<id>]` settings as a JSON object in `FLASH_PLUGIN_CONFIG`. Flash
builds a scrubbed environment containing only basic locale/path/process keys
plus those values; ambient tokens, agent sockets, and login-shell secrets are
not inherited — put credentials in the plugin's config table. Install CLI
tools under `FLASH_PLUGIN_DATA_DIR`, never into global shell paths.

Host-side lifecycle policy: 15-second `initialize` deadline, 5-second
heartbeat with two misses before teardown and restart, linear restart backoff;
more than 5 restarts within 300 seconds parks the plugin in `.crashed`
(recover with `:plugins reload`). A plugin should exit when its declared
parent pid dies.

## Framing

Length-prefixed MessagePack on stdin/stdout: a 4-byte big-endian payload
length followed by one MessagePack-encoded value, JSON-RPC-2.0-shaped.
Host requests go to plugin stdin; responses and plugin-initiated frames go to
stdout. stderr is diagnostics only — lines are logged but never treated as
plugin failure (interpreted runtimes emit warnings unprompted); use
`flash.log` for structured logging. Frames are capped at 10 MiB.
Plugin log lines travel as `flash.log` notifications and are recorded with
`source = "plugin:<id>"`.

## Lifecycle methods

- `initialize` — protocol handshake. The request carries
  `{plugin_id, version, protocol_version: 3, running_applications}`; the reply
  must echo protocol version 3 exactly. A plugin that declares `sources` must
  not reply until its canonical warm catalog (possibly an authoritative empty
  list) exists: the host proves readiness by pulling a first
  `sources.snapshot` right after the reply, and only a cleanly decoding pull
  makes the plugin eligible for warm reads. A failed first pull restarts the
  plugin (non-fatal).
- `heartbeat` (id `-1`) — liveness probe; reply promptly.
- `shutdown` — run cleanup, reply, exit.

## Host → plugin methods

- `event` — host events filtered by manifest `listen` globs:
  `core:flash.started`, `core:apps.changed|launched|terminated`,
  `core:focus.changed`, `core:window.focus.changed`, `core:ax.changed`,
  `core:clipboard.changed` (requires the `clipboard` capability),
  `core:config.changed`, `core:power.changed`, `core:space.changed`.
- `sources.snapshot` — pull the complete warm catalog. Must answer from
  memory in O(catalog) time with no I/O of any kind; 150 ms deadline, only
  dispatched to warm processes.
- `query.evaluate` — per-input evaluator; 50 ms hard deadline (the host warns
  at 40 ms round-trip; a well-behaved evaluator body stays under 10 ms).
  CPU-only over state prepared earlier — no I/O.
- `hints.discover` — return target geometry and semantics. The host owns commit:
  it posts the mouse event directly to the target app and never calls back into
  the plugin to activate a target. Use role `AXLink` for native-style semantic
  links (`f` plain except Firefox-owned targets add Command; `F` Command-Shift),
  or `FlashTerminalLink` for links inside terminal content (`f` Shift, `F`
  Command-Shift). Non-link targets always receive a plain click.
- `candidate.resolve` — resolve a selected candidate to its effect/target.
- `source.action` — source-owned actions (`tab_new`, `tab_close`, …) with the
  `performed | failed | unhandled` disposition trichotomy: `unhandled` means
  "not my context" (host may fall back), `failed` means "mine, but it broke"
  (host must NOT fall back).
- `command.invoke` — `:command subcommand` dispatch. The result may carry
  `{"ok": true, "target_pid": <pid>}` to raise that app and record the jump
  in movement history.
- `navigation.restore` — restore a durable route for a declared scheme.

Generic RPCs default to a 2-second deadline; manifest `request_timeout_ms`
raises only that generic deadline, never the fixed ones above. A
`commands.items[]` entry may declare its own `timeout_ms` for interactive
commands (`spotify login` runs a 300 s device-auth flow). While any
host-initiated request is in flight, heartbeat misses are not counted — a
single-threaded plugin running a long command is busy, not dead; the
request's own deadline bounds that suspension.

## Plugin → host

Notifications: `flash.log` (structured logging), `status.updated` (values for
declared status segments, rendered as `#{plugin:<id>.<segment>}`).

Host RPCs, capability-gated default-deny (checked per process against the
manifest):

| RPC | Capability |
| --- | --- |
| `host.ping` | none |
| `host.fetch` | `network_fetch` |
| `host.normal_mode_target`, `app.activate` | `app_control` |
| `input.post_keys` | `accessibility` |
| `ax.snapshot`, `ax.perform`, `ax.set`, `ax.select_child` | `accessibility` |

The AX broker exists because `AXUIElement` cannot cross a process boundary:
`ax.snapshot` BFS-walks a subtree (default cap 3000 nodes) and returns flat
nodes with opaque handles; geometry is delivered in NSScreen coordinates.

`capabilities` also includes `network` (composes `network-outbound` into the
sandbox profile), `network_fetch` (the host performs HTTPS GETs on the
plugin's behalf via `host.fetch`, restricted to the manifest's `fetch_urls`
prefixes with an 8 s timeout and 1 MiB UTF-8 response cap — the plugin keeps
a fully network-denied sandbox), and `subprocess` (permits helpers that
cannot run inside that profile). `network_fetch` and `fetch_urls` must be
declared together. Omitted capabilities are default-denied.

## Payload shapes and quotas

Catalog rows are `{ title, url?, metadata, effect? }`. `metadata.source` must
match a manifest `sources[].name`; routing `source_id` is always host-owned.
Catalogs are bounded to 10,000 rows / 4 MiB encoded; titles 4 KiB, URLs
16 KiB, metadata 64 entries (256-byte keys, 64-KiB values), effect text
64 KiB. Query responses use the deliberately narrower
`{ answers: [{ title, subtitle?, effect }] }` — URLs, metadata, pids,
priorities, routing fields, and unknown keys are rejected — bounded to
16 answers / 256 KiB with 16-KiB fields. In both shapes `effect` is exactly
`{ "type": "copy_text", "text": "..." }` and runs only after explicit
selection. Every bound rejects the complete payload atomically; nothing is
silently truncated. One malformed row rejects the whole snapshot and the host
keeps the last-good one.

Latency and failure logs are content-free: counts, stages, elapsed
milliseconds, method names — never query text, candidate data, clipboard
content, config values, or event payloads.

## Manifest

Required: `id`, `name`, `version`, `description`. `install` is optional and
third-party-only: a shell string run once per version from the plugin root,
sandboxed (writes confined to the plugin root/data dir/temp, secrets
read-denied, network and exec open — fetching dependencies is the point),
with its full output persisted for forensics. `exec` (argv
array) is required for any plugin that runs a process; omitting it declares
a **manifest-only plugin** — no child process ever runs, and the manifest
may only carry surfaces the host serves alone: `mappings`, `help`, and
`verbs` whose every entry declares a default inline keystroke (the bundled
`defaults` plugin is the exemplar). Anything process-bound (`sources`,
`queries`, `commands`, `listen`, `capabilities`, …) is rejected. Optional:
`request_timeout_ms`, `capabilities`, `listen`, `only_bundle_ids`,
`only_urls`, and the provider sections below. Loading is strict — unknown
top-level or nested keys and malformed known fields are rejected outright.

```json
{
  "id": "example",
  "name": "Example",
  "version": "0.1.0",
  "description": "Example plugin",
  "exec": ["./flash-plugin-example"],
  "sandbox": { "exec": ["/usr/bin/osascript"], "appleevents": true },
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

Section semantics:

- **`sandbox`** — deny-default seatbelt opt-in (even `{}`): everything is
  denied except loading the binary, broad reads minus secrets (`~/.ssh`,
  `~/.aws`, keychains, other plugins' data), and writes inside the plugin's
  data dir. Allowances: `exec` (absolute paths or bare tool names resolved
  through the login-shell PATH at spawn), `read`/`write` extra subpaths,
  `appleevents`, `signal`, `process_info`, `hid` booleans. The `network`
  capability composes `network-outbound`. `[plugin.<id>] sandbox = false`
  is the per-plugin fail-open kill switch; `[plugin.<id>] exec_paths`
  appends machine-specific tool paths. Spec-less plugins keep the legacy
  network-deny-only profile until migrated.
- **`listen`** — event-name patterns; `*` wildcard.
- **`sources`** — source descriptors for `@<source>` completion and ranking.
  `kind` is `"default"` (default) or `"locations"`; `priority` is the
  semantic salience enum `low | normal | high | important | urgent`.
- **`queries`** — registers a per-input evaluator. `exclusive_prefixes` are
  exact literal markers (never regexes) that route matching input only to
  this evaluator; without one, evaluators are additive.
- **`commands`** — `:command subcommand` registrations; subcommand `"*"`
  consumes the remainder as args.
- **`mappings`** — key bindings scoped `all | normal | insert` (default
  `normal`); `command` is an argv array with config-mapping syntax.
- **`shebangs`** — flashlight bangs; `token = "*"` is the catch-all.
- **`source_actions`** — source-owned normal-mode actions.
- **`hints`** — opts in as a hint provider. Selection is exclusive; set
  `fallback_on_empty: true` only when applicability is discovered dynamically
  and empty means "not applicable".
- **`navigation`** — durable route schemes restorable from movement history.
- **`status`** — status-bar segment names fed by `status.updated`.
- **`verbs`** — CLI/mapping verbs; `inline_keystrokes` lets the host handle
  fixed keystroke verbs without any plugin RPC.

Selectors: `only_bundle_ids` / `only_urls` may appear at the root and on
command/mapping/shebang/verb entries; root and entry selectors compound, every
populated axis must match, and `only_urls` supports `*` wildcards. Specificity
is CSS-like (scoped beats unscoped; bundle+URL beats bundle-only). The numeric
manifest `priority` (default 25) is scheduling/collision arbitration — do not
confuse it with the semantic `sources[].priority` salience enum.
