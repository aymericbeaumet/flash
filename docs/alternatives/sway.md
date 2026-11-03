# Flash and sway

[sway](https://swaywm.org) "is a tiling Wayland compositor and a drop-in
replacement for the i3 window manager for X11": i3's tree, binding modes,
workspaces and criteria, on its own compositor, with keyboards, touchpads
and displays configured in the same file. It is MIT C built on wlroots, for
Linux and FreeBSD, about 17,500 stars, 1.12 in May 2026 (window capture,
HDR10 with the Vulkan renderer). It does not run on macOS. Flash's opt-in
[tiling](../tiling.md) and [layers](../layers.md) cover the i3 half of a sway
config, as the [i3 page](i3.md) maps line by line; this page is about the
rest, the part that was a compositor's job.

| | sway | Flash |
| --- | --- | --- |
| License, price | MIT, free | MIT, free |
| Platforms | Wayland on Linux and FreeBSD | macOS 13+ |
| Windows | i3's tree and workspaces, drawn by sway itself | Opt-in tree over macOS windows, moved through Accessibility; emulated workspaces |
| Input | `input` blocks: xkb layouts and options, repeat, touchpad, per device | `defaults write` lines in `[startup] run` for repeat and the trackpad; layouts stay in System Settings |
| Outputs | `output` blocks: mode, position, scale, transform, background, colour profile | None; System Settings › Displays |
| Gestures, switches | `bindgesture`, `bindswitch` | None bound; `mouse gesture` performs one |
| Configuration | i3's syntax plus sway's; `swaymsg reload` | TOML, live reload on save |
| Maintenance | 1.12, May 2026; active | 1.1.0, October 2026 |

## Where sway is stronger

- **It is the compositor.** sway draws every surface: borders and title
  bars, per-output scale and colour profiles, HDR10, and since 1.12 the
  capture of a single window. No macOS app can do that to other apps'
  windows: WindowServer composites them all, and Flash reads no pixels.
- **Input and outputs in one file.** `xkb_options`, repeat, tap and natural
  scrolling per device type or per device, and every display's mode and
  position, in the same config as the keys. On a Mac the displays belong to
  System Settings, and remapping a key below the apps needs Karabiner-Elements'
  DriverKit driver ([Karabiner-Elements](karabiner-elements.md)).
- **Gestures and switches are bindings.** `bindgesture swipe:right workspace
  prev` and `bindswitch lid:…` run sway commands. macOS keeps the trackpad's
  three- and four-finger swipes for its own Spaces, and Flash binds no
  gesture.
- **Your i3 config runs as it is.** Flash needs it rewritten into TOML.
- **Idle inhibition per window.** `inhibit_idle` follows a window's focus,
  visibility or full screen; Flash's `caffeinate` is on or off for the
  whole Mac.

## Where Flash is stronger

- **The preferences sway kept in its config stay in one file.**
  `[startup] run` writes key repeat, the trackpad, the Dock and window
  animations with `defaults write` each time Flash starts
  ([startup commands](../startup.md)).
- **Bindings survive a non-Latin input source.** Mappings are read by key
  position on `[app] keyboard_layout`, so a Russian or Greek source keeps
  every chord working, which is what `bindsym --to-code` does for sway.
- **Reach inside the windows.** sway places windows; Flash also clicks in
  them (`mouse target`), scrolls them and switches their tabs in browsers,
  Finder and tmux, with the same keys in every app.
- **Prompts without a helper.** `system logout`, `system shutdown` and
  `system restart` ask in the centred alert, and `alert confirm` wraps any
  command, where sway calls out to swaynag.

## Flash features you might like

- `[mode.all.mappings]` chords work in every app, with Flash's modes on or
  off; NORMAL and layers are opt-in.
- [Monitors](../monitors.md#runs-and-events) on `core:user.idle`,
  `core:screen.locked` and `core:displays.changed` replace the
  `exec swayidle …` line and the scripts on output hotplug.
- `#{flash.workspaces}` in a [bar](../statusbar.md) that reads waybar
  scripts with `output = "waybar"`.
- `flash resident status --json` names the focused app's bundle ID, the
  `swaymsg -t get_tree` lookup for an `app_id`.

## Moving from sway

The bindings, rules and workspaces map as on the [i3 page](i3.md). The
sway-only lines:

| sway | Flash |
| --- | --- |
| `input type:keyboard repeat_delay 250`, `repeat_rate 30` | `defaults write NSGlobalDomain InitialKeyRepeat -int 15` and `KeyRepeat -int 2` (1/60 s ticks) in `[startup] run`, applied at the next login |
| `input type:keyboard xkb_layout us,de` | Input sources in System Settings; Flash reads keys on `[app] keyboard_layout` and places hint keys by `[keyboard] layout` |
| `xkb_options caps:escape` | System Settings › Keyboard › Keyboard Shortcuts › Modifier Keys, or Karabiner-Elements for tap and hold |
| `input type:touchpad tap enabled`, `natural_scroll enabled` | `defaults write` of `Clicking` in both trackpad domains and of `com.apple.swipescrolldirection`, below |
| `output HDMI-A-1 scale 2 position 1920,0`, `output * bg …` | System Settings › Displays and Wallpaper |
| `bindsym --to-code` | The default: keys are read by position |
| `for_window [app_id="pavucontrol"] floating enable` | `[[tiling.rules]]` with the app's `bundle_id` and `float = true` |
| `for_window [app_id="mpv"] inhibit_idle focus` | A monitor on `core:focus.changed` with `app =`, running `caffeinate on` |
| `bindsym $mod+Shift+e exec swaynag -t warning … 'swaymsg exit'` | `system logout`, which asks first |
| `bindgesture`, `bindswitch lid:on …` | No binding; macOS decides what the lid does, and a monitor on `core:displays.changed` runs what should follow |
| `exec swayidle -w timeout 300 'swaylock -f'` | A monitor on `core:user.idle`; see [swayidle](swayidle.md) |
| `bar { swaybar_command waybar }` | `[statusbar]`; see [waybar](waybar.md) |
| `swaymsg reload`, `swaymsg workspace 2` | Saving the file (or `flash config reload`), `flash workspace switch --name=2` |

```toml
[startup]
run = [
  # Key repeat in 1/60 s ticks: 250 ms, then 33 ms. Next login.
  ["defaults", "write", "NSGlobalDomain", "InitialKeyRepeat", "-int", "15"],
  ["defaults", "write", "NSGlobalDomain", "KeyRepeat", "-int", "2"],
  # Tap to click, for built-in and Bluetooth trackpads.
  ["defaults", "write", "com.apple.AppleMultitouchTrackpad", "Clicking", "-bool", "true"],
  ["defaults", "write", "com.apple.driver.AppleBluetoothMultitouch.trackpad", "Clicking", "-bool", "true"],
  ["/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", "-u"],
  # Natural scrolling. Next login.
  ["defaults", "write", "NSGlobalDomain", "com.apple.swipescrolldirection", "-bool", "true"],
]

[tiling]
enabled = true

[[tiling.rules]]
bundle_id = "com.apple.ActivityMonitor"
float = true

# inhibit_idle focus, for one player
[monitors.player_awake]
event = "core:focus.changed"
app = "com.apple.QuickTimePlayerX"
run = ["flash", "caffeinate", "on", "--minutes=120"]

# what an output hotplug script did
[monitors.docked]
event = "core:displays.changed"
run = ["~/bin/arrange-for-dock"]

[mode.all.mappings]
"alt+shift+e" = ["flash", "system", "logout"]
"alt+shift+c" = ["flash", "config", "reload"]
```

*Checked 2026-10-23 against [swaywm.org](https://swaywm.org), the sway
[README](https://github.com/swaywm/sway) and
[1.12 release notes](https://github.com/swaywm/sway/releases/tag/1.12), and
the [sway(5)](https://man.archlinux.org/man/sway.5.en) and
[sway-input(5)](https://man.archlinux.org/man/sway-input.5.en) man pages.*
