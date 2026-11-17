# Releases, signing and notarization

CI (`.github/workflows/ci.yml`, job `homebrew`) builds, signs, publishes and
updates the Homebrew tap on every push to `main` and on every version tag.
Nothing ships unless documentation, format, lint, guardrails, build, test, inspector and the
plugin gate all pass.

## What a push to `main` publishes

| Condition | Release | Cask |
| --- | --- | --- |
| `Resources/Info.plist` carries a version with no tag yet | That version: a release and tag `1.1.0` at this commit, with generated notes | `flash` |
| The version is already tagged | A `nightly-YYYYMMDD-SHA` pre-release for that commit | Rolling `flash@nightly` |
| A `*.*.*` tag pushed by hand | That version | `flash` |

So a release is one commit: bump `CFBundleShortVersionString` in
`Resources/Info.plist`, merge to `main`, and CI cuts the tag, the release and
the cask. The tag is created by the workflow token, which does not start a
second run. `CFBundleVersion` is the workflow run number. GitHub releases are
immutable after publication, so CI creates each release with its archive
attached before publishing it. A rerun accepts an existing release only when
the expected archive is already present and its tag points to the expected
commit. It downloads that immutable archive as the canonical local artifact;
the Homebrew checksum is calculated after publication, so a rebuilt archive's
different signing timestamps or zip metadata cannot invalidate the cask.

Before packaging, `Scripts/check-app-bundle.py` verifies that the staged app
contains every declared plugin and binary, the inspector, default configuration
and license files, with no development symlinks or retired binaries. Release
plugin outputs stay in `build/plugin-release`, leaving the live development
plugin tree untouched; assembly copies only the crate's declared binaries.
Every executable must contain arm64 and x86_64 slices, require no newer macOS than
the app declares, depend only on system libraries and pass strict signature
verification. Hardened-runtime builds also require that flag on each executable.
CI exercises these checks with signed universal fixtures, including missing
plugins, native-only binaries, foreign library paths and damaged resources.
Pull requests and manual workflow runs also build the complete universal
release package without installing or publishing it.

The bundle includes Flash's `LICENSE` and `ThirdPartyNotices.txt`. The latter
is collected from locked Rust dependency graphs with the pinned `cargo-about`
tool, the resolved TOMLKit and SwiftProtobuf sources, the opentelemetry-proto
definitions the OTLP types are generated from (`mise run generate:otlp`),
Ghostty's pinned terminal dependencies,
the licences of data a bundled plugin embeds (`Plugins/<id>/notices/`, such as
the Kagi bang list in `searchproviders`) and Vite's inventory of code actually
bundled into the inspector. Original aggregate license and notice files are retained
alongside selected license text and versioned source links. Missing license
text or an empty inspector inventory fails the release build. The separate
Ghostty, tmux and utf8proc notices also ship in `Contents/Resources`.

## The macOS floor

Flash runs on macOS 13 and later, and every feature behaves the same from
there. Two dependencies bound it: autostart is an `SMAppService` login item
(macOS 13), and Ghostty builds libghostty-vt, the terminal behind every
popup, for macOS 13 at the oldest. `Resources/Info.plist`'s
`LSMinimumSystemVersion` names the floor, and the guardrails keep the other
copies equal to it: the `Package.swift` platform, the plugins'
`MACOSX_DEPLOYMENT_TARGET` (`MACOS_MINIMUM` in `Scripts/_common.sh`), and the
fixture bundles. The Homebrew cask requires the same macOS
(`mise run test:cask`).

The floor stays at 13 by decision. Below it, a feature would have to go or a
hard constraint would have to bend:

- **macOS 12:** autostart has no `SMAppService`, and the remaining routes are
  a helper app or LaunchAgent (hard constraint 3) or the deprecated
  `LSSharedFileList` login items. Ghostty also refuses to build
  libghostty-vt below 13, so popups would need a patched Ghostty.
- **macOS 11:** the same, plus the Shortcuts plugin (Shortcuts arrived in
  12), and Swift concurrency, which would have to ship inside the app.

At that deployment target the Swift compiler rejects any API newer than the
floor outside an `#available` branch, so a new call into a macOS 14 API fails
the build until it has a fallback that behaves the same. The guardrails also
reject an `#available` check the floor already satisfies, which would hide a
missing fallback the next time the floor moves. Nothing checks the plugins'
Rust code this way: a plugin calling a newer system API needs its own
version check. Usage descriptions follow the oldest macOS too: macOS 13 reads
`NSCalendarsUsageDescription` and `NSRemindersUsageDescription`, macOS 14 the
full-access keys, and the bundle carries both.

