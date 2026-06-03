# Flash

[![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml)

System-wide vimium-style "find and jump" for macOS. Triggered by an external tool (Karabiner / skhd / Hammerspoon / etc.), Flash overlays hint labels on clickable elements in the focused app and lets you click them by typing a 1–3 character hint.

## Build

```bash
./Scripts/install.sh
```

Open it once so macOS knows where it lives:

```bash
open /Applications/Flash.app
```

Then in *System Settings → Privacy & Security*:

- **Accessibility** — required. Toggle Flash on.

> **Heads up on rebuilds**: every `./Scripts/install.sh` replaces the binary in `/Applications/Flash.app`. macOS keys TCC grants (Accessibility) to the ad-hoc-signed binary's hash, so the script also runs `tccutil reset` for the bundle id — meaning you re-grant once per rebuild and the grant binds to the new binary.

## Triggers

Flash registers the `flash://` URL scheme. Anything that can run a shell command can trigger it:

```bash
open -g flash://show_hints           # show hints; on commit, left-click
open -g flash://show_hints?right=1   # show hints; on commit, right-click
open -g flash://dismiss_hints        # dismiss the overlay
open -g flash://quit                 # quit the app
```

`-g` keeps focus on the target app — Flash will only briefly steal it to perform the click and then return.

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
exit_key = "<escape>"      # special keys wrapped in <>; or a single literal char like "q"

[debug]
show_bounds = false
bounds_bg = "#00000000"       # transparent fill
bounds_fg = "#FF3B9A"         # pink stroke around each detected rect
profile = false               # log every activation/precompute timing trace
slow_ms = 100                 # log activations at/above this latency; 0 disables
dump_ax = false               # dump AX tree to ~/Library/Logs/Flash/ax-dump.log per activation
dump_logs = false             # mirror stderr diagnostics to ~/Library/Logs/Flash/flash.log
```

Performance behaviours (prepared AX model, concurrent subtree walk,
parallel deferred action-name IPC) are always on and not user-configurable.

Debug logs are written to stderr. In the installed app, check `~/Library/Logs/Flash/`.

## Architecture

Flash is one resident, headless macOS app:

- **No menu bar, no Dock icon, no preferences UI.** Only the transparent hint overlay.
- **No global keyboard hooks.** Activation always comes through the `flash://` URL scheme. Hint typing only happens inside the overlay window via standard `NSWindow` `keyDown`.
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

## License

MIT (see `LICENSE` if added).
