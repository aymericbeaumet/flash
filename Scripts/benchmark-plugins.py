#!/usr/bin/env python3
"""Report cold-start, ping, RSS, and thread counts for official plugins."""

from __future__ import annotations

import argparse
import json
import os
import queue
import statistics
import subprocess
import tempfile
import threading
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PLUGINS = ROOT / "Plugins"
ENV_ALLOWLIST = (
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LOGNAME",
    "PATH",
    "SHELL",
    "TERM",
    "TMPDIR",
    "USER",
    "__CF_USER_TEXT_ENCODING",
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin", action="append", default=[], help="plugin id (repeatable)")
    parser.add_argument("--samples", type=int, default=3, help="cold launches per plugin")
    parser.add_argument("--timeout", type=float, default=5.0, help="reply deadline in seconds")
    parser.add_argument("--settle-ms", type=int, default=25, help="delay before memory sampling")
    parser.add_argument("--build", action="store_true", help="build selected plugins first")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args()
    if args.samples < 1:
        parser.error("--samples must be positive")
    return args


def executable_plugins(selected: list[str]) -> list[tuple[str, Path]]:
    wanted = set(selected)
    found: list[tuple[str, Path]] = []
    for manifest_path in sorted(PLUGINS.glob("*/manifest.json")):
        manifest = json.loads(manifest_path.read_text())
        plugin_id = manifest["id"]
        if wanted and plugin_id not in wanted:
            continue
        if "exec" not in manifest:
            continue
        binary = manifest_path.parent / f"flash-plugin-{plugin_id}"
        found.append((plugin_id, binary))
    missing_ids = wanted - {plugin_id for plugin_id, _ in found}
    if missing_ids:
        raise SystemExit(f"unknown executable plugin(s): {', '.join(sorted(missing_ids))}")
    return found


def plugin_environment(plugin_id: str, data_dir: Path) -> dict[str, str]:
    env = {key: os.environ[key] for key in ENV_ALLOWLIST if key in os.environ}
    env.update(
        {
            "FLASH_PLUGIN_ID": plugin_id,
            "FLASH_PLUGIN_VERSION": "benchmark",
            "FLASH_PLUGIN_DATA_DIR": str(data_dir),
            "FLASH_PLUGIN_CONFIG": "{}",
            "FLASH_PLUGIN_PARENT_PID": str(os.getpid()),
        }
    )
    return env


class Child:
    def __init__(self, plugin_id: str, binary: Path, data_dir: Path):
        self.frames: queue.Queue[dict] = queue.Queue()
        self.process = subprocess.Popen(
            [str(binary)],
            cwd=binary.parent,
            env=plugin_environment(plugin_id, data_dir),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            try:
                frame = json.loads(line)
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if isinstance(frame, dict):
                self.frames.put(frame)

    def request(self, request_id: int, method: str, params: dict, timeout: float) -> float:
        assert self.process.stdin is not None
        started = time.perf_counter_ns()
        wire = json.dumps(
            {"id": request_id, "method": method, "params": params},
            separators=(",", ":"),
        ).encode() + b"\n"
        self.process.stdin.write(wire)
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"{method} timed out")
            frame = self.frames.get(timeout=remaining)
            if frame.get("id") == request_id and "method" not in frame:
                result = frame.get("result")
                if not isinstance(result, dict) or result.get("ok") is not True:
                    raise RuntimeError(f"{method} failed: {result!r}")
                return (time.perf_counter_ns() - started) / 1_000_000

    def close(self) -> None:
        if self.process.stdin is not None:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=1.5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()


def process_footprint(pid: int) -> tuple[int, int | None]:
    completed = subprocess.run(
        ["/bin/ps", "-o", "rss=", "-o", "thcount=", "-p", str(pid)],
        check=False,
        capture_output=True,
        text=True,
    )
    fields = completed.stdout.split()
    if completed.returncode == 0 and fields:
        return int(fields[0]), int(fields[1]) if len(fields) > 1 else None
    completed = subprocess.run(
        ["/bin/ps", "-o", "rss=", "-p", str(pid)],
        check=True,
        capture_output=True,
        text=True,
    )
    threads = subprocess.run(
        ["/bin/ps", "-M", "-p", str(pid), "-o", "pid="],
        check=False,
        capture_output=True,
        text=True,
    )
    thread_count = len(threads.stdout.splitlines()) if threads.returncode == 0 else None
    return int(completed.stdout.strip()), thread_count


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * fraction)))
    return ordered[index]


def summarize(samples: list[dict]) -> dict:
    startup = [sample["startup_ms"] for sample in samples]
    ping = [sample["ping_ms"] for sample in samples]
    rss = [sample["rss_kib"] for sample in samples]
    threads = [sample["threads"] for sample in samples if sample["threads"] is not None]
    return {
        "samples": len(samples),
        "startup_ms": {"p50": statistics.median(startup), "p95": percentile(startup, 0.95)},
        "ping_ms": {"p50": statistics.median(ping), "p95": percentile(ping, 0.95)},
        "rss_kib": {"p50": statistics.median(rss), "max": max(rss)},
        "threads_p50": statistics.median(threads) if threads else None,
    }


def measure(plugin_id: str, binary: Path, args: argparse.Namespace) -> dict:
    if not os.access(binary, os.X_OK):
        raise SystemExit(f"missing executable {binary}; rerun with --build")
    samples = []
    with tempfile.TemporaryDirectory(prefix=f"flash-bench-{plugin_id}-") as temporary:
        for sample_number in range(args.samples):
            data_dir = Path(temporary) / str(sample_number)
            data_dir.mkdir()
            child = Child(plugin_id, binary, data_dir)
            try:
                startup_ms = child.request(
                    1, "initialize", {"protocol_version": 1}, args.timeout
                )
                # `initialize` deliberately replies before `on_start`; let
                # warm-catalog work settle so this measures an idle ping.
                time.sleep(args.settle_ms / 1000)
                ping_ms = child.request(2, "ping", {}, args.timeout)
                rss_kib, threads = process_footprint(child.process.pid)
                samples.append(
                    {
                        "startup_ms": startup_ms,
                        "ping_ms": ping_ms,
                        "rss_kib": rss_kib,
                        "threads": threads,
                    }
                )
            finally:
                child.close()
    return {"id": plugin_id, "summary": summarize(samples), "raw": samples}


def print_table(results: list[dict]) -> None:
    print("plugin\tstart p50/p95 ms\tping p50/p95 ms\tRSS p50 KiB\tthreads")
    for result in results:
        summary = result["summary"]
        threads = summary["threads_p50"]
        print(
            f"{result['id']}\t"
            f"{summary['startup_ms']['p50']:.2f}/{summary['startup_ms']['p95']:.2f}\t"
            f"{summary['ping_ms']['p50']:.2f}/{summary['ping_ms']['p95']:.2f}\t"
            f"{summary['rss_kib']['p50']:.0f}\t"
            f"{threads if threads is not None else '-'}"
        )
    total_rss = sum(result["summary"]["rss_kib"]["p50"] for result in results)
    print(f"total\t-\t-\t{total_rss:.0f}\t-")


def main() -> None:
    args = arguments()
    plugins = executable_plugins(args.plugin)
    if args.build:
        subprocess.run(
            [str(ROOT / "Scripts/build-plugins.sh"), "dev", *[item[0] for item in plugins]],
            cwd=ROOT,
            check=True,
        )
    results = [measure(plugin_id, binary, args) for plugin_id, binary in plugins]
    report = {
        "schema_version": 1,
        "generated_at_unix": int(time.time()),
        "results": results,
    }
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_table(results)


if __name__ == "__main__":
    main()
