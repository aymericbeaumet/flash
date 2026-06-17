# Plugins

Plugins are Flash-owned child processes. Each plugin has a required
`manifest.json` with `id`, `name`, `version`, `description`, `install`, and
`start` strings. Optional `request_timeout_ms` raises the per-request RPC
deadline for plugins that fan out to slower systems. Optional `capabilities`
declares sensitive host surfaces: `"clipboard"` gates
`core:clipboard.changed`, and `"accessibility"` gates the host AX broker
(`ax.snapshot`, `ax.perform`, `ax.set`).

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

Official plugins install their CLI tools under `FLASH_PLUGIN_DATA_DIR`, not into
global shell paths. Current bundled commands include `:spotify`, `:slack`,
`:media`, and `:clipboard`; authentication is explicit through command
subcommands, never during install or start.

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
    { "name": "example.items" }
  ],
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

`priority` defaults to `25`. For mappings and sources, selector specificity is
added to the declared priority before collision resolution. Built-in/default
mappings sit at priority `0`.

## Sections

- **`listen`** — string array of event-name patterns. `*` is the wildcard.
  Event payload filtering belongs to the core capability gate, not per-listener
  manifest objects.
- **`hints`** — opts the plugin in as a hints provider. Hint selection is
  exclusive: the highest-priority provider supporting the focused context owns
  `f` for that context.
- **`sources`** — root array of source descriptors the plugin owns for
  `@<source>` completion, source-scoped flashlight queries, and default source
  ranking. Each item is `{ "name": "<source.label>", "kind": "<kind>" }`.
  `kind` is optional and defaults to `"default"`; supported kinds are
  `"default"`, `"apps"`, `"browser_tabs"`, and `"tmux_tabs"`.
- **`commands`** — `items[]` are command-line `:` registrations. The host
  indexes them by `(command, subcommand)` on load; wildcard subcommand `"*"`
  consumes the remainder as args.
- **`mappings`** — `items[]` are normal/insert key bindings. `command` is an
  argv array using the same syntax as config mappings.
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

Candidates and targets are dynamic and travel over MessagePack. The flashlight
opens from a synchronous snapshot; do not fetch live candidates in
`candidate_query` unless the result truly depends on the query string. Keep
snapshots warm from `on_start`, `on_event`, or plugin-owned polling.
