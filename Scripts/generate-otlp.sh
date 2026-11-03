#!/usr/bin/env bash
# Regenerates the OTLP message types in Sources/FlashOTLP from the pinned
# opentelemetry-proto release, with protoc-gen-swift built from the
# swift-protobuf version Package.resolved pins, so the generated code and the
# runtime library always match.
#
# Usage: generate-otlp.sh
#
# Requires git, protoc and a Swift toolchain. The output is committed: a plain
# `swift build` never runs protoc.
set -euo pipefail
cd "$(dirname "$0")/.."

proto_tag=v1.11.1
proto_commit=b3f75588eb23c5fca62264edd05d382de49beb1a
command -v protoc >/dev/null || { echo "error: protoc is not on PATH" >&2; exit 1; }

swift_protobuf_version=$(python3 - <<'PY'
import json
pins = json.load(open("Package.resolved"))["pins"]
print(next(pin["state"]["version"] for pin in pins if pin["identity"] == "swift-protobuf"))
PY
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$proto_tag" \
  https://github.com/open-telemetry/opentelemetry-proto "$work/proto"
actual=$(git -C "$work/proto" rev-parse HEAD)
[[ "$actual" == "$proto_commit" ]] || {
  echo "error: opentelemetry-proto $proto_tag is $actual, expected $proto_commit" >&2
  exit 1
}

git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$swift_protobuf_version" \
  https://github.com/apple/swift-protobuf "$work/swift-protobuf"
swift build --package-path "$work/swift-protobuf" --scratch-path "$work/plugin-build" \
  -c release --product protoc-gen-swift
plugin="$work/plugin-build/release/protoc-gen-swift"

output=Sources/FlashOTLP
rm -f "$output"/*.pb.swift
mkdir -p "$output"
protos=(
  opentelemetry/proto/common/v1/common.proto
  opentelemetry/proto/resource/v1/resource.proto
  opentelemetry/proto/metrics/v1/metrics.proto
  opentelemetry/proto/logs/v1/logs.proto
  opentelemetry/proto/trace/v1/trace.proto
  opentelemetry/proto/collector/metrics/v1/metrics_service.proto
  opentelemetry/proto/collector/logs/v1/logs_service.proto
  opentelemetry/proto/collector/trace/v1/trace_service.proto
)
protoc --plugin=protoc-gen-swift="$plugin" -I "$work/proto" \
  --swift_opt=Visibility=Public --swift_opt=FileNaming=PathToUnderscores \
  --swift_out="$output" "${protos[@]}"

# protoc-gen-swift marks every file `// swift-format-ignore-file`, so the
# formatter and the strict lint leave generated code alone.
grep -L 'swift-format-ignore-file' "$output"/*.pb.swift | grep . &&
  { echo "error: generated files lack swift-format-ignore-file" >&2; exit 1; }
cp "$work/proto/LICENSE" Resources/opentelemetry-proto-LICENSE
echo "generated $(ls "$output"/*.pb.swift | wc -l | tr -d ' ') files from opentelemetry-proto $proto_tag" \
  "with swift-protobuf $swift_protobuf_version"
