# Releases, signing and notarization

CI (`.github/workflows/ci.yml`, job `homebrew`) builds, signs, publishes and
updates the Homebrew tap on every push to `main` and on every version tag.
Nothing ships unless format, lint, guardrails, build, test, inspector and the
plugin gate all pass.

## What a push to `main` publishes

| Condition | Release | Cask |
| --- | --- | --- |
| `Resources/Info.plist` carries a version with no tag yet | That version: a release and tag `1.0.0` at this commit, with generated notes | `flash` |
| The version is already tagged | Rolling `nightly` pre-release, one more asset | `flash@nightly` |
| A `*.*.*` tag pushed by hand | That version | `flash` |

So a release is one commit: bump `CFBundleShortVersionString` in
`Resources/Info.plist`, merge to `main`, and CI cuts the tag, the release and
the cask. The tag is created by the workflow token, which does not start a
second run. `CFBundleVersion` is the workflow run number.

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
"==> Stapling the notarization ticket". On a Mac that never saw this build:

```sh
curl -LO https://github.com/aymericbeaumet/flash/releases/latest/download/Flash-1.0.0.zip
ditto -x -k Flash-1.0.0.zip .
spctl -a -vv -t exec Flash.app          # source=Notarized Developer ID
xcrun stapler validate Flash.app        # The validate action worked!
codesign -dvv Flash.app 2>&1 | grep -E 'Authority|Timestamp|flags'
```

## The same by hand

The build script honours the same variables, so a release can be signed and
notarized locally:

```sh
export FLASH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export FLASH_HARDENED_RUNTIME=1
export FLASH_NOTARIZE=1
export FLASH_NOTARY_KEY_PATH="$HOME/.private_keys/AuthKey_XXXXXXXXXX.p8"
export FLASH_NOTARY_KEY_ID=XXXXXXXXXX
export FLASH_NOTARY_ISSUER_ID=00000000-0000-0000-0000-000000000000
./Scripts/build.sh --release           # build/Flash.zip, stapled
```

`FLASH_NOTARIZE=1` refuses to run without a real identity and the hardened
runtime: Apple rejects ad-hoc or unhardened binaries. When notarization is
refused, the script prints Apple's log, which names the offending file and
reason.

## What is signed

`sign_app` in `Scripts/_common.sh` signs every bundled plugin executable and
then the app, with the hardened runtime, a secure timestamp and the
entitlements in `Resources/Flash.entitlements` (AppleEvents only; Flash
cannot be sandboxed, so the Mac App Store is out of reach by design). The
dev build keeps its self-signed "Flash Dev" identity so Accessibility and
Automation grants survive rebuilds.
