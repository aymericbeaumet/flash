#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

SETUP_ONLY=0
RUN_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --setup-only) SETUP_ONLY=1 ;;
    *) RUN_ARGS+=("$arg") ;;
  esac
done

SIGN_IDENTITY="Flash Dev"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
OUTPUT_DIR="$PROJECT_DIR/build"

FIXTURE_PRODUCT="flash-native-fixture"
FIXTURE_APP_NAME="Flash Native Fixture"
FIXTURE_BUNDLE_ID="com.flash.native-fixture"
FIXTURE_INSTALL_APP="/Applications/$FIXTURE_APP_NAME.app"

ORACLE_PRODUCT="flash-native-oracle"
ORACLE_APP_NAME="Flash Native Oracle"
ORACLE_BUNDLE_ID="com.flash.native-oracle"
ORACLE_INSTALL_APP="/Applications/$ORACLE_APP_NAME.app"
ORACLE_INSTALL_BIN="$ORACLE_INSTALL_APP/Contents/MacOS/$ORACLE_PRODUCT"

STATE_FILE="${TMPDIR:-/tmp}/flash-native-fixture-state.json"
TIMINGS_FILE="${TMPDIR:-/tmp}/flash-native-oracle-timings.json"

cleanup_test_apps() {
  /usr/bin/pkill -f "$FIXTURE_INSTALL_APP/Contents/MacOS/$FIXTURE_PRODUCT" 2>/dev/null || true
  /usr/bin/pkill -f "$ORACLE_INSTALL_APP/Contents/MacOS/$ORACLE_PRODUCT" 2>/dev/null || true
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

bundle_app() {
  local product="$1"
  local app_name="$2"
  local bundle_id="$3"
  local usage="$4"
  local staging_app="$OUTPUT_DIR/$app_name.app"
  local staging_bin="$staging_app/Contents/MacOS/$product"
  local install_app="/Applications/$app_name.app"

  echo "==> Building $product (release)"
  swift build -c release --product "$product"
  local bin_path
  bin_path="$(swift build -c release --show-bin-path)/$product"
  if [[ ! -f "$bin_path" ]]; then
    echo "ERROR: built binary not found at $bin_path" >&2
    exit 1
  fi

  echo "==> Assembling $app_name.app"
  rm -rf "$staging_app"
  mkdir -p "$staging_app/Contents/MacOS"
  mkdir -p "$staging_app/Contents/Resources"
  cp "$bin_path" "$staging_bin"
  echo "APPL????" >"$staging_app/Contents/PkgInfo"
  cat >"$staging_app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$product</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$app_name</string>
    <key>CFBundleDisplayName</key>
    <string>$app_name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>$usage</string>
</dict>
</plist>
EOF

  echo "==> Codesigning $app_name.app"
  codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$bundle_id" "$staging_app" >/dev/null
  codesign --verify --strict "$staging_app"
  echo "==> Installing to $install_app"
  rm -rf "$install_app"
  cp -R "$staging_app" "$install_app"
  codesign --force --deep --sign "$SIGN_IDENTITY" --identifier "$bundle_id" "$install_app" >/dev/null
  codesign --verify --strict "$install_app"
}

bundle_app \
  "$FIXTURE_PRODUCT" \
  "$FIXTURE_APP_NAME" \
  "$FIXTURE_BUNDLE_ID" \
  "The Flash native fixture exposes AppKit controls for Flash integration tests."

bundle_app \
  "$ORACLE_PRODUCT" \
  "$ORACLE_APP_NAME" \
  "$ORACLE_BUNDLE_ID" \
  "The Flash native oracle needs Accessibility to walk the AppKit fixture's AX tree."

if [[ $SETUP_ONLY -eq 1 ]]; then
  echo
  echo "==> Setup complete"
  echo "Fixture: $FIXTURE_INSTALL_APP"
  echo "Oracle:  $ORACLE_INSTALL_APP"
  exit 0
fi

echo
echo "==> Running $ORACLE_APP_NAME"
"$ORACLE_INSTALL_BIN" \
  --fixture-app "$FIXTURE_INSTALL_APP" \
  --fixture-bundle-id "$FIXTURE_BUNDLE_ID" \
  --state-file "$STATE_FILE" \
  --timings "$TIMINGS_FILE" \
  "${RUN_ARGS[@]}"
