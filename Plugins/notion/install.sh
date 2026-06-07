#!/bin/sh
set -eu
mkdir -p "${FLASH_PLUGIN_DATA_DIR:?}/bin"
curl -fsSL https://ntn.dev | NTN_INSTALL_DIR="$FLASH_PLUGIN_DATA_DIR/bin" bash
