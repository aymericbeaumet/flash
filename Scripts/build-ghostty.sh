#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=b0c421fcd2e290629d4285c181b52fe2f2095f06
checksum=4c4b59046a50eaefcfa3afab5d28eef5c663730e5f467687f88e7003bcd29586
mode=${1:---dev}
[[ "$mode" == --dev || "$mode" == --release ]] || { echo "Usage: $0 [--dev|--release]" >&2; exit 2; }
[[ "$(zig version)" == 0.16.0 ]] || { echo 'Install Zig 0.16.0 (mise install zig).' >&2; exit 1; }
cache="$PWD/build/ghostty"
output="$cache/ghostty-vt.xcframework"
arch=$(uname -m)
stamp="xcframework-v2-$revision-0.16.0-$mode-$arch"
[[ -f "$output/.flash-build" && "$(cat "$output/.flash-build")" == "$stamp" ]] && exit 0
mkdir -p "$cache"
source_dir="$cache/ghostty-$revision"
if [[ ! -d "$source_dir" ]]; then
  curl -fLsS "https://github.com/ghostty-org/ghostty/archive/$revision.tar.gz" -o "$cache/source.tar.gz"
  [[ "$(shasum -a 256 "$cache/source.tar.gz" | cut -d ' ' -f 1)" == "$checksum" ]] || { echo 'Ghostty source checksum mismatch' >&2; exit 1; }
  tar -xzf "$cache/source.tar.gz" -C "$cache"
fi
build_arch() {
  local target=$1
  (cd "$source_dir" && zig build -Demit-lib-vt=true -Demit-exe=false -Demit-xcframework=false -Dapp-runtime=none -Doptimize=ReleaseFast -Dtarget="$target-macos" --prefix "$cache/$target")
}
if [[ "$mode" == --release ]]; then
  build_arch aarch64
  build_arch x86_64
  mkdir -p "$cache/universal"
  lipo -create "$cache/aarch64/lib/libghostty-vt.a" "$cache/x86_64/lib/libghostty-vt.a" -output "$cache/universal/libghostty-vt.a"
  library="$cache/universal/libghostty-vt.a"
else
  target=$arch
  [[ "$arch" == arm64 ]] && target=aarch64
  build_arch "$target"
  library="$cache/$target/lib/libghostty-vt.a"
fi
staging=$(mktemp -d "$cache/.xcframework.XXXXXX")
cleanup() {
  if [[ -d "$staging/previous.xcframework" && ! -e "$output" ]]; then
    mv "$staging/previous.xcframework" "$output"
  fi
  rm -rf "$staging"
}
trap cleanup EXIT
python3 - "$staging/ghostty-vt.xcframework" "$library" "$source_dir/include/ghostty" "$stamp" <<'PYTHON'
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
(output / ".flash-build").write_text(sys.argv[4] + "\n")
PYTHON
plutil -lint "$staging/ghostty-vt.xcframework/Info.plist"
if [[ -e "$output" ]]; then
  mv "$output" "$staging/previous.xcframework"
fi
mv "$staging/ghostty-vt.xcframework" "$output"
