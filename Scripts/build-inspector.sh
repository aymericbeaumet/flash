#!/usr/bin/env bash
# Build the Svelte inspector single-file bundle.
#
# Usage: build-inspector.sh [--dev|--release]   (default: --release)
#   --release  optimized, minified production build, staged into the
#              committed SwiftPM resource Sources/flash/Resources/inspector.html
#              so a plain `swift build` ships it.
#   --dev      fast development build (unminified, sourcemapped). Left at
#              Inspector/dist/index.html for the caller to drop into an
#              already-built app bundle, keeping the committed resource pristine.
#
# `swift build` does NOT run this — it ships whatever
# `Sources/flash/Resources/inspector.html` currently holds.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
parse_mode "$@"

cd "$PROJECT_DIR/Inspector"

[[ -f pnpm-lock.yaml ]] || { echo "error: missing Inspector/pnpm-lock.yaml" >&2; exit 1; }
PNPM_CONFIG_UPDATE_NOTIFIER=false pnpm install --frozen-lockfile
if [[ "$MODE" == "dev" ]]; then
  pnpm run build:dev
else
  pnpm run build
fi

if [[ "$MODE" == "release" ]]; then
  cp "$PROJECT_DIR/Inspector/dist/index.html" "$PROJECT_DIR/Sources/flash/Resources/inspector.html"
  echo "staged Sources/flash/Resources/inspector.html (release)"
else
  echo "built Inspector/dist/index.html (dev; not staged into the committed resource)"
fi
