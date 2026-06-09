#!/usr/bin/env bash
set -euo pipefail

# Build Flash.app into build/Flash.app without installing it.
#
# Usage: build.sh [--dev|--release]   (default: --release)
#   --release  optimized universal build (x86_64 + arm64) for both the app
#              and the bundled plugins, then zipped + checksummed. Always
#              cleans first so every artifact is rebuilt from scratch.
#   --dev      fast incremental debug build for the current arch only — no
#              clean, no optimization. Plugins are symlinked from the live tree.

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"
parse_mode "$@"

if [[ "$MODE" == "release" ]]; then
  # Release is always a from-scratch build: drop the swift release products
  # and the cargo target dir so nothing stale survives into a shipped bundle.
  echo "==> Cleaning (release: full rebuild)"
  swift package clean
  rm -rf "$PROJECT_DIR/build/plugin-target"
fi

echo "==> Building Rust plugins ($MODE)"
"$PROJECT_DIR/Scripts/build-plugins.sh" "$MODE"

if [[ "$MODE" == "release" ]]; then
  echo "==> Building flash (release, universal)"
  swift build -c release --arch arm64 --arch x86_64 --product flash
  swift build -c release --arch arm64 --arch x86_64 --product flashctl
  BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
  SIGN_IDENTITY="${FLASH_SIGN_IDENTITY:--}"
else
  echo "==> Building flash (debug)"
  swift build -c debug --product flash
  swift build -c debug --product flashctl
  BIN_PATH="$(swift build -c debug --show-bin-path)"
  ensure_signing_identity
  SIGN_IDENTITY="$DEV_SIGN_IDENTITY"
fi

assemble_app "$MODE" "$BIN_PATH" "$SIGN_IDENTITY"

if [[ "$MODE" == "release" ]]; then
  MARKETING_VERSION="${FLASH_MARKETING_VERSION:-}"
  BUNDLE_VERSION="${FLASH_BUNDLE_VERSION:-}"
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
  # Re-sign after editing the plist so the signature stays valid.
  codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$STAGING_PATH"

  ZIP_PATH="${FLASH_ZIP_PATH:-$PROJECT_DIR/build/$APP_NAME.zip}"
  rm -f "$ZIP_PATH" "$ZIP_PATH.sha256"
  echo "==> Creating $ZIP_PATH"
  (
    cd "$(dirname "$STAGING_PATH")"
    ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_PATH"
  )
  shasum -a 256 "$ZIP_PATH" | awk '{print $1}' >"$ZIP_PATH.sha256"
  echo "zip=$ZIP_PATH"
  echo "sha256=$(cat "$ZIP_PATH.sha256")"
fi

echo "Built: $STAGING_PATH"
