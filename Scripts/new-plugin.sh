#!/usr/bin/env bash
set -euo pipefail

# Scaffold a new bundled Rust plugin under Plugins/<id>/ with a manifest,
# Cargo.toml, and a minimal command-handling main.rs, and register it in the
# workspace members list. The generated plugin exposes a single `:<id> ping`
# command so it builds, loads, and answers immediately; edit src/main.rs to
# add real behavior. No other files need touching — the Swift plugin tests
# discover plugins by globbing Plugins/*/manifest.json.
#
# Usage: new-plugin.sh <id> "<Display Name>" "<one-line description>"
#   <id>  lowercase [a-z0-9._-], also the binary name suffix.

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <id> \"<Display Name>\" \"<description>\"" >&2
  exit 2
fi

ID="$1"
NAME="$2"
DESCRIPTION="$3"

if [[ ! "$ID" =~ ^[a-z0-9._-]+$ ]]; then
  echo "error: id must match [a-z0-9._-]+ (got: $ID)" >&2
  exit 2
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$PROJECT_DIR/Plugins/$ID"

if [[ -e "$DIR" ]]; then
  echo "error: $DIR already exists" >&2
  exit 1
fi

mkdir -p "$DIR/src"

cat >"$DIR/manifest.json" <<JSON
{
  "id": "$ID",
  "name": "$NAME",
  "version": "0.1.0",
  "description": "$DESCRIPTION",
  "install": "true",
  "start": "exec ./flash-plugin-$ID",
  "commands": {
    "items": [
      {
        "command": "$ID",
        "subcommand": "ping",
        "description": "Smoke-test the $NAME plugin"
      }
    ]
  }
}
JSON

# Profiles are workspace-global (Plugins/Cargo.toml); per-crate Cargo.tomls
# carry only their own dependencies.
cat >"$DIR/Cargo.toml" <<TOML
[package]
name = "flash-plugin-$ID"
version = "0.1.0"
edition = "2021"
license = "MIT"

[[bin]]
name = "flash-plugin-$ID"
path = "src/main.rs"

[dependencies]
flash_plugin = { path = "../_rust_flash_plugin" }
TOML

cat >"$DIR/src/main.rs" <<'RUST'
use flash_plugin::{run, CommandRequest, CommandResponse, Context};

struct PluginImpl;

flash_plugin::plugin!(PluginImpl);

impl FlashPlugin for PluginImpl {
    async fn on_command(&self, _ctx: Context, command: CommandRequest) -> CommandResponse {
        match command.subcommand.as_str() {
            "ping" => CommandResponse::toast("pong"),
            other => CommandResponse::error(format!("unknown subcommand: {other}")),
        }
    }
}

fn main() {
    run(PluginImpl);
}
RUST

# Register the crate in the explicit workspace members list (sorted
# insertion among the non-underscore entries) — an unlisted crate is
# invisible to build-plugins.sh's `-p` package selection.
awk -v id="$ID" '
  /^members = \[/ { in_members = 1 }
  in_members && /^\]/ {
    if (!inserted) { printf "  \"%s\",\n", id; inserted = 1 }
    in_members = 0
  }
  in_members && $0 ~ /^  "/ {
    member = $0
    gsub(/[" ,]/, "", member)
    if (!inserted && member !~ /^_/ && member > id) {
      printf "  \"%s\",\n", id
      inserted = 1
    }
  }
  { print }
' "$PROJECT_DIR/Plugins/Cargo.toml" >"$PROJECT_DIR/Plugins/Cargo.toml.new"
mv "$PROJECT_DIR/Plugins/Cargo.toml.new" "$PROJECT_DIR/Plugins/Cargo.toml"

echo "Created Plugins/$ID and registered it in Plugins/Cargo.toml"
echo
echo "Iterate with:"
echo "  ./Scripts/build-plugins.sh dev $ID   # build + stage just this plugin"
echo "  tail -f ~/Library/Logs/Flash/flash.log   # watcher restarts it on the swap"
echo "  flash help_show                      # or :$ID ping from the command line"
