#!/usr/bin/env bash
# Shared constants and helpers for build.sh and install.sh.
# Sourced, never executed directly.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="Flash"
BUNDLE_ID="com.flash.app"
STAGING_PATH="$PROJECT_DIR/build/$APP_NAME.app"
# parse_mode refines these: release installs "/Applications/Flash.app",
# dev installs "/Applications/Flash 🧪.app" (same bundle id — only one
# runs at a time; kill_all_flash handles both).
APP_PRODUCT_NAME="$APP_NAME"
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

# Where the resident app writes its structured log. install.sh tails this to
# confirm a launched build actually acquired the Accessibility grant.
FLASH_LOG_PATH="$HOME/Library/Logs/$APP_NAME/flash.log"

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
  if [[ "$MODE" == "dev" ]]; then
    APP_PRODUCT_NAME="$APP_NAME 🧪"
  else
    APP_PRODUCT_NAME="$APP_NAME"
  fi
  INSTALL_PATH="/Applications/$APP_PRODUCT_NAME.app"
}

kill_all_flash() {
  # Both product flavors ("Flash" release, "Flash 🧪" dev) share the bundle
  # id and must never run concurrently — quit and kill every variant.
  "$CLI_LINK_PATH" flash_quit >/dev/null 2>&1 ||
    "/Applications/$APP_NAME.app/Contents/MacOS/flash" flash_quit >/dev/null 2>&1 ||
    "/Applications/$APP_NAME 🧪.app/Contents/MacOS/flash" flash_quit >/dev/null 2>&1 ||
    true
  pkill -f "/Applications/$APP_NAME 🧪.app/Contents/MacOS/flash" 2>/dev/null || true
  killall "$APP_NAME 🧪" 2>/dev/null || true
  osascript -e 'tell application "Flash" to quit' >/dev/null 2>&1 &
  local quit_pid=$!
  for _ in {1..20}; do
    if ! kill -0 "$quit_pid" 2>/dev/null; then
      wait "$quit_pid" 2>/dev/null || true
      quit_pid=""
      break
    fi
    sleep 0.1
  done
  if [[ -n "$quit_pid" ]] && kill -0 "$quit_pid" 2>/dev/null; then
    kill "$quit_pid" 2>/dev/null || true
    wait "$quit_pid" 2>/dev/null || true
  fi
  pkill -f "/Applications/$APP_NAME.app/Contents/MacOS/flash" 2>/dev/null || true
  pkill -f "$STAGING_PATH/Contents/MacOS/flash" 2>/dev/null || true
  pkill -f "./flash-plugin-" 2>/dev/null || true
  killall "$APP_NAME" 2>/dev/null || true
  sleep 0.4
  local stragglers
  stragglers=$(pgrep -f "$APP_NAME( 🧪)?\\.app/Contents/MacOS/flash" 2>/dev/null || true)
  if [[ -n "$stragglers" ]]; then
    echo "  ... forcing SIGKILL on stragglers: $stragglers"
    for pid in $stragglers; do kill -9 "$pid" 2>/dev/null || true; done
    sleep 0.2
  fi
}

