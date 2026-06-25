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
flash mouse_target --secondary
flash mouse_grid
flash enter_normal_mode
flash enter_locked_insert_mode
flash help_show
flash help_show --topic=plugins
flash quit
flash app_open --name=Firefox
flash window_move --position=lefthalf
flash enter_command_mode --input=':flashlight @source:emojis.glyphs' --restore-mode
```

Verb arguments use standard long-flag shell syntax: `--name=value` for values, bare `--flag` for booleans (`--secondary`, `--force`, `--restore-mode`). Hyphens in a flag name are normalized to underscores internally, so `--restore-mode` and `--restore_mode` both reach the dispatcher as `restore_mode`.

Common verbs: `mouse_target`, `mouse_target --secondary`, `mouse_target --double`, `mouse_target --move`, `mouse_grid`, `mouse_grid --secondary`, `mouse_grid --double`, `mouse_grid --move`, `scroll_down`, `scroll_half_page_up`, `scroll_half_page_down`, `scroll_top`, `tab_next`, `tab_previous`, `tab_select --index=<n>`, `tab_close`, `history_back`, `history_forward`, `movement_back`, `movement_forward`, `app_previous`, `app_next`, `app_reload`, `app_reload --force`, `resource_archive`, `resource_next`, `resource_previous`, `app_undo`, `app_redo`, `window_close`, `app_find`, `app_open_finder`, `enter_command_mode --input='<text>' [--restore-mode]`, `url_copy`, `send_key --keys=<hotkey>`, `send_keys --keys=<hotkey,hotkey,...>`, `app_save`, `app_save_and_quit`, `app_print`, `document_open`, `window_new`, `tab_new`, `clipboard_copy`, `clipboard_cut`, `clipboard_paste`, `clipboard_copy_all`, `app_open --name=<app>`, `window_move --position=<slot> --screen=<n>`, `screenshot_options`, `screenshot_screen`, `screenshot_selection`, `screenshot_window`, `screenshot_screen_clipboard`, `screenshot_selection_clipboard`, `screenshot_window_clipboard`, `plugins`, `plugin_command --command=<command> --subcommand=<subcommand>`, `hints_dismiss`, `alert_dismiss`, `alert_show --message=<text> [--duration=<seconds>] [--style=standard|error]`, `quit`.

The `enter_command_mode` verb opens the command-line panel, or opens it pre-seeded when `--input='<text>'` is provided. Leading colons in the input are trimmed so `--input=:emojis` and `--input='emojis '` resolve to the same seeded buffer. `--restore-mode` makes the panel exit (submit or cancel) restore whichever mode was active when the mapping fired — bind `cmd+ctrl+space` to `["flash", "enter_command_mode", "--input=emojis ", "--restore-mode"]` and an emoji picker fired from INSERT mode returns the user to INSERT once the glyph is inserted.

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
disabled = []
third_party = []

[statusbar]
template = "#[align=left]#{mode}#[align=right]#{date}"

[flashlight]
suggestion_count = 10
precedence_alive_bonus = 10

[flashlight.aliases]
# "!g" = "!google"
# "@ft" = "@firefox.tabs"

[flashlight.precedence]
# tmux = 200
# "firefox.tabs" = 120

[mode]
labels = { normal = "N", insert = "I", command = "C" }

[mode.all.mappings]
# "ctrl+space" = ["flash", "mouse_target"]
# "ctrl+alt+n" = ["flash", "enter_normal_mode"]

[mode.normal]
leader = "\\"

[mode.normal.mappings]
"<leader>c" = ["../../scripts/toggle_caffeinate.sh"]
"h" = ["flash", "scroll_left"]
"j" = ["flash", "send_key", "--keys=down"]
"k" = ["flash", "send_key", "--keys=up"]
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
"g1" = ["flash", "tab_select", "--index=1"]
"g2" = ["flash", "tab_select", "--index=2"]
"g3" = ["flash", "tab_select", "--index=3"]
"g4" = ["flash", "tab_select", "--index=4"]
"g5" = ["flash", "tab_select", "--index=5"]
"g6" = ["flash", "tab_select", "--index=6"]
"g7" = ["flash", "tab_select", "--index=7"]
"g8" = ["flash", "tab_select", "--index=8"]
"g9" = ["flash", "tab_select", "--index=9"]
"i" = ["flash", "enter_insert_mode"]
"I" = ["flash", "enter_locked_insert_mode"]
"f" = ["flash", "mouse_target"]
"sf" = ["flash", "mouse_target", "--secondary"]
"df" = ["flash", "mouse_target", "--double"]
"mf" = ["flash", "mouse_target", "--move"]
"F" = ["flash", "mouse_grid"]
"sF" = ["flash", "mouse_grid", "--secondary"]
"dF" = ["flash", "mouse_grid", "--double"]
"mF" = ["flash", "mouse_grid", "--move"]
"u" = ["flash", "app_undo"]
"ctrl-r" = ["flash", "app_redo"]
"e" = ["flash", "resource_archive"]
"x" = ["flash", "tab_close"]
"n" = ["flash", "window_new"]
"t" = ["flash", "tab_new"]
"/" = ["flash", "app_find"]
"<leader>space" = ["flash", "enter_command_mode", "--input=:flashlight"]
"r" = ["flash", "app_reload"]
"R" = ["flash", "app_reload", "--force"]
"?" = ["flash", "help_show"]
":" = ["flash", "enter_command_mode"]

[mode.insert.mappings]
# advanced mode is enabled only by binding ["flash", "enter_normal_mode"] in [mode.all.mappings]

[debug]
log_level = "info"
# show_hints_bounds = false
# hints_bounds_bg = "#00000000"
# hints_bounds_fg = "#FF3B9A"
# http_inspector_enabled = false
# http_inspector_host = "localhost"
# http_inspector_port = 4242
```

