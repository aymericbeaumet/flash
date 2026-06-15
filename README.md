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

`./Scripts/install.sh --dev` builds an optimized current-arch app and plugins, signs Flash with the stable local "Flash Dev" identity, installs `/Applications/Flash.app`, registers login autolaunch through `~/Library/LaunchAgents/com.flash.app.autolaunch.plist`, starts the resident app, installs the `flash` CLI symlink in `~/.local/bin`, and symlinks bundled plugins from the checkout for live reload during development. Use `--release` for a clean optimized universal (Intel + Apple Silicon) build of both the app and the bundled plugins.

## Actions

Every action is a *verb* the `flash` CLI sends to the resident over a custom AppleEvent (class `Flsh`, ID `Cmd `). The same verb table backs mapping config (see below), so the two paths share a single dispatch table.

```bash
flash mouse_target
flash mouse_target secondary=1
flash mouse_grid
flash mode_normal
flash help_show
flash help_show topic=plugins
flash flash_quit
flash app_open name=Firefox
flash window_move position=lefthalf
```

Common verbs: `mouse_target`, `mouse_target secondary=1`, `mouse_target double=1`, `mouse_target move=1`, `mouse_grid`, `mouse_grid secondary=1`, `mouse_grid double=1`, `mouse_grid move=1`, `scroll_down`, `scroll_half_page_up`, `scroll_half_page_down`, `scroll_top`, `tab_next`, `tab_previous`, `tab_select index=<n>`, `tab_close`, `history_back`, `history_forward`, `movement_back`, `movement_forward`, `app_previous`, `app_next`, `app_reload`, `app_reload force=1`, `app_undo`, `app_redo`, `window_close`, `app_find`, `app_open_finder`, `flashlight`, `url_copy`, `app_save`, `app_save_and_quit`, `app_print`, `document_open`, `window_new`, `tab_new`, `clipboard_copy`, `clipboard_cut`, `clipboard_paste`, `clipboard_copy_all`, `app_open name=<app>`, `window_move position=<slot> screen=<n>`, `plugins`, `plugin_command command=<command> subcommand=<subcommand>`, `hints_dismiss`, `alert_dismiss`, `alert_show message=<text>`.

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

[statusbar]
left = "#{mode}"
right = "#{date}"

[flashlight]
suggestion_count = 10
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
# "ctrl+space" = ["flash", "mouse_target"]
# "ctrl+alt+n" = ["flash", "mode_normal"]

[mode.normal]
leader = "\\"

[mode.normal.mappings]
"<leader>c" = ["../../scripts/toggle_caffeinate.sh"]
"h" = ["flash", "scroll_left"]
"j" = ["flash", "scroll_down"]
"k" = ["flash", "scroll_up"]
"l" = ["flash", "scroll_right"]
"ctrl-d" = ["flash", "scroll_half_page_down"]
"ctrl-u" = ["flash", "scroll_half_page_up"]
"gg" = ["flash", "scroll_top"]
"G" = ["flash", "scroll_bottom"]
"[h" = ["flash", "history_back"]
"]h" = ["flash", "history_forward"]
"[t" = ["flash", "tab_previous"]
"]t" = ["flash", "tab_next"]
"[m" = ["flash", "tab_move_previous"]
"]m" = ["flash", "tab_move_next"]
"[a" = ["flash", "app_previous"]
"]a" = ["flash", "app_next"]
"T" = ["flash", "tab_reopen"]
"g1" = ["flash", "tab_select", "index=1"]
"g2" = ["flash", "tab_select", "index=2"]
"g3" = ["flash", "tab_select", "index=3"]
"g4" = ["flash", "tab_select", "index=4"]
"g5" = ["flash", "tab_select", "index=5"]
"g6" = ["flash", "tab_select", "index=6"]
"g7" = ["flash", "tab_select", "index=7"]
"g8" = ["flash", "tab_select", "index=8"]
"g9" = ["flash", "tab_select", "index=9"]
"f" = ["flash", "mouse_target"]
"sf" = ["flash", "mouse_target", "secondary=1"]
"df" = ["flash", "mouse_target", "double=1"]
"mf" = ["flash", "mouse_target", "move=1"]
"F" = ["flash", "mouse_grid"]
"sF" = ["flash", "mouse_grid", "secondary=1"]
"dF" = ["flash", "mouse_grid", "double=1"]
"mF" = ["flash", "mouse_grid", "move=1"]
"u" = ["flash", "app_undo"]
"ctrl-r" = ["flash", "app_redo"]
"x" = ["flash", "window_close"]
"n" = ["flash", "window_new"]
"t" = ["flash", "tab_new"]
"/" = ["flash", "app_find"]
"<leader>space" = ["flash", "flashlight"]
"r" = ["flash", "app_reload"]
"R" = ["flash", "app_reload", "force=1"]
"?" = ["flash", "help_show"]
":" = ["flash", "mode_command"]

