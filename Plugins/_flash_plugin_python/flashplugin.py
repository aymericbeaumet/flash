"""Shared Flash plugin SDK for Python (stdlib only) — no Flash business
concepts, mirroring the Rust `flash_plugin` crate's role for Python plugins.
Plugins import it by bare module name — the host (and the spec runner) inject
PYTHONPATH pointing at this directory at spawn, so the same import works from
the repo checkout, the staged release bundle, and third-party roots:

    from flashplugin import Plugin, ok, unhandled, fail

Speaks the wire contract from docs/plugin-protocol.md (constants pinned by
Plugins/_flash_plugin_specs/protocol.json): protocol v1, UTF-8 NDJSON over
stdio, 10 MiB line cap both directions. Frame triage: id+method is a host
request, id alone resolves a call_host pending, method alone is a
notification. Registration is keyword hooks on serve():

    Plugin().serve(on_start=..., on_evaluate=..., on_command=..., ...)

`perform` routes by kind to on_resolve/on_command/on_action/on_navigate;
those hooks return replies built with ok(**fields)/unhandled()/fail(msg).
on_hints returns either a target list or {"targets": [...], "context_pid":
pid} — the SDK wraps both as {"ok": True, "targets": [...]}. Hook errors
never break the wire: request hooks answer fail("<method> hook failed")
(evaluate answers empty — evaluators never error), lifecycle hooks log and
continue. stdin EOF is the shutdown signal: on_shutdown runs, serve()
returns, the process exits 0. call_host never raises and never returns None
— timeouts and host death arrive as {"ok": False, "error": ...} results.
"""
import json
import os
import select
import sys
import time

# ── constants ────────────────────────────────────────────────────────────

PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 10 * 1024 * 1024  # NDJSON line cap, both directions
HOST_CALL_TIMEOUT_MS = 5000

ERR_FRAME_OVERFLOW = "response exceeded outbound frame limit"
ERR_HOST_CLOSED = "host closed stdin"
ERR_HOST_TIMEOUT = "host call timed out"

_PERFORM_KINDS = ("resolve", "command", "action", "navigate")
_TIMEOUT = object()  # _read_line sentinel: deadline passed before a line
_PENDING = object()  # call_host sentinel: reply not yet received


# ── reply helpers ────────────────────────────────────────────────────────

def ok(**fields):
    return {"ok": True, **fields}


def unhandled():
    return {"ok": False, "unhandled": True}


def fail(message):
    return {"ok": False, "error": message}


# ── config / env accessors ───────────────────────────────────────────────

_config_cache = None


def config():
    """The dict parsed once from FLASH_PLUGIN_CONFIG ({} when unset/invalid)."""
    global _config_cache
    if _config_cache is None:
        try:
            parsed = json.loads(os.environ.get("FLASH_PLUGIN_CONFIG", ""))
        except ValueError:
            parsed = {}
        _config_cache = parsed if isinstance(parsed, dict) else {}
    return _config_cache


def data_dir():
    """The plugin's writable data directory; never defaults (a silent "."
    would scatter state into whatever cwd the plugin happened to spawn in)."""
    value = os.environ.get("FLASH_PLUGIN_DATA_DIR")
    if not value:
        raise RuntimeError("FLASH_PLUGIN_DATA_DIR is not set")
    return value


