# Plugins

Plugins are managed child processes owned by Flash. Each plugin has a required
`manifest.json` with `id`, `name`, `version`, `description`, `install`, and
`start` strings.

Official bundled plugins are always enabled. Third-party plugins are listed in
`[plugins] third_party` as `github:user/project` or `file:<path>`.

Plugins communicate with Flash through JSOND on stdin/stdout. stderr is reserved
for unexpected plugin errors. Plugin log messages recorded by Flash use
`source = "plugin:<id>"`.
