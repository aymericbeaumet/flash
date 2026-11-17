#!/usr/bin/env python3
"""Summarize a Flash log: the distributions a performance audit reads by hand.

Reads `~/Library/Logs/Flash/flash.log*` (or the paths given) and prints, over
the whole span or only the last `--hours`:

- `[latency]` lines by kind: count, p50, p95 and max milliseconds;
- `[latency] hints_visible` target activations by app: prepared-model hits
  and misses, their latencies, and the misses by `miss_reason`;
- `[latency] hints_empty` activations by app and path;
- `[plugin] slow catalog publish` by plugin: count, elapsed, bytes and rows;
- `[apple] refresh` by catalog: count, elapsed, and how many were slow;
- `[plugin] initialized` by plugin: startup time;
- `[mode] active_border_frame` by reason: window-list reads on main;
- `[poll] overrun` by registration;
- `[watchdog] main_busy` stalls and `main_hitch` hitches;
- `[window] placed` by app: move time and Accessibility writes per move;
- warnings and errors by kind, per hour.

Percentiles are nearest-rank. Standard library only; runs under `python3 -I`.
The first step of any performance work is this report on the logs of a day of
ordinary use, before and after the change (docs/performance.md).

Usage:
  log-summary.py [--hours N] [LOG ...]
"""

import argparse
import glob
import json
import math
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime
from typing import Dict, Iterable, List, Optional, Sequence

FIELD = re.compile(r"([a-z_]+)=(\S+)")
DEFAULT_LOGS = os.path.expanduser("~/Library/Logs/Flash/flash.log*")
TARGET_SURFACES = ("", "targets")


@dataclass
class Record:
    time_ms: int
    level: str
    message: str
    # The structured `fields` object, with the message's own `key=value`
    # pairs filled in where the object has no such key.
    fields: Dict[str, str]
    source: str
    pid: int

    @property
    def kind(self) -> str:
        return message_kind(self.message)

    @property
    def plugin(self) -> str:
        """The plugin a line was logged for (`source=plugin:<id>`), else `-`."""
        return self.source[len("plugin:"):] if self.source.startswith("plugin:") else "-"

    def number(self, *keys: str) -> Optional[float]:
        for key in keys:
            value = self.fields.get(key)
            if value is None:
                continue
            try:
                return float(value)
            except ValueError:
                return None
        return None


def message_kind(message: str) -> str:
    """A message up to its first `key=value`: `[watchdog] main_busy ms=253`
    and `[watchdog] main_busy ms=595` are one kind."""
    words: List[str] = []
    for token in message.split():
        if "=" in token:
            break
        words.append(token)
    return " ".join(words)


def parse_record(line: str) -> Optional[Record]:
    """One JSON log line, or None for anything else."""
    if not line.startswith("{"):
        return None
    try:
        raw = json.loads(line)
    except ValueError:
        return None
    if not isinstance(raw, dict):
        return None
    message = raw.get("message")
    time_ms = raw.get("time_unix_ms")
    if not isinstance(message, str) or not isinstance(time_ms, int):
        return None
    structured = raw.get("fields")
    fields: Dict[str, str] = {}
    if isinstance(structured, dict):
        fields = {str(key): str(value) for key, value in structured.items()}
    for key, value in FIELD.findall(message):
        fields.setdefault(key, value)
    pid = raw.get("pid")
    return Record(
        time_ms=time_ms,
        level=str(raw.get("level", "")),
        message=message,
        fields=fields,
        source=str(raw.get("source", "")),
        pid=pid if isinstance(pid, int) else 0,
    )


def read_records(lines: Iterable[str]) -> List[Record]:
    records = [record for record in map(parse_record, lines) if record is not None]
    records.sort(key=lambda record: record.time_ms)
    return records


def nearest_rank(values: Sequence[float], percentile: float) -> float:
    """The nearest-rank percentile of a non-empty sequence."""
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile / 100 * len(ordered)))
    return ordered[min(rank, len(ordered)) - 1]


