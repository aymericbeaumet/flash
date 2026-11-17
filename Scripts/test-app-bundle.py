#!/usr/bin/env python3
"""Exercise release bundle validation with signed universal Mach-O fixtures."""

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parent.parent


class AppBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiled = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.compiled.cleanup)
        cls.universal = Path(cls.compiled.name) / "universal"
        cls.c_source = Path(cls.compiled.name) / "main.c"
        # Prints a line, as `flash cli manpage` does, so generated files are not empty.
        cls.c_source.write_text(
            "#include <stdio.h>\nint main(void) { puts(\"fixture\"); return 0; }\n")
        compiled = subprocess.run(
            ["xcrun", "clang", "-arch", "arm64", "-arch", "x86_64",
             "-mmacosx-version-min=13.0", str(cls.c_source), "-o", str(cls.universal)],
            text=True,
            capture_output=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        shutil.copytree(REPOSITORY / "Resources", self.source / "Resources")
        shutil.copy(REPOSITORY / "LICENSE", self.source / "LICENSE")
        shutil.copy(REPOSITORY / "config.default.toml", self.source / "config.default.toml")
        self.inspector = self.source / "Sources/flash/Resources/inspector.html"
        self.inspector.parent.mkdir(parents=True)
        self.inspector.write_text("<html>fixture inspector</html>")
        plugin = self.source / "Plugins/example"
        plugin.mkdir(parents=True)
        (plugin / "manifest.json").write_text(json.dumps({
            "id": "example", "exec": ["./flash-plugin-example"]}))
        (plugin / "Cargo.toml").write_text(
            '[package]\nname = "flash-plugin-example"\nversion = "0.1.0"\n'
            '[[bin]]\nname = "flash-plugin-example"\npath = "src/main.rs"\n')
        shutil.copy(self.universal, plugin / "flash-plugin-example")
        release_artifacts = self.source / "build/plugin-release/example"
        release_artifacts.mkdir(parents=True)
        shutil.copy(self.universal, release_artifacts / "flash-plugin-example")
        (self.source / "build/ThirdPartyNotices.txt").write_text("Fixture third-party notices\n")
        docs = self.source / "build/docs"
        (docs / "files/examples").mkdir(parents=True)
        (docs / "docs.json").write_text('{"pages":[],"nav":[]}')
        (docs / "search.json").write_text("[]")
        (docs / "routes.json").write_text('{"pages":[]}')
        (docs / "files/examples/flash.toml").write_text("[statusbar]\n")
        manifest_only = self.source / "Plugins/defaults"
        manifest_only.mkdir()
        (manifest_only / "manifest.json").write_text('{"id":"defaults"}')
        self.bin_path = self.root / "bin"
        self.bin_path.mkdir()
        shutil.copy(self.universal, self.bin_path / "flash")
        resource_bundle = self.bin_path / "Flash_flash.bundle"
        resource_bundle.mkdir()
        shutil.copy(self.inspector, resource_bundle / "inspector.html")
        self.app = self.root / "Flash.app"
        self.assemble()

    def assemble(self):
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; PROJECT_DIR="$2"; STAGING_PATH="$3"; '
             'assemble_app release "$4" -', "fixture", str(REPOSITORY / "Scripts/_common.sh"),
             str(self.source), str(self.app), str(self.bin_path)],
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def validator(self):
        script = REPOSITORY / "Scripts/check-app-bundle.py"
        spec = importlib.util.spec_from_file_location("check_app_bundle", script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def validate(self):
        self.validator().validate(self.app, self.source)

    def test_release_assembly_ships_the_man_page_and_completions(self):
        resources = self.app / "Contents/Resources"
        for relative in ("flash.1", "completions/_flash", "completions/flash.bash",
                         "completions/flash.fish"):
            self.assertEqual((resources / relative).read_text(), "fixture\n", relative)
        (resources / "completions/flash.fish").write_text("")
        with self.assertRaisesRegex(ValueError, "flash.fish: missing or empty"):
            self.validate()

    def test_release_assembly_includes_its_license(self):
        self.assertEqual((self.app / "Contents/Resources/LICENSE").read_bytes(),
                         (self.source / "LICENSE").read_bytes())

    def test_complete_signed_universal_bundle_passes_with_manifest_only_plugins(self):
        self.validate()

    def test_release_assembly_ships_the_manual(self):
        self.assertEqual((self.app / "Contents/Resources/docs/docs.json").read_bytes(),
                         (self.source / "build/docs/docs.json").read_bytes())

    def test_stale_manual_file_is_rejected(self):
        (self.app / "Contents/Resources/docs/files/examples/flash.toml").write_text("[stale]\n")
        with self.assertRaisesRegex(ValueError, "documentation files"):
            self.validate()

    def test_missing_plugin_binary_is_rejected(self):
        (self.app / "Contents/Resources/Plugins/example/flash-plugin-example").unlink()
        with self.assertRaisesRegex(ValueError, "plugin.*contents"):
            self.validate()

    def test_stale_companion_binary_is_rejected(self):
        shutil.copy(self.universal,
                    self.app / "Contents/Resources/Plugins/example/flash-plugin-retired")
        with self.assertRaisesRegex(ValueError, "plugin.*contents"):
            self.validate()

    def test_release_assembly_ignores_retired_live_and_staged_companions(self):
        for directory in [self.source / "Plugins/example",
                          self.source / "build/plugin-release/example"]:
            shutil.copy(self.universal, directory / "flash-plugin-retired")
        self.assemble()
        self.assertFalse((self.app / "Contents/Resources/Plugins/example/flash-plugin-retired").exists())
        self.validate()

    def test_thin_binary_is_rejected(self):
        executable = self.app / "Contents/MacOS/flash"
        executable.unlink()
        subprocess.run(["lipo", str(self.universal), "-thin", "arm64", "-output", str(executable)],
                       capture_output=True, check=True)
        with self.assertRaisesRegex(ValueError, "architectures"):
            self.validate()

    def test_bundled_symlink_is_rejected(self):
        path = self.app / "Contents/Resources/config.default.toml"
        path.unlink()
        path.symlink_to(self.source / "config.default.toml")
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.validate()

    def test_modified_resource_is_rejected_by_signature_verification(self):
        (self.app / "Contents/Resources/AppIcon.icns").write_bytes(b"changed icon")
        with self.assertRaisesRegex(ValueError, "signature"):
            self.validate()

    def test_binary_requiring_newer_macos_than_bundle_is_rejected(self):
        executable = self.app / "Contents/MacOS/flash"
        executable.unlink()
        subprocess.run(
            ["xcrun", "clang", "-arch", "arm64", "-arch", "x86_64",
             "-mmacosx-version-min=14.0", str(self.c_source), "-o", str(executable)],
            text=True,
            capture_output=True, check=True)
        with self.assertRaisesRegex(ValueError, "minimum macOS"):
            self.validate()

    def test_external_homebrew_library_dependency_is_rejected(self):
        library_source = self.root / "external.c"
        library_source.write_text("int external_value(void) { return 0; }\n")
        library = self.root / "libexternal.dylib"
        subprocess.run(
            ["xcrun", "clang", "-arch", "arm64", "-arch", "x86_64",
             "-mmacosx-version-min=13.0", "-dynamiclib", str(library_source),
             "-Wl,-install_name,/opt/homebrew/lib/libexternal.dylib", "-o", str(library)],
            capture_output=True, check=True)
        main_source = self.root / "external-main.c"
        main_source.write_text(
            "extern int external_value(void); int main(void) { return external_value(); }\n")
        executable = self.app / "Contents/MacOS/flash"
        executable.unlink()
        subprocess.run(
            ["xcrun", "clang", "-arch", "arm64", "-arch", "x86_64",
             "-mmacosx-version-min=13.0", str(main_source), str(library), "-o", str(executable)],
            capture_output=True, check=True)
        with self.assertRaisesRegex(ValueError, "non-system dependency /opt/homebrew"):
            self.validate()

    def test_hardened_runtime_is_required_only_when_requested(self):
        runtime_path = self.root / "runtime.app"
        self.app.rename(runtime_path)
        self.app = runtime_path
        with self.assertRaisesRegex(ValueError, "hardened runtime"):
            self.validator().validate(self.app, self.source, require_hardened_runtime=True)

    def test_hardened_runtime_flag_is_accepted_on_every_executable(self):
        for path in [self.app / "Contents/Resources/Plugins/example/flash-plugin-example",
                     self.app]:
            subprocess.run(["codesign", "--force", "--options", "runtime", "--sign", "-", str(path)],
                           capture_output=True, check=True)
        self.validator().validate(self.app, self.source, require_hardened_runtime=True)


if __name__ == "__main__":
    unittest.main()
