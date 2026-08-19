#!/usr/bin/env bash
set -euo pipefail

# Build Flash.app into build/Flash.app without installing it.
#
# Usage: build.sh [--dev|--release]   (default: --release)
#   --release  optimized universal build (x86_64 + arm64) for both the app
#              and the bundled plugins, then zipped + checksummed. Always
#              cleans first so every artifact is rebuilt from scratch.
#   --dev      incremental build for the current arch only — debug Swift
#              build, plugins under the `plugin-dev` cargo profile
#              (opt-level=1, line-tables-only), no clean, no universal
#              lipo. Plugins are symlinked from the live tree and the
#              bundle is signed with the dev identity.
#
# The three independent toolchains — Rust plugins, the Swift app, and the
# Svelte inspector — build in parallel to use every core. In dev all three are
# independent (the inspector is staged into the bundle after assembly). In
# release the inspector must finish before the Swift build (which bundles the
# optimized inspector resource), so the plugins build overlaps that chain.

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"
parse_mode "$@"

SCRIPTS="$PROJECT_DIR/Scripts"

if [[ "$MODE" == "release" ]]; then
  # Release is always a from-scratch build: drop the swift release products
  # and the cargo target dir so nothing stale survives into a shipped bundle.
  echo "==> Cleaning (release: full rebuild)"
  swift package clean
  rm -rf "$PROJECT_DIR/build/plugin-target"

  # Plugins are independent of the inspector→swift chain, so build them
  # alongside it.
  echo "==> Building Rust plugins (release) [parallel]"
  "$SCRIPTS/build-plugins.sh" release &
  plugins_pid=$!

  # The universal swift build bundles the optimized inspector, so stage it
  # into the committed resource first.
  echo "==> Building inspector (release, optimized)"
  "$SCRIPTS/build-inspector.sh" --release

  echo "==> Building flash (release, universal)"
  swift build -c release --arch arm64 --arch x86_64 --product flash
  BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
  SIGN_IDENTITY="${FLASH_SIGN_IDENTITY:--}"

  wait "$plugins_pid" || {
    echo "==> Rust plugins build FAILED" >&2
    exit 1
  }
else
  # Dev: plugins, the swift app, and the inspector are fully independent — build
  # all three at once. Materialise the dev signing identity first so
  # build-plugins.sh can codesign each binary with the stable cert (ad-hoc-signed
  # cargo output gets a fresh TCC prompt every time, killing Reminders/Notes/etc.
  # grants).
  ensure_signing_identity
  echo "==> Building plugins + flash + inspector in parallel (dev)"
  DEV_PLUGIN_SIGN_IDENTITY="$DEV_SIGN_IDENTITY" "$SCRIPTS/build-plugins.sh" dev &
  plugins_pid=$!
  swift build --product flash &
  flash_pid=$!
  "$SCRIPTS/build-inspector.sh" --dev &
  inspector_pid=$!

  fail=0
  wait "$plugins_pid" || {
    echo "==> Rust plugins build FAILED" >&2
    fail=1
  }
  wait "$flash_pid" || {
    echo "==> flash build FAILED" >&2
    fail=1
  }
  wait "$inspector_pid" || {
    echo "==> inspector build FAILED" >&2
    fail=1
  }
  [[ "$fail" -eq 0 ]] || exit 1

  # `--show-bin-path` is a cheap metadata query against the build we just
  # finished (no recompile), and runs after the background build exited so the
  # two swift invocations never overlap.
  BIN_PATH="$(swift build --show-bin-path)"
  SIGN_IDENTITY="$DEV_SIGN_IDENTITY"
fi

assemble_app "$MODE" "$BIN_PATH" "$SIGN_IDENTITY"

if [[ "$MODE" == "dev" ]]; then
  # The inspector was built in parallel above; just drop its output into the
  # assembled bundle (leaving the committed resource pristine so a `--dev`
  # install never dirties the working tree) and re-sign.
  echo "==> Staging dev inspector into the app bundle"
  inspector_html="$STAGING_PATH/Contents/Resources/Flash_flash.bundle/inspector.html"
  if [[ -f "$inspector_html" ]]; then
    cp "$PROJECT_DIR/Inspector/dist/index.html" "$inspector_html"
    # The resource changed after assemble_app signed the bundle, so re-sign.
    sign_app "$STAGING_PATH" "$SIGN_IDENTITY"
  else
    echo "WARNING: $inspector_html missing; inspector not refreshed" >&2
  fi
fi

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
  sign_app "$STAGING_PATH" "$SIGN_IDENTITY"

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
