#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

SETUP_ONLY=0
SKIP_NPM_CI=0
RUN_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --setup-only) SETUP_ONLY=1 ;;
    --skip-npm-ci) SKIP_NPM_CI=1 ;;
    *) RUN_ARGS+=("$arg") ;;
  esac
done

SIGN_IDENTITY="Flash Dev"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
OUTPUT_DIR="$PROJECT_DIR/build"

FIXTURE_DIR="$PROJECT_DIR/Tests/ElectronFixture"
ELECTRON_APP="${FLASH_ELECTRON_APP:-$FIXTURE_DIR/node_modules/electron/dist/Electron.app}"

ORACLE_PRODUCT="flash-electron-oracle"
ORACLE_APP_NAME="Flash Electron Oracle"
ORACLE_BUNDLE_ID="com.flash.electron-oracle"
ORACLE_INSTALL_APP="/Applications/$ORACLE_APP_NAME.app"
ORACLE_INSTALL_BIN="$ORACLE_INSTALL_APP/Contents/MacOS/$ORACLE_PRODUCT"

EXPECTED_FILE="${TMPDIR:-/tmp}/flash-electron-expected.json"
STATE_FILE="${TMPDIR:-/tmp}/flash-electron-state.json"
TIMINGS_FILE="${TMPDIR:-/tmp}/flash-electron-oracle-timings.json"

cleanup_test_apps() {
  /usr/bin/pkill -f "$ORACLE_INSTALL_APP/Contents/MacOS/$ORACLE_PRODUCT" 2>/dev/null || true
  /usr/bin/pkill -f "$FIXTURE_DIR" 2>/dev/null || true
}
trap cleanup_test_apps EXIT
trap 'cleanup_test_apps; exit 130' INT TERM

echo "==> Preflight"
if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null |
  grep -q "\"$SIGN_IDENTITY\""; then
  cat <<EOF >&2
ERROR: signing identity "$SIGN_IDENTITY" not found in $KEYCHAIN_PATH.
Run Scripts/install.sh --dev once first; it creates the stable dev identity.
EOF
  exit 1
fi

if [[ $SKIP_NPM_CI -eq 0 ]]; then
  echo "==> Installing pinned Electron fixture dependencies"
  npm ci --prefix "$FIXTURE_DIR"
fi

if [[ ! -d "$ELECTRON_APP" ]]; then
  cat <<EOF >&2
ERROR: Electron app not found at $ELECTRON_APP.
Run this script without --skip-npm-ci, or set FLASH_ELECTRON_APP to an Electron.app path.
EOF
  exit 1
fi

echo "==> Building $ORACLE_PRODUCT (release)"
swift build -c release --product "$ORACLE_PRODUCT"
BIN_PATH="$(swift build -c release --show-bin-path)/$ORACLE_PRODUCT"
if [[ ! -f "$BIN_PATH" ]]; then
  echo "ERROR: built binary not found at $BIN_PATH" >&2
  exit 1
fi

STAGING_APP="$OUTPUT_DIR/$ORACLE_APP_NAME.app"
STAGING_BIN="$STAGING_APP/Contents/MacOS/$ORACLE_PRODUCT"
echo "==> Assembling $ORACLE_APP_NAME.app"
rm -rf "$STAGING_APP"
mkdir -p "$STAGING_APP/Contents/MacOS"
mkdir -p "$STAGING_APP/Contents/Resources"
cp "$BIN_PATH" "$STAGING_BIN"
echo "APPL????" >"$STAGING_APP/Contents/PkgInfo"
cat >"$STAGING_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$ORACLE_PRODUCT</string>
    <key>CFBundleIdentifier</key>
    <string>$ORACLE_BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$ORACLE_APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$ORACLE_APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>The Flash Electron oracle needs Accessibility to walk the Electron fixture's AX tree.</string>
</dict>
</plist>
EOF

echo "==> Codesigning $ORACLE_APP_NAME.app"
codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$ORACLE_BUNDLE_ID" "$STAGING_APP" >/dev/null
codesign --verify --strict "$STAGING_APP"
echo "==> Installing to $ORACLE_INSTALL_APP"
rm -rf "$ORACLE_INSTALL_APP"
cp -R "$STAGING_APP" "$ORACLE_INSTALL_APP"
codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$ORACLE_BUNDLE_ID" "$ORACLE_INSTALL_APP" >/dev/null
codesign --verify --strict "$ORACLE_INSTALL_APP"

if [[ $SETUP_ONLY -eq 1 ]]; then
  echo
  echo "==> Setup complete"
  echo "Electron: $ELECTRON_APP"
  echo "Oracle:   $ORACLE_INSTALL_APP"
  exit 0
fi

echo
echo "==> Running $ORACLE_APP_NAME"
"$ORACLE_INSTALL_BIN" \
  --fixture-dir "$FIXTURE_DIR" \
  --electron-app "$ELECTRON_APP" \
  --expected-file "$EXPECTED_FILE" \
  --state-file "$STATE_FILE" \
  --timings "$TIMINGS_FILE" \
  "${RUN_ARGS[@]}"
