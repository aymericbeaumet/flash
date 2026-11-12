# Flash documentation

Flash is a resident macOS app: keyboard hints for every control, a Vim-like
normal mode over all of macOS, a mouse grid, a tmux-style status bar, desktop
widgets, terminal popups and plugins with declared capabilities, configured
in one TOML file.
This is the full documentation; the
[project README](https://github.com/aymericbeaumet/flash#readme) is the
short version. Flash ships the same pages: `:help` opens them next to the
live state of your own installation, and `:help <page>` opens one directly
(`:help widgets`, `:help config`).

## Start here

1. [Install and update](install.md), then [getting started](getting-started.md):
   one hotkey, the grid, search, normal mode, the bar and widgets.
2. [How Flash works](concepts.md): the one file, the two-word commands, the
   modes and the surfaces the rest of the documentation names.
3. [Coming from Vim](vim.md), or from another tool: the
   [alternatives](alternatives/README.md) compare Flash with each one and
   show how to move your setup over.

## Find a page by task

| I want to | Read |
| --- | --- |
| Click anything from the keyboard | [Hints](hints.md), [mouse grid](mouse-grid.md) |
| Drive every app with Vim-like keys | [Normal mode](normal-mode.md), [coming from Vim](vim.md) |
| Find apps, tabs, windows and emoji, or get a quick answer | [flashlight](flashlight.md) |
| Switch, move and place windows | [Windows](windows.md) |
| Paste from my clipboard history | [Clipboard](clipboard.md) |
| Jump back to an app by letter | [Marks](marks.md) |
| See information at a glance | [Status bar](statusbar.md), [widgets](widgets.md), [popups](popups.md) |
| Get an alert, or run a script, when something happens | [Monitors](monitors.md) |
| See my next meeting and join it | [Calendar](calendar.md) |
| Run commands when Flash starts, such as `defaults write` for Dock, Finder and keyboard settings | [Startup commands](startup.md) |
| Switch audio devices | [Audio devices](audio.md) |
| Run Flash from scripts and the terminal | [Commands](commands.md) |
| Change or remove a key | [Mapping syntax](mappings.md#add-replace-or-remove-a-binding), [configuration](configuration.md#find-the-setting) |
| Add search catalogs, answers or status values | [Plugins](plugins.md) |
| Know what Flash can see and keep | [Privacy](privacy.md) |
| Install, update or remove Flash | [Install and update](install.md) |
| Fix something | [Troubleshooting](troubleshooting.md), starting with `flash resident doctor` |

## Your live reference

Inside Flash, the help is also a live reference for this installation:
[key mappings](/mappings) lists the effective keys, [commands](/commands)
the built-in and installed plugin commands, [plugins](/plugins) process
health and capabilities, [runtime](/state) the current configuration and
app state, and [logs](/logs) follow diagnostics as they happen. `?` in
NORMAL opens the mappings and `flash help show` the [homepage](/), which
checks what this Mac has already set up and what is still missing. See
[browser help](help.md).

## Reference

- [Configuration](configuration.md), [mapping syntax](mappings.md) and the
  [full default reference](https://github.com/aymericbeaumet/flash/blob/main/config.default.toml).
- [Commands](commands.md): every `flash <topic> <action>` and its options.
- The status [format](status-format.md) and [plugin values](status-plugins.md)
  behind the bar, widgets and popups.

## Going deeper

The [plugin cookbook](plugin-cookbook.md), [protocol](plugin-protocol.md) and
[Rust SDK](plugin-rust-sdk.md) cover writing plugins. The
[architecture](architecture.md), [development](development.md) and
[release](release.md) pages cover contributing, with the internals of
[input capture](input-internals.md) and the [browser help](help-internals.md).