# launch_flash_and_check_tap — `open` the installed app and report whether the
# keyboard-capture CGEventTap actually came up. A running PID is NOT proof
# Flash works: without the Accessibility grant the tap can't be created and
# Flash silently falls back to the degraded key-window path, so NORMAL mode
# stops capturing keys. Flash logs exactly one of these lines per launch once
# macOS has answered the trust check. Echoes: ok | denied | unknown.
launch_flash_and_check_tap() {
  local offset=0
  [[ -f "$FLASH_LOG_PATH" ]] && offset=$(wc -l <"$FLASH_LOG_PATH" 2>/dev/null || echo 0)
  open "$INSTALL_PATH"
  local launch_log
  for _ in {1..30}; do # up to ~6s for the tap to come up
    if [[ -f "$FLASH_LOG_PATH" ]]; then
      launch_log=$(tail -n "+$((offset + 1))" "$FLASH_LOG_PATH" 2>/dev/null || true)
      if grep -q "keyboard capture tap installed" <<<"$launch_log"; then
        echo ok
        return
      fi
      if grep -q "no accessibility grant" <<<"$launch_log"; then
        echo denied
        return
      fi
    fi
    sleep 0.2
  done
  echo unknown
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
  cp "$PROJECT_DIR/Resources/AppIcon.icns" "$STAGING_PATH/Contents/Resources/AppIcon.icns"
  # The default config ships inside the bundle and is loaded at runtime as
  # the base layer under the user's flash.toml (ConfigLoader.load), which
  # also revalidates it on every launch.
  cp "$PROJECT_DIR/config.default.toml" "$STAGING_PATH/Contents/Resources/config.default.toml"
  # Stamp the exact commit this bundle was assembled from (the About panel
  # reads FlashGitCommit).
  local git_commit
  git_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  /usr/libexec/PlistBuddy -c "Delete :FlashGitCommit" \
    "$STAGING_PATH/Contents/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :FlashGitCommit string $git_commit" \
    "$STAGING_PATH/Contents/Info.plist"
  # Dev bundles are visibly distinct: "Flash 🧪" in Finder, the menu bar,
  # and Login Items, while a release "Flash.app" can coexist untouched.
  if [[ "$mode" == "dev" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_PRODUCT_NAME" \
      "$STAGING_PATH/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_PRODUCT_NAME" \
      "$STAGING_PATH/Contents/Info.plist"
  fi
  echo "APPL????" >"$STAGING_PATH/Contents/PkgInfo"

  if [[ "$mode" == "release" ]]; then
    local plugins_dest="$STAGING_PATH/Contents/Resources/Plugins"
    for manifest in "$PROJECT_DIR"/Plugins/*/manifest.json; do
      [[ -e "$manifest" ]] || continue
      local dir id bin
      dir="$(dirname "$manifest")"
      id="$(basename "$dir")"
      bin="$dir/flash-plugin-$id"
      mkdir -p "$plugins_dest/$id"
      cp "$manifest" "$plugins_dest/$id/manifest.json"
      # Rust plugins ship their built binary; manifest-only plugins ship just
      # the manifest. Build sources and Cargo metadata never ship.
      if [[ -f "$dir/Cargo.toml" ]]; then
        if [[ ! -x "$bin" ]]; then
          echo "ERROR: missing plugin binary $bin" >&2
          exit 1
        fi
        cp "$bin" "$plugins_dest/$id/flash-plugin-$id"
        chmod +x "$plugins_dest/$id/flash-plugin-$id"
      fi
    done
  else
    if [[ -d "$PROJECT_DIR/Plugins" ]]; then
      ln -sfn "$PROJECT_DIR/Plugins" "$STAGING_PATH/Contents/Resources/Plugins"
    fi
  fi

  echo "==> Codesigning with identity: $sign_identity"
  sign_app "$STAGING_PATH" "$sign_identity"
}

# Sign a bundle inside-out: nested plugin Mach-Os first (release copies them
# into Contents/Resources/Plugins; dev symlinks binaries build-plugins.sh
# already signed, so the symlink case is skipped), then the bundle itself
# WITHOUT --deep — Apple deprecates --deep for signing, and one explicit
# pass per nested binary keeps signing deterministic instead of whatever
# traversal order --deep picks.
sign_app() {
  local bundle="$1" identity="$2"
  # FLASH_HARDENED_RUNTIME=1 signs with the hardened runtime + entitlements
  # (Resources/Flash.entitlements) for Developer ID + notarization. Dev and
  # ad-hoc builds skip hardening — it buys nothing without a real identity
  # and the Mac App Store is out of reach regardless (the App Sandbox
  # prohibits Flash's Accessibility/CGEventTap/subprocess core).
  local harden=()
  if [[ "${FLASH_HARDENED_RUNTIME:-0}" == "1" ]]; then
    harden=(--options runtime --entitlements "$PROJECT_DIR/Resources/Flash.entitlements")
  fi
  local plugins_dir="$bundle/Contents/Resources/Plugins"
  if [[ -d "$plugins_dir" && ! -L "$plugins_dir" ]]; then
    local bin
    for bin in "$plugins_dir"/*/flash-plugin-*; do
      [[ -x "$bin" ]] || continue
      codesign --force --sign "$identity" ${harden[@]+"${harden[@]}"} "$bin"
    done
  fi
  codesign --force \
    --sign "$identity" \
    --identifier "$BUNDLE_ID" \
    ${harden[@]+"${harden[@]}"} \
    "$bundle"
}
