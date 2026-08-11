# flash [![CI](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml/badge.svg)](https://github.com/aymericbeaumet/flash/actions/workflows/ci.yml)

**Click anything on macOS without reaching for the mouse.**

flash puts short keyboard hints over the clickable controls in the app you are using. Trigger it, type a hint, and keep moving. The hint overlay works across native apps, browsers, and Electron apps through macOS Accessibility—without screenshots, OCR, browser extensions, or per-app setup.

Requires macOS 14 or later and the Accessibility permission.

## Why flash?

- Jump directly to visible controls with a few keystrokes.
- Reach any screen position with a keyboard-driven precision grid.
- Add a Vim-like normal mode across macOS, with counts, sequences, and custom mappings.
- Search apps, browser tabs, tmux windows, notes, emoji, and more from one command bar.
- Extend it with managed plugins and app-aware actions.
- Keep the desktop clean: no Dock icon, menu bar item, or preferences window.

## Install

The current build is published through Homebrew:

```bash
brew install --cask aymericbeaumet/tap/flash@nightly
```

This installs `/Applications/Flash.app`, the `flash` CLI, and a login LaunchAgent. Open **System Settings → Privacy & Security → Accessibility**, enable Flash, then restart the app once.

### Build from source

You will need macOS 14+, Xcode command-line tools, Rust, and either pnpm or npm.

```bash
git clone https://github.com/aymericbeaumet/flash.git
cd flash
./Scripts/install.sh --dev
```

The installer builds and signs the app, installs it in `/Applications`, starts the resident process, and walks through the one-time Accessibility grant. Use `./Scripts/install.sh --release` for a clean universal build.

## Make your first jump

Create `~/.config/flash/flash.toml` and add a global mapping:

```toml
[mode.all.mappings]
"ctrl+space" = ["flash", "mouse_target"]
```

The config hot-reloads. Press Control-Space, then type the label shown on the target you want.

Add a precision grid and the command bar with two more mappings:

```toml
[mode.all.mappings]
"ctrl+space" = ["flash", "mouse_target"]
"ctrl+shift+space" = ["flash", "mouse_grid"]
"ctrl+alt+space" = ["flash", "enter_command_mode", "--input=:flashlight", "--restore-mode"]
```

Mappings call the same actions as the CLI, so anything you can run as `flash <verb>` can also be bound in config.

## Go further

### Normal mode

Bind `enter_normal_mode` to turn macOS into a keyboard-first environment:

```toml
[mode.all.mappings]
"ctrl+alt+n" = ["flash", "enter_normal_mode"]

[statusbar]
enabled = true
```

Normal mode includes familiar bindings such as `f` for hints, `F` for the mouse grid, `h/j/k/l` for movement, `gg` and `G` for top and bottom, `[` / `]` sequences for history, tabs, and apps, `:` for the command line, and `?` for help. Press `i` to type normally or `I` for locked insert mode.

### flashlight

`:flashlight` is a fast, typo-tolerant command bar for locations and plugin data. Its default results include apps, browser tabs, tmux windows, and other destinations. Select an explicit source for richer searches:

```text
:flashlight @notes.notes inbox
:flashlight @emojis.glyphs fire
:flashlight @system.actions
```

Bare arithmetic, unit conversions, and currency conversions are answered inline. Use `:plugins` to inspect bundled integrations and their status.

The bundled tmux source automatically merges every attached local server with
remote tmux sessions launched through SSH or Mosh. It discovers terminal apps,
PTYs, transports, hosts, tmux paths, and windows from the live process graph—no
terminal- or host-specific configuration is required. Catalogs refresh in the
background, keep their last good remote snapshot through disconnects, and label
otherwise-identical windows by host. The tmux source registers no keyboard
mappings: terminal-native shortcuts can send the user's normal tmux prefix
bindings with zero Flash round trips. Flash still resolves any discovered local
or remote window from the finder.

### Useful actions

```bash
flash mouse_target                       # left-click a hinted target
flash mouse_target --secondary           # right-click
flash mouse_target --double              # double-click
flash mouse_target --move                # move the pointer only
flash mouse_grid                         # target any screen position
flash app_open --name=Firefox            # open or focus an app
flash window_move --position=lefthalf    # tile the focused window
flash enter_command_mode                 # open the command line
flash help_show                          # show built-in help
flash plugins                            # inspect plugins
flash quit                               # stop the resident app
```

Arguments use `--name=value` for values and bare flags such as `--secondary` or `--restore-mode` for booleans.

## Configuration

flash reads `$XDG_CONFIG_HOME/flash/flash.toml` when `XDG_CONFIG_HOME` is set, otherwise `~/.config/flash/flash.toml`. Changes apply without restarting.

The canonical reference is [config.default.toml](config.default.toml). It documents hint alphabets, mappings, the status bar, flashlight ranking, plugins, and debug options.

A compact example:

```toml
[hints]
keys = "<qwerty_homerow+qwerty_toprow>"
min_length = 1

[plugins]
disabled = []
third_party = []

[flashlight]
suggestion_count = 10

[mode.normal]
leader = "\\"

[mode.normal.mappings]
"<leader>space" = ["flash", "enter_command_mode", "--input=:flashlight"]
"f" = ["flash", "mouse_target"]
```

Mapping values are argv arrays. Arrays beginning with `"flash"` dispatch in-process; any other executable is launched directly, with `~` and environment variables expanded in each argument.

## Use your existing hotkey tool

Native mappings are the simplest option, but any launcher that can execute a command can trigger flash:

```lua
-- Hammerspoon
hs.hotkey.bind({"ctrl", "alt"}, "f", function()
  hs.execute("flash mouse_target")
end)
```

```text
# skhd
ctrl + alt - f : flash mouse_target
```

Karabiner-Elements users can call `flash mouse_target` from a `shell_command` manipulator.

## Privacy and design

- The core app requires Accessibility, not Screen Recording or Input Monitoring. Integrations that access Notes, Reminders, Contacts, or other apps may request their own macOS grants.
- The core never reads screen pixels, runs OCR, or stores or logs keystrokes.
- Keyboard capture is active only while normal mode or a hint overlay owns input; modified global mappings use macOS hotkeys.
- Hint coverage follows what an app exposes through Accessibility. The bundled tmux plugin fills the main gap for terminal panes.
- Plugins are child processes owned by flash and communicate only through length-prefixed MessagePack over stdin/stdout.

## Develop

Run the unit and guardrail suites, then install the real app before manual UI verification:

```bash
swift test
(cd Plugins && cargo test --workspace)
./Scripts/check-guardrails.sh
./Scripts/install.sh --dev
```

Browser, native AppKit, and Electron integration suites are available separately:

```bash
./Scripts/test-integration-browser.sh
./Scripts/test-integration-native.sh
./Scripts/test-integration-electron.sh
```

`swift build` alone does not update the resident app in `/Applications`. See [AGENTS.md](AGENTS.md) for the architecture, source contracts, and repository guardrails.
