#!/usr/bin/env python3
"""Collect the original notices for the pinned libghostty-vt dependency graph."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tarfile


REVISION = "08a9518340e19487bd5fdf96963583fb32f0c41f"
PACKAGES = {
    "highway": "N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE",
    "wuffs": "N-V-__8AAP5JWgCGP_AD0teWpa4krRvE9VPZzvviGdbmN4jI",
    "uucode": "uucode-0.2.0-ZZjBPoGFVgCiflJNFc6Io8xzC67B6PA5bUkk4LT0kCxg",
}
SUPPLEMENTAL = {
    "simdutf-LICENSE-MIT": (
        "fc8dbc04e03ad4efc08a647ffe7f995b811a95bc04c0e85a56d5277c6593fa5f",
        "https://github.com/simdutf/simdutf/blob/v9.0.0/LICENSE-MIT"),
    "uucode-LICENSE_unicode": (
        "1eda5a3b026870c737b22e8bcd4954338612c790db688242e003f41a4fa95175",
        "https://github.com/jacobsandlund/uucode/blob/ea62149739404a73c202b48a33bf6dd2af4bd9b0/licenses/LICENSE_unicode"),
}


def cached_text(cache, package, relative, prefix=None):
    package_hash = PACKAGES[package]
    archive = Path(cache) / "p" / f"{package_hash}.tar.gz"
    # Zig (0.16 and 0.17) caches verified packages as tarballs. Read only exact regular
    # members; no archive path or link is ever extracted to the filesystem.
    with tarfile.open(archive, "r:gz") as stream:
        try:
            member = stream.getmember(f"{package_hash}/{relative}")
        except KeyError as error:
            raise ValueError(f"missing license input {package}/{relative}") from error
        if not member.isfile() or member.size > 2_000_000 and prefix is None:
            raise ValueError(f"invalid license input {package}/{relative}")
        text = stream.extractfile(member).read(prefix).decode("utf-8")
    if not text.strip():
        raise ValueError(f"missing license text {package}/{relative}")
    return text


def collect(source, cache, support):
    source, support = Path(source), Path(support)
    entries = []
    for package, package_hash in PACKAGES.items():
        zon = source / ("build.zig.zon" if package == "uucode"
                        else f"pkg/{package}/build.zig.zon")
        if package_hash not in zon.read_text():
            raise ValueError(f"{package} dependency changed; review libghostty-vt notices")
    for filename, (checksum, url) in SUPPLEMENTAL.items():
        payload = (support / filename).read_bytes()
        if hashlib.sha256(payload).hexdigest() != checksum:
            raise ValueError(f"supplemental license changed: {filename}")
        entries.append((filename, url, payload.decode("utf-8")))

    simdutf = (source / "pkg/simdutf/vendor/simdutf.h").read_text()
    if '#define SIMDUTF_VERSION "9.0.0"' not in simdutf:
        raise ValueError("simdutf version changed; review libghostty-vt notices")
    block = re.search(r"/\* From\nhttps://github\.com/endorno/pytorch/.*?\*/", simdutf, re.DOTALL)
    if not block:
        raise ValueError("missing simdutf vendored BSD license")
    entries.append(("simdutf / PyTorch-derived ISA detection BSD notice",
                    f"Ghostty {REVISION}: pkg/simdutf/vendor/simdutf.h",
                    block.group()[3:-2].strip()))

    highway_header = cached_text(cache, "highway", "hwy/base.h", prefix=1024)
    highway_copyrights = "\n".join(re.findall(r"^// (Copyright[^\n]+)", highway_header, re.MULTILINE))
    for filename in ["LICENSE", "LICENSE-BSD3"]:
        entries.append((f"Highway / {filename}",
                        "https://github.com/google/highway/tree/66486a10623fa0d72fe91260f96c892e41aceb06",
                        highway_copyrights + "\n\n" + cached_text(cache, "highway", filename)))
    wuffs_header = cached_text(cache, "wuffs", "release/c/wuffs-v0.4.c", prefix=4096)
    wuffs_copyrights = "\n".join(re.findall(r"^// (Copyright[^\n]+)", wuffs_header, re.MULTILINE))
    entries.append(("Wuffs", "https://github.com/google/wuffs/tree/7411f488fe2e2c205c3d3b3d28638b7356522930",
                    wuffs_copyrights + "\n\n" + cached_text(cache, "wuffs", "LICENSE")))
    entries.append(("uucode", "https://github.com/jacobsandlund/uucode/tree/ea62149739404a73c202b48a33bf6dd2af4bd9b0",
                    cached_text(cache, "uucode", "LICENSE.md")))
    data_header = cached_text(cache, "uucode", "ucd/auxiliary/GraphemeBreakProperty.txt", prefix=1024)
    data_copyrights = "\n".join(re.findall(r"^# (©[^\n]+)", data_header, re.MULTILINE))
    if not data_copyrights:
        raise ValueError("missing Unicode data copyright")
    entries.append(("uucode / Unicode character data", "GraphemeBreakProperty.txt", data_copyrights))
    blocks = [f"libghostty-vt third-party notices\nGhostty revision: {REVISION}\n"]
    for name, url, text in entries:
        blocks.append("\n" + "=" * 72 + f"\n{name}\nSource: {url}\n\n{text.strip()}\n")
    return "".join(blocks)


def zig_cache():
    if os.environ.get("ZIG_GLOBAL_CACHE_DIR"):
        return Path(os.environ["ZIG_GLOBAL_CACHE_DIR"])
    environment = subprocess.check_output(["zig", "env"], text=True)
    match = re.search(r'\.global_cache_dir = "([^"]+)"', environment)
    if not match:
        raise ValueError("cannot locate Zig's verified package cache")
    return Path(match[1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--zig-cache", type=Path)
    parser.add_argument("--revision", default=REVISION)
    args = parser.parse_args()
    try:
        if args.revision != REVISION:
            raise ValueError("Ghostty revision changed; review the dependency notice inventory")
        text = collect(args.source, args.zig_cache or zig_cache(),
                       Path(__file__).with_name("ghostty-notices"))
    except (ValueError, OSError, tarfile.TarError) as error:
        parser.exit(1, f"libghostty-vt license inventory failed: {error}\n")
    args.output.write_text(text)


if __name__ == "__main__":
    main()
