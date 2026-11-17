# Startup commands

[`[startup] run`](config:startup.run) lists the commands Flash runs once each
time it starts, after it loads your configuration: setting the Mac up with
its own tools (`defaults write`, `killall Dock`), starting something Flash
works with, or running a Flash command.

```toml
[startup]
run = [
  # The Dock: hidden, on the left, sliding in at once.
  ["defaults", "write", "com.apple.dock", "autohide", "-bool", "true"],
  ["defaults", "write", "com.apple.dock", "autohide-delay", "-float", "0"],
  ["defaults", "write", "com.apple.dock", "orientation", "-string", "left"],
  # Fast key repeat, in 1/60 s ticks; applies at the next login.
  ["defaults", "write", "NSGlobalDomain", "KeyRepeat", "-int", "2"],
  ["defaults", "write", "NSGlobalDomain", "InitialKeyRepeat", "-int", "15"],
  # Finder: the path bar and every extension.
  ["defaults", "write", "com.apple.finder", "ShowPathbar", "-bool", "true"],
  ["defaults", "write", "NSGlobalDomain", "AppleShowAllExtensions", "-bool", "true"],
  # The Dock and Finder read those when they start.
  ["killall", "Dock"],
  ["killall", "Finder"],
  # A Flash command.
  ["flash", "caffeinate", "on", "--minutes=60"],
]
```

With [`[app] autostart`](config:app.autostart) on, Flash starts at login, so
this is your login script.

## How they run

