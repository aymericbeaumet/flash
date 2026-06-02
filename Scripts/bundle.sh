#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="Flash"
STAGING_PATH="$PROJECT_DIR/build/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

kill_all_flash() {
    # Polite first: ask the running app to quit via its URL scheme.
    open -g flash://quit >/dev/null 2>&1 || true
    # Then by AppleScript (no-op for headless apps without a Quit suite, harmless).
    osascript -e 'tell application "Flash" to quit' >/dev/null 2>&1 || true
    # Then by exec path (covers both installed and staging-run binaries).
    pkill -f "/Applications/$APP_NAME.app/Contents/MacOS/flash" 2>/dev/null || true
    pkill -f "$STAGING_PATH/Contents/MacOS/flash" 2>/dev/null || true
    # Then by app name (catches anything we missed — e.g. an Xcode-built debug binary).
    killall "$APP_NAME" 2>/dev/null || true
    # Give launchd a beat to register termination.
    sleep 0.4
    # Last-resort SIGKILL for anything still alive.
    local stragglers
    stragglers=$(pgrep -f "$APP_NAME.app/Contents/MacOS/flash" 2>/dev/null || true)
    if [[ -n "$stragglers" ]]; then
        echo "  ... forcing SIGKILL on stragglers: $stragglers"
        for pid in $stragglers; do kill -9 "$pid" 2>/dev/null || true; done
        sleep 0.2
    fi
}

echo "==> Building flash (release)"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> Assembling staging $APP_NAME.app"
rm -rf "$STAGING_PATH"
mkdir -p "$STAGING_PATH/Contents/MacOS"
mkdir -p "$STAGING_PATH/Contents/Resources"
cp "$BIN_PATH/flash" "$STAGING_PATH/Contents/MacOS/flash"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGING_PATH/Contents/Info.plist"
echo "APPL????" > "$STAGING_PATH/Contents/PkgInfo"

echo "==> Ad-hoc codesigning staging bundle"
codesign --force --deep --sign - "$STAGING_PATH"

echo "==> Killing any running Flash instance"
kill_all_flash

# Ad-hoc signed binaries get a new cdhash on every build. TCC ties grants
# to the cdhash, so the previous Accessibility grant stops working silently
# — the toggle stays visually ON but the new binary isn't trusted.
# Resetting wipes the stale entry so the user re-grants ONCE per rebuild,
# and the grant binds to the binary they actually have installed.
echo "==> Resetting stale TCC entries for com.flash.app"
tccutil reset Accessibility com.flash.app 2>/dev/null || true
tccutil reset AppleEvents com.flash.app 2>/dev/null || true

echo "==> Installing to $INSTALL_PATH"
if [[ -d "$INSTALL_PATH" ]]; then
    rm -rf "$INSTALL_PATH"
fi
cp -R "$STAGING_PATH" "$INSTALL_PATH"

# Refresh codesign on the installed copy (some macOS versions invalidate the
# signature after move/copy; we want the same cdhash macOS will dlopen).
codesign --force --deep --sign - "$INSTALL_PATH"

# Force Launch Services to refresh routing for the URL scheme + bundle id.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_PATH" >/dev/null 2>&1 || true

# Make absolutely sure no stale process is around to handle the next URL event.
echo "==> Killing again post-install (paranoid; covers ghosts re-spawned by lsregister)"
kill_all_flash

echo "==> Starting fresh resident process"
open "$INSTALL_PATH"
sleep 0.6

# Verify exactly one resident Flash, and it's the installed copy.
NEW_PIDS=$(pgrep -f "$INSTALL_PATH/Contents/MacOS/flash" 2>/dev/null || true)
ALL_PIDS=$(pgrep -f "$APP_NAME.app/Contents/MacOS/flash" 2>/dev/null || true)
echo "==> Verification"
echo "  Installed PIDs: ${NEW_PIDS:-none}"
echo "  All Flash PIDs: ${ALL_PIDS:-none}"
if [[ -z "${NEW_PIDS:-}" ]]; then
    echo "  WARNING: the installed copy is not running. Check Console.app for launch errors."
fi

echo
echo "Installed: $INSTALL_PATH"
echo "Triggers:"
echo "  open -g flash://activate"
echo "  open -g flash://activate?right=1"
echo "  open -g flash://cancel"
echo "  open -g flash://quit"
