#!/usr/bin/env python3
import json
import os
import shlex
import subprocess
import sys
import threading
import traceback
from pathlib import Path


def _short(value, limit=2000):
    value = str(value or "").strip()
    if len(value) <= limit:
        return value
    return value[: limit - 3] + "..."


class FlashPlugin:
    def __init__(self, plugin_id, actions=None):
        self.plugin_id = plugin_id
        self.actions = actions or {}
        self.data_dir = Path(os.environ["FLASH_PLUGIN_DATA_DIR"])
        self._prepare_dirs()
        # Stdout serialization. Plugins that compute candidates on a
        # worker thread must not interleave protocol frames with the
        # serve loop's responses.
        self._emit_lock = threading.Lock()
        # Optional handler hooks. Subclasses or callers wire these.
        self.on_event = None  # fn(plugin, name, payload)
        self.on_discover_targets = None  # fn(plugin, params) -> snapshot dict
        self.on_source_action = None  # fn(plugin, name, params) -> dict
        self.on_resolve_candidate = None  # fn(plugin, candidate) -> dict
        self.on_activate_target = None  # fn(plugin, target_id, action)
        self.on_shutdown = None  # fn(plugin, reason)

    def run_in_background(self, target, *args, **kwargs):
        """Run `target(*args, **kwargs)` on a daemon thread.

        Plugins that block on slow IO (osascript, network) at startup
        must not call those routines on the serve loop's thread — the
        loop is what handles heartbeats, and blocking it for >10s causes
        Flash to treat the plugin as crashed and restart it.
        """

        def _wrap():
            try:
                target(*args, **kwargs)
            except Exception:
                self.log(
                    "warn",
                    f"[plugin] background task crashed\n{traceback.format_exc()}",
                )

        thread = threading.Thread(target=_wrap, daemon=True)
        thread.start()
        return thread

    def _prepare_dirs(self):
        for name in ("home", "config", "cache", "share", "bin"):
            (self.data_dir / name).mkdir(parents=True, exist_ok=True)

    def emit(self, value):
        line = json.dumps(value, separators=(",", ":"), sort_keys=True)
        with self._emit_lock:
            print(line, flush=True)

    def log(self, level, message, fields=None):
        self.emit(
            {
                "jsonrpc": "2.0",
                "method": "flash.log",
                "params": {
                    "level": level,
                    "message": message,
                    "fields": {k: str(v) for k, v in (fields or {}).items()},
                },
            }
        )

    def emit_snapshot(self, *, targets=None, candidates=None, context_pid=None, source_id=None):
        params = {
            "targets": targets or [],
            "candidates": candidates or [],
        }
        if context_pid is not None:
            params["context_pid"] = int(context_pid)
        if source_id is not None:
            params["source_id"] = source_id
        self.emit(
            {
                "jsonrpc": "2.0",
                "method": "snapshot.updated",
                "params": params,
            }
        )

    def invalidate_snapshot(self):
        self.emit({"jsonrpc": "2.0", "method": "snapshot.invalidated", "params": {}})

    def update_actions(self, actions):
        payload = [
            {
                "command": item.get("command", ""),
                "name": item.get("name", ""),
                "description": item.get("description", ""),
            }
            for item in actions
        ]
        self.emit(
            {
                "jsonrpc": "2.0",
                "method": "actions.updated",
                "params": {"actions": payload},
            }
        )

    def respond(self, request_id, result=None, error=None):
        if request_id is None:
            return
        response = {"jsonrpc": "2.0", "id": request_id}
        if error is not None:
            response["error"] = error
        else:
            response["result"] = result or {"ok": True}
        self.emit(response)

    def run_cli(self, argv, timeout=120):
        if not argv:
            return {"ok": False, "stdout": "", "stderr": "missing command", "status": -1}
        env = os.environ.copy()
        env["HOME"] = str(self.data_dir / "home")
        env["XDG_CONFIG_HOME"] = str(self.data_dir / "config")
        env["XDG_CACHE_HOME"] = str(self.data_dir / "cache")
        env["XDG_DATA_HOME"] = str(self.data_dir / "share")
        env["PATH"] = f"{self.data_dir / 'bin'}:{env.get('PATH', '')}"
        display = " ".join(shlex.quote(str(part)) for part in argv)
        try:
            proc = subprocess.run(
                [str(part) for part in argv],
                cwd=str(self.data_dir),
                env=env,
                text=True,
                capture_output=True,
                timeout=timeout,
            )
            result = {
                "ok": proc.returncode == 0,
                "stdout": _short(proc.stdout),
                "stderr": _short(proc.stderr),
                "status": proc.returncode,
            }
        except FileNotFoundError:
            result = {
                "ok": False,
                "stdout": "",
                "stderr": f"command not found: {argv[0]}",
                "status": 127,
            }
        except subprocess.TimeoutExpired as exc:
            result = {
                "ok": False,
                "stdout": _short(exc.stdout),
                "stderr": f"command timed out after {timeout}s",
                "status": 124,
            }
        fields = {
            "command": display,
            "status": result["status"],
            "stdout": result["stdout"],
            "stderr": result["stderr"],
        }
        self.log("info" if result["ok"] else "warn", f"[action] {display}", fields)
        return result

    def serve(self):
        self.log("info", "[plugin] process ready")
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    continue
                self.handle(request)
            except Exception as exc:
                print(traceback.format_exc(), file=sys.stderr, flush=True)
                request_id = request.get("id") if isinstance(request, dict) else None
                self.respond(request_id, {"ok": False, "error": str(exc)})

    def handle(self, request):
        request_id = request.get("id")
        method = request.get("method")
        params = request.get("params") or {}
        if method == "initialize":
            self.respond(request_id, {"ok": True})
            return
        if method == "heartbeat":
            self.respond(request_id, {"ok": True})
            return
        if method == "shutdown":
            reason = params.get("reason", "unknown")
            self.log("info", f"[plugin] shutdown reason={reason}")
            if self.on_shutdown:
                try:
                    self.on_shutdown(self, reason)
                except Exception as exc:
                    self.log("warn", f"[plugin] shutdown handler error: {exc}")
            self.respond(request_id, {"ok": True})
            raise SystemExit(0)
        if method == "event":
            name = params.get("name") or ""
            payload = params.get("payload") or {}
            if self.on_event:
                try:
                    self.on_event(self, name, payload)
                except Exception:
                    self.log("warn", "[plugin] event handler error\n" + traceback.format_exc())
            self.respond(request_id, {"ok": True})
            return
        if method == "discoverTargets":
            try:
                snapshot = (
                    self.on_discover_targets(self, params)
                    if self.on_discover_targets
                    else {"targets": [], "candidates": []}
                )
            except Exception as exc:
                self.log("warn", "[plugin] discover error\n" + traceback.format_exc())
                snapshot = {"targets": [], "candidates": [], "error": str(exc)}
            self.respond(request_id, snapshot or {"targets": [], "candidates": []})
            return
        if method == "sourceAction":
            name = params.get("name") or ""
            try:
                result = (
                    self.on_source_action(self, name, params)
                    if self.on_source_action
                    else {"did_perform": False}
                )
            except Exception as exc:
                self.log("warn", "[plugin] source action error\n" + traceback.format_exc())
                result = {"did_perform": False, "error": str(exc)}
            self.respond(request_id, result or {"did_perform": False})
            return
        if method == "resolveCandidate":
            candidate = params.get("candidate") or {}
            try:
                result = (
                    self.on_resolve_candidate(self, candidate)
                    if self.on_resolve_candidate
                    else {"did_resolve": False}
                )
            except Exception as exc:
                self.log("warn", "[plugin] resolve candidate error\n" + traceback.format_exc())
                result = {"did_resolve": False, "error": str(exc)}
            self.respond(request_id, result or {"did_resolve": False})
            return
        if method == "activateTarget":
            target_id = params.get("target_id") or ""
            action = params.get("action") or "left_click"
            if self.on_activate_target:
                try:
                    self.on_activate_target(self, target_id, action)
                except Exception:
                    self.log("warn", "[plugin] activate target error\n" + traceback.format_exc())
            # notification — no response expected
            return
        if method == "action.invoke":
            name = params.get("name")
            args = params.get("args") or []
            action = self.actions.get(name)
            if action is None:
                self.respond(request_id, {"ok": False, "error": f"unknown action: {name}"})
                return
            result = action(self, args, params)
            self.respond(request_id, result)
            return
        self.respond(request_id, {"ok": False, "error": f"unknown method: {method}"})


def cli_action(build_argv, timeout=120):
    def action(plugin, args, params):
        return plugin.run_cli(build_argv(list(args)), timeout=timeout)

    return action
