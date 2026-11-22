#!/usr/bin/env python3
"""Pin the libghostty-vt notice inventory without network or compilation."""

import importlib.util
import io
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "ghostty_notices", Path(__file__).with_name("build-ghostty-notices.py"))
notices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notices)


class GhosttyNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.cache = self.root / "cache"
        (self.cache / "p").mkdir(parents=True)
        for package, package_hash in notices.PACKAGES.items():
            zon = self.source / ("build.zig.zon" if package == "uucode"
                                 else f"pkg/{package}/build.zig.zon")
            zon.parent.mkdir(parents=True, exist_ok=True)
            zon.write_text(package_hash)
        header = self.source / "pkg/simdutf/vendor/simdutf.h"
        header.parent.mkdir(parents=True)
        header.write_text('#define SIMDUTF_VERSION "9.0.0"\n/* From\n'
                          'https://github.com/endorno/pytorch/fixture\n'
                          'Copyright Facebook\nRedistribution BSD fixture\n*/\n')
        self.files = {
            "translate-c": {"LICENSE": "Copyright Zig contributors / MIT fixture"},
            "highway": {"LICENSE": "Apache License fixture", "LICENSE-BSD3": "The Highway Project Authors",
                        "hwy/base.h": "// Copyright Google LLC\n"},
            "wuffs": {"LICENSE": "The Wuffs Authors / MIT fixture",
                      "release/c/wuffs-v0.4.c": "// Copyright The Wuffs Authors\n"},
            "uucode": {"LICENSE.md": "Copyright Jacob Sandlund / MIT fixture",
                       "ucd/auxiliary/GraphemeBreakProperty.txt": "# © 2026 Unicode®, Inc.\n"},
        }
        for package in self.files:
            self.write_archive(package)
        self.support = self.root / "support"
        shutil.copytree(Path(__file__).with_name("ghostty-notices"), self.support)

    def write_archive(self, package, symlink=None):
        package_hash = notices.PACKAGES[package]
        with tarfile.open(self.cache / "p" / f"{package_hash}.tar.gz", "w:gz") as stream:
            for relative, text in self.files[package].items():
                member = tarfile.TarInfo(f"{package_hash}/{relative}")
                if relative == symlink:
                    member.type = tarfile.SYMTYPE
                    member.linkname = "../../outside"
                    stream.addfile(member)
                else:
                    payload = text.encode()
                    member.size = len(payload)
                    stream.addfile(member, io.BytesIO(payload))

    def test_every_linked_dependency_has_original_author_notices(self):
        text = notices.collect(self.source, self.cache, self.support)
        for author in ["simdutf authors", "Facebook", "Highway Project Authors", "Wuffs Authors",
                       "Jacob Sandlund", "Zig contributors", "UNICODE LICENSE V3", "2026 Unicode"]:
            self.assertIn(author, text)

    def test_missing_dependency_license_fails_closed(self):
        del self.files["wuffs"]["LICENSE"]
        self.write_archive("wuffs")
        with self.assertRaisesRegex(ValueError, "missing license input wuffs/LICENSE"):
            notices.collect(self.source, self.cache, self.support)

    def test_archive_symlinks_are_not_followed_or_extracted(self):
        self.write_archive("highway", symlink="LICENSE")
        with self.assertRaisesRegex(ValueError, "invalid license input highway/LICENSE"):
            notices.collect(self.source, self.cache, self.support)
        self.assertFalse((self.root / "outside").exists())

    def test_changed_dependency_hash_requires_inventory_review(self):
        (self.source / "build.zig.zon").write_text("new uucode revision")
        with self.assertRaisesRegex(ValueError, "dependency changed"):
            notices.collect(self.source, self.cache, self.support)

    def test_modified_supplemental_original_is_rejected(self):
        (self.support / "simdutf-LICENSE-MIT").write_text("modified")
        with self.assertRaisesRegex(ValueError, "supplemental license changed"):
            notices.collect(self.source, self.cache, self.support)


if __name__ == "__main__":
    unittest.main()