class Plugin:
    """Blocking single-threaded plugin runtime — fully conformant: pings
    never race in-flight requests, so no locks and one write path."""

    def __init__(self):
        self._fd = sys.stdin.fileno()
        self._out = sys.stdout.buffer
        self._buf = b""
        self._skipping = False  # inside an oversized inbound line
        self._next_id = 0
        self._pending = {}  # call_host id -> _PENDING | host result
        self._hooks = {}
        self._initialized = False
        self._done = False

    # ── framing ──────────────────────────────────────────────────────────

    def _send(self, obj):
        """The single write path: one JSON object, one line, flushed.
        Returns False when the encoded frame exceeds the outbound cap."""
        data = json.dumps(obj, separators=(",", ":")).encode()
        if len(data) > MAX_FRAME_BYTES:
            return False
        try:
            self._out.write(data + b"\n")
            self._out.flush()
        except (BrokenPipeError, ValueError, OSError):
            self._done = True  # host is gone; stdin EOF follows
        return True

    def _respond(self, request_id, result):
        if not self._send({"id": request_id, "result": result}):
            self._send({"id": request_id, "result": fail(ERR_FRAME_OVERFLOW)})

    def _notify(self, method, params):
        self._send({"method": method, "params": params})  # oversized: dropped

    def _read_line(self, deadline=None):
        """The next in-cap line (bytes, newline stripped), None at EOF, or
        _TIMEOUT once `deadline` (monotonic seconds) passes. Oversized lines
        are discarded chunk by chunk — never buffered whole — and the stream
        self-heals at the next newline."""
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line, self._buf = self._buf[:nl], self._buf[nl + 1:]
                if self._skipping:
                    self._skipping = False  # tail of an oversized line
                elif len(line) <= MAX_FRAME_BYTES:
                    return line
                continue
            if self._skipping or len(self._buf) > MAX_FRAME_BYTES:
                self._buf, self._skipping = b"", True
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([self._fd], [], [], remaining)[0]:
                    return _TIMEOUT
            chunk = os.read(self._fd, 65536)
            if not chunk:  # EOF; a valid unterminated tail still parses
                if self._buf and not self._skipping:
                    line, self._buf = self._buf, b""
                    return line
                return None
            self._buf += chunk

    # ── pending map / call_host ──────────────────────────────────────────

    def call_host(self, method, params=None, timeout_ms=HOST_CALL_TIMEOUT_MS):
        """Blocking plugin→host RPC: sends the request, then pumps the read
        loop (dispatching interleaved host traffic) until the reply, the
        deadline, or EOF. Never raises and never returns None — timeouts and
        host death arrive as {"ok": False, "error": ...} result objects."""
        self._next_id += 1
        rid = self._next_id
        if self._done:
            return fail(ERR_HOST_CLOSED)
        self._pending[rid] = _PENDING
        if not self._send({"id": rid, "method": method, "params": params or {}}):
            self._pending.pop(rid, None)
            return fail(ERR_FRAME_OVERFLOW)
        deadline = time.monotonic() + timeout_ms / 1000.0
        while self._pending.get(rid) is _PENDING and not self._done:
            line = self._read_line(deadline)
            if line is _TIMEOUT:
                break
            if line is None:
                self._handle_eof()
            else:
                self._dispatch(line)
        result = self._pending.pop(rid, _PENDING)
        if result is _PENDING or result is None:
            return fail(ERR_HOST_CLOSED if self._done else ERR_HOST_TIMEOUT)
        return result if isinstance(result, dict) else fail("malformed host reply")

    def _handle_eof(self):
        self._done = True
        for rid, value in self._pending.items():
            if value is _PENDING:
                self._pending[rid] = fail(ERR_HOST_CLOSED)

    # ── dispatch ─────────────────────────────────────────────────────────

    def _dispatch(self, raw):
        try:
            msg = json.loads(raw)
        except ValueError:
            return  # wire noise is dropped, never fatal
        if not isinstance(msg, dict):
            return
        method, mid = msg.get("method"), msg.get("id")
        if method is not None and mid is not None:  # host→plugin request
            self._handle_request(mid, method, msg.get("params") or {})
        elif mid is not None:  # response to one of our call_host requests
            if self._pending.get(mid) is _PENDING:
                self._pending[mid] = msg.get("result")
        elif method == "event":  # notification; unknown methods are ignored
            hook = self._hooks.get("on_event")
            if hook is not None:
                params = msg.get("params") or {}
                try:
                    hook(str(params.get("name") or ""), params.get("payload"))
                except Exception:
                    self.log("error", "event hook failed")

    # ── handler registry ─────────────────────────────────────────────────

    def _handle_request(self, mid, method, params):
        if method == "initialize":
            self._handle_initialize(mid, params)
        elif method == "ping":
            self._respond(mid, ok())
        elif method == "evaluate":
            hook = self._hooks.get("on_evaluate")
            try:
                answers = hook(params) if hook else []
            except Exception:
                answers = []  # evaluators are additive, never error paths
            self._respond(mid, ok(answers=answers))
        elif method == "search":
            hook = self._hooks.get("on_search")
            try:
                self._respond(mid, ok(rows=hook(params) if hook else []))
            except Exception:
                self._respond(mid, fail("search hook failed"))
        elif method == "hints":
            self._respond(mid, self._hints_reply(params))
        elif method == "perform":
            self._respond(mid, self._perform_reply(params))
        else:
            self._respond(mid, fail(f"unknown method: {method}"))

    def _handle_initialize(self, mid, params):
        host_version = params.get("protocol_version")
        if host_version != PROTOCOL_VERSION:
            self._respond(mid, {
                "ok": False,
                "protocol_version": PROTOCOL_VERSION,
                "error": f"protocol version mismatch: host v{host_version},"
                         f" plugin v{PROTOCOL_VERSION}",
            })
            sys.exit(0)  # terminal: reply already flushed; host parks us in failed
        if self._initialized:
            self._respond(mid, fail("initialize may only be called once"))
            return
        self._initialized = True
        self._respond(mid, {"ok": True, "protocol_version": PROTOCOL_VERSION})
        hook = self._hooks.get("on_start")  # after the reply, per contract
        if hook is not None:
            try:
                hook()
            except Exception:
                self.log("error", "start hook failed")

    def _hints_reply(self, params):
        hook = self._hooks.get("on_hints")
        if hook is None:
            return ok(targets=[])
        try:
            reply = hook(params)
        except Exception:
            return fail("hints hook failed")
        if isinstance(reply, dict):  # {"targets": [...], "context_pid"?: pid}
            return {"ok": True, **reply}
        return ok(targets=reply if reply is not None else [])

    def _perform_reply(self, params):
        kind = params.get("kind")
        if kind not in _PERFORM_KINDS:
            return fail(f"unknown perform kind: {kind}")
        hook = self._hooks.get("on_" + kind)
        if hook is None:
            return unhandled()
        try:
            reply = hook(params)
        except Exception:
            return fail("perform hook failed")  # mine-but-broke: no fallback
        return reply if reply is not None else ok()

    # ── emitters ─────────────────────────────────────────────────────────

    def publish(self, rows):
        """Full-replacement catalog push; each row carries a first-class
        `source` naming a manifest sources[].name."""
        self._notify("publish", {"rows": rows})

    def status(self, segments):
        self._notify("status", {"segments": segments})

    def log(self, level, message, fields=None):
        self._notify("log", {"level": level, "message": message,
                             "fields": fields or {}})

    # ── serve loop ───────────────────────────────────────────────────────

    def serve(self, on_start=None, on_shutdown=None, on_event=None,
              on_evaluate=None, on_search=None, on_hints=None,
              on_resolve=None, on_command=None, on_action=None,
              on_navigate=None):
        """Registers the keyword hooks, then reads frames until stdin EOF —
        the shutdown signal: on_shutdown runs, serve() returns, exit 0."""
        hooks = dict(on_start=on_start, on_shutdown=on_shutdown,
                     on_event=on_event, on_evaluate=on_evaluate,
                     on_search=on_search, on_hints=on_hints,
                     on_resolve=on_resolve, on_command=on_command,
                     on_action=on_action, on_navigate=on_navigate)
        self._hooks = {name: hook for name, hook in hooks.items() if hook}
        while not self._done:
            line = self._read_line()
            if line is None:
                self._handle_eof()
            else:
                self._dispatch(line)
        hook = self._hooks.get("on_shutdown")
        if hook is not None:
            try:
                hook()
            except Exception:
                pass  # exiting anyway; stdout may already be gone
