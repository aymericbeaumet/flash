# Flash

[![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml)

System-wide hint-driven find and jump for macOS. Flash is a resident, headless app: it overlays hint labels on clickable elements in the focused app, then clicks or focuses the selected target when you type its hint.

## Build

```bash
./Scripts/install.sh --dev
```

Open it once so macOS knows where it lives:

```bash
open /Applications/Flash.app
```

Then grant **Accessibility** in *System Settings -> Privacy & Security -> Accessibility*.

`./Scripts/install.sh --dev` signs Flash with the stable local "Flash Dev" identity, installs `/Applications/Flash.app`, registers login autolaunch through `~/Library/LaunchAgents/com.flash.app.autolaunch.plist`, starts the resident app, installs `flash` / `flashctl` symlinks in `~/.local/bin`, and symlinks bundled plugins from the checkout for live reload during development. Use `--release` for an optimized universal (Intel + Apple Silicon) build of both the app and the bundled plugins.

## Actions

Every action is available as `flash://...` and can be invoked with `open`, the CLI, or a configured mapping:

```bash
open -g flash://mouse_target
open -g flash://mouse_target?secondary=1
open -g flash://mouse_grid
open -g flash://mode_normal
open -g flash://help_show
open -g flash://help_show?topic=plugins
open -g flash://flash_quit

flash mouse_target
flash mouse_grid move=1
flash mode_normal
flash app_open name=Firefox
flash window_move position=lefthalf
flash help_show
```

Common actions include `flash://mouse_target`, `flash://mouse_target?secondary=1`, `flash://mouse_target?double=1`, `flash://mouse_target?move=1`, `flash://mouse_grid`, `flash://mouse_grid?secondary=1`, `flash://mouse_grid?double=1`, `flash://mouse_grid?move=1`, `flash://scroll_down`, `flash://scroll_half_page_up`, `flash://scroll_half_page_down`, `flash://scroll_top`, `flash://tab_next`, `flash://tab_previous`, `flash://tab_select?index=<n>`, `flash://tab_close`, `flash://history_back`, `flash://history_forward`, `flash://movement_back`, `flash://movement_forward`, `flash://app_previous`, `flash://app_next`, `flash://app_reload`, `flash://app_reload?force=1`, `flash://app_undo`, `flash://app_redo`, `flash://window_close`, `flash://app_find`, `flash://app_open_finder`, `flash://flashlight`, `flash://url_copy`, `flash://app_save`, `flash://app_save_and_quit`, `flash://app_print`, `flash://document_open`, `flash://window_new`, `flash://tab_new`, `flash://clipboard_copy`, `flash://clipboard_cut`, `flash://clipboard_paste`, `flash://clipboard_copy_all`, `flash://app_open?name=<app>`, `flash://window_move?position=<slot>&screen=<n>`, `flash://plugins`, `flash://plugin_command?command=<command>&subcommand=<subcommand>`, `flash://hints_dismiss`, `flash://alert_dismiss`, and `flash://alert_show?message=<text>`.

## Configuration

`~/.config/flash/flash.toml` hot-reloads.

```toml
[hints]
keys = "<qwerty_homerow+qwerty_toprow>"
min_length = 1
magic_modifiers = ["cmd", "ctrl", "alt", "shift"]

[open]
ignored_apps = []

[plugins]
third_party = []

[flashlight]
precedence_alive_bonus = 10

[flashlight.aliases]
# "!g" = "!google"
# "@ft" = "@firefox.tabs"

[flashlight.precedence]
tmux = 100
firefox = 80
safari = 80
"core.apps" = 40

[mode]
labels = { normal = "N", insert = "I", command = "C" }

[mode.all.mappings]
# "ctrl+space" = "flash://mouse_target"
# "ctrl+alt+n" = "flash://mode_normal"

[mode.normal]
leader = "\\"

[mode.normal.mappings]
"<leader>c" = ["../../scripts/toggle_caffeinate.sh"]
"h" = "flash://scroll_left"
"j" = "flash://scroll_down"
"k" = "flash://scroll_up"
"l" = "flash://scroll_right"
"ctrl-d" = "flash://scroll_half_page_down"
"ctrl-u" = "flash://scroll_half_page_up"
"gg" = "flash://scroll_top"
"G" = "flash://scroll_bottom"
"[h" = "flash://history_back"
"]h" = "flash://history_forward"
"[t" = "flash://tab_previous"
"]t" = "flash://tab_next"
"[m" = "flash://tab_move_previous"
"]m" = "flash://tab_move_next"
"[a" = "flash://app_previous"
"]a" = "flash://app_next"
"T" = "flash://tab_reopen"
"g1" = "flash://tab_select?index=1"
"g2" = "flash://tab_select?index=2"
"g3" = "flash://tab_select?index=3"
"g4" = "flash://tab_select?index=4"
"g5" = "flash://tab_select?index=5"
"g6" = "flash://tab_select?index=6"
"g7" = "flash://tab_select?index=7"
"g8" = "flash://tab_select?index=8"
"g9" = "flash://tab_select?index=9"
"f" = "flash://mouse_target"
"sf" = "flash://mouse_target?secondary=1"
"df" = "flash://mouse_target?double=1"
"mf" = "flash://mouse_target?move=1"
"F" = "flash://mouse_grid"
"sF" = "flash://mouse_grid?secondary=1"
"dF" = "flash://mouse_grid?double=1"
"mF" = "flash://mouse_grid?move=1"
"u" = "flash://app_undo"
"ctrl-r" = "flash://app_redo"
"x" = "flash://window_close"
"n" = "flash://window_new"
"t" = "flash://tab_new"
"/" = "flash://app_find"
"<leader>space" = "flash://flashlight"
"r" = "flash://app_reload"
"R" = "flash://app_reload?force=1"
"?" = "flash://help_show"
":" = "flash://mode_command"

[mode.insert.mappings]
# advanced mode is enabled only by binding flash://mode_normal in [mode.all.mappings]

[debug]
log_level = "info"
# show_hints_bounds = false
# hints_bounds_bg = "#00000000"
# hints_bounds_fg = "#FF3B9A"
# http_inspector_enabled = false
# http_inspector_host = "localhost"
# http_inspector_port = 4242
```

`[mode] labels` controls the mode-cell text; its width follows the longest configured label. `[mode.all.mappings]` applies in insert and normal modes. `[mode.normal]` holds normal-mode options such as `leader = "\\"`. `[mode.normal.mappings]` extends the built-in normal-mode map and overrides only matching keys. `[mode.insert.mappings]` applies only in insert mode. Values can be `flash://...` actions or explicit command arrays such as `["sh", "~/bin/toggle-colors"]`; bare shell strings and non-Flash URLs are rejected. Relative argv paths containing `/` resolve from the config file location.

When a `[mode.all.mappings]` mapping points to `flash://mode_normal`, Flash shows the persistent mode cell and starts in normal mode. `[mode.normal.mappings]` and `[mode.insert.mappings]` mappings do not enable advanced mode. Without an advanced-mode mapping, the mode cell is hidden and Flash behaves as a direct action launcher unless `flash://mode_normal` is invoked manually.

`[flashlight.aliases]` rewrites completed query tokens such as `"!g" = "!google"` or `"@ft" = "@firefox.tabs"`. `[flashlight.precedence]` adjusts source-order tiebreakers after match quality ties; entries not listed fall back to weight `0`, and `precedence_alive_bonus` nudges running app candidates ahead of inactive app rows from the same source.

`[plugins] third_party` accepts `github:user/project` and `file:<path>` entries. Every plugin has a `manifest.json` with `id`, `name`, `version`, `description`, `install`, `start`, event subscriptions, and command registrations. Each plugin registers one or more commands (the verb after `:`), and each command has one or more subcommands. Flash runs plugin commands as managed child processes over length-prefixed MessagePack on stdin/stdout: a 4-byte big-endian payload length followed by a MessagePack value; stderr is reserved for unexpected errors. Official bundled plugins are always enabled in this version, install their CLIs under `FLASH_PLUGIN_DATA_DIR`, and include `:spotify`, `:slack`, and `:media` commands with explicit login/status/run subcommands. A plugin command may ask Flash to raise a window by returning a `target_pid`; Flash activates it and records the jump into the `ctrl-o` / `ctrl-i` movement history. The tmux plugin uses this for jump-to commands: `:tmux session <name>` and `:tmux window <session:index>` switch the active tmux client and bring its terminal forward, so you can bind a hotkey such as `flash://plugin_command?command=tmux&subcommand=window&args=main:1`.

Normal mode supports counts such as `10u` and `2[t`, `gg` / `G` for instant top/bottom scrolling, `g1` through `g9` for environment-specific indexed selection, `r` / `R` for reload / force reload, `[h` / `]h` for target page history, `[t` / `]t` for tab previous/next, `[a` / `]a` for app previous/next (MRU), `ctrl-o` / `ctrl-i` for Flash movement history, command-line mode with `:`, and `?` for help. Command-line forms include `:help [topic]`, `:q[uit]`, `:q[uit]!`, `:w[rite]`, `:p[rint]`, `:e[dit]`, `:open`, `:open <query>`, `:flashlight`, `:flashlight <query>`, `:plugins`, `:<plugin-command> <subcommand> [args...]`, `:new`, `:tabnew`, `:bd[elete]`, `:cl[ose]`, `:find`, `:u[ndo]`, `:red[o]`, `:y[ank]`, `:d[elete]`, `:pu[t]`, and `:%y[ank]`. `:open <query>` and `:flashlight <query>` show typo-tolerant results above the command line across source-labelled results such as `[app] Firefox`, `[tmux] scratch gors`, `[firefox] Gmail (https://mail.google.com)`, and `[slack] #general`; use arrows or tab / shift-tab to select and return to open. Command and sub-command suggestions (`:help <topic>`, `:plugins <sub>`, `:<plugin-command> <subcommand>`) are separate: each candidate has a visible cosmetic label and an underlying value, `<tab>` inserts the value without sending so you can keep typing arguments, `<CR>` inserts the value and sends, and arrows / shift-tab cycle the selection. Source candidates follow the `{ source, name, url }` contract, and `url` is openable whenever present; app URLs are absolute `file://` URLs to the `.app` bundle. `[open] ignored_apps = ["Flash", "com.flash.app"]` hides matching app candidates from `:open`, `:flashlight`, and `flash://app_open?name=...`.

Setting `[debug] http_inspector_enabled = true` starts a loopback-only single-page debug view with live logs, resolved config, focused app state, and plugin state. The host (`http_inspector_host`) is restricted to `localhost` / `127.0.0.1` / `::1`; the default port is `4242`. Every log line carries a `source` field such as `core:AppDelegate.swift.activate(...)` or `plugin:spotify`.

Flash stays in normal mode until the user presses `i`, commits an `f` / `F` mouse-click hint, or physically clicks while idle normal mode is capturing input. Hint clicks may include configured modifier passthrough, right-clicks, or double-clicks; they are treated as explicit mouse interactions by the user. Physical clicks are replayed so they reach the underlying app. External `flash://mode_insert`, passive focus changes, app focus requests, menu-bar clicks, status-bar popups, and `flash://app_find` do not switch to insert mode while advanced normal mode is active.

## External Tools

Karabiner-Elements:

```json
{ "type": "basic",
  "from": { "key_code": "f", "modifiers": { "mandatory": ["left_control","left_option"] } },
  "to":   [{ "shell_command": "open -g flash://mouse_target" }] }
```

Hammerspoon:

```lua
hs.hotkey.bind({"ctrl", "alt"}, "f", function() hs.urlevent.openURL("flash://mouse_target") end)
```

skhd:

```text
ctrl + alt - f : open -g flash://mouse_target
```

## Architecture

Flash is one resident, headless macOS app:

- **No menu bar, Dock icon, or preferences UI.** The visible surfaces are the transparent hint overlay, the mode cell when configured, the mapping/help/app finder overlays, and explicit alert toasts.
- **No arbitrary global key capture.** Native modified-key mappings use Carbon `RegisterEventHotKey` only for explicit `[mode.*]` entries. No event taps or Input Monitoring. Hint and normal-mode typing happens inside the overlay window through standard `NSWindow` key handling.
- **URL actions are canonical.** Native mappings and the CLI resolve to the same `URLCommand` parser used by `flash://` AppleEvents.
- **AX-event-driven prepared model.** The focused app is pre-walked from Accessibility notifications and config revisions so `flash://mouse_target` can render from a fresh prepared model when available.
- **Managed plugin children.** App-specific dynamic integrations may run as Flash-owned child processes over length-prefixed MessagePack on stdin/stdout. No sockets, Mach services, daemonized clients, or arbitrary global key capture are added.
- **Source chain** per focused app: the bundled tmux plugin for terminals running tmux, then the generic `AccessibilityProvider` for native and web content exposed through Accessibility. Sources can also feed `:open`, app activation, document URL resolution, and source-owned tab actions.

Public SPI lives in `FlashCore` (`FlashSource`, `JumpTarget`, `AppContext`, `JumpAction`). Add a source by implementing the protocol and registering a `SourceDescriptor` in `Sources/flash/App/SourceRegistry.swift`; choose an activation policy so sources are only loaded while the corresponding app class is running.

## Develop

```bash
swift build
swift test
./Scripts/install.sh --dev
```

The installed resident process runs from `/Applications/Flash.app`; `swift build` does not update the app macOS is using. Reinstall after every code change before manual UI verification.

Integration coverage:

```bash
./Scripts/test-integration-browser.sh
./Scripts/test-integration-native.sh
./Scripts/test-integration-electron.sh
```

Anything that requires the full overlay and live AX commit path still needs manual verification after install.

## License

MIT (see `LICENSE` if added).