@dataclass
class Stats:
    values: List[float] = field(default_factory=list)

    @property
    def count(self) -> int:
        return len(self.values)

    @property
    def p50(self) -> float:
        return nearest_rank(self.values, 50) if self.values else math.nan

    @property
    def p95(self) -> float:
        return nearest_rank(self.values, 95) if self.values else math.nan

    @property
    def maximum(self) -> float:
        return max(self.values) if self.values else math.nan

    @property
    def total(self) -> float:
        return sum(self.values)


@dataclass
class Activations:
    """One app's `hints_visible` target activations."""

    hits: Stats = field(default_factory=Stats)
    misses: Stats = field(default_factory=Stats)
    empty: int = 0
    miss_reasons: Dict[str, int] = field(default_factory=dict)

    @property
    def shown(self) -> int:
        return self.hits.count + self.misses.count

    @property
    def hit_rate(self) -> float:
        return self.hits.count / self.shown if self.shown else math.nan


@dataclass
class WindowMoves:
    """One app's `[window] placed` lines."""

    total: Stats = field(default_factory=Stats)
    writes: Stats = field(default_factory=Stats)
    corrections: int = 0


@dataclass
class Summary:
    files: int
    lines: int
    records: int
    start_ms: int
    end_ms: int
    launches: int
    latency: Dict[str, Stats]
    activations: Dict[str, Activations]
    empties: Dict[str, Dict[str, Stats]]
    publishes: Dict[str, Dict[str, Stats]]
    apple: Dict[str, Stats]
    apple_slow: Dict[str, int]
    startups: Dict[str, Stats]
    border: Dict[str, Stats]
    overruns: Dict[str, int]
    stalls: Stats
    hitches: Stats
    window_moves: Dict[str, WindowMoves]
    warnings: Dict[str, int]

    @property
    def hours(self) -> float:
        return max(self.end_ms - self.start_ms, 0) / 3_600_000


