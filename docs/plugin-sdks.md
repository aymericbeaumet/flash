# Plugin SDKs — seven dialects, one program

Every language ships a full-parity SDK: a complete runtime for the wire
contract in `docs/plugin-protocol.md`, holding no Flash business concepts.
The conformance suite (`Plugins/_flash_plugin_specs/`, run by
`Scripts/plugin-protocol-spec.py`) is what "parity" means — every SDK passes
the same scenarios with byte-identical canonical strings. The files are
deliberately structured as translations of one program, in one section
order: constants → config/env → framing → pending/call_host → dispatch →
handlers → emitters → serve loop.

| | where | import |
| --- | --- | --- |
| Rust | `Plugins/_flash_plugin_rust/` (crate `flash_plugin`) | path dep in-repo; git rev pin externally (`docs/plugin-rust-sdk.md`) |
| Python | `Plugins/_flash_plugin_python/flashplugin.py` | `from flashplugin import Plugin` (host-injected `PYTHONPATH`) |
| Ruby | `Plugins/_flash_plugin_ruby/flashplugin.rb` | `require "flashplugin"` (host-injected `RUBYLIB`) |
| TypeScript/Bun | `Plugins/_flash_plugin_typescript/flashplugin.ts` | `import { Plugin } from "flashplugin"` (host-injected `NODE_PATH`) |
| Go | `Plugins/_flash_plugin_go/flashplugin.go` | `replace flashplugin => ../_flash_plugin_go`; externally vendor the file |
| Zig | `Plugins/_flash_plugin_zig/flashplugin.zig` | `-Mflashplugin=` module (build-plugins.sh); externally vendor |
| Swift | `Plugins/_flash_plugin_swift/flashplugin.swift` | compiled alongside `main.swift`; externally vendor |

## The behavior checklist (every SDK, spec-enforced)

1. UTF-8 NDJSON framing, one serialized write path, 10 MiB caps both
   directions: oversized inbound lines are discarded with stream self-heal;
   an oversized outbound response is replaced by the canonical
   `response exceeded outbound frame limit` under the same id; oversized
   notifications are dropped.
2. Frame triage: `id`+`method` → host request; `id` alone → resolves the
   call_host pending map; `method` alone → notification (unknown ignored).
3. `initialize` → immediate `{ok, protocol_version: 1}`; version mismatch →
   canonical error echoing the plugin's own version, flush, exit 0; repeated
   initialize → canonical NAK, keep serving. The start hook runs AFTER the
   reply and typically ends with a publish.
4. `ping` → `{ok: true}`, answered from the read path.
5. Unknown id'd method → canonical `unknown method: <m>`.
6. stdin EOF is the shutdown signal: resolve pending host calls with
   `host closed stdin`, run the shutdown hook, exit 0.
7. Handler registry with `perform` kind-routing: resolve/command/action/
   navigate hooks; an unregistered kind answers `{ok: false, unhandled:
   true}`, an unknown kind answers an error. Evaluate/search/hints replies
   are wrapped (`{ok, answers|rows|targets}`).
8. Emitters: publish (full-replacement rows with first-class `source`),
   status (segments), log (level/message/fields, content-free).
9. call_host never throws and never returns nil — capability NAKs, the 5 s
   default timeout (`host call timed out`, per-call override), and host
   death all arrive as `{ok: false, error}` results.
10. `config()` (`{}` on absent/malformed) and `data_dir()` — which never
    defaults to `"."`; a missing `FLASH_PLUGIN_DATA_DIR` fails loudly.
11. `PROTOCOL_VERSION = 1` pinned near the top (guardrail-checked), values
    matching `Plugins/_flash_plugin_specs/protocol.json`.

Threading is an implementation choice, not a contract: Rust runs handlers on
a 2-worker tokio runtime, Swift splits read-thread lifecycle from a worker
queue, Go uses goroutines, and Python/Ruby/Zig are single-threaded and
blocking — all equally conformant, because pings never race in-flight
requests and the host's deadlines bound everything.

## Naming map

| concept | Rust | Python | Ruby | TS | Go | Zig | Swift |
| --- | --- | --- | --- | --- | --- | --- | --- |
| start hook | `on_start` | `on_start=` | `on_start:` | `onStart` | `OnStart` | `on_start` | `onStart` |
| events | `on_event` | `on_event=` | `on_event:` | `onEvent` | `OnEvent` | `on_event` | `onEvent` |
| evaluator | `evaluate` | `on_evaluate=` | `on_evaluate:` | `onEvaluate` | `OnEvaluate` | `on_evaluate` | `onEvaluate` |
| live search | `on_search` | `on_search=` | `on_search:` | `onSearch` | `OnSearch` | `on_search` | `onSearch` |
| hints | `on_hints` | `on_hints=` | `on_hints:` | `onHints` | `OnHints` | `on_hints` | `onHints` |
| perform: resolve | `on_resolve` | `on_resolve=` | `on_resolve:` | `onResolve` | `OnResolve` | `on_resolve` | `onResolve` |
| perform: command | `on_command` | `on_command=` | `on_command:` | `onCommand` | `OnCommand` | `on_command` | `onCommand` |
| perform: action | `on_action` | `on_action=` | `on_action:` | `onAction` | `OnAction` | `on_action` | `onAction` |
| perform: navigate | `on_navigate` | `on_navigate=` | `on_navigate:` | `onNavigate` | `OnNavigate` | `on_navigate` | `onNavigate` |
| shutdown hook | `on_shutdown` | `on_shutdown=` | `on_shutdown:` | `onShutdown` | `OnShutdown` | `on_shutdown` | `onShutdown` |
| publish | `ctx.publish` | `plugin.publish` | `plugin.publish` | `plugin.publish` | `p.Publish` | `rt.publish` | `runtime.publish` |
| status | `ctx.status` | `plugin.status` | `plugin.status` | `plugin.status` | `p.Status` | `rt.status` | `runtime.status` |
| log | `ctx.log(_fields)` | `plugin.log` | `plugin.log` | `plugin.log` | `p.Log` | `rt.sendLog` | `runtime.log` |
| host RPC | `ctx.call_host` | `plugin.call_host` | `plugin.call_host` | `plugin.callHost` | `p.CallHost` | `rt.callHost` | `runtime.callHost` |
| reply helpers | `PerformResponse::ok/unhandled/fail` | `ok()/unhandled()/fail()` | `FlashPlugin.ok/unhandled/fail` | `ok()/unhandled()/fail()` | `Ok()/Unhandled()/Fail()` | `ok()/unhandled()/fail()` | `ok()/unhandled()/fail()` |

Rust's `plugin!` proc-macro additionally derives which handlers are
*required* from `manifest.json` at compile time — the one deliberate
per-language extra; everywhere else a missing handler surfaces as
`unhandled`/`unknown method` at runtime and in the conformance run.

## The cross-stack rule

A protocol bug found in ANY SDK gets a minimal repro spec in
`Plugins/_flash_plugin_specs/regressions/` FIRST, then the fix lands in every
affected SDK, then any temporary `overrides.json` entry is deleted — an
xfail that starts passing fails CI, so parity debt can only shrink. See
`Plugins/_flash_plugin_specs/schema.json` for the scenario language.
