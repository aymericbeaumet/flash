# Plugins

Plugins add flashlight catalogs, inline answers, commands, hints, status
values and their own help. Open the live [Plugins](/plugins) page to inspect
this installation's processes, health, errors and capabilities;
[Commands](/commands) lists the commands they contribute.

## Enable and configure

Bundled plugins are enabled unless excluded. Plugin-specific settings live in
`[plugins.<id>]`; use the plugin's guide for its accepted keys.

```toml
[plugins]
disabled = ["feed"]
third_party = ["file:./my-plugin"]

[plugins.terminals]
ssh_hosts = ["devbox"]
```

Third-party GitHub references must pin a full commit:
`github:owner/repository@<40-character-commit>`. Review a plugin before
enabling it. Its [permissions and data access](privacy.md#plugin-isolation)
depend on the manifest and any tools it runs. A stopped on-demand plugin is
not necessarily failing; it starts when a matching command needs it, or
shortly after launch when one of your mappings runs its command.

`:plugins reload` reloads all plugins. Configuration and watched plugin
directory changes also reconcile the running set. A plugin's own help topics
appear in Flash's help next to this documentation (`:help <topic>`).

## Build an extension

Plugins are managed child processes owned by Flash, speaking NDJSON (one JSON
object per newline-terminated line) on stdin/stdout: protocol v1, documented
in the [plugin protocol](plugin-protocol.md). Start with the
[cookbook](plugin-cookbook.md) or the [Rust SDK](plugin-rust-sdk.md); the
authoring guides sit together under Advanced in the navigation. Each
plugin is a directory with a `manifest.json` declaring what it serves:
`sources` (push-published flashlight catalogs), `query` (inline answers),
`hints`, `status` segments, `listen` event patterns, `commands`
(`flash <command> <subcommand>`, two words like every Flash command: the
plugin's own, or one of Flash's own commands the plugin performs), `bangs`
(`!token`), `mappings`, `navigation` schemes, `bindings`, `capabilities`,
`sandbox` allowances, and `help` topics. `exec` is the argv that starts the
process, which runs under a deny-default sandbox unless the manifest declares
`"sandbox": false`; a manifest without `exec` is manifest-only (mappings,
help, and bindings served by the host alone).

A plugin declaring `sources`, `query`, `hints`, `status`, or `listen` is
resident (spawned at startup); one declaring only commands, bangs, or
navigation stays stopped until its first dispatch, or until startup has
settled when a configured mapping runs its command. Official bundled plugins
are enabled unless their id appears in `[plugins] disabled`. Third-party
plugins are listed in `[plugins] third_party` as
`github:user/project@<40-char commit sha>` or `file:<path>`; only third-party
manifests may declare an `install` shell step, which runs sandboxed.

Flash starts plugin processes with a scrubbed environment plus:

- `FLASH_PLUGIN_ID`
- `FLASH_PLUGIN_VERSION`
- `FLASH_PLUGIN_DATA_DIR`
- `FLASH_PLUGIN_CONFIG` (the `[plugins.<id>]` settings as JSON)

Catalogs are push-based: the plugin sends a `publish` notification whenever
its rows change and the host serves the flashlight from its own store. Status
segments arrive via the `status` notification and render as
`#{flash.plugin.<id>.<segment>}` in `[statusbar].template`. Structured logs go
through the `log` notification and are recorded with `source = "plugin:<id>"`.
Sensitive host surfaces (clipboard, accessibility, network, notifications, …)
are default-deny and must be requested via manifest `capabilities`.

Plugin dirs are watched (unless `[plugins] watching_enabled = false`) and
hot-reload on change. `flash plugins show` (`:plugins show`) opens the plugin
dashboard with per-plugin runtime state; `:plugins reload` restarts
everything, including plugins parked in `failed`.
