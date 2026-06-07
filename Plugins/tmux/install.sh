#!/bin/sh
set -eu

# The tmux binary is installed by the user via their package manager;
# the plugin probes standard Homebrew + macOS locations at startup.
# We only need to make sure PyObjC is reachable so the alacritty cell
# metrics path (NSFont ascender/descender/advance) can run. Without
# PyObjC the plugin falls back to `window / cells`, which ignores
# Alacritty's content padding and scatters the hint chips off-grid.

DATA="${FLASH_PLUGIN_DATA_DIR:?}"
LIB="$DATA/lib"
mkdir -p "$LIB"

if ! python3 -c "import sys; sys.path.insert(0, '$LIB'); import AppKit" >/dev/null 2>&1; then
  echo "==> Installing PyObjC into $LIB"
  python3 -m pip install \
    --target "$LIB" \
    --upgrade \
    --quiet \
    --disable-pip-version-check \
    pyobjc
fi
