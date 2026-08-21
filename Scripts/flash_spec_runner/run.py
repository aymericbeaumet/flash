"""Step interpreter: plays one spec against one fresh plugin process.

The runner is the host: plugin->host requests (id + method) are answered from
the spec's scripted `host.replies` table (default: a capability NAK) unless an
expect_host_rpc step intercepts them; notifications accumulate for
expect_notification / expect_none; responses are correlated by id with arrival
timestamps so latency floors (not_before_ms) measure send->arrival honestly.
"""
import json
import time

from .generators import expand, raw_bytes
from .matchers import match
from .process import SpecProcess, frame_bytes

DEFAULT_NAK = {"ok": False, "error": "not available in spec runner"}
DEFAULT_SPEC_TIMEOUT_MS = 30000
DEFAULT_EXPECT_MS = 5000


class StepFailure(Exception):
    pass


class _HostState:
    def __init__(self, replies_table):
        self.table = dict(replies_table)
        self.captures = {}  # capture name -> request id

    def reply_for(self, method):
        entry = self.table.get(method, self.table.get("*", DEFAULT_NAK))
        if isinstance(entry, list):
            value = entry[0] if len(entry) == 1 else entry.pop(0)
            return value
        return entry


class SpecRun:
    def __init__(self, spec, argv, cwd, env, variables, sandbox_profile=None):
        self.spec = spec
        self.variables = variables
        self.host = _HostState(spec.get("host", {}).get("replies", {}))
        self.responses = {}  # id -> (frame, arrival_monotonic)
        self.notifications = []  # (frame, arrival_monotonic)
        self.host_requests = []  # unmatched plugin->host requests already auto-replied
        self.send_times = {}  # request id -> monotonic write time
        self.deadline = time.monotonic() + spec.get("timeout_ms", DEFAULT_SPEC_TIMEOUT_MS) / 1000.0
        self.process = SpecProcess(argv, cwd, env, sandbox_profile)
        if self.process.parent is not None:
            variables["parent_pid"] = self.process.parent.pid
        self.log_lines = []

    # -- frame intake -------------------------------------------------------

    def _classify(self, frame, pending_rpc=None):
        """Route one inbound frame; returns the frame if it satisfies pending_rpc."""
        method, mid = frame.get("method"), frame.get("id")
        if method is not None and mid is not None:
            if pending_rpc is not None and not match(pending_rpc, frame, "rpc"):
                return frame  # delivered to the expect_host_rpc step un-replied
            reply = self.host.reply_for(method)
            if reply != "drop":
                self.process.write(frame_bytes({"id": mid, "result": reply}))
            self.host_requests.append((frame, time.monotonic()))
            return None
        if method is not None:
            if method == "flash.log":
                self.log_lines.append(frame.get("params", {}).get("message"))
            # [frame, arrival, consumed] — expect_notification marks matched
            # entries consumed so two steps never double-count one frame,
            # while unmatched earlier notifications stay claimable.
            self.notifications.append([frame, time.monotonic(), False])
            return None
        if mid is not None:
            self.responses.setdefault(mid, (frame, time.monotonic()))
        return None

    def _pump(self, until, pending_rpc=None):
        """Drain frames until `until()` is truthy or the window closes.

        Returns the value of until() (or the matched rpc frame for pending_rpc).
        A just-exited child gets a short drain grace: poll() can observe the
        exit before the reader thread has flushed the final buffered reply
        into the queue, and declaring "exited while waiting" in that window
        was a real flake (a flush-then-exit reply is legal and common).
        """
        exit_seen_at = None
        while True:
            hit = until() if until else None
            if hit:
                return hit
            now = time.monotonic()
            if now >= self.deadline:
                raise StepFailure("spec wall-clock timeout")
            try:
                frame = self.process.frames.get(timeout=0.01)
            except Exception:
                frame = None
            if frame is None:
                exited = self.process.child.poll()
                if exited is not None and self.process.frames.empty():
                    if exit_seen_at is None:
                        exit_seen_at = now
                    if now - exit_seen_at < 0.25:
                        continue
                    hit = until() if until else None
                    if hit:
                        return hit
                    raise StepFailure(
                        f"plugin exited (status {exited}) while waiting"
                    )
                continue
            matched = self._classify(frame, pending_rpc)
            if matched is not None:
                return matched

    # -- steps --------------------------------------------------------------

    def play(self):
        for index, step in enumerate(self.spec["steps"]):
            where = f"steps[{index}]"
            try:
                self._play_step(step)
            except StepFailure as failure:
                raise StepFailure(f"{where}: {failure}") from None

    def _window(self, step, key, default):
        return min(self.deadline, time.monotonic() + step.get(key, default) / 1000.0)

    def _play_step(self, step):
        if "send" in step:
            self._send(step["send"])
        elif "send_batch" in step:
            payload = b"".join(
                frame_bytes(self._register_send(expand(f, self.variables)))
                for f in step["send_batch"]
            )
            self._write(payload)
        elif "send_raw" in step:
            self._write(raw_bytes(step["send_raw"], self.variables))
        elif "sleep_ms" in step:
            wake = min(self.deadline, time.monotonic() + step["sleep_ms"] / 1000.0)
            while time.monotonic() < wake:
                try:
                    frame = self.process.frames.get(timeout=0.01)
                    self._classify(frame)
                except Exception:
                    pass
        elif "close_stdin" in step:
            self.process.close_stdin()
        elif "kill_parent" in step:
            self.process.kill_parent()
        elif "expect" in step:
            self._expect(step)
        elif "expect_notification" in step:
            expected = expand(step["expect_notification"], self.variables)
            window = self._window(step, "within_ms", DEFAULT_EXPECT_MS)

            def hit():
                for entry in self.notifications:
                    if not entry[2] and not match(expected, entry[0], "notification"):
                        entry[2] = True
                        return entry[0]
                return None

            old_deadline, self.deadline = self.deadline, window
            try:
                self._pump(hit)
            except StepFailure as failure:
                raise StepFailure(f"no notification matching {expected!r} ({failure})")
            finally:
                self.deadline = old_deadline
        elif "expect_all" in step:
            matchers = [expand(m, self.variables) for m in step["expect_all"]]
            window = self._window(step, "within_ms", DEFAULT_EXPECT_MS)
            old_deadline, self.deadline = self.deadline, window
            try:
                for matcher in matchers:
                    self._await_response(matcher, None)
            finally:
                self.deadline = old_deadline
        elif "expect_none" in step:
            expected = expand(step["expect_none"], self.variables)
            window = min(self.deadline, time.monotonic() + step.get("for_ms", 500) / 1000.0)
            while time.monotonic() < window:
                try:
                    frame = self.process.frames.get(timeout=0.01)
                except Exception:
                    continue
                self._classify(frame)
                if not match(expected, frame, "frame"):
                    raise StepFailure(f"forbidden frame arrived: {frame!r}")
            for mid, (frame, _) in self.responses.items():
                if not match(expected, frame, "frame"):
                    raise StepFailure(f"forbidden frame arrived: {frame!r}")
        elif "expect_host_rpc" in step:
            expected = expand(step["expect_host_rpc"], self.variables)
            window = self._window(step, "within_ms", DEFAULT_EXPECT_MS)
            for existing, _ in self.host_requests:
                if not match(expected, existing, "rpc"):
                    raise StepFailure(
                        f"host rpc {existing.get('method')!r} already auto-replied before "
                        "expect_host_rpc — move the step earlier or script host.replies"
                    )
            old_deadline, self.deadline = self.deadline, window
            try:
                frame = self._pump(None, pending_rpc=expected)
            except StepFailure as failure:
                raise StepFailure(f"no host rpc matching {expected!r} ({failure})")
            finally:
                self.deadline = old_deadline
            reply = step.get("reply")
            if reply == "manual":
                self.host.captures[step.get("capture", "last")] = frame["id"]
            else:
                if reply is None:
                    reply = self.host.reply_for(frame["method"])
                self.process.write(
                    frame_bytes({"id": frame["id"], "result": expand(reply, self.variables)})
                )
        elif "reply_host_rpc" in step:
            body = step["reply_host_rpc"]
            name = body["to"]
            if name not in self.host.captures:
                raise StepFailure(f"no captured host rpc named {name!r}")
            rid = self.host.captures.pop(name)
            self.process.write(
                frame_bytes({"id": rid, "result": expand(body["result"], self.variables)})
            )
        elif "expect_exit" in step:
            body = step["expect_exit"]
            window = self._window(step, "within_ms", 3000)
            code = self.process.wait_exit(window)
            if code is None:
                raise StepFailure("plugin still running past expect_exit window")
            if code != body["code"]:
                raise StepFailure(f"exit code {code}, expected {body['code']}")
        elif "expect_stderr" in step:
            body = step["expect_stderr"]
            text = self.process.stderr_text()
            if "contains" in body and body["contains"] not in text:
                raise StepFailure(f"stderr missing {body['contains']!r}")
            if "absent" in body and body["absent"] in text:
                raise StepFailure(f"stderr contains forbidden {body['absent']!r}")
        else:  # pragma: no cover - schema validation prevents this
            raise StepFailure(f"unknown step {sorted(step)}")

    def _register_send(self, frame):
        if isinstance(frame, dict) and frame.get("id") is not None and "method" in frame:
            self.send_times[frame["id"]] = time.monotonic()
        return frame

    def _send(self, frame):
        self._write(frame_bytes(self._register_send(expand(frame, self.variables))))

    def _write(self, payload):
        try:
            self.process.write(payload)
        except (OSError, ValueError):
            raise StepFailure(
                f"plugin closed stdin (exit status {self.process.child.poll()})"
            )

    def _expect(self, step):
        expected = expand(step["expect"], self.variables)
        window = self._window(step, "within_ms", DEFAULT_EXPECT_MS)
        old_deadline, self.deadline = self.deadline, window
        try:
            self._await_response(expected, step.get("not_before_ms"))
        finally:
            self.deadline = old_deadline

    def _await_response(self, expected, not_before_ms):
        want_id = expected["id"]

        def hit():
            return self.responses.get(want_id)

        try:
            frame, arrived = self._pump(hit)
        except StepFailure as failure:
            raise StepFailure(f"no response with id {want_id} ({failure})")
        del self.responses[want_id]
        problems = match(expected, frame, "frame")
        if problems:
            raise StepFailure("; ".join(problems))
        if not_before_ms is not None:
            sent = self.send_times.get(want_id)
            if sent is not None and (arrived - sent) * 1000.0 < not_before_ms:
                raise StepFailure(
                    f"response to id {want_id} arrived after "
                    f"{(arrived - sent) * 1000.0:.0f}ms, floor {not_before_ms}ms"
                )


def run_spec(spec, argv, cwd, env, variables, sandbox_profile=None):
    """Returns (failure_message_or_None, diagnostics dict)."""
    run = SpecRun(spec, argv, cwd, env, variables, sandbox_profile)
    failure = None
    try:
        run.play()
    except StepFailure as exc:
        failure = str(exc)
    except Exception as exc:  # spec isolation: never crash the whole run
        failure = f"runner error: {type(exc).__name__}: {exc}"
    finally:
        run.process.teardown()
    diagnostics = {
        "stderr_tail": run.process.stderr_text()[-2000:],
        "undecodable_lines": run.process.undecodable_lines,
        "log_lines": run.log_lines[-20:],
    }
    return failure, diagnostics
