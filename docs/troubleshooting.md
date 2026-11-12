# Troubleshooting

Start with the resident's own diagnostics:

```sh
flash resident doctor
flash resident status --json
flash config check
```

`resident doctor` checks Accessibility, the keyboard tap, secure input, the
code signature, that exactly one Flash is running, your configuration,
hotkeys taken by other apps, plugins, plugin values your bar, widgets or
monitors read that no loaded plugin publishes, the commands your terminal
popups run, status links refused since launch (a scheme outside `http`,
`https`, `mailto` and `[statusbar] link_schemes`), the OpenTelemetry receiver
running without a token while a monitor runs commands from a received
metric, Screen Recording (only while the screenshot plugin is enabled), recent hint
activations and the keyboard layout. An error exits 1.
`resident status` describes the running instance. `config check
--file=/path/to/flash.toml` validates a file without requiring the resident.
Compare them with the live [runtime](/state), [mappings](/mappings),
[plugins](/plugins) and [logs](/logs) pages. A manual install runs the CLI as
`/Applications/Flash.app/Contents/MacOS/flash`.

- **macOS will not open Flash.** Releases are not notarized yet, so the
  first launch stops at "Apple could not verify Flash": allow it once under
  **System Settings → Privacy & Security → Open Anyway**, as
  [first launch](install.md#first-launch) describes. "Flash is damaged"
  usually means the archive did not arrive intact; download it again.
- **`flash: command not found`.** Homebrew links the command; a download
  leaves it inside the app. Run `/Applications/Flash.app/Contents/MacOS/flash`
  or link it onto your `PATH` ([the `flash` command](install.md#the-flash-command)).
  Current commands start the installed app if needed, except
  `flash resident quit`. `flash config check` works without starting it.
  If automatic launch fails, open Flash from Finder to see the macOS prompt.
- **NORMAL captures typing and Escape does not exit it.** Press `i`, or use
  your configured INSERT shortcut (⌘⌃I in the starter example), to enter
  INSERT; a click keeps NORMAL. Escape cancels hints; it does not leave NORMAL. Enable both entry
  and exit shortcuts together. To stop all capture, choose **Quit** from
  Flash's menu-bar icon. If the icon is hidden, quit Flash in Activity Monitor;
  a terminal already in INSERT can also run `flash resident quit`.
- **Vim's keys act in a field, or `r` does nothing there.** In a field you
  engaged (you left INSERT in it, clicked it, pressed `gi` or `v`), NORMAL
  reads Vim's motions first: `t` is till, `H` / `L` the first / last
  visible line, and `r` and `R` do nothing, so what you typed stays; `x`
  closes the tab as everywhere.
  Escape gives NORMAL's own keys back, and so does the focus moving on. A
  field the page focused on its own, a search box on load or the address
  bar, is not engaged: `j` scrolls there
  ([engage a field](normal-mode.md#engage-a-field)). `flash resident
  status` reports `mapping_scope` `text` while a field is engaged.
- **No hints at all.** Check that Flash is enabled under Accessibility and
  that a hotkey is mapped. If Flash is missing from the Accessibility list,
  click **+** and add `/Applications/Flash.app`. Focus the app you intend to
  target and try `flash mouse target`. Some controls have no Accessibility
  representation; use the [mouse grid](mouse-grid.md) to reach their screen
  positions. Discovery with no targets intentionally shows no error overlay.
  Then see `~/Library/Logs/Flash/flash.log`.
- **Hints stopped after an update.** Current release and nightly builds are
  ad-hoc signed, and the effective Accessibility grant can be lost while the
  toggle still shows as on. Remove Flash from the list with **−** and use **+**
  to add `/Applications/Flash.app` again, then quit and reopen Flash if hints
  do not return. [Permissions after an update](install.md#permissions-after-an-update)
  explains why and gives the `tccutil` alternative; `flash resident doctor`
  reports the installed signature and grant.
- **`flash` says Flash did not answer.** The CLI reaches the resident over
  `~/Library/Application Support/Flash/run/flash.sock` and, when no
  resident runs, starts the app it belongs to and waits 15 s for the socket.
  "Flash is running but did not answer" means a resident runs without the
  socket: an older Flash, still running after an update, speaks the retired
  Apple Event. Quit it from its menu-bar icon or Activity Monitor and open
  Flash again. "did not answer … of starting" means the launch did not
  finish: open Flash from Finder to see why, then check
  `~/Library/Logs/Flash/flash.log` for `[ipc] listen_failed`
  ([IPC protocol](ipc-protocol.md#security)).
- **Two copies of Flash are running.** `flash resident doctor` reports it
  under `residents`: a release `Flash.app` and a development `Flash 🧪.app`
  both installed, or a stale process after a manual update. Quit the extra
  one from its menu-bar icon or Activity Monitor; only one may own the
  keyboard tap.
- **Keys fail after leaving a password field.** `flash resident doctor` reports secure
  input and its holding app. Password fields intentionally hide keys from the
  event tap. Flash leaves a focused password field alone and attempts to
  release a stale hold once; that can request Automation. If it remains,
  leave the password field or quit and reopen the holding app. See
  [the privacy inventory](privacy.md#keyboard) for the recovery behavior.
- **Karabiner-Elements, kanata or another remapper is installed.** They run
  alongside Flash. Flash does not remap hardware keys and reads each key as
  the remapper delivers it, so map the key the remapper produces, not the
  physical one. A rule in the remapper that consumes a chord itself keeps it
  from Flash; `flash resident doctor` lists only hotkeys other apps registered
  through macOS. Keep the remapper for Caps Lock to Hyper and similar.
- **Several displays.** Hints label the focused window on whichever display
  it is; `mouse target --scope=screen` labels every visible app on that
  window's screen. In the grid, Tab and Shift-Tab move to the next and
  previous display, and `gm` (`mouse screens`) numbers each display and
  moves the pointer and focus to the one you type. `[statusbar] monitor` is
  `"all"` or `"primary"`, and each widget names its displays.
- **The native menu bar is gone.** `[statusbar] enabled = true` asks macOS to
  auto-hide it (the global "Automatically hide and show the menu bar"
  setting), because the Flash bar takes that band; reaching for the top edge
  still reveals it, and `enabled = false` restores it when Flash was the one
  that hid it. If Flash was force-quit with the bar on, set **Automatically
  hide and show the menu bar** back yourself: **System Settings → Menu Bar**
  on macOS 26, **Control Center** on macOS 14 and 15, **Desktop & Dock** on
  macOS 13, and **System Preferences → Dock & Menu Bar** before that.
- **Missing or misplaced hints in one app.** Set
  `[debug] show_hints_bounds = true` to draw what Flash sees, and please
  [open an issue](https://github.com/aymericbeaumet/flash/issues) with the app
  name and version.
- **A hotkey does nothing.** Another app may own it; `flash resident doctor` lists
  refused hotkeys. Flash reports invalid mappings when you save the file.
- **A key types, does nothing or runs a different action.** Check the current
  mode and the effective binding on the live [mappings](/mappings) page. NORMAL
  captures unmapped keys; INSERT passes normal typing through. A mapping that
  prefixes a longer sequence waits for its timeout. Secure input can hide keys
  from the event tap. `[app] keyboard_layout` reads keypresses;
  `[keyboard] layout` is the logical layout for hints, the grid, bisect, and
  the ESDF positions HYPER uses as arrows.
- **Hints ignore your keys under a non-Latin input source.** Set
  `[app] keyboard_layout = "auto"` (the default) or name a layout explicitly.
- **A copied configuration does not load.** Run `flash config check` and
  check the active path shown by `flash resident status`. Add entries to an existing
  table such as [`[mode.all.mappings]`](config:mode.all.mappings) instead of declaring it twice: TOML
  rejects the second header with `cannot redefine existing table`. See
  [configuration](configuration.md) for `FLASH_CONFIG` and `XDG_CONFIG_HOME`.
- **A saved config change is missing.** The live [runtime](/state) page shows
  the active path, its diagnostics and the resolved configuration as JSON, and
  edits the file: Save writes it after the text parses as TOML, and Purge
  defaults removes assignments that equal the bundled file. A value a layer
  overrode is marked with that layer (`config` and the filename, or `env` and
  the `FLASH_` variable). Invalid values are diagnosed and keep the previous
  valid value.
- **A plugin or metric is unavailable.** Inspect its last error, state and
  capabilities on the live [plugins](/plugins) page; a stopped on-demand
  plugin can be healthy. `:plugins reload` reloads all plugins. Empty numeric
  status values mean unknown or unavailable, not zero.
- **A feed or the search bang list does not load on a corporate network.**
  The sandboxed `feed` and `searchproviders` plugins verify TLS against the
  Mozilla roots bundled in the plugin, because the sandbox denies the macOS
  trust service and keychains, so a private root presented by a
  TLS-inspecting proxy is not trusted and those two fetches fail; the
  plugins page shows the error. Bangs keep working from the bundled Kagi
  list, exchange rates (`answers`) are fetched by Flash itself through the
  system's trust and proxy settings, and the AI quotas use `/usr/bin/curl`.
- **Flash feels slow.** Filter the live [logs](/logs) by source or trace and
  inspect hint timings in `flash resident status --json`.
  [Observability](observability.md) explains traces and
  [performance](performance.md) describes repeatable measurements. Review
  [privacy](privacy.md) before sharing diagnostics.
- **A popup reports a missing command.** Install that tool yourself on your
  login `PATH`, then press Command-R to reread the environment and retry.
  Flash includes its plugins, but does not install tmux, gh, btop or other
  third-party tools used by integrations or your configuration.

## Known limitations

These are design decisions or platform facts, not bugs to report. The
[alternatives](alternatives/README.md#what-flash-does-not-do-whoever-you-come-from)
pages say which tool covers each one.

- **Only what an app exposes to Accessibility gets a label.** A canvas, a
  game, a remote desktop or a toolkit that publishes no tree shows no hints;
  the [grid](mouse-grid.md) clicks their screen positions. Flash never reads
  pixels, so there is no OCR fallback. When nothing is found, nothing is
  shown.
- **Password fields.** macOS secure input hides keys from every event tap. A
  hint session started in one takes Flash's own window for its labels, and
  a hold that outlives the field is released once, as described in
  [privacy](privacy.md#keyboard).
- **Ad-hoc signed downloads, until notarization.** macOS asks before the
  first launch, and an update can lose the Accessibility grant until Flash is
  removed from and re-added to the list. [Releases](release.md#signing-and-notarization)
  describes the signed pipeline that removes both.
- **The status bar replaces the native menu bar's band.** Enabling it
  auto-hides the native bar instead of adding items to it; it stays one
  pointer reach away. The bar is off by default.
- **Tiling is opt-in, and there is no hardware remapping or text
  expansion.** `[tiling]` is off by default ([tiling](tiling.md)); with it
  off, AeroSpace or yabai run alongside Flash, as Karabiner-Elements and
  kanata do.
- **No temperature, fan or S.M.A.R.T. sensors**, and no stored history:
  monitors watch values Flash already has and alert on this Mac's screen
  only, with no Notification Center entry, sound or e-mail. Alerts pause
  while the displays sleep.
- **Sandboxed plugins cannot use the Keychain or the system trust store**,
  so they verify TLS against bundled roots. Browser and Shortcuts Apple
  Events run through fixed host operations, keeping both plugins sandboxed.
  Three bundled plugins still need unsandboxed external or credentialed helpers
  ([plugin isolation](privacy.md#plugin-isolation)).
- **macOS 13 or later, Intel and Apple Silicon.** No Linux or Windows build,
  and no Mac App Store build: Accessibility and the keyboard tap are
  unavailable to a sandboxed app.
- **`[app] hide_from_capture = true` is a request.** Legacy window captures
  leave Flash's windows out; QuickTime, ⇧⌘5, video calls, AirPlay and
  Screen Sharing on macOS 15 and later still show them
  ([screen capture](privacy.md#screen-capture)). Turned off again, it
  reaches the windows already open when Flash restarts.
- **Renamed configuration keys get no compatibility shims.** `flash config
  check` rejects the old name and names the command it most likely meant; the
  [changelog](https://github.com/aymericbeaumet/flash/blob/main/CHANGELOG.md)
  gives every new spelling.
