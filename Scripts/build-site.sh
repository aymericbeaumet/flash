#!/usr/bin/env bash
# Build the published documentation site into build/site.
#
# Usage: build-site.sh [<output directory>]   (default: build/site)
#
# docs/*.md, ordered by docs/nav.json, is the one source of the manual: the
# resident serves it at /docs/<page> from its bundle, and this prerenders the
# same Svelte docs view for every page at <site>/<page>/ (the site's URL is in
# docs/nav.json). The build fails on a broken link or anchor, a page missing
# from the navigation or a navigation entry without its file, and on any
# rendered link that leaves the site or points at a local help route.
# .github/workflows/pages.yml deploys the result to GitHub Pages.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

out="${1:-$PROJECT_DIR/build/site}"
case "$out" in
  /*) ;;
  *) out="$PWD/$out" ;;
esac

cd "$PROJECT_DIR/Inspector"
[[ -f pnpm-lock.yaml ]] || { echo "error: missing Inspector/pnpm-lock.yaml" >&2; exit 1; }
pnpm install --frozen-lockfile
node scripts/site.ts site "$out"