- **Once per launch.** The list runs after the configuration loads, once
  Flash has your login shell's environment, so `PATH` is the one your
  terminal has. Saving the file never runs it, whatever you changed:
  [`flash startup run`](#run-them-again) does.
- **In order, every one.** Each command starts once the previous one ended.
  A command that exits non-zero, cannot start, times out or (a Flash
  command) fails is logged, and the next one runs anyway.
- **Commands, not shell lines.** Each is an argv array, as in a
  [monitor's `run`](monitors.md#running-commands) or a mapping:
  `["flash", "<topic>", "<action>", …]` runs a Flash command in process, and
  any other first word is an executable, found on your `PATH` and run without
  a shell. A leading `~/` and `$NAME` expand from your login environment; for
  pipes, `&&` or globs, write `["sh", "-c", "…"]`. A relative executable
  (`bin/setup`) resolves against the configuration file's directory; the
  other words are passed as written. One argv array alone is one command,
  and `run = []` runs nothing.
- **No terminal.** A command starts in your home directory and reads
  `/dev/null`, so a tool that would ask a question takes its
  non-interactive path or stops. Flash keeps the last 16 KiB of what it
  printed, stdout and stderr together.
- **Bounded.** [`[startup] timeout`](config:startup.timeout) (seconds, 600
  by default, at most 86400) bounds each command. When it runs out, the
  command and every process it started get `SIGTERM` and, five seconds later,
  `SIGKILL`; the next command then runs. Quitting Flash stops a command still
  running, with every process it started, and starts none after it.
- **Off the keyboard.** The list runs on a queue of its own, never on the
  main thread, so Flash is ready for keys while it runs; a Flash command in
  it runs as a mapping would.

## Run them again

`flash startup run` (`:startup run` on the command line) runs the list as
your file holds it now and prints how each command ended:

```console
$ flash startup run
Ran 4 startup commands; 1 failed.
ok      defaults write com.apple.dock autohide -bool true
ok      killall Dock
failed  killall Finder (exited 1)
        No matching processes belonging to you were found
ok      flash caffeinate on --minutes=60
```

It exits non-zero when a command failed, and answers that the commands are
already running when a run is still going. From a mapping, a banner shows
the first line. The log has a `[startup]` line for each command, and a
warning with the output of each one that failed (`flash logs show`).

## macOS settings with `defaults`

`defaults write <domain> <key> -<type> <value>` sets a preference: `-bool`,
`-int`, `-float` or `-string`, and `NSGlobalDomain` for the global domain.
`defaults read <domain> <key>` shows the current value; to find the key
behind a switch in System Settings, compare `defaults read` before and
after flipping it.

A process that reads its preferences when it starts needs a restart to see
a change:

| Domain | Then |
| --- | --- |
| `com.apple.dock` | `["killall", "Dock"]` |
| `com.apple.finder`, `com.apple.desktopservices`, `NSGlobalDomain AppleShowAllExtensions` | `["killall", "Finder"]` |
| `com.apple.screencapture`, `com.apple.systemuiserver` | `["killall", "SystemUIServer"]` |
| `com.apple.menuextra.clock`, `com.apple.controlcenter` | `["killall", "ControlCenter"]` |
| `com.apple.WindowManager` | `["killall", "WindowManager"]` |
| Function keys, trackpad and mouse | `["/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", "-u"]` |
| `KeyRepeat`, `InitialKeyRepeat`, `com.apple.swipescrolldirection`, `com.apple.spaces` | nothing: they apply at the next login |
| Other global keys (text substitutions, window animations) | nothing: each app reads them when it next opens |

Each of those processes restarts at once under launchd. Because the list
runs at every launch, so do the restarts: drop the `killall` lines if you
would rather restart by hand after changing a value.

Leave the native menu bar's auto-hide (`NSGlobalDomain _HIHideMenuBar`) out:
[`[statusbar] enabled`](statusbar.md) owns it and puts back only what it
changed.

### A setting that needs your password

The lock screen's "Require password after screen saver begins or display is
turned off" is no preference: macOS keeps it in the keybag that protects
your data, and only `sysadminctl -screenLock immediate -password -` given
your login password changes it. A startup command has no terminal to type it
at, and a password never belongs in `flash.toml`. The setting persists, so
set it once: in System Settings › Lock Screen, or by running that command in
a terminal. `sysadminctl -screenLock status` shows it.

## Why `[startup]` replaced `[macos]`

Development builds of Flash had a `[macos]` section: curated settings such as
`[macos.dock] autohide = true`, `[macos.defaults]` for any other preference,
and `macos diff`, `macos apply` and `macos revert`. It is gone, for two
reasons:

- **Generic.** A list of commands does what `[macos]` did and anything else
  that belongs at login, without a section per kind of setup.
- **The system's own tools.** `defaults`, `killall` and `sysadminctl` are
  what macOS ships, and what every dotfiles repository and guide already
  uses. Configuring the Mac belongs to your dotfiles: Flash assembles the
  tools you already trust instead of keeping a catalog of macOS internals
  current with each release.

What that costs, plainly:

- **No undo.** Removing a line leaves the value as the command last wrote
  it. Put one back with `defaults delete <domain> <key>` (the macOS
  default), another `defaults write`, or System Settings.
- **No diff.** Nothing compares your file with the Mac: `defaults read`
  shows a current value.
- **No validation of values.** Flash checks that each command is well formed,
  not what it writes: a misspelled key or a wrong type is written as is.
- **Restarts every time.** `killall Dock` restarts the Dock at each launch,
  where `[macos]` restarted it only after a change.
- **No password prompt.** The lock screen delay is set by hand, above.

`flash config check` rejects a `[macos]` table, with its position; the
[changelog](https://github.com/aymericbeaumet/flash/blob/main/CHANGELOG.md)
has the conversion recipe.

### Convert a macOS setup

This list replaces the corresponding `[macos]` settings for fast key repeat,
plain text entry, short animations, the Dock on the left and Finder's extra
details. Each command writes the same domain, key and type as the former
setting. Replace your old `[macos.*]` tables with the list; keep other
configuration sections as they are.

Upgrade Flash before saving the conversion: an older resident would restore
preferences when their `[macos]` entries disappear. With the new resident
running, save the file, then run `flash startup run` or restart Flash.

```toml
[startup]
run = [
  # keyboard: repeat_delay_ms = 250, repeat_interval_ms = 33,
  # press_and_hold = false, keyboard_navigation = true.
  ["defaults", "write", "NSGlobalDomain", "InitialKeyRepeat", "-int", "15"],
  ["defaults", "write", "NSGlobalDomain", "KeyRepeat", "-int", "2"],
  ["defaults", "write", "NSGlobalDomain", "ApplePressAndHoldEnabled", "-bool", "false"],
  ["defaults", "write", "NSGlobalDomain", "AppleKeyboardUIMode", "-int", "2"],
  # text: auto_capitalize, smart_quotes, smart_dashes,
  # double_space_period and auto_correct are all false.
  ["defaults", "write", "NSGlobalDomain", "NSAutomaticCapitalizationEnabled", "-bool", "false"],
  ["defaults", "write", "NSGlobalDomain", "NSAutomaticQuoteSubstitutionEnabled", "-bool", "false"],
  ["defaults", "write", "NSGlobalDomain", "NSAutomaticDashSubstitutionEnabled", "-bool", "false"],
  ["defaults", "write", "NSGlobalDomain", "NSAutomaticPeriodSubstitutionEnabled", "-bool", "false"],
  ["defaults", "write", "NSGlobalDomain", "NSAutomaticSpellingCorrectionEnabled", "-bool", "false"],
  # windows: animations = false, resize_duration_ms = 1.
  ["defaults", "write", "NSGlobalDomain", "NSAutomaticWindowAnimationsEnabled", "-bool", "false"],
  ["defaults", "write", "NSGlobalDomain", "NSWindowResizeTime", "-float", "0.001"],
  # mission_control: group_windows_by_app = true, animation_ms = 100,
  # displays_have_separate_spaces = false (the stored key is inverted).
  ["defaults", "write", "com.apple.dock", "expose-group-apps", "-bool", "true"],
  ["defaults", "write", "com.apple.dock", "expose-animation-duration", "-float", "0.1"],
  ["defaults", "write", "com.apple.spaces", "spans-displays", "-bool", "true"],
  # dock: autohide = true, autohide_delay_ms = 0,
  # minimize_to_application = true, orientation = "left".
  ["defaults", "write", "com.apple.dock", "autohide", "-bool", "true"],
  ["defaults", "write", "com.apple.dock", "autohide-delay", "-float", "0"],
  ["defaults", "write", "com.apple.dock", "minimize-to-application", "-bool", "true"],
  ["defaults", "write", "com.apple.dock", "orientation", "-string", "left"],
  # finder: show_all_extensions, show_hidden_files, show_path_bar and
  # show_status_bar are true; both ds_store_on_*_volumes are false.
  ["defaults", "write", "NSGlobalDomain", "AppleShowAllExtensions", "-bool", "true"],
  ["defaults", "write", "com.apple.finder", "AppleShowAllFiles", "-bool", "true"],
  ["defaults", "write", "com.apple.finder", "ShowPathbar", "-bool", "true"],
  ["defaults", "write", "com.apple.finder", "ShowStatusBar", "-bool", "true"],
  ["defaults", "write", "com.apple.desktopservices", "DSDontWriteNetworkStores", "-bool", "true"],
  ["defaults", "write", "com.apple.desktopservices", "DSDontWriteUSBStores", "-bool", "true"],
  # dialogs: expand_save_panel = true, expand_print_panel = true.
  ["defaults", "write", "NSGlobalDomain", "NSNavPanelExpandedStateForSaveMode", "-bool", "true"],
  ["defaults", "write", "NSGlobalDomain", "NSNavPanelExpandedStateForSaveMode2", "-bool", "true"],
  ["defaults", "write", "NSGlobalDomain", "PMPrintingExpandedStateForPrint", "-bool", "true"],
  ["defaults", "write", "NSGlobalDomain", "PMPrintingExpandedStateForPrint2", "-bool", "true"],
  # hot_corners: bottom_right = "none" (action 1, no modifiers).
  ["defaults", "write", "com.apple.dock", "wvous-br-corner", "-int", "1"],
  ["defaults", "write", "com.apple.dock", "wvous-br-modifier", "-int", "0"],
  # defaults: the two explicitly named preferences.
  ["defaults", "write", "NSGlobalDomain", "QLPanelAnimationDuration", "-float", "0"],
  ["defaults", "write", "com.apple.dock", "autohide-time-modifier", "-float", "0.1"],
  ["killall", "Dock"],
  ["killall", "Finder"],
]
```

The two save-panel keys and two print-panel keys preserve the old setting's
complete effect. Key-repeat values are rounded 1/60 s ticks, animation values
are seconds, and the `.DS_Store` keys are inverted. The old
`[macos.lock_screen] require_password = "immediately"` has no command in this
list: keep the existing setting or set it once as described
[above](#a-setting-that-needs-your-password). Restarting Flash never prompts
for that password.

See [privacy](privacy.md#startup-commands) for what this runs, and
[configuration](configuration.md) for how layers and diagnostics work.
