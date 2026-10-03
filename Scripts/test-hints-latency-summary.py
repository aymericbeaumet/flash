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
         surface="targets", targets=12, bundle="com.example.app", outcome="hit"):
    message = (
        f"[latency] hints_visible ms={ms} origin={origin} prepared={prepared} "
        f"targets={targets} class={app_class} surface={surface} bundle={bundle} "
        f"outcome={outcome}")
    return json.dumps({
        "level": "info", "message": message, "source": "core:x", "pid": 1,
        "time_unix_ms": time_ms, "trace": trace,
    })


def empty_line(trace, time_ms, ms, origin="key", surface="targets",
               bundle="com.example.app", path="prepared_model_refresh"):
    message = (
        f"[latency] hints_empty ms={ms} bundle={bundle} path={path} origin={origin} "
        f"surface={surface}")
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
        self.assertEqual(sample.bundle, "com.example.app")
        self.assertEqual(sample.outcome, "hit")
        self.assertFalse(sample.empty)

    def test_parses_an_empty_activation(self):
        sample = summary.parse_record(empty_line("e", 1000, 1500.0, bundle="org.alacritty"))
        self.assertTrue(sample.empty)
        self.assertEqual(sample.ms, 1500.0)
        self.assertEqual(sample.bundle, "org.alacritty")
        self.assertEqual(sample.path, "prepared_model_refresh")
        self.assertEqual(sample.outcome, "empty")
        self.assertEqual(sample.surface, "targets")

    def test_a_line_without_the_newer_fields_still_parses(self):
        old = json.dumps({
            "message": "[latency] hints_visible ms=4 origin=key prepared=miss targets=3 "
                       "class=native surface=targets",
            "trace": "t", "time_unix_ms": 1})
        sample = summary.parse_record(old)
        self.assertEqual((sample.bundle, sample.outcome), ("-", ""))

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

    def test_empty_activations_are_counted_beside_the_percentiles(self):
        samples = summary.read_samples([
            line("n1", 100, 10), line("n2", 200, 30),
            empty_line("e1", 300, 1500.0), empty_line("e2", 350, 2.0, surface="screen"),
        ])
        (native,) = summary.summarize(samples, [summary.parse_window("native:0:500")], None)
        self.assertEqual((native.count, native.empty), (2, 1))
        self.assertEqual(native.maximum, 30.0, "an empty activation's time is not latency")
        self.assertIn("empty", summary.format_table([native]).splitlines()[0])

    def test_a_visible_line_whose_app_gave_no_targets_counts_as_empty(self):
        # Only status-bar segments were drawn: the resident counts the
        # activation as empty, and so does the report.
        samples = summary.read_samples([
            line("n1", 100, 10),
            line("s1", 200, 900.0, outcome="empty", targets=3),
        ])
        (native,) = summary.summarize(samples, [summary.parse_window("native:0:500")], None)
        self.assertEqual((native.count, native.empty), (1, 1))
        self.assertEqual(native.maximum, 10.0)

    def test_by_bundle_groups_every_target_activation_busiest_first(self):
        samples = summary.read_samples([
            line("f1", 100, 160, bundle="org.mozilla.firefox", prepared="miss"),
            line("f2", 200, 684, bundle="org.mozilla.firefox"),
            empty_line("f3", 250, 3.0, bundle="org.mozilla.firefox"),
            empty_line("a1", 300, 2.0, bundle="org.alacritty"),
            line("g1", 400, 5, bundle="org.mozilla.firefox", surface="grid"),
            line("c1", 500, 50, bundle="com.apple.Notes", origin="cli"),
        ])
        rows = summary.summarize_by_bundle(samples, origin="key")
        self.assertEqual([row.label for row in rows], ["org.mozilla.firefox", "org.alacritty"])
        firefox, alacritty = rows
        self.assertEqual((firefox.count, firefox.empty, firefox.prepared_hits), (2, 1, 1))
        self.assertEqual((firefox.p50, firefox.p95), (160.0, 684.0))
        self.assertEqual((alacritty.count, alacritty.empty), (0, 1))
        self.assertTrue(math.isnan(alacritty.p50))
        table = summary.format_table(rows, label="app")
        self.assertTrue(table.startswith("app "), table)
        self.assertIn("org.mozilla.firefox", table)
        self.assertEqual(
            [row.label for row in summary.summarize_by_bundle(samples, origin=None)],
            ["org.mozilla.firefox", "com.apple.Notes", "org.alacritty"])

    def test_windows_or_by_bundle_is_required(self):
        with self.assertRaises(SystemExit):
            summary.main(["/dev/null"])
        with self.assertRaises(SystemExit):
            summary.main(["--by-bundle", "--window=native:0:1", "/dev/null"])

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
