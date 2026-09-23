# flash [![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml)

**Click anything on macOS from your keyboard.**

Flash puts short hints over clickable controls in the app you are using. Type a
hint to click it, or use the precision grid to reach any screen position. It also
offers a persistent Vim-like normal mode, a searchable command bar, and an
optional status bar with calendar, usage, and system details.

Requires macOS 14+ and Accessibility permission. Hints work through Accessibility
across native apps, browsers, and Electron; the bundled tmux plugin handles
terminal content. Flash never reads screen pixels or logs keystrokes.

## Install

```sh
brew install --cask aymericbeaumet/tap/flash@nightly
```

Enable Flash in **System Settings → Privacy & Security → Accessibility**, then
restart it once. The installer provides the app, the `flash` CLI, and automatic
startup. Configuration stays in a file; there is no preferences window.

For a local development build, see [building from source](docs/development.md).

## Get started

Create `~/.config/flash/flash.toml`:

```toml
[mode.all.mappings]
"ctrl+space" = ["flash", "mouse_target"]
"ctrl+shift+space" = ["flash", "mouse_grid"]
"ctrl+alt+space" = ["flash", "enter_command_mode", "--input=:flashlight", "--restore-mode"]
```

Changes apply immediately. Press Control-Space and type a hint to click a control.
Control-Option-Space searches apps, browser tabs, tmux windows, and plugin data.
Try `:flashlight @emojis.glyphs fire` to insert an emoji.

To add normal mode and its status bar:

```toml
# Add these to the same [mode.all.mappings] section:
"cmd+ctrl+[" = ["flash", "enter_normal_mode"]
"cmd+ctrl+i" = ["flash", "enter_insert_mode"]

[statusbar]
enabled = true
```

NORMAL stays active across app and tab changes. Use `f` for hints, `t` for a new
tab, `[t` / `]t` to switch tabs, `u` to undo, and Control-D/U to scroll. INSERT
starts through an explicit mapping, a physical app click, or a hint or grid
click on an input. See [normal mode](docs/normal-mode.md) for the complete bindings.

## Guides

- [Configuration](docs/configuration.md) · [Full default reference](config.default.toml)
- [Commands](docs/commands.md) · [flashlight search](docs/flashlight.md)
- [Status bar format](docs/status-format.md) · [Ready-to-use example](docs/examples/statusbar/README.md)
- [Calendar](docs/calendar.md) · [Usage and system details](docs/status-popups.md)
- [Terminal windows](docs/terminal-popups.md) · [Plugins](docs/plugin-cookbook.md)
- [Development and tests](docs/development.md) · [Architecture](docs/architecture.md)

## License

Flash is released under the [MIT License](LICENSE).
