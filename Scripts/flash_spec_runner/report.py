"""Result rows, human output, JSON report, GitHub annotations, exit code."""
import json
import sys


class Row:
    def __init__(self, plugin, spec, status, reason="", duration_ms=0, diagnostics=None):
        self.plugin = plugin
        self.spec = spec
        self.status = status  # pass | fail | skip | xfail | xpass | manifest-only
        self.reason = reason
        self.duration_ms = duration_ms
        self.diagnostics = diagnostics or {}

    def as_dict(self):
        return {
            "plugin": self.plugin,
            "spec": self.spec,
            "status": self.status,
            "reason": self.reason,
            "duration_ms": self.duration_ms,
            **self.diagnostics,
        }


class Report:
    def __init__(self, annotations=False):
        self.rows = []
        self.annotations = annotations

    def add(self, row):
        self.rows.append(row)
        marker = {
            "pass": "ok", "fail": "FAIL", "skip": "skip", "xfail": "xfail",
            "xpass": "XPASS", "manifest-only": "manifest-only",
        }[row.status]
        line = f"  {marker} {row.spec}"
        if row.reason:
            line += f" — {row.reason}"
        print(line, file=sys.stderr if row.status in ("fail", "xpass") else sys.stdout)
        if row.status in ("fail", "xpass"):
            tail = row.diagnostics.get("stderr_tail")
            if tail:
                print(f"    stderr: {tail[-400:]}", file=sys.stderr)
            if self.annotations:
                message = f"{row.plugin} × {row.spec}: {row.status} {row.reason}"
                print(f"::error title=plugin conformance::{message}")

    def failures(self):
        return [row for row in self.rows if row.status in ("fail", "xpass")]

    def summary(self):
        counts = {}
        for row in self.rows:
            counts[row.status] = counts.get(row.status, 0) + 1
        parts = ", ".join(f"{count} {status}" for status, count in sorted(counts.items()))
        verdict = "PASS" if not self.failures() else "FAIL"
        return f"{verdict}: {parts}"

    def write_json(self, path):
        with open(path, "w", encoding="utf-8") as handle:
            json.dump([row.as_dict() for row in self.rows], handle, indent=1)
