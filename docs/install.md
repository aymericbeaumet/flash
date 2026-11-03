# Install and update

Flash is one app, `/Applications/Flash.app`, whose executable is also the
`flash` command. This page installs it, keeps it current and removes it.
Once it runs, [getting started](getting-started.md#1-one-hotkey) continues
with the first hotkey.

## Requirements

- **macOS 13 (Ventura) or later.** The app and the Homebrew cask both refuse
  older versions.
- **Apple Silicon or Intel.** Every download is one universal app, so there
  is nothing to choose.
- **No developer tools.** Prebuilt downloads need no Xcode, Swift, Rust or
  mise.
- **Accessibility**, asked at first launch: it is how Flash sees controls,
  clicks them and captures keys. Flash never asks for Input Monitoring, and
  hints need no Screen Recording. Optional features ask for their own access
  the first time you use them (browser tabs, Calendars, `screenshot screen`);
  the [privacy page](privacy.md#permission-prompts) lists every prompt.

## Install

### With Homebrew

```sh
brew install --cask aymericbeaumet/tap/flash
```

The command adds the `aymericbeaumet/tap` tap and installs
`/Applications/Flash.app`. The cask links the `flash` command into
Homebrew's `bin`, installs its man page (`man flash`) and its zsh, bash and
fish completions, then opens Flash in the background so it can register its
login item and ask for Accessibility ([first launch](#first-launch)).

`aymericbeaumet/tap/flash@nightly` is the rolling build of `main`: every
push that passes CI and does not cut a release. Both casks install the same
app and command, so install only one. To switch, uninstall the current one
without `--zap`, which keeps your configuration and data, then install the
other:

```sh
brew uninstall --cask flash
brew install --cask aymericbeaumet/tap/flash@nightly
```

### From GitHub Releases

1. Download `Flash-<version>.zip` from the
   [latest release](https://github.com/aymericbeaumet/flash/releases/latest).
   Nightly builds are the pre-releases on the
   [releases page](https://github.com/aymericbeaumet/flash/releases), as
   `Flash-nightly-<date>-<commit>.zip`.
2. Unpack it (Safari may already have) and move `Flash.app` to
   `/Applications`. This page and [troubleshooting](troubleshooting.md) use
   that path.
3. Open it, and follow [first launch](#first-launch).

A download does not put `flash` on your `PATH`; see
[the `flash` command](#the-flash-command).

### First launch

1. **Allow it to open.** Releases are not notarized yet
   ([signing](release.md#signing-and-notarization)), so macOS stops the
   first launch at "Apple could not verify Flash". Click **Done**, open
   **System Settings → Privacy & Security**, scroll to **Security**, click
   **Open Anyway** and confirm. On macOS 15 and later this is the only
   route: Control-clicking the app no longer offers **Open** for an
   unverified download. With Homebrew the prompt appears right after
   `brew install`, because the cask opens Flash. A message that Flash is
   *damaged* usually means the archive did not arrive intact: download it
   again.
2. **Grant Accessibility.** Without it Flash can neither see controls nor
   capture keys, so it opens **System Settings → Privacy & Security →
   Accessibility** and shows these steps on screen. Turn **Flash** on; if it
   is not listed, click **+** and add `/Applications/Flash.app`. Flash
   notices the grant by itself; if hints still do not appear, quit and
   reopen it.
3. **Your configuration.** With no configuration file, Flash writes a
   starter `~/.config/flash/flash.toml`: one working shortcut (**⌘⇧Space**
   labels the controls of the focused app) and, commented out, the next ones
   to try. It never rewrites the file. Open it from the menu-bar icon's
   **Open Configuration**; changes apply when you save. `XDG_CONFIG_HOME` and
   `FLASH_CONFIG` select another file ([configuration](configuration.md)).
4. **Login and the menu bar.** With
   [`autostart`](config:app.autostart) on (the default), Flash registers
   itself as a login item, listed as Flash under **System Settings → General
   → Login Items**. The bolt in the menu bar offers About, Open
   Configuration and Quit; [`menu_bar_icon`](config:app.menu_bar_icon)
   hides it. There is no Dock icon and no preferences window.
5. **Check.** `flash resident doctor` checks Accessibility, the keyboard
   tap, the code signature and your configuration, and `flash help show`
   opens the help with this Mac's setup checklist.

Both settings of step 4 sit under `[app]`, and both are on by default:

```toml
[app]
autostart = true       # start at login; false removes the login item
menu_bar_icon = true   # the bolt with About, Open Configuration and Quit
```

### The `flash` command

The app's executable is also the CLI: `flash <topic> <action>` hands the
command to the running Flash and prints its answer
([commands](commands.md)). Homebrew links it as `flash`. A download leaves it
inside the app: run `/Applications/Flash.app/Contents/MacOS/flash`, or link
it into a directory on your `PATH`, such as `~/.local/bin`:

```sh
mkdir -p ~/.local/bin
ln -sf /Applications/Flash.app/Contents/MacOS/flash ~/.local/bin/flash
```

The link keeps working through updates. Without Homebrew,
`flash cli completion --shell=zsh` (or `bash`, `fish`) prints the
completions and `flash cli manpage` the man page; see
[shell queries](commands.md#status-doctor-config-events-and-shell-queries) for
loading them.

Commands need Flash running and fail with `Flash is not running` otherwise.
`flash config check`, `flash config schema` and the `cli` queries read files
and work without it.

## Update

Flash updates itself from GitHub, and Homebrew or a new download update it
too. An update replaces the app only; your configuration and data stay.

### Automatic updates

[`[app] updates`](config:app.updates) decides what Flash does by itself:

```toml
[app]
updates = "install"   # the default; "check" only tells you, "off" never looks
```

- **What it checks, and how often.** A minute after it starts, then once a
  day (an hour after a failed check), Flash asks GitHub's releases API for
  the newest stable release; nightly pre-releases are never offered. The
  request carries a `Flash/<version>` user agent and nothing else
  ([privacy](privacy.md#network)).
- **Where the download goes.** With `"install"`, a newer release's
  `Flash-<version>.zip` is downloaded into
  `~/Library/Application Support/Flash/Updates/` and verified: its SHA-256
  against the digest GitHub publishes, then the app's identity, version and
  code signature.
- **In place.** Installing swaps the new app into the running app's own path
  in one atomic step and restarts Flash into it, which then says which
  version it updated to. An install at quit restarts nothing: the next
  launch runs the new version.
- **Current releases ask first.** They are ad-hoc signed, so installing one
  costs the Accessibility grant ([permissions after an
  update](#permissions-after-an-update)). Flash therefore never installs
  them by itself: it downloads and verifies the release, tells you once that
  it is ready, and waits for `flash updates install` or the About window's
  button.
- **Developer ID builds install by themselves.** They keep their
  permissions across releases, so Flash installs a waiting update when you
  quit it, or when the screen locks or the displays sleep while no hint
  session, popup, command line or HOLD is in progress. Releases become such
  builds once Developer ID signing is set up
  ([signing](release.md#signing-and-notarization)).
- **Turning it off.** `"check"` checks the same way and only tells you, once
  per release. `"off"` never looks by itself. The commands and the About
  window work whatever the setting says.

A development build (`mise run install:dev`) never checks or updates
itself. Flash 1.1.0 and earlier have no updater: update from them with
Homebrew or a new download. [Updates](updates.md) describes each step of
the check, the verification and the install.

### Check now

- **About.** Click the menu-bar icon, then **About Flash** and **Check for
  Updates…**. When there is a release this build can install, the button
  turns into **Install** followed by its version.
- **Commands.** `flash updates check` reports the newest release and what
  installing it means for this build, and exits 1 when the check failed.
  `flash updates install` downloads and verifies it if needed, installs it
  and restarts Flash; it says why when this build cannot be replaced. Both
  run from Flash's command line too (`:updates check`).

```sh
flash updates check
flash updates install
```

### Homebrew and the updater

```sh
brew upgrade --cask flash   # or flash@nightly
```

- The cask declares `auto_updates`, because Flash updates itself, so a bare
  `brew upgrade` skips it. Naming it upgrades it, as does
  `brew upgrade --greedy` along with every other self-updating cask.
  Homebrew replaces the app and opens Flash again.
- The two paths work together. The updater replaces Homebrew's
  `/Applications/Flash.app` in place, and the `flash` link, man page and
  completions Homebrew installed point into the app, so they follow.
  Homebrew still records the version it installed, so after an in-app
  update `brew upgrade --cask flash` can reinstall the release you already
  run.
- To update only through Homebrew, set `updates = "off"`.
- The updater follows stable releases only. On a `flash@nightly` install it
  offers each new stable release, and `brew upgrade --cask flash@nightly`
  brings the nightly builds in between.
- When an administrator installed Flash where your account cannot write, the
  updater says so instead of installing: update with Homebrew or a new
  download.

### Updating a download

Quit Flash (`flash resident quit`, or **Quit** in the menu-bar icon),
replace `/Applications/Flash.app` with the new download, and open it. Your
configuration and data stay where they are. While releases are not
notarized, a new download can stop at **Open Anyway** again
([first launch](#first-launch)).

### Permissions after an update

macOS ties Accessibility, and Flash's other grants, to the code signature of
the app that received them.

- **Current releases and nightly builds** are ad-hoc signed: every build is
  a new signature, so after an update macOS no longer trusts Flash,
  sometimes while the Accessibility toggle still shows as on. Flash opens
  the Accessibility pane again when it starts without the grant. Select
  Flash, remove it with **−**, then add `/Applications/Flash.app` again with
  **+**. Or reset the entry from a terminal and allow Flash when it asks:

  ```sh
  tccutil reset Accessibility com.flash.app
  ```

  If the new grant is not picked up, quit and reopen Flash. Optional grants
  such as Automation or Calendars can be asked again the next time a
  feature needs them.
- **A Developer ID build** keeps them: the next release is signed by the
  same team, so macOS recognizes it as the same app. That is also why only
  such a build installs updates by itself.
- **A development build** keeps them across rebuilds, through its stable
  "Flash Dev" signing identity.

`flash resident doctor` reports the installed signature and whether the
Accessibility grant is in effect.

### Which version is installed

- **About Flash**, in the menu-bar icon, shows the version and the commit it
  was built from.
- `flash resident status` prints `Flash <version> (<build>)` on its first
  line, and `flash resident status --json` has `version` and `build`.
- `flash updates check` names it in its answer.

A nightly build carries the version of the latest release when it was
built; its build number and commit tell nightlies apart.

## Uninstall

1. **Undo what Flash changed in macOS.** With the status bar on, set
   `[statusbar] enabled = false` and save, which shows the native menu bar
   Flash hid; quitting leaves it auto-hidden. What your
   [startup commands](startup.md) wrote stays as they wrote it: put a value
   back with `defaults delete` or System Settings.
2. **Remove the app.**
   - **Homebrew.** `brew uninstall --cask flash` (or `flash@nightly`) quits
     Flash and removes the app, the `flash` link, the man page and the
     completions. Add `--zap` to delete `~/.config/flash`,
     `~/Library/Application Support/Flash` and `~/Library/Logs/Flash` too.
   - **A download.** Set `autostart = false` under `[app]` and save while
     Flash runs, so it removes its login item. Then quit it with
     `flash resident quit`, move `/Applications/Flash.app` to the Trash and
     delete the `flash` link you made.
3. **Delete what stays**, if you want it gone. Without `--zap`, or after a
   download, these remain:

   | Path | Contents |
   | --- | --- |
   | `~/.config/flash/` | Your configuration. A file chosen through `FLASH_CONFIG` or `XDG_CONFIG_HOME` lives elsewhere, and `--zap` leaves it. |
   | `~/Library/Application Support/Flash/` | Command and clipboard history, marks, ranking data, plugin data and caches, downloaded updates and the help server's token. |
   | `~/Library/Logs/Flash/` | Logs. |
   | `~/Library/Preferences/com.flash.app.plist` | One flag, whether Flash hid the native menu bar. `--zap` leaves it. |

   The [privacy page](privacy.md#data-stored-on-your-mac) describes every
   file. Notifications Flash posted stay in Notification Center until you
   clear them.
4. **Reset what macOS keeps.** Permission entries outlive the app:
   `tccutil reset All com.flash.app` removes all of them, or select Flash
   under **Privacy & Security → Accessibility** and click **−**. If
   **System Settings → General → Login Items** still lists Flash, remove it
   there. If the native menu bar stays hidden, turn off **System Settings →
   Control Center → Automatically hide and show the menu bar**.

## Build from source

Contributors build Flash from a checkout: [development](development.md#build-from-source)
covers Xcode, mise, `mise run setup` and `mise run install:dev`, which
installs a separately signed `/Applications/Flash 🧪.app`. That build never
updates itself; rebuild it to update. Only one Flash runs at a time, so quit
a release `Flash.app` before starting it.

## When something goes wrong

[Troubleshooting](troubleshooting.md) covers, among others:

- **macOS will not open Flash**: the [first launch](#first-launch) steps.
- **Hints stopped after an update**, or the Accessibility grant does not
  stick: [permissions after an update](#permissions-after-an-update).
- **`flash: command not found`**: [the `flash` command](#the-flash-command).
- **Two copies of Flash are running**: a release and a development build, or
  a stale process after a manual update.
