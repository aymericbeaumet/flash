# How Flash compares, and FAQ

This is the one-screen summary. The [alternatives](alternatives/README.md)
pages take each tool in turn, with where it is stronger than Flash, where
Flash is stronger, and how to move a setup over.

| | License | Hints from | Also has | Flash adds |
| --- | --- | --- | --- | --- |
| [Neru](https://github.com/y3owk1n/neru) | MIT | Accessibility, optional OCR and contour detection | Grid, bisect, scroll mode, Linux and Windows | Accessibility only, normal mode with per-app commands, search, status bar, widgets, popups, plugins |
| [Homerow](https://www.homerow.app) | Paid, closed | Accessibility | Scroll, search | Free, configured in a file, everything past clicking |
| [Shortcat](https://shortcat.app) | Closed | Accessibility, by typing visible text | | `mouse target --search` does that, next to labels |
| [Scoot](https://github.com/mjrusso/scoot) | BSD-3 | Accessibility | Grid | Normal mode, terminal hints, search, plugins |
| [Vimac](https://github.com/nchudleigh/vimac) | GPL, unmaintained | Accessibility | Scroll | Homerow's open-source predecessor; Flash is maintained |
| Wooshy, Mouseless, Superkey | Paid | Accessibility or text seek | | Superkey's text seek needs Screen Recording; Flash does not; see [Wooshy](alternatives/wooshy.md), [Mouseless](alternatives/mouseless.md) and [Superkey](alternatives/superkey.md) |
| [Vimium](https://github.com/philc/vimium), Surfingkeys, Tridactyl, Vimium C, Vimari | MIT, Apache-2.0 | The DOM, in the browser | | Every app, no extension; see [Vimium](alternatives/vimium.md), [Surfingkeys](alternatives/surfingkeys.md), [Tridactyl](alternatives/tridactyl.md), [Vimium C](alternatives/vimium-c.md) and [Vimari](alternatives/vimari.md) |
| [Neverclick](https://www.neverclick.com) | Free, closed, Windows only | A screen capture | Path and sticky hints, word targets, target snapping, drag, text selection | The same tools from Accessibility, never a capture: path, sticky, words, adjust, drag and text selection; see [Neverclick](alternatives/neverclick.md) |
| [mousemaster](https://github.com/petoncle/mousemaster) | No license stated; Windows, and macOS as root | Accessibility, screen grids, a screen capture | Combos and remapping, continuous movement, position history, zoom | Pointer mode, display labels, warps and saved positions without root or a capture; remapping stays with Karabiner or kanata; see [mousemaster](alternatives/mousemaster.md) |
| [Hammerspoon](https://www.hammerspoon.org) | MIT | | Lua automation of everything | A ready-made keyboard layer in TOML; see [Hammerspoon](alternatives/hammerspoon.md). Hammerspoon can drive Flash with `flash <topic> <action>` |
| [SketchyBar](https://github.com/FelixKratz/SketchyBar) | GPL | | Scriptable bar | tmux formats, and one plugin feeds the bar, hints, search and widgets; see [SketchyBar](alternatives/sketchybar.md) |
| [Übersicht](https://github.com/felixhageloh/uebersicht), conky | GPL | | Web-view widgets; conky needs XQuartz | Native text widgets fed by the bar's collectors; see [Übersicht](alternatives/uebersicht.md) and [conky](alternatives/conky.md) |
| [iStat Menus](https://bjango.com/mac/istatmenus/), iStatistica, TG Pro | Paid, closed | | Menu-bar monitors with SMC sensors, fan control and notifications | Thresholds on any bar value in the same file, and btop in a popup; no sensors or fans, so keep them for those; see [iStat Menus](alternatives/istat-menus.md), [iStatistica](alternatives/istatistica.md) and [TG Pro](alternatives/tg-pro.md) |
| [Stats](https://github.com/exelban/stats), eul, MenuMeters | MIT, GPL | | Free menu-bar monitors; Stats notifies on thresholds | Monitors over plugin values and any command, keyboard access to the bar; Stats still reads sensors Flash does not; see [Stats](alternatives/stats.md), [eul](alternatives/eul.md) and [MenuMeters](alternatives/menumeters.md) |
| btop, htop, Activity Monitor, Glances, Netdata | Apache, GPL, built in, LGPL, GPL | | Terminal, window and web monitors; Glances and Netdata alert | Shows the terminal ones in popups and alerts on this Mac; history and remote alerts stay with Glances or Netdata; see [btop](alternatives/btop.md), [htop](alternatives/htop.md), [Activity Monitor](alternatives/activity-monitor.md), [Glances](alternatives/glances.md) and [Netdata](alternatives/netdata.md) |
| [AltTab](https://alt-tab.app) | GPL, Pro paid | | Hold-to-cycle window switcher with thumbnails | Every window in one list, with a hint label per row and no Screen Recording; no thumbnails and no hold-to-cycle, so it runs beside AltTab; see [AltTab](alternatives/alttab.md) |
| Raycast, Alfred | Closed | | Launchers | flashlight covers apps, tabs, emoji and quick math; Flash's focus is acting on what is on screen, and it runs fine next to them; see [Raycast](alternatives/raycast.md) and [Alfred](alternatives/alfred.md) |
| Spotlight (macOS 26), LaunchBar, Kando | Built in, closed, MIT | | Launchers with actions and Quick Keys | The flashlight adds tabs, windows, bangs and every Flash command; see [Spotlight](alternatives/spotlight.md), [LaunchBar](alternatives/launchbar.md) and [Kando](alternatives/kando.md) |
| Witch, Contexts, rcmd | Paid, closed | | App and window switchers with search | `:ls` with a hint label per window and `@windows` search, no Screen Recording; see [Witch](alternatives/witch.md), [Contexts](alternatives/contexts.md) and [rcmd](alternatives/rcmd.md) |
| Maccy, Paste, Clipy, CopyQ | MIT, closed, MIT, GPL | | Clipboard managers | `!clip`: history, pins, images, plain-text paste that terminals accept; no sync; see [Maccy](alternatives/maccy.md), [Paste](alternatives/paste.md), [Clipy](alternatives/clipy.md) and [CopyQ](alternatives/copyq.md) |
| Ice, Bartender, Hidden Bar | GPL, closed, MIT | | Tidy the native menu bar | Its own bar over the band, and `mouse menubar` labels every status item; see [Ice](alternatives/ice.md), [Bartender](alternatives/bartender.md) and [Hidden Bar](alternatives/hidden-bar.md) |
| SwiftBar, xbar | MIT | | Script output in the menu bar | The same scripts as sources with `output = "xbar"`, refreshed by `flash status refresh`; see [SwiftBar](alternatives/swiftbar.md) and [xbar](alternatives/xbar.md) |
| Karabiner-Elements, skhd, Hyperkey, Leader Key, Keyboard Maestro | Unlicense, MIT, closed, MIT, closed | | Remapping, hotkeys, Hyper, sequences, macros | Modes, sequences and layers for actions; keep Karabiner or Hyperkey for remapping keys; see [Karabiner-Elements](alternatives/karabiner-elements.md), [skhd](alternatives/skhd.md), [Hyperkey](alternatives/hyperkey.md), [Leader Key](alternatives/leader-key.md) and [Keyboard Maestro](alternatives/keyboard-maestro.md) |
| [BetterTouchTool](https://folivora.ai) | Closed | | Gestures, shortcuts, snapping, clipboard, widgets | The keyboard side, plus hints; keep it for gestures; see [BetterTouchTool](alternatives/bettertouchtool.md) |
| kindaVim, SketchyVim | Subscription, GPL | | Vim inside text fields | Complementary: Flash is Vim for the desktop around the field, with Vim's motions in it, and they add operators and text objects; see [kindaVim](alternatives/kindavim.md) and [SketchyVim](alternatives/sketchyvim.md) |
| [i3](alternatives/i3.md), [sway](alternatives/sway.md), [Hyprland](alternatives/hyprland.md), [bspwm](alternatives/bspwm.md), [xmonad](alternatives/xmonad.md), [Qtile](alternatives/qtile.md), [awesome](alternatives/awesome.md), [river](alternatives/river.md) | Free software, Linux | | Tiling window managers and compositors, with modes and IPC | Opt-in tiling with emulated workspaces, binding modes as layers, the bar built in; no master, dwindle or tag layouts and no animations, which macOS reserves for WindowServer |
| [sxhkd](alternatives/sxhkd.md), [KMonad](alternatives/kmonad.md), [kanata](alternatives/kanata.md), [keyd](alternatives/keyd.md), [xremap](alternatives/xremap.md), [Interception Tools](alternatives/interception-tools.md) | Free software; KMonad and kanata also on macOS | | Hotkey daemons and remapping below the apps | Chords, sequences, layers and per-app tables for commands; what a key sends stays with kanata, KMonad or Karabiner-Elements |
| [rofi](alternatives/rofi.md), [dmenu](alternatives/dmenu.md), [wofi](alternatives/wofi.md), [fuzzel](alternatives/fuzzel.md), [Ulauncher](alternatives/ulauncher.md), [Albert](alternatives/albert.md), [KRunner](alternatives/krunner.md) | Free software, Linux; Albert source-available, also on macOS | | Launchers, modi and stdin pickers | The flashlight with `@types`, bangs and answers, and `menu choose` for dmenu scripts |
| [polybar](alternatives/polybar.md), [Waybar](alternatives/waybar.md), [eww](alternatives/eww.md), [i3blocks](alternatives/i3blocks.md), [i3status](alternatives/i3status.md) | Free software, Linux | | Script-fed bars and widgets | tmux formats over plugin values and command sources; i3blocks and Waybar scripts read unchanged; desktop widgets |
| [keynav](alternatives/keynav.md), [hints](alternatives/hints.md), [warpd](alternatives/warpd.md) | Free software; warpd also on macOS | hints: AT-SPI, or OpenCV contours; warpd: screen positions; keynav: a grid | Keyboard pointer, grid and labels | Accessibility hints in every app, the grid, bisect and pointer mode in one maintained app |
| [dunst](alternatives/dunst.md), [mako](alternatives/mako.md), [greenclip](alternatives/greenclip.md), [clipmenu](alternatives/clipmenu.md), [cliphist](alternatives/cliphist.md), [xdotool](alternatives/xdotool.md), [ydotool](alternatives/ydotool.md), [wtype](alternatives/wtype.md), [wmctrl](alternatives/wmctrl.md), [swayidle](alternatives/swayidle.md), [xss-lock](alternatives/xss-lock.md) | Free software, Linux | | Notification daemons, clipboard history, input and window scripting, idle hooks | `notify send` to Notification Center, `!clip`, the `flash` CLI for keys, clicks and windows, monitors on idle, lock and wake; see [coming from Linux](alternatives/README.md#coming-from-linux) |

Window managers are covered on their own pages: Flash moves and focuses
windows, and its opt-in [tiling](tiling.md) takes AeroSpace's tree and
emulated workspaces, so [AeroSpace](alternatives/aerospace.md),
[yabai](alternatives/yabai.md) and [Rectangle](alternatives/rectangle.md)
say what each still does better, as do the pages on
[Amethyst](alternatives/amethyst.md), [Loop](alternatives/loop.md),
[Magnet](alternatives/magnet.md), [Moom](alternatives/moom.md),
[Swish](alternatives/swish.md) and [Phoenix](alternatives/phoenix.md).

Flash only sees what an app exposes to Accessibility. Canvas-drawn interfaces
and some games show no hints; use the grid there.

## Performance

Flash prepares each focused window's targets in the background as it changes,
so most activations draw hints without walking the app. Every activation logs
its latency from the keypress to the frame that shows the hints;
[performance](performance.md) has the method, the benchmark script, and
measurements.

## FAQ

**Is it Vim?** No. NORMAL, INSERT and COMMAND are borrowed from Vim because
they are a good way to make one keyboard do two jobs; the bindings are
Vimium's and your own, not an editor's, apart from Vim's motions in a text
field.

**Does it work in Electron apps and Chrome?** Yes, through the Accessibility
tree Chromium exposes once an assistive client asks for it. Flash prepares a
window's targets in the background as it changes; a prepared window shows
hints in a fraction of a millisecond, and a cold walk of a small page takes
10 to 25 ms on an M4 Pro. A canvas, a game or a remote desktop exposes
nothing; use the grid.

**Do I have to use normal mode?** No. The starter configuration maps one
hotkey to hints and nothing else; NORMAL, the command line, the status bar
and the widgets are each opt-in, so Flash can stay a hint tool in the
Homerow or Shortcat sense for as long as you like.

**Does it phone home?** No analytics or crash reports, ever. A default
install makes three requests that carry nothing of yours: Flash asks GitHub
daily for its newest release so it can [update itself](updates.md)
(`[app] updates = "off"` stops it), the `answers` plugin fetches the ECB's
daily exchange rates for inline currency conversions (at start, then every
six hours) and `searchproviders` downloads DuckDuckGo's public bang list when
the flashlight opens, at most once a week. `[plugins] disabled = ["answers",
"searchproviders"]` stops those two.
Every other destination — feeds, remote tmux, AI quotas, third-party plugins,
OpenTelemetry — is off until you configure it; the
[privacy page](privacy.md#network) is the full list.

**Is the key tap a keylogger?** No. One session event tap, in one file
(`KeyboardCaptureTap.swift`; a guardrail rejects any other tap or global
key monitor), is installed at launch because the swallow decision must
exist before the first mapped key. For each key-down it decides from mode
state alone: in INSERT a plain key passes to the app with no lookup at all
and a modified chord is taken only when a mapping claims it; in NORMAL or
with hints up the key is swallowed and handed to Flash's interpreter.
Nothing is stored, logged or sent, Flash never requests Input Monitoring,
and macOS hides password-field keys from every tap anyway. The
[privacy page](privacy.md#keyboard) has the details.

**Why does macOS say it cannot verify Flash?** The downloads are ad-hoc
signed and not notarized yet. **System Settings → Privacy & Security →
Open Anyway** lets it run, and an update may need Accessibility re-granted;
[install and update](install.md#first-launch) has the steps and
[releases](release.md#signing-and-notarization) the signed pipeline.

**Intel Macs? Which macOS?** Every release is a universal binary with a
macOS 13 minimum, validated by CI for both slices. The author runs macOS 26
on Apple Silicon daily; reports from macOS 13, 14, 15 and Intel are welcome.

**How are plugins sandboxed?** Each plugin is a child process speaking JSON
lines on stdin and stdout, run under a deny-by-default macOS sandbox profile
built from its manifest: no `~/.ssh`, `~/.aws`, `~/.config/gh`, Keychains or
other plugins' data, writes only to its own data directory, no network
unless declared. Six of the eleven bundled plugins run that way; the five
that opt out (tmux and `screencapture` helpers, Apple Events to Chrome and
Shortcuts, the AI-quota CLIs) are listed with their reasons under
[plugin isolation](privacy.md#plugin-isolation). Third-party plugins must
pin a full commit SHA.

**Karabiner-Elements, kanata, skhd?** They run alongside. Flash does not
remap hardware keys; it reads keys as those tools deliver them, so keep
Caps Lock to Hyper where it is and map the result in `flash.toml`. skhd and
Hammerspoon can call `flash <topic> <action>` from their own bindings, and
their modes move into Flash as [layers](layers.md).

**Vimium in the browser?** Both can run. In NORMAL Flash swallows `f`
before the extension sees it, so unmap in one what you use in the other:
`"f" = false` under `[mode.apps."org.mozilla.firefox".normal.mappings]`
leaves hints to Vimium there. The [Vimium page](alternatives/vimium.md)
has the key-by-key mapping.

**Why no Mac App Store build, and why a TOML file?** Accessibility and the
keyboard tap are unavailable to a sandboxed app, so Flash ships as a direct
download and a Homebrew cask. The file is the interface because it reloads
on save, lives in dotfiles, and `flash config check` validates it in CI;
the help's runtime page edits it in a browser if you prefer.

**What does it cost at idle?** Hints follow Accessibility events and tmux
follows its control client, so nothing polls for them. Whatever must poll
(CPU, battery, a feed) ticks on the one scheduler in the process, which
coalesces wake-ups and pauses when the display sleeps. The budget and the
script that measures it are in [performance](performance.md).

**Why not Hammerspoon, Karabiner, SketchyBar and a tiler?** You can keep
them. Flash is the part that wants a single modal layer and a single file:
hints, modes and the bar sharing one set of plugins. Its tiling is opt-in and
younger than a dedicated tiler's, and it does not remap hardware keys or run
Lua.

**Does it replace iStat Menus or Stats?** For the figures in a bar and an
alert when one crosses a threshold, often: `[monitors.<name>]` watches any
value the bar can show. For temperatures, fans, S.M.A.R.T. and stored
history, no; Flash reads none of them, and those apps run beside it. The
[monitoring comparison](alternatives/README.md#monitoring) has the details.

**Non-QWERTY keyboard?** Labels, grid keys and mappings are read by key
position, so AZERTY, Dvorak and non-Latin input sources work without
configuration (`[app] keyboard_layout`).

**Several displays?** Hints cover the focused window; `--scope=screen` labels
every app on the screen. Tab moves the grid to the next display, and `gm`
(`mouse screens`) numbers each display and moves the pointer, and keyboard
focus, to the one you type. The bar sits on every display or the primary one
(`[statusbar] monitor`), and each widget can sit on one display or all of
them.

