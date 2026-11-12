# Updates

Flash checks GitHub for new releases and installs them in place. `[app]
updates` decides how much it does by itself; the `updates` commands and the
About window's **Check for Updates…** button work whatever it says.

```toml
[app]
updates = "install"   # or "check", or "off"
```

| Value | What Flash does by itself |
| --- | --- |
| `"install"` (default) | Checks a minute after it starts, then daily. A new release is downloaded and verified. A build signed with a Developer ID installs it when you quit Flash or lock the screen; any other release build tells you once that it is ready. |
| `"check"` | Checks the same way and tells you once per release that it is out. |
| `"off"` | Never looks by itself. |

A development build (`mise run install:dev`, signed by "Flash Dev") and a
build run outside an app bundle never check by themselves and never install a
release over themselves: rebuild them the way you installed them.

## Commands

| Command | What it does |
| --- | --- |
| `updates check` | Asks GitHub for the newest release now and says what installing it means for this build. With `updates = "install"`, the download and its verification follow in the background. |
| `updates install` | Downloads and verifies the newest release if needed, installs it, and restarts Flash into it. It fails, with the reason, when this build cannot be replaced. |

`flash updates check` in a terminal prints the same report and exits 1 when
the check failed. The About window's button runs the same check, and turns
into **Install** followed by the version when there is a release this build
can install.

## Permissions after an update

macOS ties the Accessibility permission to the code signature of the app
that received it.

- A release signed with a Developer ID keeps it: the next release is signed
  by the same team, so macOS recognizes it as the same app. Flash requires
  exactly that before it installs anything on its own.
- The default releases are ad-hoc signed (see [releases](release.md)). Each
  new build is a new signature, so after an update macOS asks you to allow
  Flash in Accessibility again. That is why such a build never installs an
  update by itself: Flash downloads it, tells you once, and waits for
  `updates install` (or the About window's button), so keyboard capture never
  stops working behind your back.

## How an update is installed

1. **Check.** One HTTPS request to
   `api.github.com/repos/aymericbeaumet/flash/releases/latest`, with an
   `If-None-Match` header so an unchanged answer costs nothing. Drafts and
   prereleases (the nightly builds) are ignored; versions compare
   numerically.
2. **Download.** The release's `Flash-<version>.zip`, over HTTPS, into
   `~/Library/Application Support/Flash/Updates/<version>/`.
3. **Verify.** The archive's SHA-256 must equal the digest GitHub publishes
   for the asset; a release without one is refused. `ditto` unpacks it, and
   the bundle must be `com.flash.app`, carry the release's version, and pass
   a strict, deep code-signature check. A Developer ID build also requires
   the new bundle to satisfy its own designated requirement (same team). The
   bundle is checked again right before it is installed.
4. **Install.** One atomic swap (`renamex_np` with `RENAME_SWAP`) puts the
   new bundle at the running app's path; the old one moves to `Updates/` and
   is removed once the new version has started. Flash only replaces a bundle
   your user can write to; a copy installed by an administrator elsewhere is
   reported instead (update it with `brew upgrade --cask flash`).
5. **Restart.** Flash starts the new bundle and quits. The new process waits
   for the old one to release the single-resident lock before it starts, so
   two Flash residents never run at once. At quit, nothing restarts: the next
   launch runs the new version. After the restart Flash says once which
   version it updated to.

An automatic install waits for a moment that interrupts nothing: the screen
locking or the displays going to sleep while no hint session, popup, command
line or HOLD is in progress, or Flash quitting.

Everything happens inside Flash: there is no helper app, installer, launch
agent or daemon.

## Homebrew

The Homebrew cask declares `auto_updates true`, so `brew upgrade` leaves an
updating Flash alone (`brew upgrade --greedy` still replaces it). With
`[app] updates = "off"`, update through Homebrew as usual.
[Install and update](install.md#homebrew-and-the-updater) says how the two
paths work together.

## Privacy

The check sends nothing but the request and a `Flash/<version>` user agent;
no identifier, no usage data. The [privacy page](privacy.md#network) lists
the destinations, and `[app] updates = "off"` stops them.
