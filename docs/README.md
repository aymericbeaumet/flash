# Flash manual

Flash is a resident macOS app: keyboard hints for every control, a Vim-like
normal mode over all of macOS, a mouse grid, a tmux-style status bar, desktop
widgets, terminal popups and sandboxed plugins, configured in one TOML file.
This site is the full manual; the
[project README](https://github.com/aymericbeaumet/flash#readme) is the
short version, and `:help` inside Flash shows the concise guides next to the
live state of your own installation.

## Start here

- [Getting started](getting-started.md): one hotkey, then the grid, search,
  normal mode, the bar and widgets.
- [Configuration](configuration.md) and the
  [full default reference](https://github.com/aymericbeaumet/flash/blob/main/config.default.toml).
- [Commands](commands.md): every `flash <verb>` and its options.
- [Privacy](privacy.md): each permission prompt, network destination and file.
- [Troubleshooting](troubleshooting.md), starting with `flash doctor`.

## Coming from another tool

[Alternatives](alternatives/README.md) compares Flash with Neru, Homerow,
Shortcat, Vimium, Hammerspoon, SketchyBar, AeroSpace and others, one page
each, with what they do better and how to move your setup over.

## Going deeper

The status [format](status-format.md), [plugins](status-plugins.md),
[widgets](widgets.md) and [popups](popups.md) pages cover the bar; the
[plugin cookbook](plugin-cookbook.md), [protocol](plugin-protocol.md) and
[Rust SDK](plugin-rust-sdk.md) cover writing plugins; the
[architecture](architecture.md), [development](development.md) and
[release](release.md) pages cover contributing.
