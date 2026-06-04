# Flash

[![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml)

System-wide vimium-style "find and jump" for macOS. Triggered by the `flash://` URL scheme or native shortcuts configured in `config.toml`, Flash overlays hint labels on clickable elements in the focused app and lets you click them by typing a 1–3 character hint.

## Build

```bash
./Scripts/install-release.sh
```

Open it once so macOS knows where it lives:

```bash
open /Applications/Flash.app
```

Then in *System Settings → Privacy & Security*:

- **Accessibility** — required. Toggle Flash on.

> **Heads up on rebuilds**: `./Scripts/install-release.sh` signs Flash with the stable local "Flash Dev" identity, installs `/Applications/Flash.app`, registers login autolaunch through `~/Library/LaunchAgents/com.flash.app.autolaunch.plist`, and starts the resident app. The first run with that identity may require re-granting Accessibility; later rebuilds should keep the grant.

## Triggers

Flash registers the `flash://` URL scheme. Anything that can run a shell command can trigger it:

```bash
open -g flash://show_hints           # show hints; on commit, left-click
open -g flash://show_hints?right=1   # show hints; on commit, right-click
open -g flash://dismiss_hints        # dismiss the overlay
open -g flash://quit                 # quit the app
```

`-g` keeps focus on the target app — Flash will only briefly steal it to perform the click and then return.

Flash can also register native hotkeys from `[shortcuts]` in `config.toml`. Use `flash://...` string values for fast in-process commands, or an argv array for commands that need a process spawn.

### Karabiner-Elements

```json
{ "type": "basic",
  "from": { "key_code": "f", "modifiers": { "mandatory": ["left_control","left_option"] } },
  "to":   [{ "shell_command": "open -g flash://show_hints" }] }
```

### Hammerspoon

```lua
hs.hotkey.bind({"ctrl", "alt"}, "f", function() hs.urlevent.openURL("flash://show_hints") end)
hs.hotkey.bind({"ctrl", "alt", "shift"}, "f", function() hs.urlevent.openURL("flash://show_hints?right=1") end)
```

### skhd

```
ctrl + alt - f : open -g flash://show_hints
ctrl + alt + shift - f : open -g flash://show_hints?right=1
```

## Configuration

`~/.config/flash/config.toml` — edits hot-reload, no restart needed.

```toml
[hints]
# Either a preset token in <angle brackets> or a literal character string.
keys = "<qwerty>"             # or "<colemak>", "<dvorak>", or e.g. "asdfghjkl"
min_length = 1

[overlay]
font_size = 12               # vimium-style small bold label
hint_fg = "#302505"
hint_bg_top = "#FFF785"      # gradient top stop
hint_bg_bottom = "#FFC542"   # gradient bottom stop (set equal to top for flat fill)
hint_border = "#E3BE23"

[debug]
show_bounds = false
bounds_bg = "#00000000"       # transparent fill
bounds_fg = "#FF3B9A"         # pink stroke around each detected rect
profile = false               # log every activation/precompute timing trace
slow_ms = 100                 # log activations at/above this latency; 0 disables
dump_ax = false               # dump AX tree to ~/Library/Logs/Flash/ax-dump.log per activation
dump_logs = false             # mirror stderr diagnostics to ~/Library/Logs/Flash/flash.log
log_level = "info"            # debug | info | warn | error

[shortcuts]
# Examples:
# "ctrl+space" = "flash://show_hints"
# "cmd+ctrl+a" = "flash://open_app?name=Alacritty"
# "alt+h" = "flash://move_window?position=lefthalf"
# "cmd+ctrl+g" = ["open", "https://github.com"]
```

Performance behaviours (prepared AX model, concurrent subtree walk,
parallel deferred action-name IPC) are always on and not user-configurable.

Debug logs are written to stderr. In the installed app, check `~/Library/Logs/Flash/`.

## Architecture

Flash is one resident, headless macOS app:

- **No menu bar, no Dock icon, no preferences UI.** Only the transparent hint overlay.
- **No arbitrary global key capture.** Native shortcuts use Carbon `RegisterEventHotKey` only for explicit `[shortcuts]` entries. No event taps or Input Monitoring. Hint typing only happens inside the overlay window via standard `NSWindow` `keyDown`.
- **AX-event-driven prepared model.** Subscribes to `NSWorkspace` focus + per-app `AXObserver` notifications. On any observed change, an 80-ms-debounced AX model rebuild runs in the background, then a maintenance refresh keeps the focused app warm while it remains quiet. On `show_hints`, native AX-backed hints are delivered immediately when the prepared model token, config revision, and freshness window still match.
- **Concurrent AX walking.** When a prepared model is unavailable, `AccessibilityProvider` fans out the focused window's direct children across `DispatchQueue.concurrentPerform` workers so multiple AX IPCs are in flight against the target app's main thread at once. No per-IPC AX timeout is set.
- **Provider chain** per app: `TmuxProvider` (priority 20, terminals with a tmux client in the process subtree — pane content isn't AX-clickable) → generic `AccessibilityProvider` (priority 10, every native app and browser in-page DOM via `AXWebArea` descendants).
- **Active-window only.** Flash always walks the focused application; background apps and other monitors are ignored.

Public SPI lives in `FlashCore` (`JumpProvider`, `JumpTarget`, `AppContext`, `JumpAction`). Add a new provider by implementing the protocol and registering it in `Sources/flash/App/ProviderRegistry.swift`.

## Develop

```bash
swift build
swift test
```

Browser parity coverage lives behind the signed integration runner:

```bash
./Scripts/test-integration-browser.sh --setup-only
./Scripts/test-integration-browser.sh              # 100 local snapshots, parallel by default
./Scripts/test-integration-browser.sh --jobs 4
./Scripts/test-integration-browser.sh --fixture baseline-synthetic-001
```

The browser runner provisions a Firefox profile template with pinned
Vimium-FF, copies that template per worker, drives Firefox through
Marionette, and compares Vimium's marker DOM with Flash's AX-derived
targets. The fixture corpus is offline under `Tests/BrowserSnapshots`.

## License

MIT (see `LICENSE` if added).