[mode.insert.mappings]
# advanced mode is enabled only by binding ["flash", "mode_normal"] in [mode.all.mappings]

[debug]
log_level = "info"
# show_hints_bounds = false
# hints_bounds_bg = "#00000000"
# hints_bounds_fg = "#FF3B9A"
# http_inspector_enabled = false
# http_inspector_host = "localhost"
# http_inspector_port = 4242
```

`[mode] labels` controls the mode text available to status-bar templates. `[statusbar]` controls the bar format with two template strings: `left` renders in the highlighted left cell, and `right` renders on the right side. Separators are literal inline text, such as `right = "#{script:~/bin/status.sh}#[fg=colour245] · #{date}"`. Templates can read Flash state (`#{mode}`, `#{active_app_name}`, `#{active_bundle_identifier}`, `#{date}`), plugin state (`#{plugin:ready_count}`), scripts (`#{script:~/bin/status.sh}`), or shell commands (`#{command:pmset -g batt}`). `[mode.all.mappings]` applies in insert and normal modes. `[mode.normal]` holds normal-mode options such as `leader = "\\"`. `[mode.normal.mappings]` extends the built-in normal-mode map and overrides only matching keys. `[mode.insert.mappings]` applies only in insert mode. Every mapping value is a string array. Arrays whose head is `"flash"` are in-process verb dispatches (`["flash", "<verb>", "key=value", …]`); any other head is executed directly as argv with `~`/env expansion on each element (no shell wrap). Relative argv paths containing `/` resolve from the config file location.

When a `[mode.all.mappings]` mapping points to `["flash", "mode_normal"]`, Flash shows the persistent status bar and starts in normal mode. The bar uses the screen's native reserved top-band height, falling back to the measured native menu-bar reveal height when macOS folds that reservation away. It stays below the native macOS menu/status bar reveal, insets content away from rounded screen corners, and uses Nord colors. Command-backed status sections keep their previous value until a replacement is ready. While the bar is enabled, Flash keeps the macOS top-band reservation in place and the `window_move` verb slots/remaps windows inside that reserved usable frame. `[mode.normal.mappings]` and `[mode.insert.mappings]` mappings do not enable advanced mode. Without an advanced-mode mapping, the status bar is hidden and Flash behaves as a direct action launcher unless `["flash", "mode_normal"]` is invoked manually.

`[flashlight] suggestion_count` controls how many rows the command bar shows; the default is `10`. `[flashlight.aliases]` rewrites completed query tokens such as `"!g" = "!google"` or `"@ft" = "@firefox.tabs"`. `[flashlight.precedence]` adjusts source-order tiebreakers after match quality ties; entries not listed fall back to weight `0`, and `precedence_alive_bonus` nudges running app candidates ahead of inactive app rows from the same source.

`[plugins] third_party` accepts `github:user/project@<commit-sha>` and `file:<path>` entries. GitHub references must pin a full 40-character commit SHA — moving branches and tags are rejected because a third-party plugin's `install` / `start` scripts run as the user, and a silent upstream update would land arbitrary code on every config reload. Every plugin has a `manifest.json` with `id`, `name`, `version`, `description`, `install`, `start`, event subscriptions, and command registrations. Candidate providers declare their source labels in `providers[].sources`, keep snapshots warm in memory, and refresh from host events such as `core:apps.snapshot`, `core:focus.changed`, or `core:ax.changed`; plugins should poll only when the source data has no lighter event stream. Each plugin registers one or more commands (the verb after `:`), and each command has one or more subcommands. Flash runs plugin commands as managed child processes over length-prefixed MessagePack on stdin/stdout: a 4-byte big-endian payload length followed by a MessagePack value; stderr is reserved for unexpected errors. Official bundled plugins are always enabled in this version, install their CLIs under `FLASH_PLUGIN_DATA_DIR`, and include `:spotify`, `:slack`, and `:media` commands with explicit login/status/run subcommands. A plugin command may ask Flash to raise a window by returning a `target_pid`; Flash activates it and records the jump into the `ctrl-o` / `ctrl-i` movement history. The tmux plugin uses this for jump-to commands: `:tmux session <name>` and `:tmux window <session:index>` switch the active tmux client and bring its terminal forward, so you can bind a hotkey such as `["flash", "plugin_command", "command=tmux", "subcommand=window", "args=main:1"]`.

