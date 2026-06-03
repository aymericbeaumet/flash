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
#   ./Scripts/build-firefox-e2e.sh
#   /Applications/Flash.app/...   # if you haven't run install.sh yet,
#                                   you'll need to. The signing identity
#                                   is set up there.
#
# After the first build, follow the printed instructions to grant the
# binary Accessibility. Subsequent rebuilds reuse the grant.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

BIN_NAME="flash-firefox-e2e"
OUTPUT_DIR="$PROJECT_DIR/build"
OUTPUT_BIN="$OUTPUT_DIR/$BIN_NAME"
SIGN_IDENTITY="Flash Dev"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
BUNDLE_ID="com.flash.firefox-e2e"

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

echo "==> Codesigning with $SIGN_IDENTITY"
codesign --force \
  --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options runtime \
  "$OUTPUT_BIN"

codesign --verify --strict "$OUTPUT_BIN"

cat <<EOF

==> Built: $OUTPUT_BIN

If this is your first build (or you reset TCC), you need to grant
Accessibility to this binary once:

  1. Open System Settings → Privacy & Security → Accessibility
  2. Click +, press ⌘⇧G, paste the path below:
       $OUTPUT_BIN
  3. Toggle the new "$BIN_NAME" entry on.

Because the binary is signed with the stable "$SIGN_IDENTITY" identity,
the grant persists across rebuilds — you only need to do this once per
machine.

Then run:
  $OUTPUT_BIN
EOF
