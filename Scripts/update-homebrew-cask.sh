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
  desc "Headless hint overlay for macOS"
  homepage "https://github.com/aymericbeaumet/flash"

  depends_on macos: ">= :sonoma"

  app "Flash.app"
  binary "#{appdir}/Flash.app/Contents/MacOS/flash", target: "flash"

  postflight do
    launch_agent = File.expand_path("~/Library/LaunchAgents/com.flash.app.autolaunch.plist")
    system_command "/bin/mkdir", args: ["-p", File.dirname(launch_agent)]
    File.write(launch_agent, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>Label</key>
          <string>com.flash.app.autolaunch</string>
          <key>ProgramArguments</key>
          <array>
              <string>/usr/bin/open</string>
              <string>-g</string>
              <string>/Applications/Flash.app</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
      </dict>
      </plist>
    PLIST
    system_command "/bin/chmod", args: ["644", launch_agent]
    system_command "/bin/launchctl",
                   args: ["bootout", "gui/#{Process.uid}", launch_agent],
                   must_succeed: false
    system_command "/bin/launchctl",
                   args: ["bootstrap", "gui/#{Process.uid}", launch_agent],
                   must_succeed: false
    system_command "/bin/launchctl",
                   args: ["enable", "gui/#{Process.uid}/com.flash.app.autolaunch"],
                   must_succeed: false
    system_command "/usr/bin/open",
                   args: ["-g", "/Applications/Flash.app"],
                   must_succeed: false
  end

  uninstall launchctl: "com.flash.app.autolaunch",
            quit: "com.flash.app",
            delete: "~/Library/LaunchAgents/com.flash.app.autolaunch.plist"

  zap trash: [
    "~/Library/Logs/Flash",
    "~/.config/flash",
  ]
end
RUBY

echo "$CASK_PATH"