def summarize(records: List[Record], files: int = 0, lines: int = 0) -> Summary:
    latency: Dict[str, Stats] = {}
    activations: Dict[str, Activations] = {}
    empties: Dict[str, Dict[str, Stats]] = {}
    publishes: Dict[str, Dict[str, Stats]] = {}
    apple: Dict[str, Stats] = {}
    apple_slow: Dict[str, int] = {}
    startups: Dict[str, Stats] = {}
    border: Dict[str, Stats] = {}
    overruns: Dict[str, int] = {}
    stalls = Stats()
    hitches = Stats()
    window_moves: Dict[str, WindowMoves] = {}
    warnings: Dict[str, int] = {}
    launches = set()

    for record in records:
        if record.source.startswith("core:"):
            launches.add(record.pid)
        message = record.message
        if record.level in ("warn", "error"):
            key = f"{record.level} {record.kind}"
            warnings[key] = warnings.get(key, 0) + 1

        if message.startswith("[latency] "):
            kind = message.split(" ", 2)[1]
            ms = record.number("ms", *[key for key in record.fields if key.endswith("_ms")])
            if ms is not None:
                latency.setdefault(kind, Stats()).values.append(ms)
            if kind == "hints_visible":
                note_activation(activations, record, ms)
            elif kind == "hints_empty" and ms is not None:
                bundle = record.fields.get("bundle", "-")
                by_path = empties.setdefault(bundle, {})
                by_path.setdefault(record.fields.get("path", "-"), Stats()).values.append(ms)
                if record.fields.get("surface", "targets") in TARGET_SURFACES:
                    activations.setdefault(bundle, Activations()).empty += 1
        elif message == "[plugin] slow catalog publish":
            measures = publishes.setdefault(record.plugin, {})
            for key in ("elapsed_ms", "encoded_bytes", "rows"):
                value = record.number(key)
                if value is not None:
                    measures.setdefault(key, Stats()).values.append(value)
        elif message == "[apple] refresh":
            catalog = record.fields.get("catalog", "-")
            elapsed = record.number("elapsed_ms")
            if elapsed is not None:
                apple.setdefault(catalog, Stats()).values.append(elapsed)
        elif message == "[apple] refresh slow":
            catalog = record.fields.get("catalog", "-")
            apple_slow[catalog] = apple_slow.get(catalog, 0) + 1
        elif message.startswith("[plugin] initialized"):
            ms = record.number("startup_total_ms", "elapsed_ms")
            if ms is not None:
                startups.setdefault(record.plugin, Stats()).values.append(ms)
        elif message.startswith("[mode] active_border_frame "):
            ms = record.number("read_ms")
            if ms is not None:
                border.setdefault(record.fields.get("reason", "-"), Stats()).values.append(ms)
        elif message.startswith("[poll] overrun"):
            skipped = record.fields.get("skipped", "-")
            overruns[skipped] = overruns.get(skipped, 0) + 1
        elif message.startswith("[watchdog] main_busy"):
            ms = record.number("ms")
            if ms is not None:
                stalls.values.append(ms)
        elif message.startswith("[watchdog] main_hitch"):
            ms = record.number("ms")
            if ms is not None:
                hitches.values.append(ms)
        elif message.startswith("[window] placed "):
            moves = window_moves.setdefault(record.fields.get("bundle", "-"), WindowMoves())
            total = record.number("total_ms")
            if total is not None:
                moves.total.values.append(total)
            writes = record.fields.get("writes", "none")
            moves.writes.values.append(0 if writes == "none" else len(writes.split(",")))
            moves.corrections += int(record.number("corrections") or 0)

    return Summary(
        files=files,
        lines=lines,
        records=len(records),
        start_ms=records[0].time_ms if records else 0,
        end_ms=records[-1].time_ms if records else 0,
        launches=len(launches),
        latency=latency,
        activations=activations,
        empties=empties,
        publishes=publishes,
        apple=apple,
        apple_slow=apple_slow,
        startups=startups,
        border=border,
        overruns=overruns,
        stalls=stalls,
        hitches=hitches,
        window_moves=window_moves,
        warnings=warnings,
    )


def note_activation(activations: Dict[str, Activations], record: Record, ms: Optional[float]):
    """A `hints_visible` line: only the app's own target hints count, as
    `bench:hints-summary` counts them. An app that yielded nothing while the
    status bar still drew is `outcome=empty`."""
    if record.fields.get("surface", "") not in TARGET_SURFACES or ms is None:
        return
    bundle = record.fields.get("bundle", "-")
    app = activations.setdefault(bundle, Activations())
    outcome = record.fields.get("outcome", "")
    prepared = record.fields.get("prepared", "")
    if outcome == "empty":
        app.empty += 1
    elif prepared == "hit":
        app.hits.values.append(ms)
    else:
        app.misses.values.append(ms)
        reason = record.fields.get("miss_reason", "") or "?"
        app.miss_reasons[reason] = app.miss_reasons.get(reason, 0) + 1


# Rendering.


def ms(value: float) -> str:
    return "-" if math.isnan(value) else f"{value:,.1f}"


def pct(value: float) -> str:
    return "-" if math.isnan(value) else f"{value * 100:.0f}%"


def counts(by_key: Dict[str, int]) -> str:
    """`expired=20 absent=3`, largest first; the unknown bucket `?` last."""
    ordered = sorted(by_key.items(), key=lambda item: (-item[1], item[0] == "?", item[0]))
    return " ".join(f"{key}={count}" for key, count in ordered)


def table(title: str, columns: List[str], rows: List[List[str]], left: Sequence[int] = (0,)) -> str:
    """A fixed-width table; the first column (and `left` ones) left-aligned,
    the rest right-aligned. An empty table says so."""
    if not rows:
        return f"{title}\n  (none)"
    widths = [
        max(len(column), *(len(row[index]) for row in rows))
        for index, column in enumerate(columns)
    ]

    def line(cells: List[str]) -> str:
        return "  " + "  ".join(
            cell.ljust(width) if index in left else cell.rjust(width)
            for index, (cell, width) in enumerate(zip(cells, widths))
        ).rstrip()

    return "\n".join([title, line(columns)] + [line(row) for row in rows])


