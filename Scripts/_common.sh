#!/usr/bin/env bash
# Shared constants and helpers for build.sh and install.sh.
# Sourced, never executed directly.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="Flash"
BUNDLE_ID="com.flash.app"
STAGING_PATH="$PROJECT_DIR/build/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

# Dev installs use a stable self-signed identity so TCC grants persist
# across rebuilds. Release installs honor FLASH_SIGN_IDENTITY (defaults to
# ad-hoc "-").
DEV_SIGN_IDENTITY="Flash Dev"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"

LOGIN_AGENT_LABEL="com.flash.app.autolaunch"
LOGIN_AGENT_PATH="$HOME/Library/LaunchAgents/$LOGIN_AGENT_LABEL.plist"
CLI_LINK_DIR="$HOME/.local/bin"
CLI_LINK_PATH="$CLI_LINK_DIR/flash"

# parse_mode <args...> — parses CLI flags. Sets:
#   MODE — "release" (default) or "dev"
#
# Accepted forms:
#   parse_mode             # default: --release
#   parse_mode --release   # full, clean, universal build
#   parse_mode --dev       # fast incremental current-arch build
parse_mode() {
  MODE="release"
  for arg in "$@"; do
    case "$arg" in
      --dev) MODE="dev" ;;
      --release) MODE="release" ;;
      *)
        echo "unknown argument: $arg (expected --dev or --release)" >&2
        exit 1
        ;;
    esac
  done
}

kill_all_flash() {
  "$CLI_LINK_PATH" flash_quit >/dev/null 2>&1 ||
    /Applications/$APP_NAME.app/Contents/MacOS/flash flash_quit >/dev/null 2>&1 ||
    true
  osascript -e 'tell application "Flash" to quit' >/dev/null 2>&1 || true
  pkill -f "/Applications/$APP_NAME.app/Contents/MacOS/flash" 2>/dev/null || true
  pkill -f "$STAGING_PATH/Contents/MacOS/flash" 2>/dev/null || true
  killall "$APP_NAME" 2>/dev/null || true
  sleep 0.4
  local stragglers
  stragglers=$(pgrep -f "$APP_NAME.app/Contents/MacOS/flash" 2>/dev/null || true)
  if [[ -n "$stragglers" ]]; then
    echo "  ... forcing SIGKILL on stragglers: $stragglers"
    for pid in $stragglers; do kill -9 "$pid" 2>/dev/null || true; done
    sleep 0.2
  fi
}

# Ensure a stable self-signed code-signing identity exists in the login
# keychain. TCC grants persist across rebuilds when the signing identity
# (CN of the cert) is stable, because the designated requirement clause TCC
# stores references the cert, not the binary's cdhash. With ad-hoc signing
# every rebuild changes the cdhash and invalidates the grant silently —
# which is why the old flow had to tccutil-reset on every install.
ensure_signing_identity() {
  if security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null |
    grep -q "\"$DEV_SIGN_IDENTITY\""; then
    return
  fi
  echo "==> Creating self-signed dev code-signing identity: $DEV_SIGN_IDENTITY"
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  # Self-signed leaf cert with codeSigning EKU. 10-year lifetime — this is
  # a dev convenience identity, not a public key.
  # The combination macOS expects for a code-signing leaf:
  #   - basicConstraints CA:FALSE  → it's a leaf, not an intermediate
  #   - keyUsage digitalSignature   → the key is used to sign
  #   - extendedKeyUsage codeSigning → it's specifically a codesign key
  # Missing keyUsage gives "Invalid Key Usage for policy" from
  # `security find-identity -p codesigning`.
  openssl req -x509 -newkey rsa:2048 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=$DEV_SIGN_IDENTITY" \
    -addext "basicConstraints = critical, CA:FALSE" \
    -addext "keyUsage = critical, digitalSignature" \
    -addext "extendedKeyUsage = critical, codeSigning" \
    >/dev/null 2>&1

  # security import is happiest with PKCS#12 bundles. -legacy keeps it
  # compatible with the SecurityFramework parser on current macOS.
  openssl pkcs12 -export -legacy \
    -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$DEV_SIGN_IDENTITY" \
    -passout pass:flash \
    -out "$tmp/identity.p12" \
    >/dev/null 2>&1

  # -T whitelists tools that can use the key without further keychain
  # prompts. /usr/bin/codesign is the one we care about; /usr/bin/security
  # is included so this script can sanity-check the identity afterward.
  security import "$tmp/identity.p12" \
    -k "$KEYCHAIN_PATH" \
    -P flash \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null

  # codesign and `security find-identity -p codesigning` both refuse to use
  # a cert that isn't trusted for the codeSign policy. Add a user-level
  # trust override now — this triggers ONE macOS password / Touch ID prompt
  # at first setup; subsequent builds reuse the trusted cert silently.
  echo "  → Adding user trust for code signing (you may be prompted to authenticate)..."
  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN_PATH" \
    "$tmp/cert.pem"

  echo "  ✓ Identity created and trusted. Next codesign call will use it."

  # If TCC has a previous entry for com.flash.app, its `csreq` (designated
  # requirement) was recorded against the OLD signing identity. The new
  # binary won't satisfy that csreq even though TCC's auth_value is still
  # "allowed", so AXIsProcessTrusted() returns false silently. Wipe the
  # entry now — the user re-grants once against the new identity, and
  # subsequent rebuilds with this same cert keep matching forever.
  echo "  → Resetting TCC so the next grant binds to the new identity..."
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
}

