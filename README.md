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
- **Screen Recording** — only needed if you opt-in to OCR for terminals / Electron apps. **Off by default**; see `[providers.vision]` below.
- **Automation → Safari / Chrome** — only needed for the browser DOM hints.

> **Heads up on rebuilds**: every `./Scripts/bundle.sh` replaces the binary in `/Applications/Flash.app`. macOS keys TCC grants (Accessibility, Screen Recording) to the ad-hoc-signed binary's hash, so you may need to re-grant after a rebuild. The bundle script tries to minimise this by signing with a stable identifier, but isn't perfect.

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
# Default: "<colemak>"
keys = "<colemak>"            # or "<qwerty>", "<dvorak>", or e.g. "asdfghjkl"
shift_means_right_click = true
min_length = 1

[overlay]
font_size = 14
hint_bg = "#FFD400"
hint_fg = "#1B1B1B"
dim_background = true
exit_key = "escape"

[providers]
disabled = []                 # disable by id, e.g. ["vision"]
deadline_ms_hot = 80
deadline_ms_cold = 150

[providers.vision]
# Opt-in OCR. Each bundle here means "use OCR for this app". The first time
# OCR runs you'll see a Screen Recording prompt — grant it and the app shows
# hints in terminals / Electron apps that don't expose AX.
# Default: [] (no OCR, no Screen Recording prompt).
enabled_for_bundles = []
# Examples:
# enabled_for_bundles = ["org.alacritty"]
# enabled_for_bundles = ["org.alacritty", "net.whatsapp.WhatsApp", "com.linear"]
```

## Architecture

Flash is one resident, headless macOS app:

- **No menu bar, no Dock icon, no preferences UI.** Only the transparent hint overlay.
- **No global keyboard hooks.** Activation always comes through the `flash://` URL scheme. Hint typing only happens inside the overlay window via standard `NSWindow` `keyDown`.
- **Precomputes targets continuously.** Subscribes to `NSWorkspace` + per-app `AXObserver` notifications so the hint set is ready before you ask.
- **Provider chain** per front app: bundle-specific (Safari, Chrome, Firefox, Messages, Notes, Reminders, Postico, Alacritty, WhatsApp, Linear) → generic `AccessibilityProvider` → `VisionProvider` (OCR) for opted-in bundles.

Public SPI lives in `FlashCore` (`JumpProvider`, `JumpTarget`, `AppContext`, `JumpAction`). Add a new provider by implementing the protocol and registering it in `Sources/flash/App/ProviderRegistry.swift`.

## Develop

```bash
swift build
swift test
```

## License

MIT (see `LICENSE` if added).
