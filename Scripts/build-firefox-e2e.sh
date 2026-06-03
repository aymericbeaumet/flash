#!/usr/bin/env bash
set -euo pipefail

# Build and codesign the standalone Firefox E2E test runner.
#
# Why this exists: `swift test` runs through `swiftpm-xctest-helper`,
# which is signed by Apple but the resulting cdhash + TCC plumbing
# combo doesn't reliably grant Accessibility in practice (see the
# `FirefoxIntegrationTests` skip message for the long version).
#
# This script builds the `flash-firefox-e2e` SPM product and signs it
# with the same stable self-signed "Flash Dev" identity that
# Scripts/install.sh creates for the main Flash bundle. Because TCC
# stores a designated requirement (the cert), not a cdhash, the
# Accessibility grant persists across rebuilds as long as the
# signing identity stays the same.
#
# Usage:
#   ./Scripts/build-firefox-e2e.sh         # build + sign + print grant instructions
#   ./Scripts/build-firefox-e2e.sh --run   # also run the binary at the end

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

BIN_NAME="flash-firefox-e2e"
OUTPUT_DIR="$PROJECT_DIR/build"
OUTPUT_BIN="$OUTPUT_DIR/$BIN_NAME"
SIGN_IDENTITY="Flash Dev"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
BUNDLE_ID="com.flash.firefox-e2e"

AUTO_RUN=0
for arg in "$@"; do
  case "$arg" in
    --run) AUTO_RUN=1 ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null |
  grep -q "\"$SIGN_IDENTITY\""; then
  echo "ERROR: signing identity \"$SIGN_IDENTITY\" not found in $KEYCHAIN_PATH."
  echo "Run Scripts/install.sh once first — it creates the stable dev"
  echo "code-signing identity used by both flash.app and this E2E binary."
  exit 1
fi

echo "==> Building $BIN_NAME (release)"
swift build -c release --product "$BIN_NAME"

BIN_PATH="$(swift build -c release --show-bin-path)/$BIN_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "ERROR: built binary not at expected path: $BIN_PATH"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp "$BIN_PATH" "$OUTPUT_BIN"

# Match install.sh's signing flags exactly: same identity, no hardened
# runtime, same identifier shape. TCC's stored designated requirement
# combines the cert chain *and* the signing flags — if those drift, the
# already-granted entry silently stops matching new builds. Keeping the
# two scripts in lockstep means a single grant covers every rebuild.
echo "==> Codesigning with $SIGN_IDENTITY"
codesign --force \
  --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  "$OUTPUT_BIN"

codesign --verify --strict "$OUTPUT_BIN"

# Pre-stage the binary path on the clipboard so the user can paste it
# straight into System Settings → Accessibility → + → ⌘⇧G. Saves three
# steps off the first-time setup. Failure is tolerated (pbcopy missing
# on a headless macOS — improbable but defensive).
CLIPBOARD_HINT=''
if command -v pbcopy >/dev/null 2>&1; then
  if printf '%s' "$OUTPUT_BIN" | pbcopy 2>/dev/null; then
    CLIPBOARD_HINT='  → binary path copied to clipboard; paste it after pressing ⌘⇧G in step 2.'
  fi
fi

cat <<EOF

==> Built: $OUTPUT_BIN

If this is your first build (or you reset TCC), you need to grant
Accessibility to this binary once:

  1. Open System Settings → Privacy & Security → Accessibility
  2. Click +, press ⌘⇧G, paste the path below:
       $OUTPUT_BIN
$CLIPBOARD_HINT
  3. Toggle the new "$BIN_NAME" entry on.

Because the binary is signed with the stable "$SIGN_IDENTITY" identity,
the grant persists across rebuilds — you only need to do this once per
machine.

Then run:
  $OUTPUT_BIN

(or rerun this script with --run to launch it automatically.)
EOF

# Convenience: pop System Settings open at the right pane on first
# build. Skipped when --run is set, since the runner itself can detect
# the missing grant and the user might be scripting non-interactively.
# Failure is silent (older macOS without the URL handler).
if [[ $AUTO_RUN -eq 0 ]]; then
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" \
    >/dev/null 2>&1 || true
fi

if [[ $AUTO_RUN -eq 1 ]]; then
  echo
  echo "==> Running $BIN_NAME"
  exec "$OUTPUT_BIN"
fi
