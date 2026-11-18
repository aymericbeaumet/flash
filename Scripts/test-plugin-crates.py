#!/usr/bin/env python3
"""Unit tests for Scripts/check-plugin-crates.py and Scripts/update-plugin-dependency.py."""

import importlib.util
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
UPDATE = SCRIPTS / "update-plugin-dependency.py"
SPEC = importlib.util.spec_from_file_location(
    "check_plugin_crates", SCRIPTS / "check-plugin-crates.py")
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

SDK = "Plugins/_flash_plugin_rust"
PROFILES = """
# Dev hot-loop profile.
[profile.plugin-dev]
inherits = "dev"
opt-level = 1

[profile.release]
opt-level = "z"
lto = true
"""
TOKIO = """tokio = { version = "1.54.1", default-features = false, features = [
  "rt",
  "time",
] }"""
REGISTRY = 'source = "registry+https://github.com/rust-lang/crates.io-index"'

# Stands in for cargo: logs `<directory> <arguments>` and moves the lock the
# way `cargo update --package <name>@<old> --precise <new>` would.
CARGO = """#!/bin/bash
echo "${PWD##*/} $*" >>"$CARGO_LOG"
if [[ "${PWD##*/}" == "${CARGO_FAILS_IN:-}" ]]; then
  echo "error: no matching package named tokio found" >&2
  exit 101
fi
spec="$3"
/usr/bin/sed -i '' "s/^version = \\"${spec#*@}\\"\\$/version = \\"${5:-9.9.9}\\"/" Cargo.lock
"""


def package(name, body="", profiles=""):
    return f'[package]\nname = "{name}"\nversion = "0.1.0"\n{body}{profiles}'


def lock(crates, registry):
    """A Cargo.lock: local crates with their dependency names, then registry packages."""
    entries = []
    for name, dependencies in crates.items():
        listed = "".join(f' "{dependency}",\n' for dependency in dependencies)
        entries.append(
            f'[[package]]\nname = "{name}"\nversion = "0.1.0"\ndependencies = [\n{listed}]\n')
    for name, version in registry:
        entries.append(f'[[package]]\nname = "{name}"\nversion = "{version}"\n{REGISTRY}\n')
    return "version = 4\n\n" + "\n".join(entries)


class Tree:
    """A repository-shaped temporary root: the SDK workspace and two plugin crates."""

    def __init__(self, root):
        self.root = Path(root)
        sdk = {
            "flash_plugin": ["flash_plugin_macros", "serde_json", "tokio"],
            "flash_plugin_macros": ["serde_json"],
        }
        registry = [("regex", "1.13.1"), ("serde_json", "1.0.154"), ("tokio", "1.54.1")]
        self.write(f"{SDK}/Cargo.toml", package("flash_plugin", textwrap.dedent(f"""
            [workspace]
            members = ["macros", "probe"]

            [dependencies]
            flash_plugin_macros = {{ path = "macros" }}
            serde_json = "1.0.154"
            """) + TOKIO + "\n"))
        self.write(f"{SDK}/macros/Cargo.toml", package(
            "flash_plugin_macros", '\n[dependencies]\nserde_json = "1.0.154"\n'))
        self.write(f"{SDK}/probe/Cargo.toml", package("flash_plugin_probe", textwrap.dedent("""
            [dependencies]
            flash_plugin = { path = ".." }
            tokio = { version = "1.54.1", default-features = false, features = ["rt"] }
            """)))
        self.write(f"{SDK}/Cargo.lock", lock(
            {**sdk, "flash_plugin_probe": ["flash_plugin", "tokio"]}, registry[1:]))
        self.write("Plugins/alpha/Cargo.toml", package("flash-plugin-alpha", textwrap.dedent("""
            [dependencies]
            flash_plugin = { path = "../_flash_plugin_rust" }
            regex = "1.13.1"
            # The SDK feature set.
            """) + TOKIO + '\n\n[dev-dependencies]\nserde_json = "1.0.154"\n', PROFILES))
        self.write("Plugins/alpha/Cargo.lock", lock(
            {**sdk, "flash-plugin-alpha": ["flash_plugin", "regex", "serde_json", "tokio"]},
            registry))
        # Depends on tokio only for its tests, and on serde_json only through the SDK.
        self.write("Plugins/beta/Cargo.toml", package("flash-plugin-beta", textwrap.dedent("""
            [dependencies]
            flash_plugin = { path = "../_flash_plugin_rust" }

            [dev-dependencies]
            tokio = { version = "1.54.1", default-features = false, features = ["test-util"] }
            """), PROFILES.replace("# Dev hot-loop profile.\n", "")))
        self.write("Plugins/beta/Cargo.lock", lock(
            {**sdk, "flash-plugin-beta": ["flash_plugin", "tokio"]}, registry[1:]))
        # Not a crate: a manifest-only plugin directory.
        self.write("Plugins/defaults/manifest.json", "{}\n")

    def path(self, relative):
        return self.root / relative

    def write(self, relative, text):
        path = self.path(relative)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def read(self, relative):
        return self.path(relative).read_text()

    def replace(self, relative, old, new):
        text = self.read(relative)
        assert old in text, (relative, old)
        self.write(relative, text.replace(old, new))

    def files(self):
        return {
            str(path.relative_to(self.root)): path.read_text()
            for path in sorted(self.root.rglob("Cargo.*"))
        }


