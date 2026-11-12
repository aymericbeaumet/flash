#!/usr/bin/env python3
"""Collect the notices for the dependencies included in a release bundle."""

import argparse
import json
import re
import subprocess
from pathlib import Path


class Notices:
    def __init__(self):
        self.entries = {}

    def add(self, name, text):
        if not isinstance(text, str) or not text.strip():
            raise ValueError(f"missing license text for {name}")
        self.entries.setdefault(text.strip(), set()).add(name)

    def render(self):
        blocks = ["Third-party notices for Flash\n"]
        for text, names in sorted(self.entries.items(), key=lambda entry: sorted(entry[1])):
            blocks.append("\n" + "=" * 72 + "\n" + "\n".join(sorted(names)) + "\n\n" + text + "\n")
        return "".join(blocks)


def add_rust(notices, report):
    if not report.get("licenses"):
        raise ValueError("cargo-about returned no license inventory")
    for license in report["licenses"]:
        for usage in license["used_by"]:
            crate = usage["crate"]
            notices.add(
                f"Rust: {crate['name']} {crate['version']} ({license['id']})\n"
                f"Source: https://crates.io/crates/{crate['name']}/{crate['version']}",
                license["text"],
            )
    for crate in report["crates"]:
        package = crate["package"]
        root = Path(package["manifest_path"]).parent
        for path in sorted(root.iterdir()):
            if path.is_file() and path.name.lower().startswith(
                ("license", "licence", "copying", "notice", "copyright")
            ):
                notices.add(f"Rust: {package['name']} {package['version']} / {path.name}",
                            path.read_text())


def add_plugin_data(notices, plugin_dir):
    # Data a plugin embeds from upstream (searchproviders: Kagi's bang list)
    # keeps its licence under Plugins/<id>/notices/<source>-LICENSE.
    directory = plugin_dir / "notices"
    if not directory.is_dir():
        return
    for path in sorted(directory.iterdir()):
        if path.is_file():
            source = path.name.removesuffix("-LICENSE")
            notices.add(f"Plugin data: {plugin_dir.name} / {source}", path.read_text())


def add_inspector(notices, report):
    # A single-file plugin can remove the chunks before Vite inventories their
    # licenses. An empty report must fail instead of quietly shipping no notices.
    if not report:
        raise ValueError("inspector license inventory is empty")
    for package in report:
        notices.add(
            f"Inspector: {package['name']} {package['version']} ({package['identifier']})",
            package.get("text"),
        )


def collect(root):
    notices = Notices()
    notices.add(
        "Ghostty terminal dependencies",
        (root / "build/ghostty/ghostty-vt.xcframework/ThirdPartyNotices.txt").read_text(),
    )
    notices.add("TOMLKit", (root / ".build/checkouts/TOMLKit/LICENSE").read_text())
    resolved = json.loads((root / "Package.resolved").read_text())["pins"]
    protobuf = next(pin["state"]["version"] for pin in resolved if pin["identity"] == "swift-protobuf")
    notices.add(
        f"SwiftProtobuf {protobuf} (Apache-2.0)\nSource: https://github.com/apple/swift-protobuf",
        (root / ".build/checkouts/swift-protobuf/LICENSE.txt").read_text())
    # Sources/FlashOTLP is generated from these .proto files.
    notices.add(
        "OpenTelemetry protocol definitions (opentelemetry-proto, Apache-2.0)\n"
        "Source: https://github.com/open-telemetry/opentelemetry-proto",
        (root / "Resources/opentelemetry-proto-LICENSE").read_text())
    header = (root / ".build/checkouts/TOMLKit/Sources/CTOML/Sources/toml.hpp").read_text()
    preamble = header.partition("#ifndef")[0]
    license_start = preamble.find("// MIT License")
    if license_start < 0:
        raise ValueError("toml++ license header missing; review the dependency's notices")
    license = re.sub(r"^// ?", "", preamble[license_start:], flags=re.MULTILINE).strip()
    copyrights = sorted(set(re.findall(r"// (Copyright[^\n]+)", header)))
    notices.add("toml++ (including its UTF-8 decoder)", "\n".join(copyrights) + "\n\n" + license)

    manifests = sorted((root / "Plugins").glob("*/manifest.json"))
    if not manifests:
        raise ValueError("no bundled plugin manifests found")
    for manifest in manifests:
        if not json.loads(manifest.read_text()).get("exec"):
            continue
        cargo = manifest.parent / "Cargo.toml"
        if not cargo.is_file():
            raise ValueError(f"executable plugin has no Cargo manifest: {manifest.parent.name}")
        result = subprocess.run(
            ["cargo", "about", "generate", "--manifest-path", str(cargo),
             "--config", str(root / "Scripts/licenses.toml"), "--locked", "--fail", "--format", "json"],
            check=True, capture_output=True, text=True, cwd=root,
        )
        add_rust(notices, json.loads(result.stdout))
        add_plugin_data(notices, manifest.parent)
    add_inspector(notices, json.loads((root / "Inspector/dist/licenses.json").read_text()))
    return notices.render()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    output = args.output or root / "build/ThirdPartyNotices.txt"
    try:
        text = collect(root)
    except subprocess.CalledProcessError as error:
        parser.exit(1, f"license inventory failed:\n{error.stderr[-6000:]}\n")
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f"license inventory failed: {error}\n")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text)
    print(f"Third-party notices: {output} ({len(text.encode('utf-8'))} bytes)")


if __name__ == "__main__":
    main()
