#!/usr/bin/env python3
"""Protocol conformance driver for Flash plugins, any language.

Speaks the v1 wire contract from docs/plugin-protocol.md: one JSON object
per newline-terminated line over stdio, no envelope beyond id/method/params/
result. Probes, in order:

  initialize                    must reply {"ok": true, "protocol_version": 1}
  heartbeat (id -1)             must reply (negative-id decode)
  event notification            carries doubles incl. a negative origin in
                                front_window_frame (a correct plugin ignores it)
  unknown request (id 7)        must reply with id 7 — id'd requests are never
                                silently dropped, even with doubles in params
  sources.snapshot (--snapshot) must return >0 candidates within
                                --max-snapshot-ms (default 1500); timed
  shutdown                      sent only after the probes settle, must reply

Any plugin→host request (id + method from the plugin) is NAK'd like a host
that doesn't offer the capability — SDKs must tolerate that interleaving.

Exits non-zero when any probe fails. Usage, from anywhere:
    python3 Scripts/plugin-protocol-smoke.py [--snapshot] [--seconds N] -- <argv...>
    python3 Scripts/plugin-protocol-smoke.py -- python3 main.py
    python3 Scripts/plugin-protocol-smoke.py --snapshot -- bun run main.ts
"""
import json
import os
import subprocess
import sys
import time


def frame(obj):
    return json.dumps(obj, separators=(",", ":")).encode("utf-8") + b"\n"


# The decoder probe: doubles with a negative origin are exactly what the host
# emits for a window on a display left of the primary.
DOUBLES_EVENT = {
    "method": "event",
    "params": {
        "name": "core:window.focus.changed",
        "payload": {
            "bundle_id": "dev.flash.smoke",
            "pid": 999,
            "front_window_frame": {
                "x": -1912.5,
                "y": -140.25,
                "width": 1512.0,
                "height": 982.0,
            },
        },
    },
}


def main():
    args = sys.argv[1:]
    want_snapshot = "--snapshot" in args
    seconds = 6.0
    if "--seconds" in args:
        seconds = float(args[args.index("--seconds") + 1])
    max_snapshot_ms = 1500.0
    if "--max-snapshot-ms" in args:
        max_snapshot_ms = float(args[args.index("--max-snapshot-ms") + 1])
    argv = args[args.index("--") + 1 :]

    child = subprocess.Popen(
        argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    child.stdin.write(
        frame(
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "plugin_id": os.environ.get("FLASH_PLUGIN_ID", "driver-test"),
                    "version": "0.1.0",
                    "protocol_version": 1,
                    "running_applications": [],
                },
            }
        )
    )
    child.stdin.write(frame({"id": -1, "method": "heartbeat"}))
    child.stdin.write(frame(DOUBLES_EVENT))
    child.stdin.write(
        frame(
            {
                "id": 7,
                "method": "driver.unknown",
                "params": {"x": -1912.5, "y": 982.0},
            }
        )
    )
    snapshot_sent_at = time.monotonic()
    if want_snapshot:
        child.stdin.write(frame({"id": 2, "method": "sources.snapshot", "params": {}}))
    child.stdin.flush()

    os.set_blocking(child.stdout.fileno(), False)
    deadline = time.time() + seconds
    buf = b""
    seen = {
        "initialize": False,
        "heartbeat": False,
        "unknown": False,
        "snapshot": None,
        "snapshot_ms": None,
        "shutdown": False,
    }
    # Shutdown goes out only after the earlier probes settle (or most of the
    # deadline passes) — the real host never sends shutdown while it is still
    # awaiting initialize, and a plugin whose startup makes host RPCs needs
    # those answered before it can reply at all.
    shutdown_sent = False
    shutdown_by = time.time() + seconds * 0.6

    def probes_settled():
        done = seen["initialize"] and seen["heartbeat"] and seen["unknown"]
        if want_snapshot:
            done = done and seen["snapshot"] is not None
        return done

    while time.time() < deadline and not seen["shutdown"]:
        if not shutdown_sent and (probes_settled() or time.time() > shutdown_by):
            try:
                child.stdin.write(frame({"id": 3, "method": "shutdown", "params": {}}))
                child.stdin.flush()
            except OSError:
                pass
            shutdown_sent = True
        chunk = child.stdout.read(1 << 20)
        if chunk:
            buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                print(f"undecodable line: {line[:200]!r}", file=sys.stderr)
                continue
            method = msg.get("method")
            mid = msg.get("id")
            if method is not None and mid is not None:
                # Plugin→host request: NAK it like a host that doesn't offer
                # the capability, interleaved with pending host requests.
                print(f"host-rpc: {method} -> NAK")
                try:
                    child.stdin.write(
                        frame(
                            {
                                "id": mid,
                                "result": {
                                    "ok": False,
                                    "error": "not available in smoke driver",
                                },
                            }
                        )
                    )
                    child.stdin.flush()
                except OSError:
                    pass
            elif method == "flash.log":
                print(f"log: {msg['params'].get('message')}")
            elif method == "status.updated":
                print(f"status: {msg['params']}")
            elif mid == 1:
                result = msg.get("result", {})
                print(f"initialize: {result}")
                seen["initialize"] = (
                    result.get("ok") is True and result.get("protocol_version") == 1
                )
            elif mid == -1:
                seen["heartbeat"] = True
                print("heartbeat: replied")
            elif mid == 7:
                seen["unknown"] = True
                print(f"unknown-method: replied {msg.get('result', {})}")
            elif mid == 2:
                elapsed_ms = (time.monotonic() - snapshot_sent_at) * 1000
                candidates = msg.get("result", {}).get("candidates") or []
                seen["snapshot"] = len(candidates)
                seen["snapshot_ms"] = elapsed_ms
                titles = ", ".join(c.get("title", "?") for c in candidates[:3])
                print(
                    f"snapshot: {len(candidates)} candidates in {elapsed_ms:.0f}ms"
                    f" ({titles}, ...)"
                )
            elif mid == 3:
                seen["shutdown"] = True
                print("shutdown: ok")
        time.sleep(0.02)
    child.kill()
    err = child.stderr.read()
    if err:
        print(f"stderr: {err[:400]}", file=sys.stderr)

    failures = [
        name
        for name, passed in (
            ("initialize", seen["initialize"]),
            ("heartbeat", seen["heartbeat"]),
            ("unknown-method reply", seen["unknown"]),
            ("shutdown", seen["shutdown"]),
        )
        if not passed
    ]
    if want_snapshot:
        if not seen["snapshot"]:
            failures.append("snapshot")
        elif seen["snapshot_ms"] > max_snapshot_ms:
            failures.append(f"snapshot took {seen['snapshot_ms']:.0f}ms")
    print("PASS" if not failures else f"FAIL: {', '.join(failures)}")
    sys.exit(0 if not failures else 1)


if __name__ == "__main__":
    main()