class TreeTestCase(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.tree = Tree(directory.name)

    def problems(self):
        return check.problems(self.tree.root)


class CheckTests(TreeTestCase):
    def test_agreeing_crates_pass(self):
        self.assertEqual(self.problems(), [])

    def test_profile_value_drift_names_the_crates_and_values(self):
        self.tree.replace("Plugins/beta/Cargo.toml", 'opt-level = "z"', 'opt-level = "s"')
        self.assertEqual(self.problems(), [
            "[profile.release] opt-level differs between plugin crates\n"
            '  "z": Plugins/alpha\n'
            '  "s": Plugins/beta'])

    def test_profile_key_only_one_crate_sets(self):
        self.tree.replace("Plugins/alpha/Cargo.toml", "lto = true", "lto = true\nstrip = true")
        self.assertEqual(self.problems(), [
            "[profile.release] strip differs between plugin crates\n"
            "  true: Plugins/alpha\n"
            "  (unset): Plugins/beta"])

    def test_missing_profile_is_reported_once(self):
        self.tree.replace(
            "Plugins/beta/Cargo.toml", '[profile.release]\nopt-level = "z"\nlto = true\n', "")
        self.assertEqual(self.problems(), [
            "[profile.release] is missing from Plugins/beta (1 plugin crates declare it)"])

    def test_sdk_workspace_profiles_are_not_compared(self):
        self.assertNotIn("[profile", self.tree.read(f"{SDK}/Cargo.toml"))
        self.assertEqual(self.problems(), [])

    def test_version_requirement_drift_names_the_crates_and_values(self):
        self.tree.replace(f"{SDK}/probe/Cargo.toml", "1.54.1", "1.55.0")
        self.assertEqual(self.problems(), [
            "tokio is declared differently\n"
            '  "1.54.1": Plugins/_flash_plugin_rust, Plugins/alpha,'
            " Plugins/beta [dev-dependencies]\n"
            '  "1.55.0": Plugins/_flash_plugin_rust/probe'])

    def test_drift_between_dependency_tables_of_two_crates(self):
        self.tree.replace("Plugins/alpha/Cargo.toml", 'serde_json = "1.0.154"', 'serde_json = "1"')
        self.assertEqual(self.problems(), [
            "serde_json is declared differently\n"
            '  "1.0.154": Plugins/_flash_plugin_rust, Plugins/_flash_plugin_rust/macros\n'
            '  "1": Plugins/alpha [dev-dependencies]'])

    def test_registry_dependency_features_may_differ(self):
        self.tree.replace("Plugins/alpha/Cargo.toml", '"time",', '"time",\n  "net",')
        self.assertEqual(self.problems(), [])

    def test_sdk_dependency_must_be_declared_the_same_way(self):
        self.tree.replace(
            "Plugins/beta/Cargo.toml", 'flash_plugin = { path = "../_flash_plugin_rust" }',
            'flash_plugin = { path = "../_flash_plugin_rust", features = ["extra"] }')
        self.assertEqual(self.problems(), [
            "flash_plugin is declared differently\n"
            "  path Plugins/_flash_plugin_rust: Plugins/_flash_plugin_rust/probe, Plugins/alpha\n"
            '  path Plugins/_flash_plugin_rust, features = ["extra"]: Plugins/beta'])

    def test_lock_drift_names_the_locks_and_versions(self):
        self.tree.replace("Plugins/beta/Cargo.lock", '"1.54.1"', '"1.54.3"')
        self.assertEqual(self.problems(), [
            "tokio is locked at different versions\n"
            "  1.54.1: Plugins/_flash_plugin_rust/Cargo.lock, Plugins/alpha/Cargo.lock\n"
            "  1.54.3: Plugins/beta/Cargo.lock"])

    def test_lock_reads_the_version_a_crate_depends_on_among_several(self):
        self.tree.replace(
            "Plugins/alpha/Cargo.lock", ' "flash_plugin",\n "regex",\n "serde_json",\n "tokio",',
            ' "flash_plugin",\n "regex",\n "serde_json",\n "tokio 1.54.1",')
        self.tree.write("Plugins/alpha/Cargo.lock", self.tree.read("Plugins/alpha/Cargo.lock") + (
            f'\n[[package]]\nname = "tokio"\nversion = "0.2.25"\n{REGISTRY}\n'))
        self.assertEqual(self.problems(), [])

    def test_command_reports_and_fails(self):
        script = SCRIPTS / "check-plugin-crates.py"
        environment = {**os.environ, "FLASH_PLUGIN_PROJECT_DIR": str(self.tree.root)}
        passing = subprocess.run(
            [sys.executable, "-I", script], env=environment, text=True, capture_output=True)
        self.assertEqual((passing.returncode, passing.stdout, passing.stderr), (0, "", ""))
        self.tree.replace("Plugins/beta/Cargo.toml", "1.54.1", "1.55.0")
        failing = subprocess.run(
            [sys.executable, "-I", script], env=environment, text=True, capture_output=True)
        self.assertEqual(failing.returncode, 1)
        self.assertIn("tokio is declared differently", failing.stderr)
        self.assertIn("mise run update:plugin-dependency", failing.stderr)

    def test_unreadable_manifest_fails(self):
        self.tree.write("Plugins/beta/Cargo.toml", "[package\n")
        with self.assertRaisesRegex(check.CrateError, "Plugins/beta/Cargo.toml"):
            self.problems()


class UpdateTests(TreeTestCase):
    @classmethod
    def setUpClass(cls):
        # One executable for every test: macOS assesses each new one on first run.
        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        cls.tools = Path(directory.name)
        cargo = cls.tools / "cargo"
        cargo.write_text(CARGO)
        cargo.chmod(0o755)

    def setUp(self):
        super().setUp()
        self.log = self.tree.root / "cargo.log"

    def update(self, *arguments, **environment):
        return subprocess.run(
            [sys.executable, "-I", UPDATE, *arguments], text=True, capture_output=True,
            env={
                **os.environ, **environment,
                "PATH": f"{self.tools}{os.pathsep}{os.environ['PATH']}",
                "FLASH_PLUGIN_PROJECT_DIR": str(self.tree.root),
                "CARGO_LOG": str(self.log),
            })

    def cargo_calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_sets_the_requirement_in_every_crate_and_refreshes_every_lock(self):
        result = self.update("tokio", "1.55.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, textwrap.dedent("""\
            tokio: version requirement set to "1.55.0"
              Plugins/_flash_plugin_rust/Cargo.toml [dependencies]: "1.54.1" -> "1.55.0"
              Plugins/_flash_plugin_rust/probe/Cargo.toml [dependencies]: "1.54.1" -> "1.55.0"
              Plugins/alpha/Cargo.toml [dependencies]: "1.54.1" -> "1.55.0"
              Plugins/beta/Cargo.toml [dev-dependencies]: "1.54.1" -> "1.55.0"
              Plugins/_flash_plugin_rust/Cargo.lock: tokio 1.54.1 -> 1.55.0
              Plugins/alpha/Cargo.lock: tokio 1.54.1 -> 1.55.0
              Plugins/beta/Cargo.lock: tokio 1.54.1 -> 1.55.0
            """))
        self.assertEqual(self.cargo_calls(), [
            "_flash_plugin_rust update --package tokio@1.54.1 --precise 1.55.0",
            "alpha update --package tokio@1.54.1 --precise 1.55.0",
            "beta update --package tokio@1.54.1 --precise 1.55.0",
        ])
        # Only the requirement moved: features, comments and layout survive.
        self.assertIn(
            '# The SDK feature set.\n' + TOKIO.replace("1.54.1", "1.55.0"),
            self.tree.read("Plugins/alpha/Cargo.toml"))
        self.assertIn(
            'tokio = { version = "1.55.0", default-features = false, features = ["test-util"] }',
            self.tree.read("Plugins/beta/Cargo.toml"))
        self.assertEqual(self.problems(), [])

    def test_refreshes_the_lock_of_a_crate_that_only_builds_a_changed_crate(self):
        # beta never names serde_json, but its lock resolves the SDK's requirement.
        result = self.update("serde_json", "1.0.160")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Plugins/beta/Cargo.toml", result.stdout)
        self.assertIn("  Plugins/beta/Cargo.lock: serde_json 1.0.154 -> 1.0.160\n", result.stdout)
        self.assertEqual([call.split()[0] for call in self.cargo_calls()], [
            "_flash_plugin_rust", "alpha", "beta"])

    def test_touches_only_the_crates_that_use_the_dependency(self):
        before = self.tree.files()
        result = self.update("regex", "1.13.2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        after = self.tree.files()
        self.assertEqual(
            sorted(path for path in after if after[path] != before[path]),
            ["Plugins/alpha/Cargo.lock", "Plugins/alpha/Cargo.toml"])
        self.assertEqual(
            self.cargo_calls(), ["alpha update --package regex@1.13.1 --precise 1.13.2"])

    def test_range_requirement_resolves_without_precise(self):
        result = self.update("regex", ">=1.13, <2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('regex = ">=1.13, <2"\n', self.tree.read("Plugins/alpha/Cargo.toml"))
        self.assertEqual(self.cargo_calls(), ["alpha update --package regex@1.13.1"])

    def test_aligns_a_drifted_requirement(self):
        self.tree.replace("Plugins/beta/Cargo.toml", "1.54.1", "1.50.0")
        self.assertNotEqual(self.problems(), [])
        result = self.update("tokio", "1.54.1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            'Plugins/beta/Cargo.toml [dev-dependencies]: "1.50.0" -> "1.54.1"', result.stdout)
        self.assertNotIn("Plugins/alpha", result.stdout)
        self.assertEqual(self.problems(), [])

    def test_unchanged_requirement_changes_nothing(self):
        before = self.tree.files()
        result = self.update("tokio", "1.54.1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("already", result.stdout)
        self.assertEqual(self.tree.files(), before)
        self.assertEqual(self.cargo_calls(), [])

    def refused(self, *arguments, **environment):
        before = self.tree.files()
        result = self.update(*arguments, **environment)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.tree.files(), before)
        return result.stderr

    def test_refuses_an_unknown_dependency(self):
        error = self.refused("tokyo", "1.55.0")
        self.assertEqual(
            error,
            "error: no plugin crate declares tokyo; the registry dependencies are:"
            " regex, serde_json, tokio\n")
        self.assertEqual(self.cargo_calls(), [])

    def test_refuses_a_path_dependency(self):
        error = self.refused("flash_plugin", "0.2.0")
        self.assertIn("flash_plugin is a path dependency", error)
        self.assertEqual(self.cargo_calls(), [])

    def test_refuses_a_malformed_requirement(self):
        for requirement in ("", "latest", '1.55.0"', "1.55.0\n[x]"):
            with self.subTest(requirement=requirement):
                self.assertIn("not a version requirement", self.refused("tokio", requirement))
        self.assertEqual(self.cargo_calls(), [])

    def test_refuses_an_entry_it_cannot_rewrite(self):
        manifest = self.tree.read("Plugins/alpha/Cargo.toml").replace('regex = "1.13.1"\n', "")
        self.tree.write(
            "Plugins/alpha/Cargo.toml", manifest + '\n[dependencies.regex]\nversion = "1.13.1"\n')
        self.assertEqual(self.problems(), [])
        self.assertIn(
            "Plugins/alpha/Cargo.toml: cannot rewrite regex", self.refused("regex", "1.13.2"))
        self.assertEqual(self.cargo_calls(), [])

    def test_cargo_failure_restores_every_file(self):
        error = self.refused("tokio", "1.55.0", CARGO_FAILS_IN="alpha")
        self.assertIn("failed in Plugins/alpha; every file is restored", error)
        self.assertIn("no matching package named tokio", error)
        self.assertEqual([call.split()[0] for call in self.cargo_calls()], [
            "_flash_plugin_rust", "alpha"])

    def test_usage(self):
        result = self.update("tokio")
        self.assertEqual(result.returncode, 2)
        self.assertIn(
            "usage: update-plugin-dependency.py <dependency> <requirement>", result.stderr)


if __name__ == "__main__":
    unittest.main()
