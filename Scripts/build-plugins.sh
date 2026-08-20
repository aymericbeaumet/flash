#!/usr/bin/env bash
set -euo pipefail

# Build every compiled bundled plugin and drop each binary next to its
# manifest.json as `flash-plugin-<id>`. Language is detected per plugin dir
# by convention — Rust is the default for new plugins:
#   Cargo.toml  → Rust   (one workspace-aware cargo invocation for all)
#   go.mod      → Go     (mise-pinned toolchain)
#   main.zig    → Zig    (mise-pinned toolchain)
#   main.swift  → Swift  (Xcode toolchain, same as the host app)
#   none        → interpreted (python3/ruby/bun via manifest exec; nothing
#                 to build — sources run in place)
#
# Every language links its shared per-language SDK from the sibling
# Plugins/_<language>_flash_plugin directory: Rust via the workspace path
# dep, Go via a go.mod replace, Zig via the flashplugin module below, Swift
# by compiling the SDK source alongside main.swift. Interpreted SDKs
# (python/ruby/typescript) are imported relatively at runtime and staged
# into the release bundle by Scripts/_common.sh.
#
# All build artifacts land under build/plugin-target (never inside the
# watched plugin trees, so the dev file-watcher never sees intermediate
# files). Toolchains come from mise (repo mise.toml pins them); rust stays
# rustup-managed for its multi-target universal builds.
#
# Usage: build-plugins.sh [dev|release] [id…]
#   dev       — native-arch build (`plugin-dev` cargo profile / go build /
#               zig ReleaseSafe), signed with the stable dev identity so
#               TCC grants persist across rebuilds.
#   release   — optimized universal binaries (x86_64 + arm64) via lipo.
#   id…       — optional plugin ids; `build-plugins.sh dev tmux` is the
#               single-plugin hot loop.

MODE="${1:-release}"
if [[ $# -gt 0 ]]; then shift; fi
ONLY=("$@")

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

TARGET_DIR="$PROJECT_DIR/build/plugin-target"
export CARGO_TARGET_DIR="$TARGET_DIR"
mkdir -p "$TARGET_DIR/other"

if [[ "$MODE" == "release" ]]; then
  # Make sure both Apple targets are available; harmless if already added.
  rustup target add x86_64-apple-darwin aarch64-apple-darwin >/dev/null 2>&1 || true
fi

# A real plugin is defined by its manifest.json; support crates such as the
# shared SDK at Plugins/_rust_flash_plugin have none and are built only as
# dependencies.
plugin_dirs=()
for manifest in Plugins/*/manifest.json; do
  [[ -e "$manifest" ]] || continue
  dir="$(dirname "$manifest")"
  if ((${#ONLY[@]})); then
    keep=0
    for want in "${ONLY[@]}"; do
      [[ "$want" == "$(basename "$dir")" ]] && keep=1
    done
    ((keep)) || continue
  fi
  plugin_dirs+=("$dir")
done

# Reject typo'd ids loudly instead of silently building nothing. (The
# ${arr[@]+…} idiom keeps empty-array expansion safe under macOS bash 3.2's
# set -u.)
if ((${#ONLY[@]})); then
  fail=0
  for want in "${ONLY[@]}"; do
    found=0
    for dir in ${plugin_dirs[@]+"${plugin_dirs[@]}"}; do
      [[ "$(basename "$dir")" == "$want" ]] && found=1
    done
    if ((!found)); then
      echo "unknown plugin id: $want" >&2
      fail=1
    fi
  done
  ((fail)) && exit 1
fi

if ((${#plugin_dirs[@]} == 0)); then
  echo "no plugins found under Plugins/*/manifest.json" >&2
  exit 1
fi

rust_pkg_args=()
build_dirs=()
for dir in "${plugin_dirs[@]}"; do
  if [[ -f "$dir/Cargo.toml" ]]; then
    rust_pkg_args+=(-p "flash-plugin-$(basename "$dir")")
    build_dirs+=("$dir")
  elif [[ -f "$dir/go.mod" || -f "$dir/main.zig" || -f "$dir/main.swift" ]]; then
    build_dirs+=("$dir")
  fi
done

echo "==> Building ${#build_dirs[@]} compiled plugin(s) of ${#plugin_dirs[@]} selected ($MODE)"

if ((${#rust_pkg_args[@]})); then
  if [[ "$MODE" == "release" ]]; then
    cargo build --manifest-path Plugins/Cargo.toml --release \
      --target x86_64-apple-darwin \
      --target aarch64-apple-darwin \
      "${rust_pkg_args[@]}"
  else
    cargo build --manifest-path Plugins/Cargo.toml --profile plugin-dev \
      "${rust_pkg_args[@]}"
  fi
fi

# Build a Go or Zig plugin into $TARGET_DIR/other/<name>; echoes nothing,
# artifacts stay out of the watched plugin trees.
build_other() {
  local dir="$1" id="$2" out="$3" arch="$4" # arch: native|x86_64|aarch64
  if [[ -f "$dir/go.mod" ]]; then
    local goenv=(GOFLAGS=-trimpath CGO_ENABLED=0)
    case "$arch" in
      x86_64) goenv+=(GOOS=darwin GOARCH=amd64) ;;
      aarch64) goenv+=(GOOS=darwin GOARCH=arm64) ;;
    esac
    (cd "$dir" && env "${goenv[@]}" mise exec go -- go build -o "$out" .)
  elif [[ -f "$dir/main.swift" ]]; then
    local swiftargs=(-O)
    case "$arch" in
      x86_64) swiftargs+=(-target x86_64-apple-macos14.0) ;;
      aarch64) swiftargs+=(-target arm64-apple-macos14.0) ;;
    esac
    (cd "$dir" && xcrun swiftc "${swiftargs[@]}" \
      main.swift ../_swift_flash_plugin/flashplugin.swift -o "$out")
  else
    local zigargs=(-O ReleaseSafe -lc -femit-bin="$out")
    case "$arch" in
      x86_64) zigargs+=(-target x86_64-macos) ;;
      aarch64) zigargs+=(-target aarch64-macos) ;;
    esac
    (cd "$dir" && mise exec zig -- zig build-exe \
      --dep flashplugin -Mroot=main.zig \
      -Mflashplugin=../_zig_flash_plugin/flashplugin.zig "${zigargs[@]}")
  fi
}

