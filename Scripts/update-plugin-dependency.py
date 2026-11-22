#!/usr/bin/env python3
"""Set one dependency's version requirement in every plugin crate that uses it.

The plugin crates are hermetic: a dependency several of them declare is a copy
in each manifest and each lock, and the plugin gate rejects copies that
disagree (check-plugin-crates.py). This rewrites the requirement in every
manifest that declares the dependency, the SDK workspace's crates included,
then refreshes the Cargo.lock of every crate that changed or that builds a
changed crate through a path dependency, with `cargo update -p <dependency>`.
A full version (`1.55.0`) is also the version every lock resolves to
(`--precise`); any other requirement (`1.55`, `>=1.50, <2`) resolves to the
newest match.

It refuses a dependency no crate declares and one declared by path or git,
prints every manifest and lock change, and restores every file when cargo
rejects the requirement. Nothing is committed.

Usage:
  update-plugin-dependency.py <dependency> <requirement>
"""

import copy
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "check_plugin_crates", Path(__file__).with_name("check-plugin-crates.py"))
crates = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(crates)
tomllib = crates.tomllib

COMPARATOR = r"(?:[=^~]|[<>]=?)?\s*(?:\d+|\*)(?:\.(?:\d+|\*)){0,2}(?:-[0-9A-Za-z.-]+)?"
REQUIREMENT = re.compile(rf"{COMPARATOR}(?:\s*,\s*{COMPARATOR})*")
FULL_VERSION = re.compile(r"=?\s*(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)")
HEADER = re.compile(r"\s*\[\[?\s*([^\[\]]+?)\s*\]\]?\s*(?:#.*)?")


class Refusal(Exception):
    """A request this script does not carry out; nothing was written."""


def rewritten(text, keys, requirement):
    """The manifest text with `keys` set to `requirement` in the dependency tables.

    Edits `key = "…"` and `key = { … version = "…" … }` in place, so comments
    and layout survive; the caller verifies the result.
    """
    names = "|".join(re.escape(key) for key in sorted(keys))
    entry = re.compile(
        rf'(\s*"?(?:{names})"?\s*=\s*(?:\{{[^\n]*?\bversion\s*=\s*)?")[^"\n]*(".*)', re.DOTALL)
    lines = text.splitlines(keepends=True)
    table = ""
    for index, line in enumerate(lines):
        header = HEADER.fullmatch(line.rstrip("\n"))
        if header:
            table = header.group(1)
        elif table.rsplit(".", 1)[-1] in crates.DEPENDENCY_TABLES:
            match = entry.fullmatch(line)
            if match:
                lines[index] = f"{match.group(1)}{requirement}{match.group(2)}"
    return "".join(lines)


def expected(manifest, package, requirement):
    """The parsed manifest the rewrite must produce: only this requirement moved."""
    manifest = copy.deepcopy(manifest)
    tables = [manifest]
    tables += list(manifest.get("target", {}).values())
    for holder in tables:
        for name in crates.DEPENDENCY_TABLES:
            for key, spec in holder.get(name, {}).items():
                if isinstance(spec, str):
                    if key == package:
                        holder[name][key] = requirement
                elif spec.get("package", key) == package:
                    spec["version"] = requirement
    return manifest


def dependents(all_crates, changed):
    """The lock roots of the changed crates and of every crate that builds one by path."""
    paths = {
        crate.directory: {
            crates.path_target(declaration)
            for declaration in crates.declarations(crate) if "path" in declaration.spec
        }
        for crate in all_crates
    }
    affected = set(changed)
    grew = True
    while grew:
        grew = False
        for directory, targets in paths.items():
            if directory not in affected and targets & affected:
                affected.add(directory)
                grew = True
    roots = []
    for crate in all_crates:
        if crate.directory in affected and crate.root not in roots:
            roots.append(crate.root)
    return roots


def locked_specs(packages, package):
    """`name@version` for each version of `package` a local crate depends on directly."""
    specs = []
    for entry in packages:
        if "source" in entry:
            continue
        version = crates.locked_version(packages, entry.get("name"), package)
        if version is not None and f"{package}@{version}" not in specs:
            specs.append(f"{package}@{version}")
    return specs or [package]


