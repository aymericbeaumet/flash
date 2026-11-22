#!/usr/bin/env python3
"""Check that the plugin crates agree on what Cargo cannot share between them.

Every bundled plugin is a hermetic crate: its own manifest, its own lock and a
path dependency on the SDK workspace (Plugins/_flash_plugin_rust), with no
workspace above them to inherit from. What they have in common is therefore a
copy in each crate, and this fails when the copies disagree:

- build profiles: every plugin crate declares the same `[profile.*]` tables.
  The SDK workspace is not compared: it ships no binary, and a plugin build
  takes its profiles from the plugin crate.
- direct dependencies: a dependency two crates declare has one version
  requirement (or one git revision) in both, the SDK workspace's crates
  included. A path dependency, the SDK's above all, is declared the same way
  by every crate, features included. The features of a registry dependency
  are not compared: each plugin compiles only what it uses (tokio's `net`,
  nix's feature sets).
- locks: a registry dependency two crates declare resolves to one version in
  both Cargo.lock files.

`mise run update:plugin-dependency` changes one requirement in every crate.
Standard library only; runs under `python3 -I`.

Usage:
  check-plugin-crates.py
"""

import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    sys.exit("python3 has no tomllib (3.11+): use 'mise run test:plugins'")

SDK = "Plugins/_flash_plugin_rust"
DEPENDENCY_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")
UNSET = "(unset)"


class CrateError(Exception):
    """A manifest or lock that cannot be read."""


@dataclass(frozen=True)
class Crate:
    directory: str  # relative to the repository, as messages name it
    root: str  # the directory that holds its Cargo.lock
    plugin: bool
    manifest: dict

    @property
    def name(self):
        return self.manifest.get("package", {}).get("name", "")


@dataclass(frozen=True)
class Declaration:
    crate: Crate
    table: str  # `dependencies`, `target.<cfg>.dev-dependencies`…
    key: str
    spec: dict

    @property
    def package(self):
        return self.spec.get("package", self.key)

    @property
    def registry(self):
        return "path" not in self.spec and "git" not in self.spec

    @property
    def where(self):
        table = "" if self.table == "dependencies" else f" [{self.table}]"
        return f"{self.crate.directory}{table}"


def read_toml(path):
    try:
        return tomllib.loads(path.read_text())
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise CrateError(f"{path}: {error}") from error


def load_crates(project):
    """The SDK workspace's crates, then every plugin crate, as the gate walks them."""
    manifest = read_toml(project / SDK / "Cargo.toml")
    members = manifest.get("workspace", {}).get("members", [])
    crates = [Crate(SDK, SDK, False, manifest)]
    for member in members:
        directory = f"{SDK}/{member}"
        crates.append(Crate(directory, SDK, False, read_toml(project / directory / "Cargo.toml")))
    for path in sorted((project / "Plugins").glob("[!_]*/Cargo.toml")):
        directory = f"Plugins/{path.parent.name}"
        crates.append(Crate(directory, directory, True, read_toml(path)))
    return crates


def declarations(crate):
    """Every direct dependency a manifest declares, in each table that can hold one."""
    tables = [(name, crate.manifest.get(name, {})) for name in DEPENDENCY_TABLES]
    for target, body in crate.manifest.get("target", {}).items():
        tables += [(f"target.{target}.{name}", body.get(name, {})) for name in DEPENDENCY_TABLES]
    for table, entries in tables:
        for key, spec in entries.items():
            spec = {"version": spec} if isinstance(spec, str) else spec
            yield Declaration(crate, table, key, spec)


def path_target(declaration):
    """The crate directory a path dependency names, relative to the repository."""
    return os.path.normpath(os.path.join(declaration.crate.directory, declaration.spec["path"]))


def pin(declaration):
    """What a declaration pins, as the text two crates must share."""
    spec = declaration.spec
    if "path" in spec:
        # A crate of this repository: the whole declaration is the contract.
        rest = {key: value for key, value in spec.items() if key not in ("path", "package")}
        if isinstance(rest.get("features"), list):
            rest["features"] = sorted(rest["features"])
        details = "".join(f", {key} = {json.dumps(rest[key])}" for key in sorted(rest))
        return f"path {path_target(declaration)}{details}"
    if "git" in spec:
        reference = next(
            (f" {key} {spec[key]}" for key in ("rev", "tag", "branch") if key in spec), "")
        return f"git {spec['git']}{reference}"
    registry = f" from {spec['registry']}" if "registry" in spec else ""
    return f"{json.dumps(spec.get('version', '*'))}{registry}"


