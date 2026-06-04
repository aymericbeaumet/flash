#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="Flash"
BUNDLE_ID="com.flash.app"
ZIP_PATH="${1:-$PROJECT_DIR/build/$APP_NAME.zip}"
mkdir -p "$(dirname "$ZIP_PATH")"
OUT_DIR="$(cd "$(dirname "$ZIP_PATH")" && pwd)"
ZIP_NAME="$(basename "$ZIP_PATH")"
ZIP_PATH="$OUT_DIR/$ZIP_NAME"
STAGING_PATH="$OUT_DIR/$APP_NAME.app"
SIGN_IDENTITY="${FLASH_SIGN_IDENTITY:--}"
MARKETING_VERSION="${FLASH_MARKETING_VERSION:-}"
BUNDLE_VERSION="${FLASH_BUNDLE_VERSION:-}"

echo "==> Building flash (release)"
swift build -c release --product flash

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> Assembling $STAGING_PATH"
rm -rf "$STAGING_PATH" "$ZIP_PATH" "$ZIP_PATH.sha256"
mkdir -p "$STAGING_PATH/Contents/MacOS"
mkdir -p "$STAGING_PATH/Contents/Resources"
cp "$BIN_PATH/flash" "$STAGING_PATH/Contents/MacOS/flash"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGING_PATH/Contents/Info.plist"
echo "APPL????" > "$STAGING_PATH/Contents/PkgInfo"

if [[ -n "$MARKETING_VERSION" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
        "$STAGING_PATH/Contents/Info.plist"
fi

if [[ -n "$BUNDLE_VERSION" ]]; then
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleVersion $BUNDLE_VERSION" \
        "$STAGING_PATH/Contents/Info.plist"
fi

echo "==> Codesigning with identity: $SIGN_IDENTITY"
codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$STAGING_PATH"

echo "==> Creating $ZIP_PATH"
(
    cd "$OUT_DIR"
    ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_NAME"
)

shasum -a 256 "$ZIP_PATH" | awk '{print $1}' > "$ZIP_PATH.sha256"

echo "zip=$ZIP_PATH"
echo "sha256=$(cat "$ZIP_PATH.sha256")"