def lock_changes(before, after):
    """`name old -> new` for every package whose locked versions moved."""
    def versions(packages):
        found = {}
        for entry in packages:
            found.setdefault(entry["name"], set()).add(entry["version"])
        return found

    old, new = versions(before), versions(after)
    changes = []
    for name in sorted(set(old) | set(new)):
        gone = sorted(old.get(name, set()) - new.get(name, set()))
        came = sorted(new.get(name, set()) - old.get(name, set()))
        if gone or came:
            changes.append(f"{name} {'/'.join(gone) or 'absent'} -> {'/'.join(came) or 'removed'}")
    return changes


def update(project, package, requirement):
    all_crates = crates.load_crates(project)
    declared = [
        declaration for crate in all_crates for declaration in crates.declarations(crate)
        if declaration.package == package
    ]
    if not declared:
        known = sorted({
            declaration.package for crate in all_crates
            for declaration in crates.declarations(crate) if declaration.registry
        })
        raise Refusal(
            f"no plugin crate declares {package}; the registry dependencies are:"
            f" {', '.join(known)}")
    for declaration in declared:
        if not declaration.registry:
            raise Refusal(
                f"{package} is a {'path' if 'path' in declaration.spec else 'git'} dependency"
                f" in {declaration.where}; it has no version requirement to set")
    if not REQUIREMENT.fullmatch(requirement):
        raise Refusal(f"not a version requirement: {requirement!r}")

    stale = [
        declaration for declaration in declared
        if declaration.spec.get("version") != requirement
    ]
    if not stale:
        print(f"{package} is already {json.dumps(requirement)} in every crate that declares it")
        return

    # Rewrite in memory first: an entry this cannot edit refuses before any write.
    originals = {}
    edits = {}
    changed = []
    for crate in all_crates:
        moved = [declaration for declaration in stale if declaration.crate is crate]
        if not moved:
            continue
        path = project / crate.directory / "Cargo.toml"
        text = path.read_text()
        edit = rewritten(text, {declaration.key for declaration in moved}, requirement)
        try:
            parsed = tomllib.loads(edit)
        except tomllib.TOMLDecodeError:
            parsed = None
        if parsed != expected(crate.manifest, package, requirement):
            raise Refusal(
                f"{crate.directory}/Cargo.toml: cannot rewrite {package} in place; this edits"
                f' `{package} = "…"` and `{package} = {{ version = "…", … }}` entries')
        originals[path] = text
        edits[path] = edit
        changed.append(crate.directory)

    roots = dependents(all_crates, changed)
    locks = {root: project / root / "Cargo.lock" for root in roots}
    for path in locks.values():
        originals[path] = path.read_text()
    precise = FULL_VERSION.fullmatch(requirement)

    def restore():
        for path, text in originals.items():
            path.write_text(text)

    try:
        for path, edit in edits.items():
            path.write_text(edit)
        for root in roots:
            locked = tomllib.loads(originals[locks[root]]).get("package", [])
            for spec in locked_specs(locked, package):
                command = ["cargo", "update", "--package", spec]
                if precise:
                    command += ["--precise", precise.group(1)]
                result = subprocess.run(
                    command, cwd=project / root, text=True, capture_output=True, check=False)
                if result.returncode:
                    raise Refusal(
                        f"`{' '.join(command)}` failed in {root}; every file is restored\n"
                        f"{result.stderr.strip()}")
    except BaseException:
        restore()
        raise

    print(f"{package}: version requirement set to {json.dumps(requirement)}")
    for declaration in stale:
        print(
            f"  {declaration.crate.directory}/Cargo.toml [{declaration.table}]:"
            f" {json.dumps(declaration.spec.get('version', '*'))} -> {json.dumps(requirement)}")
    for root in roots:
        before = tomllib.loads(originals[locks[root]]).get("package", [])
        after = crates.locked_packages(project, root)
        moved = lock_changes(before, after)
        print(f"  {root}/Cargo.lock: {', '.join(moved) if moved else 'unchanged'}")


def main(arguments):
    if len(arguments) != 2:
        print("usage: update-plugin-dependency.py <dependency> <requirement>", file=sys.stderr)
        return 2
    project = crates.project_directory()
    try:
        update(project, *arguments)
        remaining = crates.problems(project)
    except (Refusal, crates.CrateError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if remaining:
        print("error: the plugin crates still disagree:", file=sys.stderr)
        print("\n".join(remaining), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
