"""Plugin process management: production-parity env, drained pipes, teardown.

Mirrors PluginProcess.sanitizedPluginEnvironment: an 11-key allowlist plus the
FLASH_PLUGIN_* contract vars — a plugin that depends on an inherited secret
passes conformance here and fails in the app, so the scrub is the default and
ambient FLASH_PLUGIN_ID/VERSION/DATA_DIR/CONFIG are honored only as explicit
caller overrides (spec fixtures win over them).

Both pipes are drained on daemon threads from spawn: stdout frames land in a
Queue the step interpreter consumes; stderr accumulates in a capped buffer
(diagnostics-only per the protocol — a flooding plugin must never deadlock the
runner). Teardown escalates close-stdin -> SIGTERM -> killpg(SIGKILL) so a
plugin that forked a grandchild inheriting the pipes can never hang the run.
"""
import json
import os
import queue
import signal
import subprocess
import tempfile
import threading
import time

ENV_ALLOWLIST = [
    "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH", "SHELL",
    "TERM", "TMPDIR", "USER", "__CF_USER_TEXT_ENCODING",
]

STDERR_CAP = 256 * 1024


def frame_bytes(obj):
    return json.dumps(obj, separators=(",", ":")).encode("utf-8") + b"\n"


def build_environment(_plugins_dir, plugin_id, data_dir, config_json, parent_pid, spec):
    env = {}
    for key in ENV_ALLOWLIST:
        if key in os.environ:
            env[key] = os.environ[key]
    env["FLASH_PLUGIN_ID"] = plugin_id
    env["FLASH_PLUGIN_VERSION"] = os.environ.get("FLASH_PLUGIN_VERSION", "0.1.0")
    env["FLASH_PLUGIN_DATA_DIR"] = data_dir
    env["FLASH_PLUGIN_PARENT_PID"] = str(parent_pid)
    if config_json is not None:
        env["FLASH_PLUGIN_CONFIG"] = config_json
    for key, value in spec.get("env", {}).items():
        env[str(key)] = str(value)
    for key in spec.get("env_unset", []):
        env.pop(key, None)
    return env


class SpecProcess:
    """One plugin child per spec, plus its optional ephemeral parent."""

    def __init__(self, argv, cwd, env, sandbox_profile=None):
        self.parent = None
        if env.get("FLASH_PLUGIN_PARENT_PID") == "ephemeral":
            self.parent = subprocess.Popen(
                ["/bin/sleep", "3600"], stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            env["FLASH_PLUGIN_PARENT_PID"] = str(self.parent.pid)
        if sandbox_profile is not None:
            argv = ["/usr/bin/sandbox-exec", "-p", sandbox_profile] + list(argv)
        self.child = subprocess.Popen(
            argv, cwd=cwd, env=env, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.frames = queue.Queue()
        self._stderr_lock = threading.Lock()
        self._stderr = b""
        self.stderr_truncated = False
        self.undecodable_lines = 0
        threading.Thread(target=self._drain_stdout, daemon=True).start()
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    def _drain_stdout(self):
        buf = b""
        stream = self.child.stdout
        while True:
            chunk = stream.read1(1 << 20)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    self.frames.put(json.loads(line))
                except ValueError:
                    self.undecodable_lines += 1

    def _drain_stderr(self):
        stream = self.child.stderr
        while True:
            chunk = stream.read1(1 << 16)
            if not chunk:
                break
            with self._stderr_lock:
                if len(self._stderr) < STDERR_CAP:
                    self._stderr += chunk[: STDERR_CAP - len(self._stderr)]
                else:
                    self.stderr_truncated = True

    def stderr_text(self):
        with self._stderr_lock:
            return self._stderr.decode("utf-8", "replace")

    def write(self, data):
        self.child.stdin.write(data)
        self.child.stdin.flush()

    def close_stdin(self):
        try:
            self.child.stdin.close()
        except OSError:
            pass

    def kill_parent(self):
        if self.parent is not None:
            self.parent.kill()

    def wait_exit(self, deadline):
        """Poll for exit until the monotonic deadline; returns the code or None."""
        while time.monotonic() < deadline:
            code = self.child.poll()
            if code is not None:
                return code
            time.sleep(0.01)
        return self.child.poll()

    def teardown(self):
        """close stdin -> 1s grace -> SIGTERM -> 0.5s -> killpg(SIGKILL)."""
        self.close_stdin()
        if self.wait_exit(time.monotonic() + 1.0) is None:
            try:
                self.child.terminate()
            except OSError:
                pass
            if self.wait_exit(time.monotonic() + 0.5) is None:
                try:
                    os.killpg(self.child.pid, signal.SIGKILL)
                except (OSError, ProcessLookupError):
                    pass
                self.wait_exit(time.monotonic() + 1.0)
        if self.parent is not None:
            try:
                self.parent.kill()
                self.parent.wait(timeout=1)
            except (OSError, subprocess.TimeoutExpired):
                pass


def make_data_dir(spec, variables):
    """Fresh per-spec data dir with any declared fixture files.

    realpath is load-bearing for the sandbox lane: mkdtemp returns a
    /var/folders/... path but seatbelt matches canonical vnode paths
    (/private/var/...), so an unresolved path makes the profile's data-dir
    write allowance silently never match.
    """
    from .generators import expand

    root = os.path.realpath(tempfile.mkdtemp(prefix="flash-spec-"))
    for name, content in spec.get("data_dir", {}).items():
        path = os.path.join(root, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        content = expand(content, variables)
        with open(path, "w", encoding="utf-8") as handle:
            if isinstance(content, str):
                handle.write(content)
            else:
                json.dump(content, handle)
    return root
