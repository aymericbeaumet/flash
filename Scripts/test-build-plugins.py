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
        shutil.copy(Path(__file__).with_name("_common.sh"), scripts)
        plugin = self.root / "Plugins/example"
        plugin.mkdir(parents=True)
        (plugin / "manifest.json").write_text("{}")
        # Two `[[bin]]` targets: the manifest exec plus a companion binary
        # the crate owns. Both must be published.
        (plugin / "Cargo.toml").write_text(
            '[[bin]]\nname = "flash-plugin-example"\npath = "src/main.rs"\n\n'
            '[[bin]]\nname = "flash-plugin-example-bridge"\npath = "src/bridge.rs"\n'
        )
        target = self.root / "build/plugin-target/plugin-dev"
        target.mkdir(parents=True)
        self.source = target / "flash-plugin-example"
        self.destination = plugin / self.source.name
        self.companion_source = target / "flash-plugin-example-bridge"
        self.companion = plugin / self.companion_source.name
        self.compile(0)
        self.compile(0, source=self.companion_source)
        mock_bin = self.root / "bin"
        mock_bin.mkdir()
        cargo = mock_bin / "cargo"
        cargo.write_text("#!/bin/sh\nexit 0\n")
        cargo.chmod(0o755)
        rustup = mock_bin / "rustup"
        rustup.write_text("#!/bin/sh\nexit 0\n")
        rustup.chmod(0o755)
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

    def compile(self, result, source=None, architecture=None):
        arguments = ["cc"]
        if architecture:
            arguments += ["-arch", architecture]
        subprocess.run(arguments + ["-x", "c", "-", "-o", str(source or self.source)],
                       input=f"int main(void) {{ return {result}; }}\n",
                       text=True, capture_output=True, check=True)

    def build(self):
        result = subprocess.run(["bash", "Scripts/build-plugins.sh", "dev"],
                                cwd=self.root, env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def run_build(self, mode="dev"):
        return subprocess.run(["bash", "Scripts/build-plugins.sh", mode],
                              cwd=self.root, env=self.env,
                              text=True, capture_output=True)

    def test_release_publishes_universal_artifacts_without_touching_live_plugins(self):
        self.build()
        live_inode = self.destination.stat().st_ino
        live_bytes = self.destination.read_bytes()
        for target, architecture in [("aarch64", "arm64"), ("x86_64", "x86_64")]:
            directory = self.root / f"build/plugin-target/{target}-apple-darwin/release"
            directory.mkdir(parents=True)
            self.compile(0, source=directory / self.source.name, architecture=architecture)
            self.compile(0, source=directory / self.companion.name, architecture=architecture)

        result = self.run_build("release")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.destination.stat().st_ino, live_inode,
                         "release packaging must not trigger the live plugin watcher")
        self.assertEqual(self.destination.read_bytes(), live_bytes)
        for name in [self.source.name, self.companion.name]:
            artifact = self.root / "build/plugin-release/example" / name
            self.assertTrue(artifact.is_file())
            architectures = subprocess.check_output(["lipo", "-archs", str(artifact)], text=True)
            self.assertEqual(set(architectures.split()), {"arm64", "x86_64"})

    def test_manifest_declaring_exec_without_a_crate_fails_the_build(self):
        """A manifest whose binary nobody builds must not be installed.

        The host cannot tell a missing executable from a crash loop: it spends
        the restart budget, parks the plugin and drops its warm catalog, so the
        plugin's sources read empty until the next resident restart.
        """
        orphan = self.root / "Plugins/orphan"
        orphan.mkdir(parents=True)
        (orphan / "manifest.json").write_text('{"exec": ["./flash-plugin-orphan"]}')
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nothing builds its binary", result.stdout + result.stderr)

    def test_manifest_declaring_exec_without_a_built_binary_fails_the_build(self):
        """A crate that produces no binary aborts at the staging copy."""
        declared = self.root / "Plugins/declared"
        declared.mkdir(parents=True)
        (declared / "manifest.json").write_text('{"exec": ["./flash-plugin-declared"]}')
        (declared / "Cargo.toml").write_text(
            '[[bin]]\nname = "flash-plugin-declared"\npath = "src/main.rs"\n'
        )
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((declared / "flash-plugin-declared").exists())

    def test_every_declared_binary_is_published(self):
        self.build()
        self.assertTrue(self.destination.exists())
        self.assertTrue(self.companion.exists(),
                        "the crate's second [[bin]] must be published too")
        self.assertEqual(subprocess.run([self.companion]).returncode, 0)

    def test_companion_binary_republishes_on_change(self):
        self.build()
        inode = self.companion.stat().st_ino
        self.compile(5, source=self.companion_source)
        self.build()
        self.assertNotEqual(self.companion.stat().st_ino, inode)
        self.assertEqual(subprocess.run([self.companion]).returncode, 5)
        # The untouched sibling keeps its inode: publication is per binary.
        self.assertEqual(subprocess.run([self.destination]).returncode, 0)

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
