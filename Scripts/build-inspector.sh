#!/usr/bin/env bash
# Build the Svelte inspector and stage the single-file bundle as a SwiftPM
# resource. `swift build` does NOT run this — it ships the committed
# `Sources/flash/Resources/inspector.html`. Run this whenever the UI in
# `Inspector/` changes, then commit the regenerated resource.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/Inspector"

if command -v pnpm >/dev/null 2>&1; then
  pnpm install
  pnpm build
elif command -v npm >/dev/null 2>&1; then
  npm install
  npm run build
else
  echo "error: need pnpm or npm to build the inspector" >&2
  exit 1
fi

cp "$root/Inspector/dist/index.html" "$root/Sources/flash/Resources/inspector.html"
echo "staged Sources/flash/Resources/inspector.html"
