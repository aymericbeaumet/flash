#!/usr/bin/env bash
# Builds the pinned libghostty-vt as the static XCFramework SwiftPM links.
#
# Usage: build-ghostty.sh [--dev|--release]   (default: --dev)
#   --dev      the host architecture. A universal framework already built for
#              this revision serves dev builds unchanged, so alternating
#              release and dev builds never rewrites it (or relinks SwiftPM).
#   --release  arm64 + x86_64, built in parallel and combined with lipo.
#
# Both modes use ReleaseFast. Per-architecture installs are stamped and kept
# under build/ghostty/<zig target>, so a later mode reuses a finished slice
# without invoking Zig. The x86_64 slice keeps Zig's macOS baseline (core2):
# Ghostty's build replaces a macOS target with its generic macOS target when
# building on macOS, which drops any -Dcpu model before compilation.
set -euo pipefail
cd "$(dirname "$0")/.."
revision=b40acce58dcf77df52231c3798ea58e924647c89
checksum=206f6e301bc96443020114390eddc68c8ce648f6195c50a4fae43b350531e2b1
zig_version=0.16.0
mode=${1:---dev}
[[ "$mode" == --dev || "$mode" == --release ]] || { echo "Usage: $0 [--dev|--release]" >&2; exit 2; }
[[ "$(zig version)" == "$zig_version" ]] || { echo "Install Zig $zig_version (mise install zig)." >&2; exit 1; }
cache="$PWD/build/ghostty"
output="$cache/ghostty-vt.xcframework"
if [[ "$mode" == --release ]]; then
  architectures=(arm64 x86_64)
else
  architectures=("$(uname -m)")
fi
stamp_prefix="xcframework-v3-$revision-$zig_version"
if [[ -f "$output/.flash-build" ]]; then
  current=$(cat "$output/.flash-build")
  if [[ "$current" == "$stamp_prefix "* ]]; then
    covered=1
    for architecture in "${architectures[@]}"; do
      [[ " ${current#"$stamp_prefix"} " == *" $architecture "* ]] || covered=0
    done
    [[ $covered == 1 ]] && exit 0
  fi
fi
mkdir -p "$cache"
source_dir="$cache/ghostty-$revision"
if [[ ! -d "$source_dir" ]]; then
  archive=$(mktemp "$cache/.source.XXXXXX")
  curl -fLsS "https://github.com/ghostty-org/ghostty/archive/$revision.tar.gz" -o "$archive"
  [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" == "$checksum" ]] || { rm -f "$archive"; echo 'Ghostty source checksum mismatch' >&2; exit 1; }
  # Retired revisions (and their Zig caches) are never used again.
  find "$cache" -mindepth 1 -maxdepth 1 \( -name 'ghostty-*' -o -name 'source.tar.gz' \) ! -name "ghostty-$revision" ! -name 'ghostty-vt.xcframework' -exec rm -rf {} +
  tar -xzf "$archive" -C "$cache"
  rm -f "$archive"
fi
zig_target() { [[ "$1" == arm64 ]] && echo aarch64 || echo "$1"; }
build_architecture() {
  local target prefix slice_stamp
  target=$(zig_target "$1")
  prefix="$cache/$target"
  slice_stamp="$revision-$zig_version-ReleaseFast"
  [[ -f "$prefix/.flash-build" && "$(cat "$prefix/.flash-build")" == "$slice_stamp" ]] && return 0
  rm -rf "$prefix"
  (cd "$source_dir" && zig build -Demit-lib-vt=true -Demit-exe=false -Demit-xcframework=false -Dapp-runtime=none -Doptimize=ReleaseFast -Dtarget="$target-macos" --prefix "$prefix")
  echo "$slice_stamp" >"$prefix/.flash-build"
}
pids=()
for architecture in "${architectures[@]}"; do
  build_architecture "$architecture" &
  pids+=($!)
done
for pid in "${pids[@]}"; do
  wait "$pid" || { echo 'libghostty-vt build failed' >&2; exit 1; }
done
staging=$(mktemp -d "$cache/.xcframework.XXXXXX")
cleanup() {
  if [[ -d "$staging/previous.xcframework" && ! -e "$output" ]]; then
    mv "$staging/previous.xcframework" "$output"
  fi
  rm -rf "$staging"
}
trap cleanup EXIT
if [[ ${#architectures[@]} -gt 1 ]]; then
  slices=()
  for architecture in "${architectures[@]}"; do
    slices+=("$cache/$(zig_target "$architecture")/lib/libghostty-vt.a")
  done
  mkdir -p "$staging/universal"
  lipo -create "${slices[@]}" -output "$staging/universal/libghostty-vt.a"
  library="$staging/universal/libghostty-vt.a"
else
  library="$cache/$(zig_target "${architectures[0]}")/lib/libghostty-vt.a"
fi
python3 - "$staging/ghostty-vt.xcframework" "$library" "$source_dir/include/ghostty" "$stamp_prefix" <<'PYTHON'
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys

output, library, headers = map(Path, sys.argv[1:4])
architectures = sorted(subprocess.check_output(["lipo", "-archs", str(library)], text=True).split())
if not architectures or not set(architectures) <= {"arm64", "x86_64"}:
    raise SystemExit(f"Unexpected Ghostty architectures: {architectures}")
identifier = "macos-" + "_".join(architectures)
slice_dir = output / identifier
slice_dir.mkdir(parents=True)
shutil.copy2(library, slice_dir / library.name)
shutil.copytree(headers, slice_dir / "Headers/ghostty")
(slice_dir / "Headers/module.modulemap").write_text(
    'module GhosttyVt {\n  umbrella header "ghostty/vt.h"\n  export *\n}\n'
)
metadata = {
    "AvailableLibraries": [{
        "BinaryPath": library.name,
        "HeadersPath": "Headers",
        "LibraryIdentifier": identifier,
        "LibraryPath": library.name,
        "SupportedArchitectures": architectures,
        "SupportedPlatform": "macos",
    }],
    "CFBundlePackageType": "XFWK",
    "XCFrameworkFormatVersion": "1.0",
}
with (output / "Info.plist").open("wb") as stream:
    plistlib.dump(metadata, stream)
(output / ".flash-build").write_text(" ".join([sys.argv[4], *architectures]) + "\n")
PYTHON
plutil -lint "$staging/ghostty-vt.xcframework/Info.plist"
if [[ -e "$output" ]]; then
  mv "$output" "$staging/previous.xcframework"
fi
mv "$staging/ghostty-vt.xcframework" "$output"
