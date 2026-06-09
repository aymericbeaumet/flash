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
- `:slack login|version|run`
- `:media play|pause|toggle|next|previous|volumeup|volumedown|mute|get|status|run`

Authentication is explicit. Install and start do not run login flows.

## Providers

Every surface a plugin drives — hints, candidates, commands, mappings — is one
entry in a unified `providers` array, tagged by `kind` and gated by the same
optional, symmetric conditions:

```json
"providers": [
  { "kind": "hints", "bundle_ids": ["org.mozilla.firefox"] },
  { "kind": "candidates" },
  {
    "kind": "commands",
    "commands": [
      { "command": "slack", "subcommand": "run", "description": "Run slack" }
    ]
  },
  {
    "kind": "mappings",
    "modes": ["normal"],
    "mappings": [
      { "key": "ctrl+k", "command": "flash://plugin_command?command=slack&subcommand=run" }
    ]
  }
]
```

Shared, optional conditions on any entry:

- **`bundle_ids`** — apps the provider applies to (empty = every app). For
  `commands`/`mappings` the gate folds into each entry, and the entry's own
  `bundle_ids` wins.
- **`modes`** — `normal` / `insert` the provider applies to (empty = every
  mode). Folds into a `mappings` entry's `mode` when the entry doesn't set one.
- **`priority`** — precedence override; defaults to the manifest `priority`
  (25).

### kinds

- **`hints`** — opts the plugin in as a *hints provider* for the apps it
  matches. Hint selection is exclusive: when `f` fires, only the single
  highest-priority hints provider supporting the focused app runs, so an
  opted-in plugin (priority 25 > the core AX walk's 10) fully owns `f` for that
  app and must return its own targets, with no fallback. To position geometry,
  request `ax.snapshot` with `geometry: true`; each node then carries a
  `frame: [x, y, w, h]` in NSScreen space, ready to drop into a target.

- **`candidates`** — opts the plugin into the flashlight surface. Candidates are
  global and additive across plugins; a plugin self-limits its snapshot via the
  focus events it subscribes to, so this kind is a capability toggle rather than
  an app/mode gate.

- **`commands`** — `commands[]` are the `:`-verbs the plugin registers. A
  `bundle_ids` gate scopes them to the focused app; unconditional commands (the
  default) are always available.

- **`mappings`** — `mappings[]` are key bindings, mode-scoped, app-conditional,
  and priority-ordered. `command` is a `flash://` URL. Config/default mappings
  sit at priority 0, so a plugin mapping (priority 25) wins a key collision; a
  negative priority defers to the built-in default. A plugin may push an updated
  set at runtime via a `mappings.updated` notification (sibling of
  `commands.updated`); Flash re-applies it for the focused app without a
  restart.