`[mode] labels` controls the mode text available to status-bar templates. `[statusbar]` controls the bar format with a single `template` string that uses tmux-style alignment markers — `#[align=left]`, `#[align=centre]` (or `#[align=center]`), `#[align=right]` — to switch which region subsequent text or variables land in. Default region is left. Style markers like `#[fg=colour245]` stay in whatever region the parser is currently filling. Templates can read Flash state (`#{mode}`, `#{active_app_name}`, `#{active_bundle_identifier}`, `#{date}`), tmux-compatible variables (`#H`, `#h`, `#S`, `#{host}`, `#{hostname}`, `#{host_short}`, `#{user}`, `#{uid}`, `#{pid}`, and other tmux status variables, which render as an empty string when Flash has no equivalent), plugin state (`#{plugin:ready_count}`), plugin status segments (`#{plugin:system.battery}`), scripts (`#{script:~/bin/status.sh}`), or shell commands (`#{command:pmset -g batt}`). Triple-quoted TOML multi-line templates may span rows; Flash ignores newlines before rendering, e.g. `template = """\n  #[align=left]#{mode}\n  #[align=center]#{active_app_name}\n  #[align=right]#{plugin:system.battery}#[fg=colour245] · #{date}\n  """`. `[mode.all.mappings]` applies in insert and normal modes. `[mode.normal]` holds normal-mode options such as `leader = "\\"`. `[mode.normal.mappings]` extends the built-in normal-mode map and overrides only matching keys. `[mode.insert.mappings]` applies only in insert mode. Every mapping value is a string array. Arrays whose head is `"flash"` or a path whose basename is `"flash"` are in-process verb dispatches (`["flash", "<verb>", "--key=value", "--flag", …]`); any other head is executed directly as argv with `~`/env expansion on each element (no shell wrap). Relative argv paths containing `/` resolve from the config file location.

When a `[mode.all.mappings]` mapping points to `["flash", "enter_normal_mode"]`, Flash shows the persistent status bar and starts in normal mode. The bar uses the screen's native reserved top-band height, falling back to the measured native menu-bar reveal height when macOS folds that reservation away. It stays below the native macOS menu/status bar reveal, insets content away from rounded screen corners, and uses Nord colors. Mode, focused-app, plugin status, and date changes re-render from their own change sources; command-backed status sections are polled only when the template contains them and keep their previous value until a replacement is ready. While the bar is enabled, Flash keeps the macOS top-band reservation in place and the `window_move` verb slots/remaps windows inside that reserved usable frame. `[mode.normal.mappings]` and `[mode.insert.mappings]` mappings do not enable advanced mode. Without an advanced-mode mapping, the status bar is hidden and Flash behaves as a direct action launcher unless `["flash", "enter_normal_mode"]` is invoked manually.

`[flashlight] suggestion_count` controls how many rows the command bar shows; the default is `10`. `[flashlight.aliases]` rewrites completed query tokens such as `"!g" = "!google"` or `"@ft" = "@firefox.tabs"`. The default flashlight pool is intentionally location-only: apps, tabs, tmux windows, Slack channels, and plugin-provided locations. Other sources stay hidden unless the query includes an explicit `@source` filter such as `@emojis.glyphs` or `@notes.notes`. Source descriptors declare a generalized `priority` (`background`, `low`, `normal`, `high`, `critical`) used as a same-tier tiebreaker; `[flashlight.precedence]` can still override individual source labels for location rows or explicit `@source` result sets, and `precedence_alive_bonus` nudges running candidates ahead of inactive rows from the same source.

