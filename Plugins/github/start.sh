#!/bin/sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
DATA="${FLASH_PLUGIN_DATA_DIR:?}"
mkdir -p "$DATA/bin" "$DATA/home" "$DATA/config" "$DATA/cache" "$DATA/share"
export PATH="$DATA/bin:$PATH"
export HOME="$DATA/home"
export XDG_CONFIG_HOME="$DATA/config"
export XDG_CACHE_HOME="$DATA/cache"
export XDG_DATA_HOME="$DATA/share"
export GH_CONFIG_DIR="$DATA/config/gh"
export PYTHONDONTWRITEBYTECODE=1
exec python3 -B "$DIR/plugin.py"