Some APIs exist on both sides of the floor but behave differently. macOS 14
made activation cooperative, so `ActivationModel` adds
`activateIgnoringOtherApps` to every request on macOS 13, where only it moves
activation. macOS 14's `URL(string:)` repairs a string a URL cannot hold (a
space, a non-ASCII path or host) where macOS 13's returns nil, so every URL
string Flash did not write as a literal parses through `URLParsing`, which
repairs it the same way on macOS 13 (a guardrail rejects any other parse,
and a test checks the repair against the running macOS's own parser).

Every Mach-O records the floor as its minimum OS:

```sh
vtool -show-build build/Flash.app/Contents/MacOS/flash
otool -l build/Flash.app/Contents/Resources/Plugins/sysinfo/flash-plugin-sysinfo | grep -A3 LC_BUILD_VERSION
```

`Scripts/check-app-bundle.py` fails a release whose executable needs a newer
macOS than the bundle declares. GitHub retired its macOS 13 runners, so CI
builds against the floor without running on it: check the oldest supported
macOS by hand before sharing a release (below). On macOS 13, cover the
fallbacks in particular:

- Activation: a hint or the grid takes the keyboard while another app is
  frontmost, Escape and INSERT hand it back, a popup closes on an app switch,
  `app switch` brings the chosen app forward, and the About window comes to
  the front.
- Calendars and Reminders: the first `calendar next` and `@reminders` search
  show macOS's prompt with Flash's explanation, and read once granted.
- URLs: a tmux pane printing `https://ja.wikipedia.org/wiki/日本` gets a link
  hint that opens the page.
- `[app] autostart`, a terminal popup and a text popup, and `[startup] run`
  (its commands run once after login, and `flash startup run` lists how
  each ended).

## Before sharing a release

Automated checks establish bundle completeness and protocol behavior. A public
launch also needs these checks against the downloaded release, using a fresh
macOS account or machine:

- Developer ID signing, notarization and stapling pass Gatekeeper with the
  download's quarantine intact. Ad-hoc builds need the documented Open Anyway
  step and lose their permission grants on every update; use a notarized
  build for a broad launch. Developer ID signing is also what lets the
  in-app updater install releases by itself: it installs only a release that
  satisfies the running build's designated requirement (the same team), and
  an ad-hoc build asks first ([updates](updates.md)).
- First launch, Accessibility approval, the starter shortcut, Escape and INSERT
  recovery work without a developer checkout or Rust, Zig, Node or Python.
  Optional external CLIs remain prerequisites only for their own features.
- The oldest supported macOS and both CPU architectures run hints, browser and
  native-app actions, popups, app switching and sleep/wake correctly. Binary
  minimum-OS metadata and cross-compilation do not establish runtime behavior.
- Homebrew install, upgrade and uninstall work with the exact published asset;
  a manual download works from `/Applications/Flash.app` too. Confirm one resident
  with `flash resident doctor`, and keep the privacy and troubleshooting guides current.
- The release notes are written by hand in [CHANGELOG.md](https://github.com/aymericbeaumet/flash/blob/main/CHANGELOG.md):
  the commit that bumps the version renames its `## Unreleased` heading to
  `## <version>`, and CI publishes that section ahead of GitHub's generated
  list, which names pull requests, not changes. The README promises that a
  renamed configuration key's replacement is spelled out there.
- `flash@nightly` is cut only by a push to `main` whose version is already
  tagged, so right after a version bump the nightly cask can be older than
  the stable one until the next push.

Use the signed fixture suites in [development](development.md) for native,
browser and Electron interaction. A passing pure test suite or a locked console
does not substitute for these checks.

## Signing and notarization

Release builds are ad-hoc signed until the secrets below exist. With them,
CI signs with your Developer ID, hardens the runtime
(`Resources/Flash.entitlements`), submits the zip to Apple's notary service,
staples the ticket and zips again. Users then skip "Open Anyway", and the
Accessibility grant survives updates because the signature is stable.

Everything is read from GitHub Actions secrets of the repository
(Settings › Secrets and variables › Actions › Repository secrets). Missing
secrets only skip the step with a warning in the job log.

| Secret | Contents |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | The Developer ID Application certificate and its private key, as a `.p12`, base64-encoded in one line |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `NOTARY_KEY_ID` | The App Store Connect API key ID, ten characters |
| `NOTARY_ISSUER_ID` | The issuer ID of that key, a UUID |
| `NOTARY_KEY_P8` | The `.p8` private key file, base64-encoded in one line |

### 1. Create the certificate

You need an Apple Developer Program membership.

1. On the Mac you release from, open Xcode › Settings › Accounts, select your
   Apple ID and team, then Manage Certificates › + › **Developer ID
   Application**. Xcode creates the key pair and installs the certificate in
   your login keychain. (Without Xcode: create a certificate signing request
   in Keychain Access, then upload it at
   <https://developer.apple.com/account/resources/certificates/add>, type
   Developer ID Application, and double-click the downloaded `.cer`.)
2. In Keychain Access, under My Certificates, find "Developer ID Application:
   Your Name (TEAMID)". Expand it so the private key shows, select both the
   certificate and the key, right-click › Export 2 items, format `.p12`, and
   set a password. That password is `MACOS_CERTIFICATE_PASSWORD`.
3. Encode it:

   ```sh
   base64 -i DeveloperID.p12 | tr -d '\n' | pbcopy
   ```

   Paste the clipboard as `MACOS_CERTIFICATE_P12`, then delete the `.p12`.

The certificate is valid for five years. CI finds the identity by name in
the imported certificate, so nothing else to configure.

### 2. Create the notarization key

1. Open <https://appstoreconnect.apple.com/access/integrations/api> (Users
   and Access › Integrations › App Store Connect API › Team Keys).
2. Generate an API key with the **Developer** role, named for example
   `flash-ci`.
3. Note the **Issuer ID** at the top of the page (`NOTARY_ISSUER_ID`) and the
   key's **Key ID** (`NOTARY_KEY_ID`).
4. Download the `.p8` file. Apple lets you download it once. Encode it:

   ```sh
   base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy
   ```

   Paste the clipboard as `NOTARY_KEY_P8`, then delete the file.

### 3. Add the secrets

With the GitHub CLI, from the repository:

```sh
gh secret set MACOS_CERTIFICATE_P12 < <(base64 -i DeveloperID.p12 | tr -d '\n')
gh secret set MACOS_CERTIFICATE_PASSWORD
gh secret set NOTARY_KEY_ID
gh secret set NOTARY_ISSUER_ID
gh secret set NOTARY_KEY_P8 < <(base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n')
```

Each command without a redirect prompts for the value. `HOMEBREW_TAP_TOKEN`,
already present, lets the job push the cask to `aymericbeaumet/homebrew-tap`.

### 4. Verify the first signed build

Run the workflow (push to `main`, or Actions › CI › Run workflow is not
enough: the job only deploys on a push). In the job log, "Signing as:
Developer ID Application: …" and "==> Notarizing" should appear, then
"==> Stapling the notarization ticket". Bump the marketing version when first
enabling signing: an existing immutable ad-hoc release cannot be replaced by
a signed archive. On a Mac that never saw the new stable build:

```sh
audit_dir="$(mktemp -d)"
gh release download --repo aymericbeaumet/flash --pattern 'Flash-*.zip' --dir "$audit_dir"
ditto -x -k "$audit_dir"/Flash-*.zip "$audit_dir"
spctl -a -vv -t exec "$audit_dir/Flash.app"   # source=Notarized Developer ID
xcrun stapler validate "$audit_dir/Flash.app" # The validate action worked!
codesign -dvv "$audit_dir/Flash.app" 2>&1 | grep -E 'Authority|Timestamp|flags'
```

## The same by hand

The release build honours the same variables, so a release can be signed and
notarized locally:

```sh
export FLASH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export FLASH_HARDENED_RUNTIME=1
export FLASH_NOTARIZE=1
export FLASH_NOTARY_KEY_PATH="$HOME/.private_keys/AuthKey_XXXXXXXXXX.p8"
export FLASH_NOTARY_KEY_ID=XXXXXXXXXX
export FLASH_NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000
mise run build:release                # build/Flash.zip, stapled
```

`FLASH_NOTARIZE=1` refuses to run without a real identity and the hardened
runtime: Apple rejects ad-hoc or unhardened binaries. When notarization is
refused, the script prints Apple's log, which names the offending file and
reason.

## What is signed

`sign_app` in `Scripts/_common.sh` signs every bundled plugin executable and
then the app, with the hardened runtime, a secure timestamp and the
entitlements in `Resources/Flash.entitlements` (Apple Events, and the
Contacts and Calendars access the Contacts and Reminders catalogs read
through; Flash cannot be sandboxed, so the Mac App Store is out of reach by
design). The
dev build keeps its self-signed "Flash Dev" identity so Accessibility and
Automation grants survive rebuilds.
