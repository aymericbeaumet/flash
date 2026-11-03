# Plugin cookbook

Graded, real Rust exemplars — read them in order. Each one is bundled, small,
and idiomatic; copy its shape. The stdio protocol remains language-neutral,
but Rust is the sole maintained SDK and implementation language for official
plugins.

## Rust (the default path)

1. **Command wrapper — `Plugins/screenshot` (~80 LOC + unit tests).** The
   smallest useful plugin: manifest `commands` + one `on_command` hook mapping
   subcommands to Apple's `screencapture` via `run_command`, with the argv
   plan kept pure and unit-tested, and one host RPC
   (`host.normal_mode_target`, the `app_control` capability) to name the
   focused window. Command-only plugins are on-demand: the host spawns them
   at first use rather than at startup, or shortly after launch when a
   configured mapping runs one of their commands.
2. **Event-refreshed catalog + commands + host RPC — `Plugins/shortcuts`
   (~290 LOC + unit tests).** A `sources` plugin that lists every macOS
   shortcut through `AppleScriptOperation::ShortcutsList` in the host (the
   faceless Shortcuts Events service), pushes the rows with `publish` only
   when they changed, and runs the picked one from `on_resolve`. Nothing
   polls: opening the flashlight (`core:session.opened`), focus leaving
   Shortcuts (`core:focus.changed`) and `core:config.*` relist behind a
   `RefreshGate`, and a cheap stamp of the Shortcuts database's size and
   modification time skips an unchanged library. `flash shortcuts open`
   launches the app through `host.open` (the `open` capability) and
   `flash shortcuts refresh` relists now. The plugin stays sandboxed:
   `apple_events` with `apple_events_targets = ["com.apple.shortcuts.events"]`
   permits only fixed host templates; `ShortcutRun` takes the picked name as
   literal data.

3. **Push catalog from configuration — `Plugins/snippets` (~220 LOC +
   tests).** A `sources` plugin reading the snippets file its
   `[plugins.snippets] file` setting names, building its complete row set with
   `insert_text` effects and pushing it with `publish` from `on_start`. It
   declares `"lifecycle": "publish_then_exit"` with `"watch_settings":
   ["file"]`: the process exits once the catalog is published, the host keeps
   the rows, and it runs again when the setting or the file changes, so no
   child stays resident for data that rarely changes. No readiness dance:
   initialize replies immediately and the catalog lands when ready; a broken
   file publishes an authoritative empty catalog, warned.
4. **Event-driven catalog + core commands + navigation — `Plugins/browsers`
   (~2,500 LOC).** Browser tabs behind one per-bundle engine table: a shared
   AppleScript skeleton with per-dialect phrases for Chromium-family browsers
   and Safari, and for Firefox the host Accessibility broker
   (`host.ax_snapshot` / `host.ax_perform`, the `accessibility` capability)
   completed from a file the browser keeps on disk. Refreshes fan out per
   browser and publish on change; the core commands its manifest declares
   (`tab select`, the tab moves) arrive in `on_command` with the focused
   browser as `context` and answer the performed / unhandled / error
   trichotomy, what the plugin leaves unhandled falls back to its
   `bindings`, and every row's `navigation_url` route restores through
   `on_navigate`.
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
`mise run test:plugins` is the one-command gate.

## Overriding what an app does for a command

No code needed: a manifest-only plugin (no `exec`) declares `bindings`,
keyed by the command line, and its entries win over the `defaults`
conventions for the apps it names. Say an app opens a tab with Cmd-Shift-N,
closes one with a two-chord sequence, has a menu item for a new window and no
print at all:

```json
{
  "id": "example-app",
  "name": "Example App",
  "version": "0.1.0",
  "description": "What Example App does for Flash's commands",
  "bindings": {
    "tab new": { "com.example.app": "cmd+shift+n" },
    "tab close": { "com.example.app": ["cmd+k", "cmd+w"] },
    "window new": { "com.example.app": { "menu": ["File", "New Window"] } },
    "app print": { "com.example.app": false }
  }
}
```

Drop it in a directory, list it as `file:<path>` in `[plugins] third_party`,
and `t` in that app now sends Cmd-Shift-N. A bundle-id entry beats any
plugin-wide `""` entry; to cover a family of apps with `""` instead, scope the
plugin with `only_bundle_ids` (or `only_terminals`) and, between plugins that
both match, raise `priority`. A plugin with a process goes one step further
by performing a command itself: a `commands[]` entry under Flash's topic
(`{"command": "tab", "subcommand": "close"}`) puts it in the source chain
ahead of every binding, with `confirm` on the entry when the command is
destructive. The inspector's Mappings page ("How commands resolve in <App>")
shows which source or binding won and which plugin declared it.

## The loop

```bash
mise run new:plugin -- myplugin "My Plugin" "What it does"   # Rust scaffold, zero-edit green
mise run build:plugins -- myplugin                            # per-id Rust hot build
tail -f ~/Library/Logs/Flash/flash.log                        # watcher restart + plugin logs
mise run test:plugin myplugin                                 # the crate's cargo tests
```

Debugging is a first-class feature of the transport: run the plugin binary in
a terminal and type NDJSON at it — `{"id":1,"method":"initialize","params":
{"protocol_version":1}}` — no host required.

Contracts you must not break — the full statements live in
`docs/plugin-protocol.md` and AGENTS.md: publish complete replacements —
of the catalog, or of one source with `publish_source` — never deltas, and
keep volatile and static rows in separate sources so a publish is
proportional to the change; on transient failure don't publish (the host
keeps last-good) and publish an authoritative `[]` only when the source is
truly empty; keep `evaluate` synchronous and I/O-free; bound every refresh;
reply to `initialize` immediately — startup work belongs in `on_start`.
