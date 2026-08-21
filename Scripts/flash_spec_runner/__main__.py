"""CLI: legacy single-plugin mode and the full conformance matrix.

Legacy (from a plugin dir; manifest.json read from cwd — the documented
debugging loop and what CI's per-plugin steps call):

    python3 Scripts/plugin-protocol-spec.py [--skip GLOB]... [--only GLOB]... -- <argv...>

Matrix (from anywhere inside the repo):

    plugin-protocol-spec.py --all [--jobs N] [--report out.json]
    plugin-protocol-spec.py --plugin emojis --plugin snippets
    plugin-protocol-spec.py --probes                 # conformance probes × full suite
    plugin-protocol-spec.py --sandbox --flash-bin .build/debug/flash
    plugin-protocol-spec.py --list | --validate-only
"""
import argparse
import concurrent.futures
import fnmatch
import json
import os
import pathlib
import subprocess
import sys
import threading
import time

from . import discover
from .process import build_environment, make_data_dir
from .report import Report, Row
from .run import run_spec
from .schema import SpecError

# The sandbox lane boots each sandboxed plugin under its real generated
# profile and proves the handshake + warm pull still work — a too-tight
# profile fails here instead of at user runtime.
SANDBOX_LANE_SPECS = ("lifecycle/handshake", "sources/warm-readiness")


def parse_args(argv=None):
    parser = argparse.ArgumentParser(prog="plugin-protocol-spec.py")
    parser.add_argument("--skip", action="append", default=[], metavar="GLOB")
    parser.add_argument("--only", action="append", default=[], metavar="GLOB")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--plugin", action="append", default=[], metavar="ID")
    parser.add_argument("--probes", action="store_true")
    parser.add_argument("--sandbox", action="store_true")
    parser.add_argument("--flash-bin", default=None)
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 4))
    parser.add_argument("--max-minutes", type=float, default=20.0)
    parser.add_argument("--report", default=None)
    parser.add_argument("--github-annotations", action="store_true")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("argv", nargs=argparse.REMAINDER)
    return parser.parse_args(argv)


def selected(spec_name, args):
    if args.only and not any(fnmatch.fnmatch(spec_name, g) for g in args.only):
        return False
    return not any(fnmatch.fnmatch(spec_name, g) for g in args.skip)


def load_shared_specs():
    try:
        return discover.shared_specs()
    except SpecError as error:
        print(f"spec validation failed: {error}", file=sys.stderr)
        sys.exit(2)


def run_one_plugin(plugin_dir, plugin_key, argv, specs, overrides, args, deadline,
                   sandbox_profile_for=None):
    """Run every applicable spec against one plugin; returns Row list."""
    rows = []
    manifest_path = plugin_dir / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, ValueError) as error:
        return [Row(plugin_key, "-", "fail", f"unreadable manifest: {error}")]
    if not manifest.get("exec"):
        return [Row(plugin_key, "-", "manifest-only")]
    exec_argv = argv or manifest["exec"]
    features = discover.manifest_features(manifest)
    try:
        local_specs = discover.plugin_specs(plugin_dir)
    except SpecError as error:
        rows.append(Row(plugin_key, "-", "fail", str(error)))
        local_specs = []
    for spec in [s for s in specs if discover.applicable(s, features)] + local_specs:
        name = spec["name"]
        if not selected(name, args):
            continue
        if time.monotonic() > deadline:
            rows.append(Row(plugin_key, name, "fail", "global --max-minutes cap reached"))
            break
        mode, reason = overrides.disposition(plugin_key, name)
        if mode == "skip":
            rows.append(Row(plugin_key, name, "skip", reason))
            continue
        variables = {"plugin_id": manifest.get("id", plugin_key)}
        data_dir = os.environ.get("FLASH_PLUGIN_DATA_DIR") or make_data_dir(spec, variables)
        variables["data_dir"] = data_dir
        if spec.get("config") is not None:
            config_json = json.dumps(spec["config"], separators=(",", ":"))
        else:
            config_json = os.environ.get("FLASH_PLUGIN_CONFIG")
        parent = "ephemeral" if spec.get("parent") == "ephemeral" else os.getpid()
        env = build_environment(
            discover.PLUGINS_DIR, os.environ.get("FLASH_PLUGIN_ID", variables["plugin_id"]),
            data_dir, config_json, parent, spec)
        profile = sandbox_profile_for(plugin_dir, data_dir) if sandbox_profile_for else None
        started = time.monotonic()
        failure, diagnostics = run_spec(spec, exec_argv, plugin_dir, env, variables, profile)
        duration = int((time.monotonic() - started) * 1000)
        if mode == "xfail":
            status = "xfail" if failure else "xpass"
            why = reason if failure else f"xfail entry is stale — spec passes ({reason})"
        else:
            status = "fail" if failure else "pass"
            why = failure or ""
        rows.append(Row(plugin_key, name, status, why, duration, diagnostics))
    return rows


