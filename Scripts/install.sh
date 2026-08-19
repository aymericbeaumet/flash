#!/usr/bin/env bash
set -euo pipefail

# Build Flash.app and install it to /Applications, then restart the
# resident process.
#
# Usage: install.sh [--dev|--release]   (default: --release)
#   --release  optimized universal build (x86_64 + arm64), always rebuilt
#              from scratch.
#   --dev      fast incremental build for the current arch — debug Swift
#              build + `plugin-dev`-profile plugins — signed with the
#              stable "Flash Dev" identity so TCC grants persist.

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
sign_app "$INSTALL_PATH" "$SIGN_IDENTITY"

# Force Launch Services to refresh routing for the URL scheme + bundle id.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$INSTALL_PATH" >/dev/null 2>&1 || true

echo "==> Killing again post-install (defensive)"
kill_all_flash

echo "==> Removing legacy LaunchAgent (autostart now lives in-app via SMAppService)"
launchctl bootout "gui/$(id -u)" "$LOGIN_AGENT_PATH" >/dev/null 2>&1 || true
rm -f "$LOGIN_AGENT_PATH"

echo "==> Installing CLI symlink"
mkdir -p "$CLI_LINK_DIR"
# The `flash` binary is fat: argv-less it runs the resident app, with argv
# it AppleEvents the verb to the resident and exits. There's only one
# Mach-O to symlink.
ln -sf "$INSTALL_PATH/Contents/MacOS/flash" "$CLI_LINK_PATH"

echo "==> Starting fresh resident process"
TAP_STATUS=$(launch_flash_and_check_tap)

NEW_PIDS=$(pgrep -f "$INSTALL_PATH/Contents/MacOS/flash" 2>/dev/null || true)
ALL_PIDS=$(pgrep -f "$APP_NAME.app/Contents/MacOS/flash" 2>/dev/null || true)
echo "==> Verification"
echo "  Installed PIDs: ${NEW_PIDS:-none}"
echo "  All Flash PIDs: ${ALL_PIDS:-none}"
echo "  Signed with:    $SIGN_IDENTITY"
echo "  CLI:            $CLI_LINK_PATH"
case "$TAP_STATUS" in
  ok) echo "  Accessibility:  ✓ keyboard-capture tap installed" ;;
  denied) echo "  Accessibility:  ✗ NOT granted — keyboard tap could not be created" ;;
  *) echo "  Accessibility:  ? unconfirmed (no tap status logged within ~6s)" ;;
esac
if [[ -z "${NEW_PIDS:-}" ]]; then
  echo "  WARNING: the installed copy is not running. Check Console.app for launch errors."
fi

# A running Flash with no Accessibility grant is silently broken: NORMAL mode
# falls back to key-window capture and stops catching keys. TCC grants can't be
# scripted, so walk the user through the one-time grant and finish the job —
# the tap is only created at launch, so Flash must be restarted once enabled.
if [[ "$TAP_STATUS" != "ok" && -n "${NEW_PIDS:-}" ]]; then
  echo
  echo "⚠️  Flash is running but can't capture keys yet — macOS hasn't granted it"
  echo "    Accessibility. This is a ONE-TIME step; the grant then persists across"
  echo "    '--dev' rebuilds (they share the stable \"$DEV_SIGN_IDENTITY\" certificate)."
  echo
  echo "    Opening System Settings ▸ Privacy & Security ▸ Accessibility…"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
  echo "    → Enable \"$APP_NAME\". If it's already listed from an older signature,"
  echo "      toggle it OFF then ON — or: tccutil reset Accessibility $BUNDLE_ID"
  if [[ -t 0 ]]; then
    read -r -t 180 -p "    Press Enter once enabled to restart Flash and verify… " _ || true
    echo
    kill_all_flash
    TAP_STATUS=$(launch_flash_and_check_tap)
    if [[ "$TAP_STATUS" == "ok" ]]; then
      echo "  Accessibility:  ✓ keyboard-capture tap installed — Flash is ready."
    else
      echo "  Accessibility:  still '$TAP_STATUS'. Enable $APP_NAME, then re-run:"
      echo "                  ./Scripts/install.sh --$MODE"
    fi
  else
    echo "    Then re-run: ./Scripts/install.sh --$MODE"
  fi
fi

echo
echo "Installed: $INSTALL_PATH"
echo "Triggers:"
echo "  flash mouse_target"
echo "  flash mouse_target secondary=1"
echo "  flash hints_dismiss"
echo "  flash flash_quit"
echo "  flash help_show"
