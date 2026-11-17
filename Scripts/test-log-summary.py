#!/usr/bin/env python3
"""Unit tests for Scripts/log-summary.py."""

import importlib.util
import io
import json
import math
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "log_summary", Path(__file__).with_name("log-summary.py"))
summary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(summary)

HOUR = 3_600_000


def record(time_ms, message, level="info", source="core:X.swift", pid=100, fields=None):
    raw = {
        "level": level, "message": message, "pid": pid, "source": source,
        "time_unix_ms": time_ms,
    }
    if fields is not None:
        raw["fields"] = fields
    return json.dumps(raw)


def visible(time_ms, ms, bundle, prepared="hit", outcome="hit", surface="targets",
            miss_reason=None):
    message = (
        f"[latency] hints_visible ms={ms} origin=key prepared={prepared} targets=10 "
        f"class=native surface={surface} bundle={bundle} outcome={outcome}")
    if miss_reason is not None:
        message += f" miss_reason={miss_reason}"
    return record(time_ms, message)


LINES = [
    record(0, "[statusbar] render visible=49", level="trace"),
    visible(1_000, 18.5, "com.slack", prepared="hit"),
    visible(2_000, 70.7, "com.slack", prepared="miss", outcome="miss", miss_reason="expired"),
    visible(3_000, 229.0, "com.slack", prepared="miss", outcome="miss", miss_reason="expired"),
    visible(4_000, 90.0, "com.slack", prepared="miss", outcome="retried",
            miss_reason="invalidated"),
    visible(5_000, 50.0, "com.slack", prepared="miss", outcome="miss"),
    visible(6_000, 900.0, "com.slack", prepared="miss", outcome="empty", miss_reason="absent"),
    visible(7_000, 17.4, "org.firefox", prepared="hit"),
    visible(8_000, 5.0, "org.firefox", prepared="none", outcome="none", surface="grid"),
    record(9_000, "[latency] hints_empty ms=1502.3 bundle=org.alacritty "
                  "path=prepared_model_refresh origin=key surface=targets"),
    record(9_500, "[latency] tap_to_route ms=0.3", level="debug"),
    record(9_600, "[latency] tap_to_route ms=30.0", level="debug"),
    record(9_700, "[latency] normal_dispatch action=scroll sync_ms=2.5", level="debug"),
    record(10_000, "[plugin] slow catalog publish", level="warn", source="plugin:history",
           fields={"elapsed_ms": "280", "encoded_bytes": "716800", "rows": "3172"}),
    record(11_000, "[plugin] slow catalog publish", level="warn", source="plugin:history",
           fields={"elapsed_ms": "1070", "encoded_bytes": "716800", "rows": "3172"}),
    record(12_000, "[plugin] slow catalog publish", level="warn", source="plugin:browsers",
           fields={"elapsed_ms": "60", "encoded_bytes": "1024", "rows": "20"}),
    record(13_000, "[apple] refresh", level="debug",
           fields={"catalog": "notes", "elapsed_ms": "17950", "outcome": "ok", "rows": "326"}),
    record(13_000, "[apple] refresh slow", level="warn",
           fields={"catalog": "notes", "elapsed_ms": "17950", "outcome": "ok", "rows": "326"}),
    record(14_000, "[apple] refresh", level="debug",
           fields={"catalog": "reminders", "elapsed_ms": "15", "outcome": "ok", "rows": "14"}),
    record(15_000, "[plugin] initialized elapsed_ms=296", source="plugin:answers",
           fields={"elapsed_ms": "296", "startup_total_ms": "298.36"}),
    record(15_100, "[plugin] initialized elapsed_ms=512", source="plugin:emojis",
           fields={"elapsed_ms": "512", "startup_total_ms": "514.43"}),
    record(16_000, "[mode] active_border_frame reason=app_activated pid=6 read_ms=4.9 "
                   "frame=(0,0,1,1)", level="trace"),
    record(16_100, "[mode] active_border_frame reason=app_activated pid=6 read_ms=252.5 "
                   "frame=(0,0,1,1)", level="trace"),
    record(16_200, "[mode] active_border_frame reason=app_activated_settled_80ms pid=6 "
                   "read_ms=1.0 frame=(0,0,1,1)", level="trace"),
    record(17_000, "[poll] overrun skipped=core:menu_bar_reveal", level="debug"),
    record(17_100, "[poll] overrun skipped=core:menu_bar_reveal", level="debug"),
    record(18_000, "[watchdog] main_busy ms=253", level="warn",
           fields={"last_activity_ms_ago": "mode_overlay(337)"}),
    record(18_100, "[watchdog] main_hitch ms=61", level="info",
           fields={"last_activity_ms_ago": "mode_overlay(70)"}),
    record(18_500, "[discover] frontmost_window_covered pid=43122 covering=[\"1:2\"] "
                   "repaired=false", level="warn"),
    record(18_600, "[window] placed pid=5 bundle=com.slack source=focused "
                   "writes=position corrections=0 outcome=converged resolve_ms=0.12 "
                   "frame_ms=0.05 apply_ms=14.20 total_ms=14.50", level="debug"),
    record(18_700, "[window] placed pid=5 bundle=com.slack source=focused "
                   "writes=position,size,size corrections=1 outcome=converged "
                   "resolve_ms=0.10 frame_ms=0.04 apply_ms=40.00 total_ms=40.30",
           level="debug"),
    record(18_800, "[window] placed pid=6 bundle=org.alacritty source=windows "
                   "writes=none corrections=0 outcome=converged resolve_ms=0.10 "
                   "frame_ms=0.03 apply_ms=0.00 total_ms=0.20", level="debug"),
    record(19_000, "[plugin] crashed", level="error", source="plugin:x", pid=200),
    record(2 * HOUR, "[statusbar] render visible=49", level="trace", pid=200),
    "not json at all",
]