def sandbox_profile_factory(flash_bin):
    def generate(plugin_dir, data_dir):
        result = subprocess.run(
            [flash_bin, "_plugin-sandbox-profile", "--root", str(plugin_dir),
             "--data-dir", data_dir],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            raise RuntimeError(f"profile generation failed: {result.stderr.strip()}")
        return result.stdout
    return generate


def main(argv=None):
    args = parse_args(argv)
    plugin_argv = args.argv[1:] if args.argv and args.argv[0] == "--" else args.argv

    specs_probe_pairs = load_shared_specs()
    shared = [spec for spec, probe_only in specs_probe_pairs if not probe_only]
    probe_specs = [spec for spec, probe_only in specs_probe_pairs]

    if args.validate_only:
        for plugin_dir in discover.plugin_dirs() + discover.probe_dirs():
            try:
                discover.plugin_specs(plugin_dir)
            except SpecError as error:
                print(f"spec validation failed: {error}", file=sys.stderr)
                sys.exit(2)
        print(f"{len(specs_probe_pairs)} shared spec file(s) valid")
        return
    if args.list:
        for spec, probe_only in specs_probe_pairs:
            gate = ",".join(spec.get("requires", [])) or "always"
            lane = "probe" if probe_only else "shared"
            print(f"{spec['name']}\t{lane}\t{gate}\t{spec['contract']}")
        return

    report = Report(annotations=args.github_annotations)
    deadline = time.monotonic() + args.max_minutes * 60.0
    overrides = discover.Overrides()

    if plugin_argv and not (args.all or args.plugin or args.probes):
        # Legacy mode: cwd is the plugin dir, argv is the plugin command.
        cwd = pathlib.Path.cwd()
        if not (cwd / "manifest.json").exists():
            print("cannot read ./manifest.json (run from the plugin dir)", file=sys.stderr)
            sys.exit(2)
        print(f"== {cwd.name}")
        for row in run_one_plugin(cwd, cwd.name, plugin_argv, shared, overrides, args, deadline):
            report.add(row)
    else:
        targets = []
        if args.all:
            targets += [(d, d.name, shared) for d in discover.plugin_dirs()]
        for wanted in args.plugin:
            matches = [d for d in discover.plugin_dirs() if d.name == wanted]
            if not matches:
                print(f"unknown plugin id: {wanted}", file=sys.stderr)
                sys.exit(2)
            targets += [(matches[0], wanted, shared)]
        if args.probes:
            targets += [(d, f"probe:{d.name}", probe_specs) for d in discover.probe_dirs()]
        if args.sandbox:
            if not args.flash_bin:
                print("--sandbox requires --flash-bin", file=sys.stderr)
                sys.exit(2)
            factory = sandbox_profile_factory(args.flash_bin)
            args.only = args.only or list(SANDBOX_LANE_SPECS)
            sandboxed = []
            for plugin_dir, key, spec_set in targets or [
                (d, d.name, shared) for d in discover.plugin_dirs()
            ]:
                manifest = json.loads((plugin_dir / "manifest.json").read_text())
                if "sandbox" in manifest:
                    sandboxed.append((plugin_dir, f"sandbox:{key}", spec_set, factory))
            targets = sandboxed
        elif not targets:
            print("nothing selected: use --all / --plugin / --probes or legacy `-- argv`",
                  file=sys.stderr)
            sys.exit(2)

        lock = threading.Lock()

        def worker(entry):
            plugin_dir, key, spec_set = entry[:3]
            factory = entry[3] if len(entry) > 3 else None
            rows = run_one_plugin(
                plugin_dir, key, None, spec_set, overrides, args, deadline,
                sandbox_profile_for=factory)
            with lock:
                print(f"== {key}")
                for row in rows:
                    report.add(row)

        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            list(pool.map(worker, targets))

    if args.report:
        report.write_json(args.report)
    print(report.summary())
    sys.exit(0 if not report.failures() else 1)


if __name__ == "__main__":
    main()