def stats_cells(stats: Stats) -> List[str]:
    return [str(stats.count), ms(stats.p50), ms(stats.p95), ms(stats.maximum)]


def local_time(time_ms: int) -> str:
    return datetime.fromtimestamp(time_ms / 1000).strftime("%Y-%m-%d %H:%M")


def render(summary: Summary) -> str:
    sections = [
        f"Flash log summary: {summary.files} file(s), {summary.lines:,} lines, "
        f"{summary.records:,} records, {summary.hours:.1f} h "
        f"({local_time(summary.start_ms)} to {local_time(summary.end_ms)}), "
        f"{summary.launches} launch(es)"
    ]

    sections.append(
        table(
            "[latency] by kind (ms)",
            ["kind", "n", "p50", "p95", "max"],
            [[kind] + stats_cells(stats) for kind, stats in sorted(summary.latency.items())],
        )
    )

    rows = []
    total = Activations()
    for bundle, app in sorted(
        summary.activations.items(), key=lambda item: (-(item[1].shown + item[1].empty), item[0])
    ):
        rows.append(activation_cells(bundle, app))
        total.hits.values += app.hits.values
        total.misses.values += app.misses.values
        total.empty += app.empty
        for reason, count in app.miss_reasons.items():
            total.miss_reasons[reason] = total.miss_reasons.get(reason, 0) + count
    if len(rows) > 1:
        rows.append(activation_cells("total", total))
    sections.append(
        table(
            "[latency] hints_visible target activations by app (prepared-model hit rate; ms)",
            [
                "app", "n", "hit", "miss", "empty", "hit%", "hit p50", "miss p50", "miss p95",
                "miss max", "misses by reason",
            ],
            rows,
            left=(0, 10),
        )
    )

    rows = []
    for bundle, by_path in sorted(
        summary.empties.items(),
        key=lambda item: (-sum(stats.count for stats in item[1].values()), item[0]),
    ):
        merged = Stats([value for stats in by_path.values() for value in stats.values])
        paths = counts({path: stats.count for path, stats in by_path.items()})
        rows.append([bundle] + stats_cells(merged) + [paths])
    sections.append(
        table(
            "[latency] hints_empty by app (ms to give up)",
            ["app", "n", "p50", "p95", "max", "paths"],
            rows,
            left=(0, 5),
        )
    )

    rows = []
    for plugin, measures in sorted(
        summary.publishes.items(),
        key=lambda item: (-item[1].get("elapsed_ms", Stats()).count, item[0]),
    ):
        elapsed = measures.get("elapsed_ms", Stats())
        kib = Stats([value / 1024 for value in measures.get("encoded_bytes", Stats()).values])
        rows.append(
            [plugin]
            + stats_cells(elapsed)
            + [ms(elapsed.total), ms(kib.p50), ms(measures.get("rows", Stats()).p50)]
        )
    sections.append(
        table(
            "[plugin] slow catalog publish by plugin (decode ms)",
            ["plugin", "n", "p50", "p95", "max", "total", "KiB p50", "rows p50"],
            rows,
        )
    )

    rows = []
    for catalog in sorted(set(summary.apple) | set(summary.apple_slow)):
        stats = summary.apple.get(catalog, Stats())
        rows.append(
            [catalog] + stats_cells(stats)
            + [ms(stats.total), str(summary.apple_slow.get(catalog, 0))]
        )
    sections.append(
        table(
            "[apple] refresh by catalog (ms)",
            ["catalog", "n", "p50", "p95", "max", "total", "slow"],
            rows,
        )
    )

    rows = [
        [plugin] + stats_cells(stats)
        for plugin, stats in sorted(summary.startups.items(), key=lambda item: -item[1].p50)
    ]
    if len(rows) > 1:
        rows.append(
            ["all"] + stats_cells(Stats([v for s in summary.startups.values() for v in s.values]))
        )
    sections.append(
        table(
            "[plugin] initialized by plugin (startup_total_ms)",
            ["plugin", "n", "p50", "p95", "max"],
            rows,
        )
    )

    rows = [
        [reason] + stats_cells(stats) + [ms(stats.total)]
        for reason, stats in sorted(summary.border.items(), key=lambda item: -item[1].count)
    ]
    if len(rows) > 1:
        every = Stats([value for stats in summary.border.values() for value in stats.values])
        rows.append(["total"] + stats_cells(every) + [ms(every.total)])
    sections.append(
        table(
            "[mode] active_border_frame window-list reads on main by reason (read_ms)",
            ["reason", "n", "p50", "p95", "max", "total"],
            rows,
        )
    )

    sections.append(
        table(
            "[poll] overrun by registration",
            ["registration", "n"],
            [[key, str(count)] for key, count in sorted(summary.overruns.items(), key=lambda i: -i[1])],
        )
    )

    sections.append(
        table(
            "[watchdog] main thread stalls and hitches (ms)",
            ["kind", "n", "p50", "p95", "max"],
            [
                [kind] + stats_cells(stats)
                for kind, stats in [("main_busy", summary.stalls), ("main_hitch", summary.hitches)]
                if stats.count
            ],
        )
    )

    rows = [
        [bundle]
        + stats_cells(moves.total)
        + [ms(moves.writes.p50), ms(moves.writes.maximum), str(moves.corrections)]
        for bundle, moves in sorted(
            summary.window_moves.items(), key=lambda item: (-item[1].total.count, item[0])
        )
    ]
    sections.append(
        table(
            "[window] placed by app (total_ms; AX writes per move)",
            ["bundle", "n", "p50", "p95", "max", "writes p50", "writes max", "corrections"],
            rows,
        )
    )

    hours = summary.hours or math.nan
    rows = [
        [key, str(count), ms(count / hours) if hours else "-"]
        for key, count in sorted(summary.warnings.items(), key=lambda item: (-item[1], item[0]))
    ]
    sections.append(table("warnings and errors by kind", ["kind", "n", "per hour"], rows))
    return "\n\n".join(sections) + "\n"


