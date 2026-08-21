#!/usr/bin/env bash
set -euo pipefail

# Scaffold a new bundled Rust plugin under Plugins/<id>/ as a hermetic
# standalone crate: manifest, Cargo.toml (path dep on the shared SDK +
# per-crate build profiles), the canonical clippy.toml copy, a committed
# Cargo.lock, and a minimal command-handling main.rs. The generated plugin
# exposes a single `:<id> ping` command so it builds, loads, and answers
# immediately; edit src/main.rs to add real behavior. No other files need
# touching — every consumer (build-plugins.sh, the host, the Swift plugin
# tests) discovers plugins by globbing Plugins/*/manifest.json.
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
  "exec": ["./flash-plugin-$ID"],
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
flash_plugin = { path = "../_flash_plugin_rust" }

# Dev hot-loop profile used by Scripts/build-plugins.sh: mild optimization
# (fully-unoptimized tokio is visibly slow under the plugin latency contracts),
# line-tables-only debuginfo keeps the shared target dir small.
[profile.plugin-dev]
inherits = "dev"
opt-level = 1
debug = "line-tables-only"

# Long-lived resident child process: optimize for size and cold start.
[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
strip = true
panic = "abort"
TOML

# Every Rust plugin carries a byte-identical copy of the canonical clippy
# config (clippy discovers config by walking up from the invocation cwd);
# check-guardrails.sh fails if a copy drifts from the canonical one.
cp "$PROJECT_DIR/Plugins/_flash_plugin_rust/clippy.toml" "$DIR/clippy.toml"

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

CARGO_TARGET_DIR="$PROJECT_DIR/build/plugin-target" \
  cargo generate-lockfile --manifest-path "$DIR/Cargo.toml"

echo "Created hermetic plugin crate Plugins/$ID (commit its Cargo.lock)"
echo
echo "Iterate with:"
echo "  ./Scripts/build-plugins.sh dev $ID   # build + stage just this plugin"
echo "  tail -f ~/Library/Logs/Flash/flash.log   # watcher restarts it on the swap"
echo "  flash help_show                      # or :$ID ping from the command line"