def disagreement(title, groups):
    """One problem: a title, then each differing value with the crates that hold it."""
    lines = [title]
    for value, holders in groups.items():
        lines.append(f"  {value}: {', '.join(holders)}")
    return "\n".join(lines)


def grouped(pairs):
    groups = {}
    for value, holder in pairs:
        holders = groups.setdefault(value, [])
        if holder not in holders:
            holders.append(holder)
    return groups


def flattened(table, prefix=""):
    """`{"package": {"x": {"opt-level": 3}}}` as `{"package.x.opt-level": "3"}`."""
    flat = {}
    for key, value in table.items():
        if isinstance(value, dict):
            flat.update(flattened(value, f"{prefix}{key}."))
        else:
            flat[f"{prefix}{key}"] = json.dumps(value)
    return flat


def profile_problems(crates):
    plugins = [crate for crate in crates if crate.plugin]
    profiles = {crate.directory: crate.manifest.get("profile", {}) for crate in plugins}
    problems = []
    for name in sorted({name for tables in profiles.values() for name in tables}):
        missing = [directory for directory, tables in profiles.items() if name not in tables]
        if missing:
            problems.append(
                f"[profile.{name}] is missing from {', '.join(missing)}"
                f" ({len(profiles) - len(missing)} plugin crates declare it)")
        declared = {
            directory: flattened(tables[name])
            for directory, tables in profiles.items() if name in tables
        }
        for key in sorted({key for flat in declared.values() for key in flat}):
            groups = grouped(
                (flat.get(key, UNSET), directory) for directory, flat in declared.items())
            if len(groups) > 1:
                problems.append(disagreement(
                    f"[profile.{name}] {key} differs between plugin crates", groups))
    return problems


def dependency_problems(crates):
    by_package = {}
    for crate in crates:
        for declaration in declarations(crate):
            by_package.setdefault(declaration.package, []).append(declaration)
    problems = []
    for package in sorted(by_package):
        groups = grouped(
            (pin(declaration), declaration.where) for declaration in by_package[package])
        if len(groups) > 1:
            problems.append(disagreement(f"{package} is declared differently", groups))
    return problems


def locked_packages(project, root):
    return read_toml(project / root / "Cargo.lock").get("package", [])


def locked_version(packages, crate_name, package):
    """The version a crate's direct dependency resolves to in its lock.

    None when the lock does not say: a lock behind its manifest is what the
    gate's `--locked` builds report.
    """
    for entry in packages:
        if entry.get("name") != crate_name or "source" in entry:
            continue
        for dependency in entry.get("dependencies", []):
            name, _, rest = dependency.partition(" ")
            if name != package:
                continue
            if rest:
                return rest.split(" ")[0]
            versions = [other["version"] for other in packages if other.get("name") == package]
            return versions[0] if len(versions) == 1 else None
    return None


def lock_problems(project, crates):
    locks = {}
    by_package = {}
    for crate in crates:
        if crate.root not in locks:
            locks[crate.root] = locked_packages(project, crate.root)
        for declaration in declarations(crate):
            if not declaration.registry:
                continue
            version = locked_version(locks[crate.root], crate.name, declaration.package)
            if version is not None:
                by_package.setdefault(declaration.package, []).append(
                    (version, f"{crate.root}/Cargo.lock"))
    problems = []
    for package in sorted(by_package):
        groups = grouped(by_package[package])
        if len(groups) > 1:
            problems.append(disagreement(f"{package} is locked at different versions", groups))
    return problems


def problems(project):
    crates = load_crates(project)
    return profile_problems(crates) + dependency_problems(crates) + lock_problems(project, crates)


def project_directory():
    override = os.environ.get("FLASH_PLUGIN_PROJECT_DIR")
    return Path(override) if override else Path(__file__).resolve().parent.parent


def main():
    try:
        found = problems(project_directory())
    except CrateError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if not found:
        return 0
    print(
        "error: the plugin crates disagree; hermetic crates keep identical copies",
        file=sys.stderr)
    print("\n".join(found), file=sys.stderr)
    print(
        "'mise run update:plugin-dependency -- <dependency> <requirement>' sets one"
        " requirement in every crate and refreshes the locks.",
        file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
