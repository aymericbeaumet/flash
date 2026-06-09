# Plugins

Plugins are managed child processes owned by Flash. Each plugin has a required
`manifest.json` with `id`, `name`, `version`, `description`, `install`, and
`start` strings. Optional `request_timeout_ms` (default `2000`) raises the
per-request RPC deadline for plugins that fan out to the network.

Official bundled plugins are always enabled. Third-party plugins are listed in
`[plugins] third_party` as `github:user/project` or `file:<path>`.

Plugins communicate with Flash through length-prefixed MessagePack on
stdin/stdout — a 4-byte big-endian payload length followed by a MessagePack
value. stderr is reserved for unexpected plugin errors. Plugin log messages
recorded by Flash use `source = "plugin:<id>"`.

Official plugins install their CLI tools under `FLASH_PLUGIN_DATA_DIR`, not into
global shell paths. Current bundled commands:

- `:spotify login|status|pause|play|toggle|next|previous|search|run`
- `:github login|status|issues|prs|run`
- `:linear login|mine|query|start|view|pr|create|run`
- `:slack login|version|run`
- `:notion login|version|api|workers|run`
- `:media play|pause|toggle|next|previous|volumeup|volumedown|mute|get|status|run`

Authentication is explicit. Install and start do not run login flows.

## Hints and mappings

A plugin can drive two more core surfaces, both gated on the manifest:

- **`provides_hints`** (bool, default false). Opts the plugin in as a *hints
  provider* for the apps it matches (`bundle_ids`). Hint selection is
  exclusive: when `f` fires, only the single highest-priority hints provider
  supporting the focused app runs — so an opted-in plugin (manifest `priority`
  defaults to 25, above the core AX walk's 10) fully owns `f`/hints for that
  app and must return its own targets. Plugins that don't set this keep the
  core AX hints untouched. To position hint geometry, request
  `ax.snapshot` with `geometry: true`; each node then carries a
  `frame: [x, y, w, h]` in NSScreen space, ready to drop into a target.

- **`mappings`** (array, default `[]`). Key bindings the plugin contributes.
  Each entry is mode-scoped, app-conditional, and priority-ordered:

  ```json
  { "key": "ctrl+k", "mode": "normal", "command": "flash://plugin_command?command=slack&subcommand=run",
    "bundle_ids": ["com.tinyspeck.slackmacgap"], "priority": 30 }
  ```

  `mode` is `normal` (default), `insert`, or `all`. `command` is a `flash://`
  URL. `bundle_ids` defaults to the manifest's bundles; the binding applies
  only while one of them is focused. `priority` defaults to the manifest
  priority (25): config/default mappings sit at 0, so a plugin mapping wins a
  key collision; a negative priority defers to the built-in default. A plugin
  may push an updated set at runtime via a `mappings.updated` notification
  (sibling of `commands.updated`); Flash re-applies it for the focused app
  without a restart.
