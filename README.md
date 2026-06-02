# Flash

System-wide vimium-style "find and jump" for macOS. Triggered by an external tool (Karabiner / skhd / Hammerspoon / etc.), Flash overlays hint labels on clickable elements in the focused app and lets you click them by typing a 1–3 character hint.

## Build

```bash
./Scripts/bundle.sh
mv build/Flash.app /Applications/
```

Open it once so macOS knows where it lives:

```bash
open /Applications/Flash.app
```

Then in *System Settings → Privacy & Security*:

- **Accessibility** — required. Toggle Flash on.
- **Automation → Safari / Chrome** — only needed for the browser DOM hints.

> **Heads up on rebuilds**: every `./Scripts/bundle.sh` replaces the binary in `/Applications/Flash.app`. macOS keys TCC grants (Accessibility) to the ad-hoc-signed binary's hash, so the script also runs `tccutil reset` for the bundle id — meaning you re-grant once per rebuild and the grant binds to the new binary.

## Triggers

Flash registers the `flash://` URL scheme. Anything that can run a shell command can trigger it:

```bash
open -g flash://activate           # show hints; on commit, left-click
open -g flash://activate?right=1   # show hints; on commit, right-click
open -g flash://cancel             # dismiss the overlay
open -g flash://quit               # quit the app
```

`-g` keeps focus on the target app — Flash will only briefly steal it to perform the click and then return.

### Karabiner-Elements

```json
{ "type": "basic",
  "from": { "key_code": "f", "modifiers": { "mandatory": ["left_control","left_option"] } },
  "to":   [{ "shell_command": "open -g flash://activate" }] }
```

### Hammerspoon

```lua
hs.hotkey.bind({"ctrl", "alt"}, "f", function() hs.urlevent.openURL("flash://activate") end)
hs.hotkey.bind({"ctrl", "alt", "shift"}, "f", function() hs.urlevent.openURL("flash://activate?right=1") end)
```

### skhd

```
ctrl + alt - f : open -g flash://activate
ctrl + alt + shift - f : open -g flash://activate?right=1
```

## Configuration

`~/.config/flash/config.toml` — edits hot-reload, no restart needed.

```toml
[hints]
# Either a preset token in <angle brackets> or a literal character string.
keys = "<qwerty>"             # or "<colemak>", "<dvorak>", or e.g. "asdfghjkl"
min_length = 1
# Which apps' controls get hinted on activation:
#   "active_app"     — only the focused app (default, fastest)
#   "active_monitor" — every visible app on the focused monitor
#   "everywhere"     — every visible app on every monitor
scope = "active_app"

[overlay]
font_size = 14
hint_bg = "#FFD400"
hint_fg = "#1B1B1B"
exit_key = "escape"

[debug]
show_bounds = false
bounds_bg = "#00000000"       # transparent fill
bounds_fg = "#FF3B9A"         # pink stroke around each detected rect
profile = false               # log every activation/precompute timing trace
slow_ms = 100                 # log activations at/above this latency; 0 disables
```

Debug logs are written to stderr. In the installed app, check `~/Library/Logs/Flash/`.

## Architecture

Flash is one resident, headless macOS app:

- **No menu bar, no Dock icon, no preferences UI.** Only the transparent hint overlay.
- **No global keyboard hooks.** Activation always comes through the `flash://` URL scheme. Hint typing only happens inside the overlay window via standard `NSWindow` `keyDown`.
- **Precomputes targets continuously.** Subscribes to `NSWorkspace` + per-app `AXObserver` notifications so the hint set is ready before you ask.
- **Provider chain** per app: Safari/Chrome DOM bridge (Vimium-style `do JavaScript` discovery — exact DOM rects, priority 30) → generic `AccessibilityProvider` (priority 10, every native app and Firefox's in-page DOM via `AXWebArea` descendants). When the browser script bridge is unavailable (Automation denied, "Allow JavaScript from Apple Events" off), the AX walker fills in via dedup.
- **Multi-app scope.** With `hints.scope ≠ active_app`, Flash walks every relevant app and tags each `JumpTarget` with the owning pid so the commit step activates the right process before clicking.

Public SPI lives in `FlashCore` (`JumpProvider`, `JumpTarget`, `AppContext`, `JumpAction`). Add a new provider by implementing the protocol and registering it in `Sources/flash/App/ProviderRegistry.swift`.

## Develop

```bash
swift build
swift test
```

## License

MIT (see `LICENSE` if added).
