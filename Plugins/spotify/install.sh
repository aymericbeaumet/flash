#!/bin/sh
set -eu
cd "$(dirname "$0")"
python3 ../_lib/install_cli.py spotify