# Stage every binary at a temp path, sign the staged files, then swap each
# in with an atomic `mv`. Overwriting the destination *in place* modifies an
# already-signed Mach-O's bytes, which invalidates the kernel's cached
# code-signature and makes the next exec die with "Killed: 9". A rename
# installs a fresh inode whose signature the kernel re-evaluates cleanly.
# Signing BEFORE the rename matters too: the dev file-watcher's restart
# debounce starts at the rename, so the binary must already carry its final
# signature when it lands — TCC-gated plugins get re-prompted on every
# cdhash change unless their designated-requirement clause matches the same
# stable cert the host bundle uses.
staged_paths=()
for dir in "${build_dirs[@]}"; do
  id="$(basename "$dir")"
  bin="flash-plugin-$id"
  staged="$dir/$bin.staged"
  if [[ -f "$dir/Cargo.toml" ]]; then
    if [[ "$MODE" == "release" ]]; then
      lipo -create \
        "$TARGET_DIR/x86_64-apple-darwin/release/$bin" \
        "$TARGET_DIR/aarch64-apple-darwin/release/$bin" \
        -output "$staged"
    else
      cp "$TARGET_DIR/plugin-dev/$bin" "$staged"
    fi
  else
    echo "==> Building plugin $id ($MODE)"
    if [[ "$MODE" == "release" ]]; then
      build_other "$dir" "$id" "$TARGET_DIR/other/$bin-x86_64" x86_64
      build_other "$dir" "$id" "$TARGET_DIR/other/$bin-aarch64" aarch64
      lipo -create \
        "$TARGET_DIR/other/$bin-x86_64" \
        "$TARGET_DIR/other/$bin-aarch64" \
        -output "$staged"
    else
      build_other "$dir" "$id" "$TARGET_DIR/other/$bin" native
      cp "$TARGET_DIR/other/$bin" "$staged"
    fi
  fi
  chmod +x "$staged"
  staged_paths+=("$staged")
done

if [[ "$MODE" != "release" && -n "${DEV_PLUGIN_SIGN_IDENTITY:-}" ]] &&
  ((${#staged_paths[@]} > 0)); then
  codesign --force \
    --sign "$DEV_PLUGIN_SIGN_IDENTITY" \
    ${staged_paths[@]+"${staged_paths[@]}"} >/dev/null
fi

for staged in ${staged_paths[@]+"${staged_paths[@]}"}; do
  mv -f "$staged" "${staged%.staged}"
done
