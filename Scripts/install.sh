#!/usr/bin/env bash
set -euo pipefail

# Build Flash.app and install it to /Applications, then restart the
# resident process.
#
# Usage: install.sh [--dev|--release]   (default: --release)
#   --release  optimized universal build (x86_64 + arm64), always rebuilt
#              from scratch.
#   --dev      fast incremental debug build for the current arch, signed with
#              the stable "Flash Dev" identity so TCC grants persist.

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"
parse_mode "$@"

"$PROJECT_DIR/Scripts/build.sh" "--$MODE"

if [[ "$MODE" == "release" ]]; then
  SIGN_IDENTITY="${FLASH_SIGN_IDENTITY:--}"
else
  SIGN_IDENTITY="$DEV_SIGN_IDENTITY"
fi

echo "==> Killing any running Flash instance"
kill_all_flash

echo "==> Installing to $INSTALL_PATH"
if [[ -d "$INSTALL_PATH" ]]; then
  rm -rf "$INSTALL_PATH"
fi
cp -R "$STAGING_PATH" "$INSTALL_PATH"

# Re-sign the installed copy so the on-disk signature is unambiguous.
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
