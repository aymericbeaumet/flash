#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="Flash"
BUNDLE_ID="com.flash.app"
STAGING_PATH="$PROJECT_DIR/build/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
SIGN_IDENTITY="Flash Dev"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
LOGIN_AGENT_LABEL="com.flash.app.autolaunch"
LOGIN_AGENT_PATH="$HOME/Library/LaunchAgents/$LOGIN_AGENT_LABEL.plist"
CLI_LINK_DIR="$HOME/.local/bin"
CLI_LINK_PATH="$CLI_LINK_DIR/flash"
CLICTL_LINK_PATH="$CLI_LINK_DIR/flashctl"

kill_all_flash() {
    open -g flash://flash_quit >/dev/null 2>&1 || true
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
# which is why the previous flow had to tccutil-reset on every install.
ensure_signing_identity() {
    if security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
       | grep -q "\"$SIGN_IDENTITY\""; then
        return
    fi
    echo "==> Creating self-signed dev code-signing identity: $SIGN_IDENTITY"
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
        -subj "/CN=$SIGN_IDENTITY" \
        -addext "basicConstraints = critical, CA:FALSE" \
        -addext "keyUsage = critical, digitalSignature" \
        -addext "extendedKeyUsage = critical, codeSigning" \
        >/dev/null 2>&1

    # security import is happiest with PKCS#12 bundles. -legacy keeps it
    # compatible with the SecurityFramework parser on current macOS.
    openssl pkcs12 -export -legacy \
        -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$SIGN_IDENTITY" \
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
    # requirement) was recorded against the OLD signing identity (ad-hoc, or
    # a previous self-signed leaf). The new binary won't satisfy that csreq
    # even though TCC's auth_value is still "allowed", so AXIsProcessTrusted()
    # returns false silently. Wipe the entry now — the user re-grants once
    # against the new identity, and subsequent rebuilds with this same cert
    # keep matching forever. This step does NOT run on regular builds; it's
    # tied to identity creation, which only happens once per machine.
    echo "  → Resetting TCC so the next grant binds to the new identity..."
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
}

install_login_agent() {
    mkdir -p "$(dirname "$LOGIN_AGENT_PATH")"
    cat > "$LOGIN_AGENT_PATH" <<EOF
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

echo "==> Building flash (debug)"
swift build -c debug --product flash
swift build -c debug --product flashctl

BIN_PATH="$(swift build -c debug --show-bin-path)"

echo "==> Assembling staging $APP_NAME.app"
rm -rf "$STAGING_PATH"
mkdir -p "$STAGING_PATH/Contents/MacOS"
mkdir -p "$STAGING_PATH/Contents/Resources"
cp "$BIN_PATH/flash" "$STAGING_PATH/Contents/MacOS/flash"
cp "$BIN_PATH/flashctl" "$STAGING_PATH/Contents/MacOS/flashctl"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGING_PATH/Contents/Info.plist"
if [[ -d "$PROJECT_DIR/Plugins" ]]; then
    ln -sfn "$PROJECT_DIR/Plugins" "$STAGING_PATH/Contents/Resources/Plugins"
fi
echo "APPL????" > "$STAGING_PATH/Contents/PkgInfo"

ensure_signing_identity

echo "==> Codesigning with stable identity: $SIGN_IDENTITY"
codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$STAGING_PATH"

echo "==> Killing any running Flash instance"
kill_all_flash

echo "==> Installing to $INSTALL_PATH"
if [[ -d "$INSTALL_PATH" ]]; then
    rm -rf "$INSTALL_PATH"
fi
cp -R "$STAGING_PATH" "$INSTALL_PATH"

# Re-sign the installed copy to make sure the on-disk signature is current
# (cp -R preserves it, but a defensive re-sign avoids ambiguity).
codesign --force --deep \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    "$INSTALL_PATH"

# Force Launch Services to refresh routing for the URL scheme + bundle id.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_PATH" >/dev/null 2>&1 || true

echo "==> Killing again post-install (defensive)"
kill_all_flash

echo "==> Installing login autolaunch"
install_login_agent

echo "==> Installing CLI symlinks"
mkdir -p "$CLI_LINK_DIR"
ln -sf "$INSTALL_PATH/Contents/MacOS/flashctl" "$CLI_LINK_PATH"
ln -sf "$INSTALL_PATH/Contents/MacOS/flashctl" "$CLICTL_LINK_PATH"

echo "==> Starting fresh resident process"
open "$INSTALL_PATH"
sleep 0.6

NEW_PIDS=$(pgrep -f "$INSTALL_PATH/Contents/MacOS/flash" 2>/dev/null || true)
ALL_PIDS=$(pgrep -f "$APP_NAME.app/Contents/MacOS/flash" 2>/dev/null || true)
echo "==> Verification"
echo "  Installed PIDs: ${NEW_PIDS:-none}"
echo "  All Flash PIDs: ${ALL_PIDS:-none}"
echo "  Signed with:    $SIGN_IDENTITY"
echo "  Login agent:    $LOGIN_AGENT_PATH"
echo "  CLI:            $CLI_LINK_PATH"
echo "  CLI:            $CLICTL_LINK_PATH"
if [[ -z "${NEW_PIDS:-}" ]]; then
    echo "  WARNING: the installed copy is not running. Check Console.app for launch errors."
fi

echo
echo "Installed: $INSTALL_PATH"
echo "Triggers:"
echo "  open -g flash://mouse_target"
echo "  open -g flash://mouse_target?right=1"
echo "  open -g flash://hints_dismiss"
echo "  open -g flash://flash_quit"
echo "  flash mouse_target"
echo "  flash help_show"
echo
echo "First build with the stable identity? Press ctrl+space; Flash will"
echo "open System Settings → Privacy & Security → Accessibility for you."
echo "Toggle Flash on once. From then on, every ./Scripts/dev.sh re-uses"
echo "the same signing cert, so TCC's stored designated requirement keeps"
echo "matching and the grant persists across rebuilds — no more re-granting."
