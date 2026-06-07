# Plugins

Plugins are managed child processes owned by Flash. Each plugin has a required
`manifest.json` with `id`, `name`, `version`, `description`, `install`, and
`start` strings.

Official bundled plugins are always enabled. Third-party plugins are listed in
`[plugins] third_party` as `github:user/project` or `file:<path>`.

Plugins communicate with Flash through JSOND on stdin/stdout. stderr is reserved
for unexpected plugin errors. Plugin log messages recorded by Flash use
`source = "plugin:<id>"`.

Official plugins install their CLI tools under `FLASH_PLUGIN_DATA_DIR`, not into
global shell paths. Current bundled commands:

- `:spotify login|status|pause|play|toggle|next|previous|search|run`
- `:github login|status|issues|prs|run`
- `:linear login|mine|query|start|view|pr|create|run`
- `:slack login|version|run`
- `:notion login|version|api|workers|run`
- `:media play|pause|toggle|next|previous|volumeup|volumedown|mute|get|status|run`

Authentication is explicit. Install and start do not run login flows.