`[plugins] third_party` accepts `github:user/project@<commit-sha>` and `file:<path>` entries. GitHub references must pin a full 40-character commit SHA — moving branches and tags are rejected because a third-party plugin's `install` / `start` scripts run as the user, and a silent upstream update would land arbitrary code on every config reload. `[plugins] disabled = ["defaults"]` keeps matching bundled or third-party plugin ids unloaded; `defaults` owns built-in plugin-layer defaults such as `app_save`, `app_print`, `document_open`, and `window_new`. Every plugin has a `manifest.json` with `id`, `name`, `version`, `description`, `install`, `start`, optional `listen` event patterns, root active-window selectors (`only_bundle_ids`, `only_urls`), and provider registrations such as `sources` descriptors (`name`, generalized `kind`, generalized `priority`), `status.segments`, `commands.items`, `mappings.items`, `source_actions`, `navigation.schemes`, `verbs.items`, and optional `hints`. Flash loads manifests eagerly and preindexes commands, mappings, bangs, verbs, source descriptors, source actions, schemes, event listeners, and selector specificity so runtime dispatch matches against prepared tables instead of walking raw manifests. The `:plugins` modal shows those manifest registration totals above the per-plugin runtime status table. Runtime values still travel over the managed MessagePack channel: candidate providers keep their locations warm in memory, status segments publish `status.updated` notifications that templates read as `#{plugin:<id>.<segment>}`, and candidates / command responses / source-action responses may include `navigation_url` to record a durable movement-history route. Flash runs plugin commands as managed child processes over length-prefixed MessagePack on stdin/stdout: a 4-byte big-endian payload length followed by a MessagePack value; stderr is reserved for unexpected errors. Official bundled plugins install their CLIs under `FLASH_PLUGIN_DATA_DIR`, and include `:spotify`, `:slack`, `:media`, `:system`, and `:screenshot` commands with explicit subcommands. The `system` plugin controls macOS through subcommands such as `:system lock`, `:system restart`, `:system shutdown`, and `:system logout`; its action picker is available through `:flashlight @system.actions`. The `screenshot` plugin drives macOS's native Screenshot shortcuts through System Events (`:screenshot selection`, `:screenshot window_clipboard`, etc.) and does not read pixels inside Flash; mappings should use `["flash", "plugin_command", "--command=screenshot", "--subcommand=selection"]`. The `gmail` plugin applies only to focused `mail.google.com` browser tabs: it maps fixed Gmail `g...` go-to destinations (`gi`, `gs`, `gb`, `gt`, `gd`, `ga`, `gk`, `gl`) to current-tab navigation that does not create a tab, full-reload Gmail, or require Gmail keyboard shortcuts; Safari and Chromium-family browsers set the page hash, while Firefox AX-focuses the existing address bar and submits the target URL through Flash-owned synthetic text input without using Cmd-L or typing into the page. It maps `gn`/`gp` to browser history forward/back like `L`/`H`, maps `o` by sending Gmail's native open-selected-email shortcut, and maps `resource_archive`, `resource_next`, and `resource_previous` on Gmail thread pages to Gmail's accessible toolbar buttons. A plugin command may ask Flash to raise a window by returning a `target_pid`; when it also returns `navigation_url`, Flash records that route into the `ctrl-o` / `ctrl-i` movement history and restores it through the plugin that registered the route's scheme. The tmux plugin uses this for jump-to commands: `:tmux session <name>` and `:tmux window <session:index>` switch the active tmux client, bring its terminal forward, and record `tmux://...` routes, so you can bind a hotkey such as `["flash", "plugin_command", "--command=tmux", "--subcommand=window", "--args=main:1"]`.

The bundled Slack candidate source (`@slack.channels`) reads Slack's local app storage for channel ids/names and falls back to the live Accessibility sidebar for currently visible rows. ID-backed rows open through `slack://channel?...` deep links instead of typing into Slack's search box, and current/unread/starred rows use the shared same-score priority enum. Flash does not expect users to paste Slack tokens and does not extract Slack's own app tokens; an explicit `[plugin.slack] api_token` / `SLACK_API_TOKEN` remains an optional override for workspaces where local desktop storage is incomplete. If Slack is installed with a nonstandard profile location, set `[plugin.slack] data_dir = "/path/to/Slack"` to point at the directory that contains Slack's `IndexedDB`, `Local Storage`, `Session Storage`, and `WebStorage` folders.

