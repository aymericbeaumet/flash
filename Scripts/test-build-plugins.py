#!/usr/bin/env python3
"""Exercise atomic plugin publication with real Mach-O signatures."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PluginPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / "Scripts"
        scripts.mkdir()
        shutil.copy(Path(__file__).with_name("build-plugins.sh"), scripts)
        plugin = self.root / "Plugins/example"
        plugin.mkdir(parents=True)
        (plugin / "manifest.json").write_text("{}")
        (plugin / "Cargo.toml").write_text("")
        target = self.root / "build/plugin-target/plugin-dev"
        target.mkdir(parents=True)
        self.source = target / "flash-plugin-example"
        self.destination = plugin / self.source.name
        self.compile(0)
        mock_bin = self.root / "bin"
        mock_bin.mkdir()
        cargo = mock_bin / "cargo"
        cargo.write_text("#!/bin/sh\nexit 0\n")
        cargo.chmod(0o755)
        # Signing must finish outside all watched plugin directories.
        codesign = mock_bin / "codesign"
        codesign.write_text(
            '#!/bin/sh\nif [ "$1" = --force ]; then\n'
            '  for arg in "$@"; do\n'
            '    case "$arg" in *Plugins/*) exit 97;; esac\n'
            '  done\nfi\nexec /usr/bin/codesign "$@"\n'
        )
        codesign.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{mock_bin}:{os.environ['PATH']}",
                        DEV_PLUGIN_SIGN_IDENTITY=os.environ.get("DEV_PLUGIN_SIGN_IDENTITY") or "-")

    def compile(self, result):
        subprocess.run(["cc", "-x", "c", "-", "-o", str(self.source)],
                       input=f"int main(void) {{ return {result}; }}\n",
                       text=True, capture_output=True, check=True)

    def build(self):
        result = subprocess.run(["bash", "Scripts/build-plugins.sh", "dev"],
                                cwd=self.root, env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unchanged_build_preserves_published_inode(self):
        self.build()
        inode = self.destination.stat().st_ino
        self.build()
        self.assertEqual(self.destination.stat().st_ino, inode)

    def test_changed_code_replaces_published_inode(self):
        self.build()
        inode = self.destination.stat().st_ino
        self.compile(3)
        self.build()
        self.assertNotEqual(self.destination.stat().st_ino, inode)
        self.assertEqual(subprocess.run([self.destination]).returncode, 3)

    def test_changed_signature_is_replaced(self):
        self.build()
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-",
                        "--identifier", "different.identity", str(self.destination)],
                       capture_output=True, check=True)
        inode = self.destination.stat().st_ino
        self.build()
        self.assertNotEqual(self.destination.stat().st_ino, inode)
        signature = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4",
                                    str(self.destination)], text=True,
                                   capture_output=True, check=True).stderr
        self.assertIn("Identifier=flash-plugin-example", signature)


if __name__ == "__main__":
    unittest.main()
