# Plugins

Plugins are managed child processes owned by Flash. Each plugin has a required
`manifest.json` with `manifest_version` (required integer, currently `1`), `id`,
`name`, `version`, `description`, `install`, and `start` strings. Optional
`request_timeout_ms` (default `2000`) raises the per-request RPC deadline for
plugins that fan out to the network. Optional `capabilities` lists sensitive
host surfaces the plugin opts into: today `"clipboard"` gates delivery of
`core:clipboard.changed`, and the host filters that event out for any plugin
that hasn't declared the capability.

Official bundled plugins are always enabled. Third-party plugins are listed in
`[plugins] third_party` as `github:user/project@<commit-sha>` or
`file:<path>`. GitHub references must pin a full 40-character commit SHA —
moving branches and tags are rejected because a third-party plugin's
`install` / `start` strings run as the user and a moving upstream ref would
let arbitrary code land on every config reload.

Plugins communicate with Flash through length-prefixed MessagePack on
stdin/stdout — a 4-byte big-endian payload length followed by a MessagePack
value. stderr is reserved for unexpected plugin errors. Plugin log messages
recorded by Flash use `source = "plugin:<id>"`.

Official plugins install their CLI tools under `FLASH_PLUGIN_DATA_DIR`, not into
global shell paths. Current bundled commands:

- `:spotify login|status|pause|play|toggle|next|previous|search|run`
- `:slack login|version|run`
- `:media play|pause|toggle|next|previous|volumeup|volumedown|mute|get|status|run`
- `:clipboard` — open the clipboard history in a navigable modal (`j`/`k`
  or arrows to move, Return pastes the selected entry into the focused app)

The bundled `searchengines` plugin exports no commands; instead it serves
DuckDuckGo-style bangs in the flashlight (see the `shebang` provider below):
type `!<bang> <query>`, e.g. `!r cat` opens a Reddit search in the default
browser.

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
      { "key": "ctrl+k", "command": ["flash", "plugin_command", "--command=slack", "--subcommand=run"] }
    ]
  },
  {
    "kind": "shebang",
    "command": "search",
    "shebangs": [
      { "token": "r", "description": "Reddit" },
      { "token": "*" }
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
  and priority-ordered. `command` is a string array matching the host's mapping
  syntax: `["flash", "<verb>", "k=v", …]` for in-process verb dispatch, or any
  other head for argv exec. Config/default mappings sit at priority 0, so a
  plugin mapping (priority 25) wins a key collision; a negative priority defers
  to the built-in default. A plugin may push an updated set at runtime via a
  `mappings.updated` notification (sibling of `commands.updated`); Flash
  re-applies it for the focused app without a restart.

- **`shebang`** — `shebangs[]` are flashlight bangs. When a flashlight
  submission begins with `!<token>` (e.g. `!r cat`), Flash routes the remainder
  to the provider's `command` (folded into each entry; an entry may override it)
  instead of resolving a candidate, dispatched as `command.invoke` with the
  bang `token` as the subcommand — so a `shebang` provider needs no matching
  `commands` entry. A `token` of `"*"` is a catch-all that claims every
  otherwise-unclaimed bang, letting one plugin serve a large bang table (e.g.
  the full DuckDuckGo set) without enumerating it in the manifest. The first
  plugin to claim a token (or the catch-all) wins.
