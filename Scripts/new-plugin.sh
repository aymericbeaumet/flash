#!/usr/bin/env bash
set -euo pipefail

# Scaffold a new bundled Rust plugin under Plugins/<id>/ with a manifest,
# Cargo.toml, and a minimal command-handling main.rs. The generated plugin
# registers a single `:<id> ping` command so it builds and runs immediately;
# edit src/main.rs to add real behavior.
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
  "commands": [
    { "command": "$ID", "subcommand": "ping", "description": "Smoke-test the $NAME plugin" }
  ]
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
flash-plugin = { path = "../_flash_plugin_rust" }
serde_json = "1"
tokio = { version = "1", default-features = false, features = [
  "rt-multi-thread",
  "macros",
  "io-std",
  "io-util",
  "process",
  "time",
  "sync",
] }

[profile.release]
opt-level = "z"
lto = true
codegen-units = 1
strip = true
panic = "abort"
TOML

cat >"$DIR/src/main.rs" <<'RUST'
use flash_plugin::serde_json::{json, Value};
use flash_plugin::{run, str_field, Context, Plugin};

struct PluginImpl;

impl Plugin for PluginImpl {
    async fn handle(&self, _ctx: Context, method: String, params: Value) -> Value {
        if method != "command.invoke" {
            return json!({ "ok": false, "error": format!("unknown method: {method}") });
        }
        match str_field(&params, "subcommand") {
            "ping" => json!({ "ok": true, "stdout": "pong" }),
            other => json!({ "ok": false, "error": format!("unknown subcommand: {other}") }),
        }
    }
}

fn main() {
    run(PluginImpl);
}
RUST

echo "Created Plugins/$ID"
echo "Next: add \"$ID\" to the expected-id set in Tests/FlashTests/PluginSystemTests.swift,"
echo "then run Scripts/build-plugins.sh."
