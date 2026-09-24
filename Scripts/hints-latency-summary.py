#!/usr/bin/env python3
"""Summarize Flash's `[latency] hints_visible` log lines per benchmark class.

Scripts/benchmark-hints.sh runs each class's oracle in bench mode and passes
the time window it measured in. Every activation in a window is counted once
(by trace id); the table reports p50, p95 and max milliseconds from the
trigger (tap event, Carbon hotkey event or AppleEvent arrival) to the Core
Animation commit that shows the hints.

Usage:
  hints-latency-summary.py [--origin=key|hotkey|cli]
      --window=<class>:<start_unix_ms>:<end_unix_ms> [--window=...] LOG [LOG...]
"""

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Tuple

PREFIX = "[latency] hints_visible "
FIELD = re.compile(r"([a-z_]+)=(\S+)")


@dataclass(frozen=True)
class Sample:
    trace: str
    time_ms: int
    ms: float
    origin: str
    prepared: str
    targets: int
    app_class: str
    surface: str


@dataclass(frozen=True)
class Window:
    label: str
    start_ms: int
    end_ms: int


@dataclass(frozen=True)
class Row:
    label: str
    count: int
    p50: float
    p95: float
    maximum: float
    prepared_hits: int
    other_classes: int


def parse_record(line: str) -> Optional[Sample]:
    """One JSON log line, or None when it is not a hints_visible line."""
    if PREFIX not in line:
        return None
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        return None
    message = record.get("message", "")
    trace = record.get("trace")
    time_ms = record.get("time_unix_ms")
    if not message.startswith(PREFIX) or not trace or not isinstance(time_ms, int):
        return None
    fields = dict(FIELD.findall(message[len(PREFIX):]))
    try:
        return Sample(
            trace=trace,
            time_ms=time_ms,
            ms=float(fields["ms"]),
            origin=fields["origin"],
            prepared=fields["prepared"],
            targets=int(fields["targets"]),
            app_class=fields["class"],
            surface=fields.get("surface", ""),
        )
    except (KeyError, ValueError):
        return None


def read_samples(lines: Iterable[str]) -> List[Sample]:
    """Every sample, one per trace (the earliest), in time order."""
    by_trace: Dict[str, Sample] = {}
    for line in lines:
        sample = parse_record(line)
        if sample is None:
            continue
        kept = by_trace.get(sample.trace)
        if kept is None or sample.time_ms < kept.time_ms:
            by_trace[sample.trace] = sample
    return sorted(by_trace.values(), key=lambda sample: sample.time_ms)


def nearest_rank(values: List[float], percentile: float) -> float:
    """The nearest-rank percentile of a non-empty list."""
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile / 100 * len(ordered)))
    return ordered[min(rank, len(ordered)) - 1]


def parse_window(raw: str) -> Window:
    label, start, end = raw.rsplit(":", 2)
    window = Window(label=label, start_ms=int(start), end_ms=int(end))
    if not label or window.end_ms < window.start_ms:
        raise ValueError(raw)
    return window


def summarize(samples: List[Sample], windows: List[Window], origin: Optional[str]) -> List[Row]:
    rows = []
    for window in windows:
        chosen = [
            sample
            for sample in samples
            if window.start_ms <= sample.time_ms <= window.end_ms
            and sample.surface in ("", "targets")
            and (origin is None or sample.origin == origin)
        ]
        values = [sample.ms for sample in chosen]
        rows.append(
            Row(
                label=window.label,
                count=len(chosen),
                p50=nearest_rank(values, 50) if values else math.nan,
                p95=nearest_rank(values, 95) if values else math.nan,
                maximum=max(values) if values else math.nan,
                prepared_hits=sum(sample.prepared == "hit" for sample in chosen),
                other_classes=sum(sample.app_class != window.label for sample in chosen),
            )
        )
    return rows


def format_table(rows: List[Row]) -> str:
    def ms(value: float) -> str:
        return "-" if math.isnan(value) else f"{value:.1f}"

    lines = [
        f"{'class':<10} {'runs':>5} {'p50 ms':>8} {'p95 ms':>8} {'max ms':>8} {'prepared':>9}",
    ]
    for row in rows:
        lines.append(
            f"{row.label:<10} {row.count:>5} {ms(row.p50):>8} {ms(row.p95):>8} "
            f"{ms(row.maximum):>8} {row.prepared_hits:>4}/{row.count:<4}"
        )
    for row in rows:
        if row.other_classes:
            lines.append(
                f"note: {row.other_classes} {row.label} run(s) logged another app class; "
                "was the fixture frontmost?"
            )
    return "\n".join(lines)


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--window", action="append", required=True, type=parse_window)
    parser.add_argument("--origin", choices=["key", "hotkey", "cli"])
    parser.add_argument("logs", nargs="+")
    args = parser.parse_args(argv)
    lines: List[str] = []
    for path in args.logs:
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                lines.extend(handle)
        except OSError as error:
            print(f"warning: {error}", file=sys.stderr)
    rows = summarize(read_samples(lines), args.window, args.origin)
    print(format_table(rows))
    return 0 if all(row.count for row in rows) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