Normal mode supports counts such as `10u` and `2[t`, `gg` / `G` for instant top/bottom scrolling, `g1` through `g9` for environment-specific indexed selection, `r` / `R` for reload / force reload, `[h` / `]h` for target page history, `[t` / `]t` for tab previous/next, `[a` / `]a` for app previous/next (MRU), `ctrl-o` / `ctrl-i` for Flash movement history, command-line mode with `:`, and `?` for help. Command-line forms include `:help [topic]`, `:q[uit]`, `:q[uit]!`, `:w[rite]`, `:p[rint]`, `:e[dit]`, `:open`, `:open <query>`, `:flashlight`, `:flashlight <query>`, `:plugins`, `:<plugin-command> <subcommand> [args...]`, `:new`, `:tabnew`, `:bd[elete]`, `:cl[ose]`, `:find`, `:u[ndo]`, `:red[o]`, `:y[ank]`, `:d[elete]`, `:pu[t]`, and `:%y[ank]`. `:open <query>` and `:flashlight <query>` show typo-tolerant results below the centered command line across source-labelled results such as `[app] Firefox`, `[tmux] scratch gors`, `[firefox] Gmail (https://mail.google.com)`, and `[slack] #general`; opening the surface renders warmed app candidates immediately, asks plugins for warm snapshots with a short first-screen deadline, and holds late plugin rows until the user types so an idle list does not reshuffle under the cursor. Use arrows or shift-tab to cycle; app and tmux-window rows are final destinations, so tab or return submits them like command-return. For other rows, tab inserts the selected candidate without opening, return inserts or opens when the result is a source-owned finisher or exact primary-title match, and command-return force-opens real candidates. Synthetic `[source] @...` rows are insert-only for tab, return, and command-return. Command and sub-command suggestions (`:help <topic>`, `:plugins <sub>`, `:<plugin-command> <subcommand>`) are separate: each candidate has a visible cosmetic label and an underlying value, `<tab>` inserts the value without sending so you can keep typing arguments, `<CR>` inserts the value and submits only for terminal/plugin-subcommand completions, and arrows / shift-tab cycle the selection. Source candidates follow the `{ source, name, url }` contract, and `url` is openable whenever present; app URLs are absolute `file://` URLs to the `.app` bundle. `[open] ignored_apps = ["Flash", "com.flash.app"]` hides matching app candidates from `:open`, `:flashlight`, and the `app_open` verb.

Setting `[debug] http_inspector_enabled = true` starts a loopback-only single-page debug view with live logs, resolved config, focused app state, and plugin state. The host (`http_inspector_host`) is restricted to `localhost` / `127.0.0.1` / `::1`; the default port is `4242`. Every log line carries a `source` field such as `core:AppDelegate.swift.activate(...)` or `plugin:spotify`.

Flash stays in normal mode until the user presses `i`, commits an `f` / `F` mouse-click hint, or physically clicks while idle normal mode is capturing input. Hint clicks may include configured modifier passthrough, right-clicks, or double-clicks; they are treated as explicit mouse interactions by the user. Physical clicks are replayed so they reach the underlying app. External `mode_insert` verbs, passive focus changes, app focus requests, menu-bar clicks, status-bar popups, and the `app_find` verb do not switch to insert mode while advanced normal mode is active.

## External Tools

Karabiner-Elements:

```json
{ "type": "basic",
  "from": { "key_code": "f", "modifiers": { "mandatory": ["left_control","left_option"] } },
  "to":   [{ "shell_command": "flash mouse_target" }] }
```

Hammerspoon:

```lua
hs.hotkey.bind({"ctrl", "alt"}, "f", function() hs.execute("flash mouse_target") end)
```

skhd:

```text
ctrl + alt - f : flash mouse_target
```

## Architecture

Flash is one resident, headless macOS app:

- **No menu bar, Dock icon, or preferences UI.** The visible surfaces are the transparent hint overlay, the status bar when advanced mode is configured, the mapping/help/app finder overlays, and explicit alert toasts.
- **No arbitrary global key capture.** Native modified-key mappings use Carbon `RegisterEventHotKey` only for explicit `[mode.*]` entries. No event taps or Input Monitoring. Hint and normal-mode typing happens inside the overlay window through standard `NSWindow` key handling.
- **Verbs are canonical.** Mapping config arrays (`["flash", "<verb>", "key=value"]`), the `flash` CLI, and the resident's custom AppleEvent (class `Flsh`, ID `Cmd `) all resolve through the same in-process verb dispatch table.
- **AX-event-driven prepared model.** The focused app is pre-walked from Accessibility notifications and config revisions so `mouse_target` can render from a fresh prepared model when available.
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
