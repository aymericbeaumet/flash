#!/usr/bin/env python3
"""Spec-driven protocol conformance runner for Flash plugins, any language.

Drives one plugin process through the JSON scenarios in Plugins/_specs/,
speaking the v1 wire contract from docs/plugin-protocol.md (one JSON object
per newline-terminated line over stdio). The specs are the shared test suite
for every plugin SDK/library — Rust, Python, TypeScript, Ruby, Go, Zig,
Swift — so a conformance gap fails identically no matter the language.

Spec files are objects:

  {
    "name": "lifecycle",
    "when": "always",            # always | sources | queries — gated on the
                                 # plugin's ./manifest.json declaring that
                                 # provider section
    "steps": [
      {"send": {...}},           # write one frame ("${plugin_id}" expands)
      {"send_raw": "..."},       # write raw bytes (malformed-line probes)
      {"expect": {"id": 1, "result": {...}}, "within_ms": 5000}
    ]
  }

`expect` waits for the response frame with that id and subset-matches the
expected object: scalars compare equal, objects recurse per key, and matcher
objects assert shape — {"$type": "array"|"string"|"object"|"number"|"bool",
"$min_len": N, "$each": {...}}. While waiting, the runner behaves like a
minimal host: plugin→host requests (id + method) are NAK'd with
{ok: false, error}, `flash.log` lines are printed, and other notifications
are ignored — SDKs must tolerate that interleaving.

A fresh plugin process runs per spec. Exits non-zero when any step fails.
Usage, from the plugin's directory (manifest.json is read from cwd):
    python3 Scripts/plugin-protocol-spec.py [--skip NAME]... [--only NAME]... -- <argv...>
    python3 Scripts/plugin-protocol-spec.py -- python3 main.py
    python3 Scripts/plugin-protocol-spec.py --skip snapshot -- ./flash-plugin-reminders
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

SPECS_DIR = pathlib.Path(__file__).resolve().parent.parent / "Plugins" / "_specs"


def frame(obj):
    return json.dumps(obj, separators=(",", ":")).encode("utf-8") + b"\n"


def substitute(value, variables):
    if isinstance(value, str):
        for name, replacement in variables.items():
            value = value.replace("${%s}" % name, replacement)
        return value
    if isinstance(value, list):
        return [substitute(item, variables) for item in value]
    if isinstance(value, dict):
        return {key: substitute(item, variables) for key, item in value.items()}
    return value


def match(expected, actual, path):
    """Subset match; returns a list of mismatch descriptions (empty = pass)."""
    if isinstance(expected, dict) and any(k.startswith("$") for k in expected):
        return match_shape(expected, actual, path)
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{path}: expected object, got {type(actual).__name__}"]
        problems = []
        for key, value in expected.items():
            if key not in actual:
                problems.append(f"{path}.{key}: missing")
            else:
                problems += match(value, actual[key], f"{path}.{key}")
        return problems
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(expected) != len(actual):
            return [f"{path}: expected {expected!r}, got {actual!r}"]
        problems = []
        for index, (want, got) in enumerate(zip(expected, actual)):
            problems += match(want, got, f"{path}[{index}]")
        return problems
    if expected != actual:
        return [f"{path}: expected {expected!r}, got {actual!r}"]
    return []


def match_shape(expected, actual, path):
    kinds = {
        "array": list,
        "string": str,
        "object": dict,
        "number": (int, float),
        "bool": bool,
    }
    problems = []
    if "$type" in expected:
        want = kinds[expected["$type"]]
        if not isinstance(actual, want):
            return [f"{path}: expected {expected['$type']}, got {type(actual).__name__}"]
    if "$min_len" in expected and len(actual) < expected["$min_len"]:
        problems.append(f"{path}: length {len(actual)} < {expected['$min_len']}")
    if "$each" in expected:
        for index, item in enumerate(actual):
            problems += match(expected["$each"], item, f"{path}[{index}]")
    return problems


class SpecFailure(Exception):
    pass


def run_spec(spec, argv, variables):
    child = subprocess.Popen(
        argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    os.set_blocking(child.stdout.fileno(), False)
    buf = b""
    responses = {}  # id -> full frame, for expects that arrive out of order

    def pump():
        """Drain available frames with host-like behavior for plugin traffic."""
        nonlocal buf
        while True:
            chunk = child.stdout.read(1 << 20)
            if not chunk:
                break
            buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                print(f"  undecodable plugin line: {line[:200]!r}", file=sys.stderr)
                continue
            method, mid = msg.get("method"), msg.get("id")
            if method is not None and mid is not None:
                # Plugin→host request: NAK like a host without the capability.
                print(f"  host-rpc: {method} -> NAK")
                try:
                    child.stdin.write(
                        frame(
                            {
                                "id": mid,
                                "result": {"ok": False, "error": "not available in spec runner"},
                            }
                        )
                    )
                    child.stdin.flush()
                except OSError:
                    pass
            elif method == "flash.log":
                print(f"  log: {msg.get('params', {}).get('message')}")
            elif method is not None:
                pass  # other notifications (status.updated, ...) are fine
            elif mid is not None:
                responses[mid] = msg

    try:
        for index, step in enumerate(spec["steps"]):
            where = f"{spec['name']}[{index}]"
            if "send" in step or "send_raw" in step:
                if "send" in step:
                    payload = frame(substitute(step["send"], variables))
                else:
                    payload = step["send_raw"].encode("utf-8")
                try:
                    child.stdin.write(payload)
                    child.stdin.flush()
                except OSError:
                    raise SpecFailure(
                        f"{where}: plugin closed stdin (exit status {child.poll()})"
                    )
            elif "expect" in step:
                expected = substitute(step["expect"], variables)
                want_id = expected["id"]
                deadline = time.monotonic() + step.get("within_ms", 5000) / 1000.0
                while want_id not in responses:
                    exited = child.poll() is not None
                    pump()  # drain even after exit — the reply may be buffered
                    if want_id in responses:
                        break
                    if exited:
                        raise SpecFailure(
                            f"{where}: plugin exited (status {child.returncode}) "
                            f"before replying to id {want_id}"
                        )
                    if time.monotonic() > deadline:
                        raise SpecFailure(f"{where}: no response with id {want_id}")
                    time.sleep(0.01)
                problems = match(expected, responses.pop(want_id), "frame")
                if problems:
                    raise SpecFailure(f"{where}: " + "; ".join(problems))
            else:
                raise SpecFailure(f"{where}: unknown step {sorted(step)}")
    finally:
        deadline = time.monotonic() + 1.0
        while child.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)  # let a post-shutdown plugin exit cleanly
        try:
            child.stdin.close()
        except OSError:
            pass
        child.kill()
        err = child.stderr.read()
        if err:
            print(f"  stderr: {err[:400]}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip", action="append", default=[], metavar="NAME")
    parser.add_argument("--only", action="append", default=[], metavar="NAME")
    parser.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    argv = args.argv[1:] if args.argv and args.argv[0] == "--" else args.argv
    if not argv:
        parser.error("plugin argv required after --")

    try:
        manifest = json.loads(pathlib.Path("manifest.json").read_text())
    except (OSError, ValueError) as error:
        print(f"cannot read ./manifest.json: {error}", file=sys.stderr)
        sys.exit(2)
    features = {"always"}
    if manifest.get("sources"):
        features.add("sources")
    if "queries" in manifest:
        features.add("queries")

    variables = {"plugin_id": manifest.get("id", "spec-test")}
    os.environ.setdefault("FLASH_PLUGIN_ID", variables["plugin_id"])

    specs = []
    for path in sorted(SPECS_DIR.glob("*.json")):
        spec = json.loads(path.read_text())
        if spec.get("when", "always") not in features:
            continue
        if args.only and spec["name"] not in args.only:
            continue
        if spec["name"] in args.skip:
            continue
        specs.append(spec)
    if not specs:
        print("no applicable specs selected", file=sys.stderr)
        sys.exit(2)

    failures = []
    for spec in specs:
        print(f"spec: {spec['name']}")
        try:
            run_spec(spec, argv, variables)
            print("  ok")
        except SpecFailure as failure:
            print(f"  FAIL {failure}", file=sys.stderr)
            failures.append(str(failure))
    print("PASS" if not failures else f"FAIL: {len(failures)} spec step(s)")
    sys.exit(0 if not failures else 1)


if __name__ == "__main__":
    main()
