#!/usr/bin/env bash
set -euo pipefail

# Build every executable bundled plugin as a hermetic Rust crate. Dev binaries
# land next to their manifests; release binaries stay in build/plugin-release
# so packaging never changes the live plugin tree. Manifest-only plugins have
# no process to build.
#
# All build artifacts land under build/plugin-target (never inside the
# watched plugin trees, so the dev file-watcher never sees intermediate
# files). The repository pins Rust through mise.
#
# Usage: build-plugins.sh [dev|release] [id…]
#   dev       — native-arch `plugin-dev` build, signed with the stable dev
#               identity so TCC grants persist across rebuilds.
#   release   — optimized universal binaries (x86_64 + arm64) via lipo.
#   id…       — optional plugin ids; `build-plugins.sh dev tmux` is the
#               single-plugin hot loop.

MODE="${1:-release}"
if [[ $# -gt 0 ]]; then shift; fi
ONLY=("$@")

source "$(cd "$(dirname "$0")" && pwd)/_common.sh"
cd "$PROJECT_DIR"

TARGET_DIR="$PROJECT_DIR/build/plugin-target"
RELEASE_DIR="$PROJECT_DIR/build/plugin-release"
export CARGO_TARGET_DIR="$TARGET_DIR"
# rustc and the cc crate stamp this as each binary's minimum macOS; Rust's own
# default is older than the app's.
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MINIMUM"
mkdir -p "$TARGET_DIR"

# A real plugin is defined by its manifest.json; support crates such as the
# shared SDK at Plugins/_flash_plugin_rust have none and are built only as
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

build_dirs=()
for dir in "${plugin_dirs[@]}"; do
  [[ -f "$dir/Cargo.toml" ]] && build_dirs+=("$dir")
done

echo "==> Building ${#build_dirs[@]} compiled plugin(s) of ${#plugin_dirs[@]} selected ($MODE)"

# Rust plugins are hermetic standalone crates — one cargo invocation per dir.
# The shared CARGO_TARGET_DIR still dedupes SDK/dep artifacts across crates
# (cargo keys compiled artifacts by package-id + metadata hash). Release
# builds use committed Cargo.lock files. Update those locks deliberately with
# `cargo update` when changing dependencies.
for dir in "${build_dirs[@]}"; do
  if [[ "$MODE" == "release" ]]; then
    cargo build --manifest-path "$dir/Cargo.toml" --release --locked \
      --target x86_64-apple-darwin \
      --target aarch64-apple-darwin
  else
    cargo build --manifest-path "$dir/Cargo.toml" --profile plugin-dev --locked
  fi
done

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
# Every declared `[[bin]]`, including companions, uses the same publication
# flow: the live manifest directory for dev, isolated build output for release.
# A crate with no explicit `[[bin]]` produces `flash-plugin-<id>`.
stage_dir="$(mktemp -d "$TARGET_DIR/plugin-stage.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
staged_paths=()
destinations=()
for dir in "${build_dirs[@]}"; do
  id="$(basename "$dir")"
  destination_dir="$dir"
  if [[ "$MODE" == "release" ]]; then
    destination_dir="$RELEASE_DIR/$id"
    rm -rf "$destination_dir"
    mkdir -p "$destination_dir"
  fi
  while IFS= read -r bin; do
    [[ -n "$bin" ]] || continue
    staged="$stage_dir/$bin"
    if [[ "$MODE" == "release" ]]; then
      lipo -create \
        "$TARGET_DIR/x86_64-apple-darwin/release/$bin" \
        "$TARGET_DIR/aarch64-apple-darwin/release/$bin" \
        -output "$staged"
    else
      cp "$TARGET_DIR/plugin-dev/$bin" "$staged"
    fi
    chmod +x "$staged"
    staged_paths+=("$staged")
    destinations+=("$destination_dir/$bin")
  done < <(crate_binaries "$dir/Cargo.toml" "flash-plugin-$id")
done

if [[ "$MODE" != "release" && -n "${DEV_PLUGIN_SIGN_IDENTITY:-}" ]] &&
  ((${#staged_paths[@]} > 0)); then
  codesign --force \
    --sign "$DEV_PLUGIN_SIGN_IDENTITY" \
    ${staged_paths[@]+"${staged_paths[@]}"} >/dev/null
fi

signature_fingerprint() {
  local details
  details="$(codesign -d --verbose=4 -r- "$1" 2>&1)" || return 1
  [[ "$details" == *"CandidateCDHashFull sha256="* ]] || return 1
  printf '%s\n' "$details" | awk \
    '/^(CandidateCDHashFull sha256=|Authority=|TeamIdentifier=|designated =>)/'
}

same_dev_artifact() {
  local staged_signature installed_signature
  [[ -f "$2" ]] || return 1
  cmp -s "$1" "$2" && return 0
  # CMS signing timestamps change bytes on every signed build. Compare the
  # native code directory and certificate requirement, then verify the old
  # file still matches that signature. Universal release builds always swap.
  staged_signature="$(signature_fingerprint "$1")" || return 1
  installed_signature="$(signature_fingerprint "$2")" || return 1
  [[ "$staged_signature" == "$installed_signature" ]] || return 1
  codesign --verify --strict "$2" >/dev/null 2>&1
}

for ((i = 0; i < ${#staged_paths[@]}; i++)); do
  staged="${staged_paths[$i]}"
  destination="${destinations[$i]}"
  if [[ "$MODE" != "release" ]] && same_dev_artifact "$staged" "$destination"; then
    continue
  fi
  mv -f "$staged" "$destination"
done

# Post-condition: a manifest that declares `exec` must be backed by a crate and
# by a published binary. The Cargo.toml filter above exists for manifest-only
# plugins, but it is silent — a plugin directory whose crate has not landed
# installs a manifest whose binary nobody builds, and the host cannot tell that
# apart from a crash loop: it spends its restart budget, parks the plugin and
# drops its warm catalog, so the source reads empty until the next restart.
missing=0
for dir in "${plugin_dirs[@]}"; do
  id="$(basename "$dir")"
  published="$dir/flash-plugin-$id"
  [[ "$MODE" != "release" ]] || published="$RELEASE_DIR/$id/flash-plugin-$id"
  grep -q '"exec"' "$dir/manifest.json" || continue
  if [[ ! -f "$dir/Cargo.toml" ]]; then
    echo "plugin $id declares exec but has no Cargo.toml — nothing builds its binary" >&2
    missing=1
  elif [[ ! -x "$published" ]]; then
    echo "plugin $id declares exec but $published is missing after the build" >&2
    missing=1
  fi
done
((missing == 0)) || exit 1
exit 0
