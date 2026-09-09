"""Contract tests for the runner, including real child stdout intake."""
import unittest
import json
import os
from pathlib import Path
import sys
import time
from unittest.mock import patch

from .matchers import match
from .process import SpecProcess
from .run import run_spec
from .wire import valid_pid, validate_result
from .schema import SpecError, validate
from .discover import manifest_features


class MatcherTests(unittest.TestCase):
    def test_literal_scalars_preserve_json_types(self):
        self.assertTrue(match(True, 1))
        self.assertTrue(match(1, True))
        self.assertEqual(match(1, 1.0), [])  # both are JSON numbers (e.g. geometry)
        self.assertEqual(match(True, True), [])

    def test_one_of_preserves_nested_scalar_types(self):
        self.assertTrue(match({"$one_of": [True]}, 1))
        self.assertTrue(match({"$one_of": [{"ok": True}]}, {"ok": 1}))

    def test_shared_wire_corpus(self):
        path = Path(__file__).resolve().parents[2] / "Plugins/_flash_plugin_specs/fixtures/wire-values.fixture"
        fixture = json.loads(path.read_text())
        for method in ("perform", "hints"):
            for case in fixture[method]:
                self.assertEqual(validate_result(method, case["value"]) is None, case["valid"], case["name"])
        for case in fixture["pid"]:
            self.assertEqual(valid_pid(case["value"]), case["valid"], case["name"])
        for case in fixture["protocol_version"]:
            self.assertEqual(validate_result("initialize", {"ok": True, "protocol_version": case["value"]}) is None, case["valid"], case["name"])
        for case in fixture["encoded_rows"]:
            self.assertEqual(len(json.dumps(case["value"], ensure_ascii=False, separators=(",", ":")).encode()), case["encoded_bytes"])

    def test_schema_does_not_accept_boolean_or_negative_deadlines(self):
        for value in (True, -1, 1.5):
            with self.assertRaises(SpecError):
                validate({"contract": "test", "steps": [{"sleep_ms": value}]}, "test")

    def test_mixed_source_manifest_runs_both_warm_and_live_contracts(self):
        features = manifest_features({"sources": [{"name": "warm"}, {"name": "live", "live": True}]})
        self.assertTrue({"sources_warm", "sources_live"} <= features)


class ProcessTests(unittest.TestCase):
    def spawn(self, script):
        process = SpecProcess([sys.executable, "-c", script], os.getcwd(), os.environ.copy())
        self.addCleanup(process.teardown)
        return process

    def test_oversized_unterminated_output_is_rejected_before_eof(self):
        with patch("Scripts.flash_spec_runner.process.FRAME_CAP", 32):
            process = self.spawn("import sys,time; sys.stdout.write('x'*64); sys.stdout.flush(); time.sleep(5)")
            deadline = time.monotonic() + 2
            while process.intake_error is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertIn("byte limit", process.intake_error)
            self.assertFalse(process.stdout_done.is_set())
            self.assertTrue(process.frames.empty())

    def test_flooded_frame_queue_fails_instead_of_growing_or_blocking(self):
        with patch("Scripts.flash_spec_runner.process.QUEUED_FRAME_CAP", 4):
            process = self.spawn("import sys; sys.stdout.write('{\"method\":\"log\",\"params\":{}}\\n'*10000)")
            self.assertEqual(process.wait_exit(time.monotonic() + 3), 0)
            self.assertTrue(process.stdout_done.wait(1))
            self.assertIn("queue", process.intake_error)
            self.assertLessEqual(process.frames.qsize(), 4)

    def test_partial_json_on_eof_is_not_accepted_as_a_frame(self):
        process = self.spawn("import sys; sys.stdout.write('{\"id\":1,\"result\":{\"ok\":true}}')")
        self.assertEqual(process.wait_exit(time.monotonic() + 3), 0)
        self.assertTrue(process.stdout_done.wait(1))
        self.assertIn("unterminated", process.intake_error)
        self.assertTrue(process.frames.empty())

    def test_a_child_ignoring_stdin_cannot_block_the_write_deadline(self):
        process = self.spawn("import time; time.sleep(5)")
        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            process.write(b"x" * (1024 * 1024), deadline=started + 0.05)
        self.assertLess(time.monotonic() - started, 1)


class RunTests(unittest.TestCase):
    def run_child(self, result, copies=1, sleep_step=False, method="ping"):
        script = ("import json,sys; json.loads(sys.stdin.readline()); "
                  f"sys.stdout.write({(json.dumps({'id': 1, 'result': result}) + chr(10))!r}*{copies}); "
                  "sys.stdout.flush(); sys.stdin.read()")
        steps = [
            {"send": {"id": 1, "method": method, "params": {}}},
            {"expect": {"id": 1, "result": {"ok": result["ok"]}}},
        ]
        if sleep_step:
            steps.append({"sleep_ms": 50})
        steps += [{"close_stdin": True}, {"expect_exit": {"code": 0}}]
        return run_spec({"steps": steps}, [sys.executable, "-c", script], os.getcwd(), os.environ.copy(), {})[0]

    def test_response_law_is_independent_of_the_expected_subset(self):
        self.assertIn("boolean", self.run_child({"ok": 1}))
        self.assertIn("nonempty error", self.run_child({"ok": False}))
        self.assertIsNone(self.run_child({"ok": True}))

    def test_initialize_rejection_may_report_its_version_without_weakening_perform(self):
        result = {"ok": False, "protocol_version": 1, "error": "protocol version mismatch"}
        self.assertIsNone(self.run_child(result, method="initialize"))
        self.assertIsNotNone(self.run_child(result, method="perform"))
        self.assertIsNone(self.run_child({"ok": False, "error": "already initialized"}, method="initialize"))
        for version in (True, 1.0, 99, None):
            self.assertIsNotNone(validate_result("initialize", dict(result, protocol_version=version)))
        self.assertIsNotNone(validate_result("initialize", dict(result, extra=1)))

    def test_duplicate_reply_is_detected_after_consuming_the_first(self):
        self.assertIn("duplicate", self.run_child({"ok": True}, copies=2))
        self.assertIn("duplicate", self.run_child({"ok": True}, copies=2, sleep_step=True))

    def test_intentional_repeated_ids_still_receive_one_reply_per_request(self):
        script = "import sys,json\nfor line in sys.stdin:\n f=json.loads(line); print(json.dumps({'id':f['id'],'result':{'ok':True}}),flush=True)"
        frame = {"id": 7, "method": "ping", "params": {}}
        expected = {"id": 7, "result": {"ok": True}}
        spec = {"steps": [{"send_batch": [frame, frame]}, {"expect_all": [expected, expected]},
                          {"close_stdin": True}, {"expect_exit": {"code": 0}}]}
        failure, _ = run_spec(spec, [sys.executable, "-c", script], os.getcwd(), os.environ.copy(), {})
        self.assertIsNone(failure)


if __name__ == "__main__":
    unittest.main()
