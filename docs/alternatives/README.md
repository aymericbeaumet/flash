# Alternatives

One page per tool Flash is compared with, each in the same shape: what the
tool is, a side-by-side table, where it is stronger than Flash, where Flash
is stronger, the Flash features a user of that tool tends to like, how to
move a setup over, and how to run the two side by side. The pages try to be
fair: several of these tools do things Flash does not and never will, and
many of them run fine next to it.

Facts were checked on 2026-10-14 against each project's own README, site,
changelog or GitHub data, on 2026-10-20 for the monitoring pages, and on
2026-10-23 for the launcher, keyboard, clipboard, menu bar, utility,
switcher and window manager pages, and for the Linux pages.

Coming from a Linux desktop? [Coming from Linux](#coming-from-linux) says
what macOS does differently and links a page for each tool, from i3, sway
and Hyprland to rofi, Waybar, kanata and dunst.
Versions and prices move; the source links on each page are the place to
re-check.

## Hint and pointer tools

| | Open source | Hints from | Also | Page |
| --- | --- | --- | --- | --- |
| Neru | MIT | Accessibility, optional OCR, contour and segmentation | Grid, bisect, scroll, custom modes, Linux and Windows beta | [neru](neru.md) |
| Homerow | No, paid | Accessibility | Scroll mode, search and labels together | [homerow](homerow.md) |
| Shortcat | No, free beta | Accessibility, search first | Menu search, window switching | [shortcat](shortcat.md) |
| Scoot | BSD-3 | Accessibility | Grid, freestyle pointer | [scoot](scoot.md) |
| Vimac | GPL-3, discontinued | Accessibility | Scroll mode | [vimac](vimac.md) |
| Mouseless | No, paid | Coordinate grid, label mode in beta | macOS, Windows, Linux | [mouseless](mouseless.md) |
| Wooshy | No, free with naps or subscription | Accessibility, search | Whole-UI search, text yank | [wooshy](wooshy.md) |
| Superkey | No, paid | OCR, optional Accessibility | Hyper key, remaps | [superkey](superkey.md) |
| warpd | MIT, unmaintained | Pixels, no element detection | Persistent vi pointer mode, Linux | [warpd](warpd.md) |
| Neverclick | No, free, Windows only | A screen capture; accessibility as a fallback | Path, sticky, words, drag, text selection | [neverclick](neverclick.md) |
| mousemaster | No license stated; Windows, and macOS as root | Accessibility, grids, a screen capture | Combos and remapping, position history, zoom | [mousemaster](mousemaster.md) |

## Browser extensions

They work inside the page, from its DOM; Flash works from Accessibility, so
its hints also reach the browser's own interface and every other app.

| | In one line | Page |
| --- | --- | --- |
| Vimium | The reference Vim-keys extension for Chrome, Edge and Firefox, whose keys Flash's NORMAL follows | [vimium](vimium.md) |
| Surfingkeys | A programmable extension configured in JavaScript, Safari included | [surfingkeys](surfingkeys.md) |
| Tridactyl | Firefox driven like Vim, with an ex command line and `:set` options | [tridactyl](tridactyl.md) |
| Vimium C | A Vimium fork with many more commands and options, for Chromium browsers and Firefox; no release since April 2025 | [vimium-c](vimium-c.md) |
| Vimari | Vimium for Safari, last released in 2021 | [vimari](vimari.md) |

## Vim in text fields

Flash is Vim for the desktop around a text field, with Vim's motions inside
it; these two bring the rest of Vim into the field, operators included, and
fit with Flash rather than replace it.

| | In one line | Page |
| --- | --- | --- |
| kindaVim | Vim's motions and operators in macOS text fields, by subscription | [kindavim](kindavim.md) |
| SketchyVim | Real Vim, through libvim, in accessible text fields; free, quiet since 2024 | [sketchyvim](sketchyvim.md) |

## Automation and keyboard

| | In one line | Page |
| --- | --- | --- |
| Hammerspoon | Lua automation of everything macOS exposes; Flash replaces the hotkeys and hints, not the Lua | [hammerspoon](hammerspoon.md) |
| BetterTouchTool | Gestures, shortcuts, snapping and much more in one paid app; keep it for the gestures | [bettertouchtool](bettertouchtool.md) |
| Karabiner-Elements | Rewrites what keys send, below every app; runs beside Flash, which never remaps | [karabiner-elements](karabiner-elements.md) |
| skhd | A hotkey daemon with modes, often paired with yabai; Flash's mappings and layers cover it | [skhd](skhd.md) |
| Hyperkey | Turns Caps Lock into Hyper; keep it and bind the chord it sends in Flash | [hyperkey](hyperkey.md) |
| Leader Key | A leader key, then nested letters; NORMAL sequences do the same | [leader-key](leader-key.md) |
| Keyboard Maestro | Macros from hundreds of actions, conditions and triggers; far beyond Flash's macros | [keyboard-maestro](keyboard-maestro.md) |

## Launchers

| | In one line | Page |
| --- | --- | --- |
| Raycast | A launcher with extensions, AI and window management | [raycast](raycast.md) |
| Alfred | The long-lived launcher with workflows and the Powerpack | [alfred](alfred.md) |
| Spotlight | Built into macOS; on macOS 26 it gained actions, Quick Keys and a clipboard | [spotlight](spotlight.md) |
| LaunchBar | Apps, documents and bookmarks by abbreviation, with script actions | [launchbar](launchbar.md) |
| Kando | A cross-platform pie menu for the mouse, pen, touch or keyboard | [kando](kando.md) |

## Clipboard managers

Flash keeps its own [clipboard history](../clipboard.md), searched with
`!clip`; these pages say when a dedicated manager is still the better fit.

| | In one line | Page |
| --- | --- | --- |
| Maccy | A free, keyboard-first clipboard history with pins | [maccy](maccy.md) |
| Paste | Unlimited history and pinboards, synced with iPhone and iPad; a subscription or a lifetime licence | [paste](paste.md) |
| Clipy | A free history and snippets in a menu | [clipy](clipy.md) |
| CopyQ | A cross-platform manager with tabs, editing and a scripting API | [copyq](copyq.md) |

## Bars and widgets

| | In one line | Page |
| --- | --- | --- |
| SketchyBar | The reference scriptable bar for macOS, and a stronger bar than Flash's | [sketchybar](sketchybar.md) |
| Übersicht | Desktop widgets in JavaScript and HTML, dormant since 2023 | [uebersicht](uebersicht.md) |
| conky | The Linux desktop monitor, awkward on macOS | [conky](conky.md) |
| SwiftBar | Script output as menu-bar items, from a plugin folder; Flash's bar reads the same scripts | [swiftbar](swiftbar.md) |
| xbar | The BitBar reboot, quiet since its 2021 beta; its scripts run in Flash unchanged | [xbar](xbar.md) |

## Menu bar managers

With its bar on, Flash auto-hides the native menu bar, so there is less to
tidy; with it off, these tools and Flash's hints work together.

| | In one line | Page |
| --- | --- | --- |
| Ice | Free, open-source hiding, search and a bar under the notch; no commit since September 2025 | [ice](ice.md) |
| Bartender | Paid hiding with triggers, search and a keyboard Command Bar | [bartender](bartender.md) |
| Hidden Bar | A free, minimal arrow that hides status items | [hidden-bar](hidden-bar.md) |

## Menu bar utilities

| | In one line | Page |
| --- | --- | --- |
| MeetingBar | The next meeting in the menu bar, joined with a click; Flash's bar shows it too | [meetingbar](meetingbar.md) |
| Itsycal | A month calendar with your events in the menu bar | [itsycal](itsycal.md) |
| Amphetamine | Keeps the Mac awake on demand or on a long list of triggers | [amphetamine](amphetamine.md) |
| KeepingYouAwake | A free menu-bar switch, with durations, around Apple's `caffeinate` | [keepingyouawake](keepingyouawake.md) |

## Monitoring

| | Open source | Price | Alerts | Sensors, fans | History | Surfaces | Page |
| --- | --- | --- | --- | --- | --- | --- | --- |
| iStat Menus | No | One-time licence, $11.99 on the App Store | Rules on most metrics; macOS notifications | Temperatures, fans with control, S.M.A.R.T. | Hour and day graphs | Menu bar | [istat-menus](istat-menus.md) |
| Stats | MIT | Free | Per-module thresholds; macOS notifications | Temperatures, power; unmaintained fan control | Charts, up to 10 minutes | Menu bar, macOS widgets | [stats](stats.md) |
| iStatistica Pro | No | $9.99 | Thresholds on most metrics; can run a command | 40+ sensors and fans with its plugin | Per-app CPU history, CSV | Menu bar, macOS widgets, LAN web page | [istatistica](istatistica.md) |
| TG Pro | No | $10 one-time | Temperatures, shutdowns, battery service; notification, sound, e-mail | Temperatures, fan control, S.M.A.R.T. | Peak values, CSV logs | Menu bar, window | [tg-pro](tg-pro.md) |
| eul | MIT, dormant since 2021 | Free | None | CPU temperature, fan speeds | Short graphs | Menu bar, macOS widgets | [eul](eul.md) |
| MenuMeters | GPL-2, unmaintained | Free | None | None | Menu-bar graphs | Menu bar | [menumeters](menumeters.md) |
| btop | Apache-2.0 | Free | None | CPU temperature | Live graphs | Terminal | [btop](btop.md) |
| htop | GPL-2.0-or-later | Free | None | None | Live meters | Terminal | [htop](htop.md) |
| Activity Monitor | No, built into macOS | Free | None | None | CPU and GPU history, 12 hours of energy | Window, Dock icon | [activity-monitor](activity-monitor.md) |
| Glances | LGPL-3 | Free | Three levels, an events log, command actions | Linux only | About an hour; exports | Terminal, web UI, API | [glances](glances.md) |
| Netdata | GPL-3 agent | Free; Cloud has paid tiers | Hundreds built in; e-mail, chat, paging | SMC sensors, NVMe health | Per-second, tiered, on disk | Web dashboard | [netdata](netdata.md) |
| Flash | MIT | Free | `[monitors.<name>]` warning and error thresholds; the centred alert, and a macOS notification with `notify = true` | Battery temperature only | 20 samples per plugin, up to 512 per named source | Its own bar, desktop widgets, popups | [monitors](../monitors.md) |

Flash is not a hardware monitor. Its [monitors](../monitors.md) put a
warning and an error threshold, with a direction, on a value Flash already
has: a status plugin's CPU, memory, disk, network or battery figure, or a
named source printing a number from any command. They are evaluated beside
the status bar and widgets on Flash's one clock, whether the bar is on or
off. A monitor raises Flash's centred alert, amber or red, as its value
rises into warning or error, at most once per level every five minutes, and
says nothing on recovery; `notify = true` also posts the rise to
Notification Center. Built-in monitors cover low battery, a nearly full
disk, memory pressure, plugin failures and slow process spawns, and
`flash monitors show` opens the help's monitors page with each one's state.

What that is good for:

- Thresholds on anything the bar can show, not only hardware: a CI status,
  a queue length or a quota printed by your own command can alert like a
  full disk.
- The same file as the bar, widgets and popups, and no extra process,
  timer or helper; the system plugin they read is sandboxed and spawns no
  process.
- Keyboard first: hints on bar segments, `:sysinfo cpu` and the other details
  pagers, and btop, htop or Glances one key away in a terminal popup.
- Free and open source.

What it does not do:

- No SMC temperatures, fans, voltages, CPU frequency or S.M.A.R.T., unless
  a plugin or a named source supplies them. iStat Menus, Stats, TG Pro and
  Netdata read them.
- No long-term history: plugin charts hold 20 samples and a named source up
  to 512, with no stored graphs and no exports.
- No per-process network accounting; Apple's `nettop` runs in a popup.
- Alerts reach this Mac only, while Flash runs, and its clock pauses while
  the displays sleep: no e-mail or paging of its own, though a monitor's
  `run` can call a command that sends one.
- Its bar replaces the native menu bar instead of adding items to it.

## Battery, fans and maintenance

Each of these does one job Flash leaves alone; Flash shows the figures it
can read and raises the alerts it can.

| | In one line | Page |
| --- | --- | --- |
| coconutBattery | Battery health and history for the Mac, iPhone and iPad | [coconutbattery](coconutbattery.md) |
| AlDente | Charge limits and battery care; Flash controls no charging | [aldente](aldente.md) |
| Macs Fan Control | Fan speeds, temperatures and fan curves; Flash reads no fans | [macs-fan-control](macs-fan-control.md) |
| Sensei | A performance dashboard with cleaning and maintenance tools | [sensei](sensei.md) |

## Window switchers

| | Open source | Rows | Picking | Page |
| --- | --- | --- | --- | --- |
| AltTab | GPL-3.0; Pro paid | Thumbnails, a preview, icons or titles; needs Screen Recording for thumbnails | Hold and Tab, arrows, mouse; search in Pro | [alttab](alttab.md) |
| Witch | No, paid | App, window and tab lists with live search | Held-modifier cycling, search | [witch](witch.md) |
| Contexts | No, paid; no release since 2022 | Windows, searched by typing; a sidebar by Space | Search, held-modifier cycling, Fast Search letters | [contexts](contexts.md) |
| rcmd | No, free with a paid Pro | Apps by their first letter | Right Command and a letter | [rcmd](rcmd.md) |
| Flash | MIT | Icon, app, title and a minimized, hidden or other-Space badge; no thumbnails | One hint label key, or Tab and the arrows; `@windows` to search by title | [windows](../windows.md#switch-to-any-window) |

## Window managers

Flash places and focuses windows, and tiles them, opt-in, with emulated
workspaces ([tiling](../tiling.md)). These pages say where each tool is
stronger, and how to run it next to Flash with `[tiling]` off.

| | In one line | Page |
| --- | --- | --- |
| AeroSpace | i3-like tree tiling with emulated workspaces, the model Flash's tiling follows | [aerospace](aerospace.md) |
| yabai | Binary space partitioning over native Spaces, with an optional scripting addition | [yabai](yabai.md) |
| Rectangle | Keyboard shortcuts and snap areas for halves, thirds and quarters | [rectangle](rectangle.md) |
| Amethyst | Automatic tiling with xmonad's layouts | [amethyst](amethyst.md) |
| Loop | A radial menu on a held key, with a preview before it moves | [loop](loop.md) |
| Magnet | Drag-to-snap and shortcuts, from the App Store | [magnet](magnet.md) |
| Moom | Saved layouts of many windows and an on-screen grid | [moom](moom.md) |
| Swish | Trackpad gestures on title bars and the Dock | [swish](swish.md) |
| Phoenix | Window and app management scripted in JavaScript | [phoenix](phoenix.md) |

## Coming from Linux

Each tool of a Linux desktop has its own page below, written for someone
who knows that tool well and is now on a Mac: what it still does better,
what Flash does instead, and its configuration translated line by line.
A few things are different on macOS whatever you used:

- **There is one compositor.** No X11 or Wayland session to replace:
  WindowServer draws every window. Flash, AeroSpace and yabai move other
  apps' windows through Accessibility after they appear; none of them
  places a window before its first frame, and without SIP changes none can
  decorate or animate another app's window.
- **Spaces have no public API.** Creating or switching them, or moving a
  window between them, takes yabai's scripting addition with SIP partly
  off. Flash's [tiling](../tiling.md) emulates workspaces instead, as
  AeroSpace does.
- **Permissions are grants, not groups.** Instead of the `input` group or
  root, an app asks for Accessibility in System Settings › Privacy &
  Security; Flash needs nothing else for keys, windows and hints. System
  Settings' Modifier Keys remaps Caps Lock and the modifiers; tap-hold keys,
  key layers and per-device remaps take Karabiner-Elements' DriverKit
  virtual keyboard, which kanata and KMonad also use.
- **Keyboard capture has limits.** Flash's one session event tap decides
  whether a key is swallowed and never rewrites it, and a focused password
  field hides keys from every tap ([privacy](../privacy.md#keyboard)).
- **System services belong to Apple.** Notification Center is the only
  notification server, there is one pasteboard and no PRIMARY selection,
  and the lock screen and idle handling are the system's. Flash posts
  notifications, keeps clipboard history and runs commands on idle, lock and
  wake events, but replaces none of them.
- **Super is Command, and Command belongs to apps.** Window chords usually
  move to Option, as in AeroSpace, or to Command-Control. A chord in
  `[mode.all.mappings]` is taken system-wide, so an Option chord stops
  typing its accented letter.
- **Flash's modes are opt-in.** Layers, NORMAL keys and sequences start
  once an all-mode chord runs `mode normal` ([advanced mode](../modes.md#advanced-mode));
  chords alone work without them.

### Window managers and compositors

| | Runs on macOS | In one line | Page |
| --- | --- | --- | --- |
| i3 | No | Flash's opt-in tiling is the same tree, emulated workspaces and binding modes as layers; i3 keeps its title bars, real workspaces and IPC tree. AeroSpace is the dedicated i3-like tiler | [i3](i3.md) |
| sway | No | The i3 half maps as on the i3 page; inputs, outputs, gestures and HDR were the compositor's and stay with macOS | [sway](sway.md) |
| Hyprland | No | Binds, submaps, a dropdown terminal and the bar move over; dwindle, master, animations and blur cannot | [hyprland](hyprland.md) |
| bspwm | No | yabai keeps the binary tree on macOS; Flash's tree is AeroSpace's, with the hotkey daemon built in | [bspwm](bspwm.md) |
| xmonad | No | No Haskell, no master and stack in Flash: Amethyst tiles that way on macOS, and Flash brings the keys, scratchpad and bar | [xmonad](xmonad.md) |
| Qtile | No | Key chords and modes, groups and DropDowns map to layers, workspaces and popups; Python layouts and widgets do not | [qtile](qtile.md) |
| awesome | No | Tags and Lua widgets have no Flash equivalent; Hammerspoon is the Lua desktop on macOS, Flash the keyboard half | [awesome](awesome.md) |
| river | No | Window managers as separate programs is river's idea; `riverctl` maps, modes and tags become mappings, layers and workspaces | [river](river.md) |

### Hotkeys and key remapping

| | Runs on macOS | In one line | Page |
| --- | --- | --- | --- |
| sxhkd | No | Chord chains become NORMAL sequences and layers; brace expansion, release and replay do not exist | [sxhkd](sxhkd.md) |
| KMonad | Yes, with Karabiner's driver | Keep it for what keys send; Flash binds what they then do | [kmonad](kmonad.md) |
| kanata | Yes, with Karabiner's driver | Runs next to Flash: kanata's layers and tap-hold, Flash's commands on the result | [kanata](kanata.md) |
| keyd | No | Its overloads and layers go to kanata or Karabiner-Elements; its application mapper and `command()` bindings to Flash | [keyd](keyd.md) |
| xremap | No | App-specific remaps of chords become Flash's per-app tables, where a command replaces the remapped chord | [xremap](xremap.md) |
| Interception Tools | No | caps2esc and dual-function keys need a remapper on macOS, or the system's own Caps Lock setting | [interception-tools](interception-tools.md) |

### Launchers and menus

| | Runs on macOS | In one line | Page |
| --- | --- | --- | --- |
| rofi | Under XQuartz only | Modi become flashlight `@types` and bangs, `-dmenu` becomes `menu choose`; themes and script modes stay with rofi | [rofi](rofi.md) |
| dmenu | Under XQuartz only | `menu choose` reads the same stdin and prints the pick; patches and `config.h` have no equivalent | [dmenu](dmenu.md) |
| wofi | No | Its drun, run and dmenu modes map to the flashlight and `menu choose`; GTK styling does not | [wofi](wofi.md) |
| fuzzel | No | App launching and dmenu mode map over; icons in the list do not | [fuzzel](fuzzel.md) |
| Ulauncher | No | Extensions become plugins or bangs, shortcuts become bangs; the calculator and file search are built in | [ulauncher](ulauncher.md) |
| Albert | Yes, from its own Homebrew tap | It runs on the Mac too; triggers and plugins are its strength, windows, tabs and the rest of Flash are Flash's | [albert](albert.md) |
| KRunner | No | Runners map to `@types`, answers and bangs; D-Bus runners become plugins | [krunner](krunner.md) |

### Bars and widgets

| | Runs on macOS | In one line | Page |
| --- | --- | --- | --- |
| polybar | No | Modules become sources and plugin values, IPC hooks `status set` and `status refresh`; the tray, scroll actions and extra bars stay behind | [polybar](polybar.md) |
| Waybar | No | Custom modules with `return-type: json` run unchanged as `output = "waybar"` sources; CSS styling does not | [waybar](waybar.md) |
| eww | No | Polls, listens and `eww update` map to sources and `status set`; arbitrary GTK widgets do not | [eww](eww.md) |
| i3blocks | No | Block scripts run unchanged with `output = "i3blocks"`, signals become `status refresh` | [i3blocks](i3blocks.md) |
| i3status | No | Its modules map to plugin values; Flash does not read the i3bar protocol | [i3status](i3status.md) |
| conky | Builds, with XQuartz | Desktop widgets in tmux formats; no Lua or Cairo drawing | [conky](conky.md) |

### Pointer and hints

| | Runs on macOS | In one line | Page |
| --- | --- | --- | --- |
| keynav | No | Its bisection is `mouse grid --bisect`, on keynav's own keys; composed command lines and recordings are not | [keynav](keynav.md) |
| hints | No | The same idea, labels from the accessibility tree; Flash adds no screenshot fallback, the grid covers apps without a tree | [hints](hints.md) |
| warpd | Yes, unmaintained | `mouse pointer`, `mouse grid --bisect` and element hints in one maintained app | [warpd](warpd.md) |

### Notifications, clipboard, scripting and idle

| | Runs on macOS | In one line | Page |
| --- | --- | --- | --- |
| dunst | No | Notification Center replaces it; Flash posts notifications and alerts, without dunst's rules or scripts | [dunst](dunst.md) |
| mako | No | Criteria and modes have no macOS equivalent beyond Focus; Flash posts and labels notifications | [mako](mako.md) |
| greenclip | No | `!clip` is the rofi clipboard mode, with pins, images and plain-text paste | [greenclip](greenclip.md) |
| clipmenu | No | `!clip` replaces clipmenud and the dmenu picker; there is no PRIMARY selection to record | [clipmenu](clipmenu.md) |
| cliphist | No | Flash keeps the history itself; `menu choose` remains for piping your own lists | [cliphist](cliphist.md) |
| xdotool | Under XQuartz only | `key send`, `mouse` and `window` commands cover keys, clicks and windows; typing arbitrary text does not | [xdotool](xdotool.md) |
| ydotool | No | Key and mouse commands that act by meaning, with no daemon or virtual device; keycodes and absolute moves do not map | [ydotool](ydotool.md) |
| wtype | No | Chords map to `key send` and `key sequence`; typed strings to snippets or the clipboard | [wtype](wtype.md) |
| wmctrl | Under XQuartz only | `window`, `app open` and `workspace` commands act on every Mac app | [wmctrl](wmctrl.md) |
| swayidle | No | `core:user.idle` and lock and sleep events in monitors; `caffeinate` inhibits sleep; no before-sleep hook | [swayidle](swayidle.md) |
| xss-lock | No | macOS owns the lock screen; monitors run commands when it locks and unlocks | [xss-lock](xss-lock.md) |

## What Flash does not do, whoever you come from

- It reads no pixels. An app that exposes nothing to Accessibility (a
  canvas, a game, a remote desktop) gets the keyboard grid, not labels.
- It runs on macOS 13 or later only. There is no Linux or Windows build.
- It has no preferences window. Everything is one TOML file.
- It does not remap hardware keys or expand text, and its tiling stops at
  what macOS allows without SIP changes: no native Spaces control.
- It reads no temperature, fan or S.M.A.R.T. sensor and controls no
  hardware; its alerts stay on this Mac.
- Version 1.0.0 shipped in October 2026 from one maintainer. Configuration
  keys that get renamed receive no compatibility shims.

The [comparison table and FAQ](../comparison.md) is the one-screen summary.
