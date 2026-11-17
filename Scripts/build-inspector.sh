#!/usr/bin/env bash
# Build the Svelte inspector single-file bundle, and the manual it serves.
#
# Usage: build-inspector.sh [--dev|--release]   (default: --release)
#   --release  optimized, minified production build, staged into the
#              committed SwiftPM resource Sources/flash/Resources/inspector.html
#              so a plain `swift build` ships it.
#   --dev      fast development build (unminified, sourcemapped). Left at
#              Inspector/dist/index.html for the caller to drop into an
#              already-built app bundle, keeping the committed resource pristine.
#
# Both modes also bundle docs/ into build/docs (docs.json, search.json,
# routes.json and the files pages link), which assemble_app copies to
# Contents/Resources/docs for the resident's /docs pages and `:help`
# completion. Bundling fails on a broken link or anchor.
#
# `swift build` does NOT run this — it ships whatever
# `Sources/flash/Resources/inspector.html` currently holds.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
parse_mode "$@"

cd "$PROJECT_DIR/Inspector"

[[ -f pnpm-lock.yaml ]] || { echo "error: missing Inspector/pnpm-lock.yaml" >&2; exit 1; }
pnpm install --frozen-lockfile
if [[ "$MODE" == "dev" ]]; then
  pnpm run build:dev
else
  pnpm run build
fi

# The bundled manual pins its repository links to the commit it ships from,
# like the About panel's FlashGitCommit.
revision="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || true)"
if [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
  node scripts/site.ts bundle "$PROJECT_DIR/build/docs" "--revision=$revision"
else
  node scripts/site.ts bundle "$PROJECT_DIR/build/docs"
fi

if [[ "$MODE" == "release" ]]; then
  cp "$PROJECT_DIR/Inspector/dist/index.html" "$PROJECT_DIR/Sources/flash/Resources/inspector.html"
  echo "staged Sources/flash/Resources/inspector.html (release)"
else
  echo "built Inspector/dist/index.html (dev; not staged into the committed resource)"
fi
