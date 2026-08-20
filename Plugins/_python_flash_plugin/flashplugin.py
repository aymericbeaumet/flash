"""Shared Flash plugin SDK for Python (stdlib only) — no Flash business
concepts, mirroring the Rust `flash_plugin` crate's role for Python plugins.
Plugins bootstrap it with a two-line path insert (the directory sits beside
every plugin in both the checkout and the staged release bundle):

    sys.path.insert(0, os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "_python_flash_plugin"))
    from flashplugin import Plugin

Speaks the wire contract from docs/plugin-protocol.md: protocol v1, one JSON
object per newline-terminated line over stdio. Three frame shapes: id+method
is a request, id only is a response, method only is a notification. Host and
plugin id counters are independent and may overlap, so replies to our own
call_host requests are correlated through a local pending map — any id+method
frame arriving on stdin is a host->plugin request, never a reply.
"""
import json
import os
import sys

PROTOCOL_VERSION = 1

_PENDING = object()  # sentinel: reply not yet received (None is a valid result)
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
    return os.environ.get("FLASH_PLUGIN_DATA_DIR", ".")


class Plugin:
    """Blocking single-threaded serve loop for command/evaluator plugins."""

    def __init__(self):
        self._in = sys.stdin.buffer
        self._out = sys.stdout.buffer
        self._next_id = 0
        self._pending = {}  # our request id -> _PENDING | host result
        self._on_command = None
        self._on_query = None
        self._done = False

    def send(self, obj):
        self._out.write(json.dumps(obj, separators=(",", ":")).encode() + b"\n")
        self._out.flush()

    def respond(self, request_id, result):
        self.send({"id": request_id, "result": result})

    def notify(self, method, params):
        self.send({"method": method, "params": params})

    def log(self, level, message):
        self.notify("flash.log", {"level": level, "message": message, "fields": {}})

    def call_host(self, method, params=None):
        """Blocking host RPC: pumps the read loop (dispatching interleaved
        host requests/notifications) until our reply arrives."""
        self._next_id += 1
        rid = self._next_id
        self._pending[rid] = _PENDING
        self.send({"id": rid, "method": method, "params": params or {}})
        while self._pending.get(rid) is _PENDING:
            line = self._in.readline()
            if not line:
                self._pending.pop(rid, None)
                raise EOFError("host closed stdin while awaiting reply")
            self._handle(line)
        return self._pending.pop(rid)

    def _handle(self, raw):
        raw = raw.strip()
        if not raw:
            return
        try:
            msg = json.loads(raw)
        except ValueError:
            return  # wire noise is dropped, never fatal
        method, mid = msg.get("method"), msg.get("id")
        if method is None:  # response frame — resolve one of our call_host ids
            if self._pending.get(mid) is _PENDING:
                self._pending[mid] = msg.get("result")
            return
        if mid is None:  # notification — this SDK subscribes to none
            return
        if method == "initialize":
            if (msg.get("params") or {}).get("protocol_version") != PROTOCOL_VERSION:
                self.respond(mid, {"ok": False, "error": "protocol version mismatch"})
                self._done = True
                return
            self.respond(mid, {"ok": True, "protocol_version": PROTOCOL_VERSION})
        elif method == "heartbeat":
            self.respond(mid, {"ok": True})
        elif method == "shutdown":
            self.respond(mid, {"ok": True})
            self._done = True
        elif method == "command.invoke" and self._on_command is not None:
            self.respond(mid, self._on_command(msg.get("params") or {}))
        elif method == "query.evaluate" and self._on_query is not None:
            # Synchronous CPU-only evaluator: the hook returns the answer
            # list (possibly empty — additive parsers decline, never error).
            self.respond(mid, {"answers": self._on_query(msg.get("params") or {})})
        else:
            self.respond(mid, {"ok": False, "error": f"unsupported method {method}"})

    def serve(self, on_command=None, on_query=None):
        self._on_command = on_command
        self._on_query = on_query
        while not self._done:
            line = self._in.readline()
            if not line:  # host closed stdin — clean exit
                return
            self._handle(line)