Normal mode supports counts such as `10u` and `2[t`, `gg` / `G` for instant top/bottom scrolling, `j` / `k` for native down/up arrow keystrokes, `g1` through `g9` for environment-specific indexed selection, source-owned `r` / `R` reloads for browsers and tmux, source-owned `t` new tabs/windows for browsers and tmux, `e` for source-owned archive actions such as Gmail archive, `[h` / `]h` for target page history, `[t` / `]t` for tab previous/next, `[a` / `]a` for app previous/next (MRU), `ctrl-o` / `ctrl-i` for Flash movement history, command-line mode with `:`, and `?` for help. While Flash owns normal-mode keyboard capture, delivered key events are hermetic: mapped chords dispatch Flash commands, pending sequence prefixes wait for `sequence_timeout_ms`, and unmapped/dead-key/modified events are consumed rather than forwarded to the focused app. If macOS stops making the overlay the key window, Flash treats that as capture loss and retries; it does not switch modes for that recovery path. Movement history prefers plugin-emitted route URLs when present, so a tmux-window jump restores the tmux window rather than only reactivating Terminal. App switches and focused-window changes also feed movement history with the current location when a source can identify it. Command-line forms include `:help [topic]`, `:q[uit]`, `:q[uit]!`, `:w[rite]`, `:p[rint]`, `:e[dit]`, `:open`, `:open <query>`, `:flashlight`, `:flashlight <query>`, `:plugins`, `:<plugin-command> <subcommand> [args...]`, `:new`, `:tabnew`, `:bd[elete]`, `:cl[ose]`, `:find`, `:u[ndo]`, `:red[o]`, `:y[ank]`, `:d[elete]`, `:pu[t]`, and `:%y[ank]`. `:open <query>` and `:flashlight <query>` show typo-tolerant location results below the centered command line: apps, tabs, tmux windows, Slack channels, and plugin-provided locations. Other sources are hidden unless the query includes an explicit source selector such as `@emojis.glyphs fire` or `@notes.notes inbox`. Opening the surface seeds one immutable list from warmed app caches and the plugins' warm in-memory locations. That visible list is immutable until the surface closes, so later plugin responses or background refreshes affect only the next open and never reshuffle rows under the cursor. Use arrows or shift-tab to cycle; location rows are final destinations, so tab or return submits them like command-return. For other rows, tab inserts the selected candidate without opening, return inserts or opens when the result is a source-owned finisher or exact primary-title match, and command-return force-opens real candidates. Synthetic `[source] @...` rows are insert-only for tab, return, and command-return. Command and sub-command suggestions (`:help <topic>`, `:plugins <sub>`, `:<plugin-command> <subcommand>`) are separate: each candidate has a visible cosmetic label and an underlying value, `<tab>` inserts the value without sending so you can keep typing arguments, `<CR>` inserts the value and submits only for terminal/plugin-subcommand completions, and arrows / shift-tab cycle the selection. Source candidates follow the `{ source, name, url }` contract, and `url` is openable whenever present; app URLs are absolute `file://` URLs to the `.app` bundle. `[open] ignored_apps = ["Flash", "com.flash.app"]` hides matching app candidates from `:open`, `:flashlight`, and the `app_open` verb.

Setting `[debug] http_inspector_enabled = true` starts a loopback-only single-page debug view with live logs, resolved config, focused app state, and plugin state. The host (`http_inspector_host`) is restricted to `localhost` / `127.0.0.1` / `::1`; the default port is `4242`. Every log line carries a `source` field such as `core:AppDelegate.swift.activate(...)` or `plugin:spotify`.

Flash stays in normal mode until the user presses `i`, presses `I` for locked insert mode, uses a mapped command that intentionally opens a typing surface such as `t` (`tab_new`) or `/` (`app_find`), or clicks an editable/terminal target physically or through an `f` / `F` mouse hint. Hint clicks may include configured modifier passthrough, right-clicks, or double-clicks; they are treated as explicit mouse interactions by the user. Physical clicks are replayed so they reach the underlying app. A physical or hinted primary click enters insert mode only for terminal apps or after the post-click Accessibility check confirms the focused element is editable; right-clicks release capture for context menus without using that insert-entry probe. Passive focus changes, app focus requests, menu-bar clicks, and status-bar popups do not switch to insert mode while advanced normal mode is active. Plain insert entry (`i`, `I`, command-line restore, or mapped commands such as `t` / `/`) does not search for and focus a nearby text field; Flash only attempts a single-strong-editable focus repair after a pointer or hint handoff has already identified an editable target. Once Flash is in insert mode, switching away from the app that owned INSERT returns to normal mode. For focus changes inside the same app, a short post-entry Accessibility check arms generic focus-loss exit only when the app has an editable focused element; after that, a focused-element or focused-window change returns to normal mode when Accessibility no longer reports an editable focused element. If a mouse button is held, Flash waits until release and re-checks so text selection is not interrupted. Browser `t` opens a new tab, enters insert for the location field, then returns to normal after the document URL changes to a committed `http` / `https` page. Locked insert mode skips those automatic focus and navigation exits; it stays in insert mode until `enter_normal_mode` is invoked, usually through the user's Escape mapping. Value changes while typing do not trigger the generic focus-loss probe.

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
- **Verbs are canonical.** Mapping config arrays (`["flash", "<verb>", "--key=value"]`), the `flash` CLI, and the resident's custom AppleEvent (class `Flsh`, ID `Cmd `) all resolve through the same in-process verb dispatch table.
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
