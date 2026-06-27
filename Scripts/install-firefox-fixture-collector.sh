#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXTENSION_DIR="$PROJECT_DIR/Resources/firefox-fixture-collector"
BUILD_DIR="$PROJECT_DIR/build/firefox-fixture-collector"
XPI_PATH="$BUILD_DIR/flash-fixture-collector.xpi"
HOST_NAME="com.flash.fixture_collector"
HOST_SCRIPT="$PROJECT_DIR/Scripts/flash-fixture-collector-host.py"
HOST_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
HOST_MANIFEST="$HOST_DIR/$HOST_NAME.json"
EXTENSION_ID="flash-fixture-collector@aymericbeaumet.com"

mkdir -p "$BUILD_DIR" "$HOST_DIR"
chmod +x "$HOST_SCRIPT"

python3 - "$HOST_MANIFEST" "$HOST_SCRIPT" "$EXTENSION_ID" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
host_script = sys.argv[2]
extension_id = sys.argv[3]
payload = {
    "name": "com.flash.fixture_collector",
    "description": "Write sanitized Flash browser fixtures into the local checkout.",
    "path": host_script,
    "type": "stdio",
    "allowed_extensions": [extension_id],
}
manifest_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

rm -f "$XPI_PATH"
(
  cd "$EXTENSION_DIR"
  zip -qr "$XPI_PATH" manifest.json background.js content-script.js
)

cat <<EOF
Installed native host:
  $HOST_MANIFEST

Packaged extension:
  $XPI_PATH

Firefox Release requires a signed extension for permanent daily use. This
script prepares the native host and XPI. Install the signed XPI in stable
Firefox, or load the XPI temporarily from about:debugging while iterating.

Extension id:
  $EXTENSION_ID
EOF
