#!/usr/bin/env python3
"""Unit tests for Scripts/hints-latency-summary.py."""

import importlib.util
import json
import math
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "hints_latency_summary", Path(__file__).with_name("hints-latency-summary.py"))
summary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(summary)


def line(trace, time_ms, ms, origin="key", prepared="hit", app_class="native",
         surface="targets", targets=12):
    message = (
        f"[latency] hints_visible ms={ms} origin={origin} prepared={prepared} "
        f"targets={targets} class={app_class} surface={surface}")
    return json.dumps({
        "level": "info", "message": message, "source": "core:x", "pid": 1,
        "time_unix_ms": time_ms, "trace": trace,
    })


class ParseTests(unittest.TestCase):
    def test_parses_the_line_flash_logs(self):
        sample = summary.parse_record(line("abc", 1000, 12.3))
        self.assertEqual(sample.trace, "abc")
        self.assertEqual(sample.ms, 12.3)
        self.assertEqual(sample.origin, "key")
        self.assertEqual(sample.prepared, "hit")
        self.assertEqual(sample.targets, 12)
        self.assertEqual(sample.app_class, "native")
        self.assertEqual(sample.surface, "targets")

    def test_ignores_other_and_malformed_lines(self):
        self.assertIsNone(summary.parse_record('{"message": "[discover] pipeline"}'))
        self.assertIsNone(summary.parse_record("not json [latency] hints_visible ms=1"))
        self.assertIsNone(summary.parse_record(json.dumps({
            "message": "[latency] hints_visible ms=x origin=key prepared=hit targets=1 class=native",
            "trace": "t", "time_unix_ms": 1})))
        self.assertIsNone(summary.parse_record(json.dumps({
            "message": "[latency] hints_visible ms=1 origin=key", "trace": "t",
            "time_unix_ms": 1})))

    def test_one_sample_per_trace(self):
        samples = summary.read_samples([
            line("a", 2000, 30), line("a", 1000, 10), line("b", 1500, 20), "noise"])
        self.assertEqual([(s.trace, s.ms) for s in samples], [("a", 10.0), ("b", 20.0)])


class StatisticsTests(unittest.TestCase):
    def test_nearest_rank(self):
        values = [float(v) for v in range(1, 101)]
        self.assertEqual(summary.nearest_rank(values, 50), 50)
        self.assertEqual(summary.nearest_rank(values, 95), 95)
        self.assertEqual(summary.nearest_rank([7.0], 95), 7.0)
        self.assertEqual(summary.nearest_rank([3.0, 1.0, 2.0], 50), 2.0)

    def test_windows_split_classes_and_filter_origin_and_surface(self):
        samples = summary.read_samples([
            line("n1", 100, 10), line("n2", 200, 30, prepared="miss"),
            line("g1", 250, 99, surface="grid"),
            line("c1", 260, 50, origin="cli"),
            line("b1", 1100, 40, app_class="browser"),
            line("b2", 1200, 60, app_class="native"),
        ])
        rows = summary.summarize(
            samples,
            [summary.parse_window("native:0:500"), summary.parse_window("browser:1000:1500")],
            origin="key")
        native, browser = rows
        self.assertEqual((native.count, native.p50, native.maximum), (2, 10.0, 30.0))
        self.assertEqual(native.prepared_hits, 1)
        self.assertEqual((browser.count, browser.other_classes), (2, 1))
        table = summary.format_table(rows)
        self.assertIn("native", table)
        self.assertIn("note: 1 browser run(s) logged another app class", table)

    def test_an_empty_window_reports_dashes(self):
        rows = summary.summarize([], [summary.parse_window("electron:0:1")], origin=None)
        self.assertEqual(rows[0].count, 0)
        self.assertTrue(math.isnan(rows[0].p50))
        self.assertIn("electron       0        -", summary.format_table(rows))

    def test_rejects_malformed_windows(self):
        for raw in ["native", "native:5:1", ":1:2", "native:a:b"]:
            with self.assertRaises(ValueError, msg=raw):
                summary.parse_window(raw)


if __name__ == "__main__":
    unittest.main()
