# Flash

[![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml)

System-wide hint-driven find and jump for macOS. Flash is a resident, headless app: it overlays hint labels on clickable elements in the focused app, then clicks or focuses the selected target when you type its hint.

## Build

```bash
./Scripts/install-release.sh
```

Open it once so macOS knows where it lives:

```bash
open /Applications/Flash.app
```

Then grant **Accessibility** in *System Settings -> Privacy & Security -> Accessibility*.

`./Scripts/install-release.sh` signs Flash with the stable local "Flash Dev" identity, installs `/Applications/Flash.app`, registers login autolaunch through `~/Library/LaunchAgents/com.flash.app.autolaunch.plist`, starts the resident app, and installs `flash` / `flashctl` symlinks in `~/.local/bin`.

## Actions

Every action is available as `flash://...` and can be invoked with `open`, the CLI, or a configured mapping:

```bash
open -g flash://mouse_click
open -g flash://mouse_click?right=1
open -g flash://mouse_click?double=1
open -g flash://mode_normal
open -g flash://help_show
open -g flash://flash_quit

flash mouse_click
flash mode_normal
flash app_open name=Firefox
flash window_move position=lefthalf
flash help_show
```

Common actions include `flash://mouse_click`, `flash://mouse_click?right=1`, `flash://mouse_click?double=1`, `flash://mouse_move`, `flash://scroll_down`, `flash://scroll_half_page_up`, `flash://scroll_half_page_down`, `flash://scroll_top`, `flash://tab_next`, `flash://tab_previous`, `flash://tab_select`, `flash://tab_close`, `flash://app_back`, `flash://app_forward`, `flash://app_undo`, `flash://app_redo`, `flash://window_close`, `flash://app_find`, `flash://app_open_finder`, `flash://app_open_finder?all=1`, `flash://url_copy`, `flash://app_save`, `flash://app_save_and_quit`, `flash://app_print`, `flash://document_open`, `flash://window_new`, `flash://tab_new`, `flash://tab_new_insert`, `flash://clipboard_copy`, `flash://clipboard_cut`, `flash://clipboard_paste`, `flash://clipboard_copy_all`, `flash://app_open?name=<app>`, `flash://window_move?position=<slot>&screen=<n>`, `flash://hints_dismiss`, `flash://alert_dismiss`, and `flash://alert_show?message=<text>`.

## Configuration

`~/.config/flash/flash.toml` hot-reloads.

```toml
[hints]
keys = "<qwerty_homerow+qwerty_toprow>"
min_length = 1
magic_modifiers = ["cmd", "ctrl", "alt", "shift"]

[open]
ignored_apps = []

[mode]
labels = { normal = "N", insert = "I", command = "C" }

[mode.all]
# "ctrl+space" = "flash://mouse_click"
# "ctrl+alt+n" = "flash://mode_normal"

[mode.normal]
"h" = "flash://scroll_left"
"j" = "flash://scroll_down"
"k" = "flash://scroll_up"
"l" = "flash://scroll_right"
"ctrl-d" = "flash://scroll_half_page_down"
"ctrl-u" = "flash://scroll_half_page_up"
"gg" = "flash://scroll_top"
"G" = "flash://scroll_bottom"
"gt" = "flash://tab_next"
"gT" = "flash://tab_previous"
"gN" = "flash://tab_select"
"f" = "flash://mouse_click"
"rf" = "flash://mouse_click?right=1"
"df" = "flash://mouse_click?double=1"
"mf" = "flash://mouse_move"
"u" = "flash://app_undo"
"ctrl-r" = "flash://app_redo"
"x" = "flash://window_close"
"t" = "flash://tab_new_insert"
"/" = "flash://app_find"
"o" = "flash://app_open_finder?all=1"
"O" = "flash://app_open_finder?all=1"
"?" = "flash://help_show"
":" = "flash://mode_command"

[mode.insert]
# advanced mode is enabled only by binding flash://mode_normal in [mode.all]

[debug]
log_level = "info"
```

`[mode] labels` controls the mode-cell text; its width follows the longest configured label. `[mode.all]` applies in insert and normal modes. `[mode.normal]` extends the built-in normal-mode map and overrides only matching keys. `[mode.insert]` applies only in insert mode. Values must be `flash://...` actions.

When a `[mode.all]` mapping points to `flash://mode_normal`, Flash shows the persistent mode cell and starts in normal mode. `[mode.normal]` and `[mode.insert]` mappings do not enable advanced mode. Without an advanced-mode mapping, the mode cell is hidden and Flash behaves as a direct action launcher unless `flash://mode_normal` is invoked manually.

Normal mode supports counts such as `10u` and `2gT`, `ctrl-o` / `ctrl-i` movement history, command-line mode with `:`, and `?` for the mapping view. Command-line forms include `:q[uit]`, `:q[uit]!`, `:w[rite]`, `:p[rint]`, `:e[dit]`, `:open`, `:open <query>`, `:new`, `:tabnew`, `:bd[elete]`, `:cl[ose]`, `:find`, `:u[ndo]`, `:red[o]`, `:y[ank]`, `:d[elete]`, `:pu[t]`, and `:%y[ank]`. `:open <query>` shows typo-tolerant results above the command line across source-labelled results such as `[app] Firefox`, `[tmux] scratch gors`, `[firefox] Gmail (https://mail.google.com)`, and `[slack] #general`; use arrows or tab / shift-tab to select and return to open. `[open] ignored_apps = ["Flash", "com.flash.app"]` hides matching app candidates from `:open` and `flash://app_open?name=...`.

Flash stays in normal mode until the user presses `i`, or a committed `f` / `rf` / `df` hint targets editable input or tmux/terminal content. External `flash://mode_insert`, passive focus changes, app focus requests, menu-bar clicks, status-bar popups, and `flash://app_find` do not switch to insert mode while advanced normal mode is active.

## External Tools

Karabiner-Elements:

```json
{ "type": "basic",
  "from": { "key_code": "f", "modifiers": { "mandatory": ["left_control","left_option"] } },
  "to":   [{ "shell_command": "open -g flash://mouse_click" }] }
```

Hammerspoon:

```lua
hs.hotkey.bind({"ctrl", "alt"}, "f", function() hs.urlevent.openURL("flash://mouse_click") end)
```

skhd:

```text
ctrl + alt - f : open -g flash://mouse_click
```

## Architecture

Flash is one resident, headless macOS app:

- **No menu bar, Dock icon, or preferences UI.** The visible surfaces are the transparent hint overlay, the mode cell when configured, the mapping/help/app finder overlays, and explicit alert toasts.
- **No arbitrary global key capture.** Native modified-key mappings use Carbon `RegisterEventHotKey` only for explicit `[mode.*]` entries. No event taps or Input Monitoring. Hint and normal-mode typing happens inside the overlay window through standard `NSWindow` key handling.
- **URL actions are canonical.** Native mappings and the CLI resolve to the same `URLCommand` parser used by `flash://` AppleEvents.
- **AX-event-driven prepared model.** The focused app is pre-walked from Accessibility notifications and config revisions so `flash://mouse_click` can render from a fresh prepared model when available.
- **Source chain** per focused app: `TmuxProvider` for terminals running tmux, then generic `AccessibilityProvider` for native and web content exposed through Accessibility. Sources can also feed `:open`, app activation, document URL resolution, and source-owned tab actions.

Public SPI lives in `FlashCore` (`FlashSource`, `JumpTarget`, `AppContext`, `JumpAction`, and the `JumpProvider` compatibility alias). Add a source by implementing the protocol and registering a `SourceDescriptor` in `Sources/flash/App/SourceRegistry.swift`; choose an activation policy so sources are only loaded while the corresponding app class is running.

## Develop

```bash
swift build
swift test
./Scripts/install-release.sh
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