install_login_agent() {
  mkdir -p "$(dirname "$LOGIN_AGENT_PATH")"
  cat >"$LOGIN_AGENT_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LOGIN_AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-g</string>
        <string>$INSTALL_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
  chmod 644 "$LOGIN_AGENT_PATH"
  launchctl bootout "gui/$(id -u)" "$LOGIN_AGENT_PATH" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LOGIN_AGENT_PATH" >/dev/null 2>&1 || true
  launchctl enable "gui/$(id -u)/$LOGIN_AGENT_LABEL" >/dev/null 2>&1 || true
}

# assemble_app <mode> <bin_path> <sign_identity>
# Builds build/Flash.app from an already-compiled swift bin dir.
#   dev     — symlinks the live Plugins/ dir (binaries built in place).
#   release — copies each plugin's manifest + compiled binary into the
#             bundle; no Rust sources or cargo metadata ship.
assemble_app() {
  local mode="$1" bin_path="$2" sign_identity="$3"

  echo "==> Assembling $STAGING_PATH"
  rm -rf "$STAGING_PATH"
  mkdir -p "$STAGING_PATH/Contents/MacOS"
  mkdir -p "$STAGING_PATH/Contents/Resources"
  cp "$bin_path/flash" "$STAGING_PATH/Contents/MacOS/flash"
  # Ship the SwiftPM resource bundle (the built Svelte inspector). It goes
  # in Contents/Resources/ where Bundle.module resolves it via
  # Bundle.main.resourceURL and where codesign --deep can sign the nested
  # bundle; without it the inspector serves the missing-resource fallback.
  if [[ -d "$bin_path/Flash_flash.bundle" ]]; then
    rm -rf "$STAGING_PATH/Contents/Resources/Flash_flash.bundle"
    cp -R "$bin_path/Flash_flash.bundle" "$STAGING_PATH/Contents/Resources/Flash_flash.bundle"
  fi
  cp "$PROJECT_DIR/Resources/Info.plist" "$STAGING_PATH/Contents/Info.plist"
  echo "APPL????" >"$STAGING_PATH/Contents/PkgInfo"

  if [[ "$mode" == "release" ]]; then
    local plugins_dest="$STAGING_PATH/Contents/Resources/Plugins"
    for manifest in "$PROJECT_DIR"/Plugins/*/manifest.json; do
      [[ -e "$manifest" ]] || continue
      local dir id bin
      dir="$(dirname "$manifest")"
      id="$(basename "$dir")"
      bin="$dir/flash-plugin-$id"
      if [[ ! -x "$bin" ]]; then
        echo "ERROR: missing plugin binary $bin" >&2
        exit 1
      fi
      mkdir -p "$plugins_dest/$id"
      cp "$manifest" "$plugins_dest/$id/manifest.json"
      cp "$bin" "$plugins_dest/$id/flash-plugin-$id"
      chmod +x "$plugins_dest/$id/flash-plugin-$id"
    done
  else
    if [[ -d "$PROJECT_DIR/Plugins" ]]; then
      ln -sfn "$PROJECT_DIR/Plugins" "$STAGING_PATH/Contents/Resources/Plugins"
    fi
  fi

  echo "==> Codesigning with identity: $sign_identity"
  codesign --force --deep \
    --sign "$sign_identity" \
    --identifier "$BUNDLE_ID" \
    "$STAGING_PATH"
}