def activation_cells(label: str, app: Activations) -> List[str]:
    return [
        label,
        str(app.shown + app.empty),
        str(app.hits.count),
        str(app.misses.count),
        str(app.empty),
        pct(app.hit_rate),
        ms(app.hits.p50),
        ms(app.misses.p50),
        ms(app.misses.p95),
        ms(app.misses.maximum),
        counts(app.miss_reasons),
    ]


def read_logs(paths: List[str]) -> List[str]:
    lines: List[str] = []
    for log in paths:
        try:
            with open(log, encoding="utf-8", errors="replace") as handle:
                lines.extend(handle)
        except OSError as error:
            print(f"warning: {error}", file=sys.stderr)
    return lines


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        epilog="Without LOG arguments the resident's own logs are read: " + DEFAULT_LOGS,
    )
    parser.add_argument(
        "--hours", type=float, help="only the last N hours of the logs, counted from their end"
    )
    parser.add_argument("logs", nargs="*")
    args = parser.parse_args(argv)
    paths = args.logs or sorted(glob.glob(DEFAULT_LOGS))
    if not paths:
        print(f"no log found at {DEFAULT_LOGS}", file=sys.stderr)
        return 1
    lines = read_logs(paths)
    records = read_records(lines)
    if args.hours is not None and records:
        cutoff = records[-1].time_ms - int(args.hours * 3_600_000)
        records = [record for record in records if record.time_ms >= cutoff]
    if not records:
        print("no log records", file=sys.stderr)
        return 1
    print(render(summarize(records, files=len(paths), lines=len(lines))), end="")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
