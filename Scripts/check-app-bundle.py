#!/usr/bin/env python3
"""Validate the self-contained universal app before release packaging."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tomllib


ARCHITECTURES = {"arm64", "x86_64"}


def command(arguments, description):
    result = subprocess.run(arguments, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(f"{description}: {result.stderr.strip()[:500]}")
    return result.stdout


def version_tuple(value):
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def validate_binary(binary, minimum_macos, require_hardened_runtime):
    if not os.access(binary, os.X_OK):
        raise ValueError(f"{binary}: binary is not executable")
    architectures = set(command(["lipo", "-archs", str(binary)],
                                f"{binary}: architectures could not be read").split())
    if architectures != ARCHITECTURES:
        raise ValueError(f"{binary}: expected universal architectures, found {sorted(architectures)}")
    for architecture in sorted(architectures):
        loads = command(["otool", "-arch", architecture, "-l", str(binary)],
                        f"{binary}: load commands could not be read")
        load_command = None
        versions = []
        for line in loads.splitlines():
            fields = line.split()
            if fields[:1] == ["cmd"]:
                load_command = fields[1]
            if (load_command == "LC_BUILD_VERSION" and fields[:1] == ["minos"]
                    or load_command == "LC_VERSION_MIN_MACOSX" and fields[:1] == ["version"]):
                versions.append(fields[1])
        if not versions or any(version_tuple(value) > minimum_macos for value in versions):
            raise ValueError(f"{binary} ({architecture}): minimum macOS {versions} exceeds bundle")
        libraries = command(["otool", "-arch", architecture, "-L", str(binary)],
                            f"{binary}: dependencies could not be read")
        for line in libraries.splitlines():
            if " (compatibility version " not in line:
                continue
            dependency = line.strip().split(" (compatibility version ", 1)[0]
            if not dependency.startswith(("/System/Library/", "/usr/lib/")):
                raise ValueError(f"{binary}: non-system dependency {dependency}")
    command(["codesign", "--verify", "--strict", str(binary)],
            f"{binary}: signature verification failed")
    if require_hardened_runtime:
        details = subprocess.run(["codesign", "-d", "--verbose=4", str(binary)],
                                 text=True, capture_output=True, check=True)
        if not re.search(r"^CodeDirectory .*flags=0x[0-9a-fA-F]+\([^)]*\bruntime\b",
                         details.stderr, re.MULTILINE):
            raise ValueError(f"{binary}: hardened runtime is missing")


def validate(app, source, require_hardened_runtime=False):
    app, source = Path(app), Path(source)
    for path in [app, *app.rglob("*")]:
        if path.is_symlink():
            raise ValueError(f"{path}: release bundle must not contain a symlink")
    contents = app / "Contents"
    resources = contents / "Resources"
    with (contents / "Info.plist").open("rb") as stream:
        metadata = plistlib.load(stream)
    with (source / "Resources/Info.plist").open("rb") as stream:
        expected_metadata = plistlib.load(stream)
    for key in ("CFBundleIdentifier", "CFBundleExecutable", "LSUIElement", "LSMinimumSystemVersion"):
        if metadata.get(key) != expected_metadata.get(key):
            raise ValueError(f"{app}: unexpected {key}: {metadata.get(key)!r}")
    required = {
        "LICENSE": source / "LICENSE",
        "ThirdPartyNotices.txt": source / "build/ThirdPartyNotices.txt",
        "config.default.toml": source / "config.default.toml",
        "Ghostty-LICENSE": source / "Resources/Ghostty-LICENSE",
        "tmux-LICENSE": source / "Resources/tmux-LICENSE",
        "utf8proc-LICENSE": source / "Resources/utf8proc-LICENSE",
        "Flash_flash.bundle/inspector.html": source / "Sources/flash/Resources/inspector.html",
        "docs/docs.json": source / "build/docs/docs.json",
        "docs/search.json": source / "build/docs/search.json",
        "docs/routes.json": source / "build/docs/routes.json",
    }
    for relative, original in required.items():
        bundled = resources / relative
        if not bundled.is_file() or not bundled.stat().st_size or bundled.read_bytes() != original.read_bytes():
            raise ValueError(f"{bundled}: missing or stale release resource")
    bundled_docs = resources / "docs/files"
    expected_docs = source / "build/docs/files"
    expected_files = {p.relative_to(expected_docs) for p in expected_docs.rglob("*") if p.is_file()}
    actual_files = {p.relative_to(bundled_docs) for p in bundled_docs.rglob("*") if p.is_file()}
    if expected_files != actual_files or any(
            (expected_docs / p).read_bytes() != (bundled_docs / p).read_bytes() for p in expected_files):
        raise ValueError(f"{bundled_docs}: missing or stale documentation files")
    if not (resources / "AppIcon.icns").is_file():
        raise ValueError(f"{app}: missing app icon")
    for relative in ("flash.1", "completions/_flash", "completions/flash.bash",
                     "completions/flash.fish"):
        generated = resources / relative
        if not generated.is_file() or generated.stat().st_size == 0:
            raise ValueError(f"{generated}: missing or empty; assemble_app generates it")
    expected_plugins = {p.parent.name: p for p in (source / "Plugins").glob("*/manifest.json")}
    plugins = resources / "Plugins"
    if not plugins.is_dir() or {p.name for p in plugins.iterdir()} != set(expected_plugins):
        raise ValueError(f"{plugins}: plugin inventory does not match source manifests")
    binaries = [contents / "MacOS" / metadata["CFBundleExecutable"]]
    for plugin_id, source_manifest in sorted(expected_plugins.items()):
        bundled = plugins / plugin_id
        manifest = bundled / "manifest.json"
        if not manifest.is_file() or manifest.read_bytes() != source_manifest.read_bytes():
            raise ValueError(f"{manifest}: missing or stale plugin manifest")
        expected_files = {"manifest.json"}
        cargo_file = source_manifest.parent / "Cargo.toml"
        binary_names = []
        if cargo_file.is_file():
            with cargo_file.open("rb") as stream:
                cargo = tomllib.load(stream)
            binary_names = [binary["name"] for binary in cargo.get("bin", [])]
            binary_names = binary_names or [f"flash-plugin-{plugin_id}"]
            expected_files.update(binary_names)
            binaries.extend(bundled / name for name in binary_names)
        definition = json.loads(source_manifest.read_text())
        if definition.get("exec") and Path(definition["exec"][0]).name not in binary_names:
            raise ValueError(f"{manifest}: exec is not a declared bundled binary")
        extension = source_manifest.parent / "extension"
        if extension.is_dir():
            expected_files.add("extension")
            expected_payloads = {p.relative_to(extension) for p in extension.rglob("*") if p.is_file()}
            bundled_extension = bundled / "extension"
            actual_payloads = {p.relative_to(bundled_extension)
                               for p in bundled_extension.rglob("*") if p.is_file()}
            if expected_payloads != actual_payloads or any(
                    (extension / p).read_bytes() != (bundled_extension / p).read_bytes()
                    for p in expected_payloads):
                raise ValueError(f"{bundled_extension}: missing or stale extension payload")
        if {p.name for p in bundled.iterdir()} != expected_files:
            raise ValueError(f"{bundled}: plugin bundle contents differ from declared files")
    minimum_macos = version_tuple(metadata["LSMinimumSystemVersion"])
    for binary in binaries:
        validate_binary(binary, minimum_macos, require_hardened_runtime)
    command(["codesign", "--verify", "--deep", "--strict", str(app)],
            f"{app}: bundle signature verification failed")
    return len(binaries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--require-hardened-runtime", action="store_true")
    arguments = parser.parse_args()
    try:
        count = validate(arguments.app, arguments.source, arguments.require_hardened_runtime)
    except (ValueError, OSError) as error:
        parser.exit(1, f"Release bundle validation failed: {error}\n")
    print(f"Release bundle verified: {count} signed universal executables")


if __name__ == "__main__":
    main()