class ParseTests(unittest.TestCase):
    def test_kind_stops_at_the_first_key_value(self):
        self.assertEqual(summary.message_kind("[watchdog] main_busy ms=253"), "[watchdog] main_busy")
        self.assertEqual(summary.message_kind("[plugin] slow catalog publish"),
                         "[plugin] slow catalog publish")
        self.assertEqual(
            summary.message_kind("[discover] frontmost_window_covered pid=1 covering=[x]"),
            "[discover] frontmost_window_covered")

    def test_fields_merge_the_structured_object_and_the_message(self):
        parsed = summary.parse_record(record(
            5, "[plugin] initialized elapsed_ms=296", source="plugin:answers",
            fields={"startup_total_ms": "298.36", "elapsed_ms": "296"}))
        self.assertEqual(parsed.fields["startup_total_ms"], "298.36")
        self.assertEqual(parsed.number("startup_total_ms", "elapsed_ms"), 298.36)
        self.assertEqual(parsed.plugin, "answers")
        self.assertEqual(summary.parse_record(record(5, "[x] y")).plugin, "-")
        self.assertIsNone(summary.parse_record("not json"))
        self.assertIsNone(summary.parse_record(json.dumps({"message": "no time"})))
        self.assertIsNone(summary.parse_record("[]"))

    def test_records_are_ordered_by_time(self):
        records = summary.read_records([record(20, "b"), record(10, "a"), "noise"])
        self.assertEqual([r.message for r in records], ["a", "b"])

    def test_nearest_rank(self):
        values = [float(v) for v in range(1, 101)]
        self.assertEqual(summary.nearest_rank(values, 50), 50)
        self.assertEqual(summary.nearest_rank(values, 95), 95)
        self.assertEqual(summary.nearest_rank([7.0], 95), 7.0)
        self.assertTrue(math.isnan(summary.Stats().p50))


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.summary = summary.summarize(summary.read_records(LINES), files=1, lines=len(LINES))

    def test_header_counts_span_and_launches(self):
        self.assertEqual(self.summary.records, len(LINES) - 1)
        self.assertEqual(self.summary.hours, 2.0)
        self.assertEqual(self.summary.launches, 2, "one host pid per launch")

    def test_latency_by_kind(self):
        kinds = self.summary.latency
        self.assertEqual(kinds["tap_to_route"].maximum, 30.0)
        self.assertEqual(kinds["normal_dispatch"].p50, 2.5, "sync_ms counts as the latency")
        self.assertEqual(kinds["hints_visible"].count, 8)
        self.assertEqual(kinds["hints_empty"].p50, 1502.3)

    def test_hints_visible_hits_misses_and_reasons_by_app(self):
        slack = self.summary.activations["com.slack"]
        self.assertEqual((slack.hits.count, slack.misses.count, slack.empty), (1, 4, 1))
        self.assertEqual(slack.hit_rate, 0.2)
        self.assertEqual(slack.hits.p50, 18.5)
        self.assertEqual((slack.misses.p50, slack.misses.maximum), (70.7, 229.0))
        self.assertEqual(slack.miss_reasons, {"expired": 2, "invalidated": 1, "?": 1})
        firefox = self.summary.activations["org.firefox"]
        self.assertEqual((firefox.hits.count, firefox.misses.count), (1, 0), "the grid is no app")
        alacritty = self.summary.activations["org.alacritty"]
        self.assertEqual((alacritty.shown, alacritty.empty), (0, 1))
        self.assertEqual(
            self.summary.empties["org.alacritty"]["prepared_model_refresh"].count, 1)

    def test_plugin_publishes_apple_catalogs_and_startups(self):
        history = self.summary.publishes["history"]
        self.assertEqual(history["elapsed_ms"].count, 2)
        self.assertEqual(history["elapsed_ms"].maximum, 1070)
        self.assertEqual(history["encoded_bytes"].p50, 716800)
        self.assertEqual(self.summary.apple["notes"].p50, 17950)
        self.assertEqual(self.summary.apple_slow, {"notes": 1})
        self.assertEqual(self.summary.startups["emojis"].p50, 514.43)

    def test_border_reads_overruns_stalls_and_warnings(self):
        border = self.summary.border
        self.assertEqual(border["app_activated"].count, 2)
        self.assertEqual(border["app_activated"].maximum, 252.5)
        self.assertEqual(border["app_activated_settled_80ms"].total, 1.0)
        self.assertEqual(self.summary.overruns, {"core:menu_bar_reveal": 2})
        self.assertEqual(self.summary.stalls.values, [253.0])
        self.assertEqual(self.summary.hitches.values, [61.0])
        self.assertEqual(self.summary.warnings["warn [watchdog] main_busy"], 1)
        self.assertEqual(self.summary.warnings["warn [plugin] slow catalog publish"], 3)
        self.assertEqual(self.summary.warnings["error [plugin] crashed"], 1)
        self.assertEqual(self.summary.warnings["warn [discover] frontmost_window_covered"], 1)

    def test_window_moves_by_app(self):
        slack = self.summary.window_moves["com.slack"]
        self.assertEqual(slack.total.values, [14.5, 40.3])
        self.assertEqual(slack.writes.values, [1, 3])
        self.assertEqual(slack.corrections, 1)
        alacritty = self.summary.window_moves["org.alacritty"]
        self.assertEqual(alacritty.writes.values, [0], "a window already in place takes none")

    def test_render_prints_every_section(self):
        text = summary.render(self.summary)
        for heading in [
            "[latency] by kind", "hints_visible target activations by app",
            "[latency] hints_empty by app", "[plugin] slow catalog publish by plugin",
            "[apple] refresh by catalog", "[plugin] initialized by plugin",
            "[mode] active_border_frame", "[poll] overrun by registration",
            "[watchdog] main thread stalls and hitches", "main_hitch",
            "[window] placed by app",
            "warnings and errors by kind",
        ]:
            self.assertIn(heading, text)
        self.assertIn("expired=2 invalidated=1 ?=1", text)
        self.assertIn("20%", text)
        self.assertIn("2 launch(es)", text)
        self.assertIn("per hour", text)
        self.assertIn("total", text)

    def test_an_empty_section_says_so(self):
        empty = summary.summarize([])
        self.assertIn("(none)", summary.render(empty))
        self.assertEqual(empty.hours, 0)


class MainTests(unittest.TestCase):
    def test_reads_the_given_logs_and_honours_hours(self):
        with tempfile.TemporaryDirectory() as directory:
            log = os.path.join(directory, "flash.log")
            with open(log, "w", encoding="utf-8") as handle:
                handle.write("\n".join(LINES) + "\n")
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(summary.main([log]), 0)
            self.assertIn("com.slack", out.getvalue())
            out = io.StringIO()
            with redirect_stdout(out):
                self.assertEqual(summary.main(["--hours", "1", log]), 0)
            self.assertNotIn("com.slack", out.getvalue(), "the last hour has no activation")
            self.assertEqual(summary.main([os.path.join(directory, "missing.log")]), 1)


if __name__ == "__main__":
    unittest.main()
