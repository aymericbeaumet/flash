#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  update-homebrew-cask.sh --tap-dir PATH --token TOKEN --version VERSION --url URL --sha256 SHA256
EOF
}

die() {
  echo "error: $*" >&2
  usage >&2
  exit 2
}

TAP_DIR=""
TOKEN=""
VERSION=""
URL=""
SHA256=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tap-dir)
      TAP_DIR="${2:-}"
      shift 2
      ;;
    --token)
      TOKEN="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --url)
      URL="${2:-}"
      shift 2
      ;;
    --sha256)
      SHA256="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$TAP_DIR" ]] || die "--tap-dir is required"
[[ -n "$TOKEN" ]] || die "--token is required"
[[ -n "$VERSION" ]] || die "--version is required"
[[ -n "$URL" ]] || die "--url is required"
[[ -n "$SHA256" ]] || die "--sha256 is required"

mkdir -p "$TAP_DIR/Casks"
CASK_PATH="$TAP_DIR/Casks/$TOKEN.rb"

cat >"$CASK_PATH" <<RUBY
# This cask is automatically updated by aymericbeaumet/flash. DO NOT EDIT.

cask "$TOKEN" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$URL",
      verified: "github.com/aymericbeaumet/flash/"
  name "Flash"
  desc "Keyboard hints to click any on-screen control"
  homepage "https://github.com/aymericbeaumet/flash"

  depends_on macos: ">= :sonoma"

  app "Flash.app"
  binary "#{appdir}/Flash.app/Contents/MacOS/flash", target: "flash"

  # Autostart is owned by the app (SMAppService, [app] autostart). Remove the
  # LaunchAgent that earlier casks installed, then start Flash so it registers
  # its login item and walks the user through the Accessibility grant.
  postflight do
    legacy_agent = File.expand_path("~/Library/LaunchAgents/com.flash.app.autolaunch.plist")
    if File.exist?(legacy_agent)
      system_command "/bin/launchctl",
                     args: ["bootout", "gui/#{Process.uid}", legacy_agent],
                     must_succeed: false
      File.delete(legacy_agent)
    end
    system_command "/usr/bin/open",
                   args: ["-g", "#{appdir}/Flash.app"],
                   must_succeed: false
  end

  uninstall quit: "com.flash.app"

  zap trash: [
    "~/.config/flash",
    "~/Library/Application Support/Flash",
    "~/Library/Application Support/Mozilla/NativeMessagingHosts/com.flash.firefox_bridge.json",
    "~/Library/Logs/Flash",
  ]

  caveats <<~EOS
    Flash needs the Accessibility permission to read and click controls:
      System Settings → Privacy & Security → Accessibility

    Flash is not notarized yet. If macOS blocks the first launch, allow it in
      System Settings → Privacy & Security → Open Anyway
  EOS
end
RUBY

echo "$CASK_PATH"
