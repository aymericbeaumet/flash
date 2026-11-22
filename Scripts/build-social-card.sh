#!/usr/bin/env bash
# Render the card a shared link shows into docs/assets/social-card.jpg.
#
# Usage: build-social-card.sh [<Chrome executable>]
#
# Scripts/social-card.html is the card, 1280 by 640. The published site names
# it as every page's og:image (Inspector/scripts/site.ts), and it is the image
# to upload as the repository's social preview (GitHub has no API for that:
# Settings > General > Social preview). Headless Chrome renders the page; sips
# writes the app icon it shows and the JPEG. Chrome is a system application,
# like the browsers the fixtures and benchmarks drive.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

chrome="${1:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[[ -x "$chrome" ]] || { echo "error: no Chrome executable at $chrome" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$PROJECT_DIR/Scripts/social-card.html" "$work/card.html"
sips -s format png -z 512 512 "$PROJECT_DIR/Resources/AppIcon.icns" --out "$work/icon.png" >/dev/null
"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1280,640 --user-data-dir="$work/profile" \
  --screenshot="$work/card.png" "file://$work/card.html" >/dev/null 2>&1
[[ -s "$work/card.png" ]] || { echo "error: Chrome rendered no card" >&2; exit 1; }
sips -s format jpeg -s formatOptions 90 "$work/card.png" \
  --out "$PROJECT_DIR/docs/assets/social-card.jpg" >/dev/null
echo "wrote docs/assets/social-card.jpg"
