#!/usr/bin/env python3
"""Time the flash CLI's round trip to the running resident.

Runs `flash --help` (process start-up alone: it never contacts the resident)
and `flash resident status` (start-up, the socket handshake, the request and
its reply), each --runs times, and prints nearest-rank percentiles in
milliseconds. The difference between the two medians is what the resident
and its socket add. It never starts a resident: with none running it says
so and exits 1, so a cold start is never mistaken for a round trip.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--cli", default=str(Path.home() / ".local/bin/flash"), help="the flash executable"
    )
    parser.add_argument("--runs", type=int, default=50, help="runs per command")
    return parser.parse_args()


def resident_running() -> bool:
    result = subprocess.run(
        ["/usr/bin/pgrep", "-f", r"Flash( 🧪)?\.app/Contents/MacOS/flash$"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def percentile(samples: list[float], fraction: float) -> float:
    ordered = sorted(samples)
    rank = max(1, int(round(fraction * len(ordered) + 0.5)))
    return ordered[min(rank, len(ordered)) - 1]


def measure(argv: list[str], runs: int) -> tuple[list[float], int]:
    samples = []
    status = 0
    for _ in range(runs):
        start = time.perf_counter()
        status = subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        samples.append((time.perf_counter() - start) * 1000)
    return samples, status


def main() -> int:
    options = arguments()
    if not os.access(options.cli, os.X_OK):
        print(f"{options.cli} is not executable", file=sys.stderr)
        return 1
    if not resident_running():
        print("no Flash resident is running: start it first", file=sys.stderr)
        return 1
    rows = []
    for label, words in (("start-up", ["--help"]), ("round trip", ["resident", "status"])):
        samples, status = measure([options.cli, *words], options.runs)
        if status != 0:
            print(f"flash {' '.join(words)} exited {status}", file=sys.stderr)
            return 1
        rows.append((label, " ".join(words), samples))
    print(f"{'':12} {'command':18} {'p50':>7} {'p90':>7} {'min':>7} {'max':>7}  (ms, {options.runs} runs)")
    for label, command, samples in rows:
        print(
            f"{label:12} {command:18} {percentile(samples, 0.5):7.1f} {percentile(samples, 0.9):7.1f}"
            f" {min(samples):7.1f} {max(samples):7.1f}"
        )
    added = percentile(rows[1][2], 0.5) - percentile(rows[0][2], 0.5)
    print(f"the round trip adds {added:.1f} ms at the median")
    return 0


if __name__ == "__main__":
    sys.exit(main())
