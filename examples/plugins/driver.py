#!/usr/bin/env python3
"""Protocol smoke driver for Flash plugins, any language.

Speaks the wire contract from docs/plugin-protocol.md against a plugin
process: initialize (protocol v3) → heartbeat → optional sources.snapshot →
shutdown, printing every frame. Exits non-zero when the lifecycle fails.

Usage, from the plugin's directory:
    python3 ../driver.py [--snapshot] [--seconds N] -- <argv...>
    python3 ../driver.py -- /usr/bin/python3 main.py
    python3 ../driver.py --snapshot -- bun run main.ts
"""
import os
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "python-aiproviders"))
from flashplugin import decode, encode  # reuse the example shim's codec


def frame(obj):
    payload = encode(obj)
    return struct.pack(">I", len(payload)) + payload


def main():
    args = sys.argv[1:]
    want_snapshot = "--snapshot" in args
    seconds = 6.0
    if "--seconds" in args:
        seconds = float(args[args.index("--seconds") + 1])
    argv = args[args.index("--") + 1 :]

    child = subprocess.Popen(
        argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    child.stdin.write(
        frame(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "plugin_id": os.environ.get("FLASH_PLUGIN_ID", "driver-test"),
                    "version": "0.1.0",
                    "protocol_version": 3,
                    "running_applications": [],
                },
            }
        )
    )
    child.stdin.write(frame({"jsonrpc": "2.0", "id": -1, "method": "heartbeat"}))
    if want_snapshot:
        child.stdin.write(
            frame({"jsonrpc": "2.0", "id": 2, "method": "sources.snapshot", "params": {}})
        )
    child.stdin.write(
        frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": {}})
    )
    child.stdin.flush()

    os.set_blocking(child.stdout.fileno(), False)
    deadline = time.time() + seconds
    buf = b""
    seen = {"initialize": False, "heartbeat": False, "snapshot": None, "shutdown": False}
    while time.time() < deadline and not seen["shutdown"]:
        chunk = child.stdout.read(1 << 20)
        if chunk:
            buf += chunk
        while len(buf) >= 4:
            (n,) = struct.unpack(">I", buf[:4])
            if len(buf) < 4 + n:
                break
            payload, buf = buf[4 : 4 + n], buf[4 + n :]
            msg, _ = decode(payload)
            method = msg.get("method")
            mid = msg.get("id")
            if method == "flash.log":
                print(f"log: {msg['params'].get('message')}")
            elif method == "status.updated":
                print(f"status: {msg['params']}")
            elif mid == 1:
                result = msg.get("result", {})
                print(f"initialize: {result}")
                seen["initialize"] = result.get("ok") is True
            elif mid == -1:
                seen["heartbeat"] = msg.get("result", {}).get("ok") is True
                print("heartbeat: ok")
            elif mid == 2:
                candidates = msg.get("result", {}).get("candidates") or []
                seen["snapshot"] = len(candidates)
                titles = ", ".join(c.get("title", "?") for c in candidates[:3])
                print(f"snapshot: {len(candidates)} candidates ({titles}, ...)")
            elif mid == 3:
                seen["shutdown"] = True
                print("shutdown: ok")
        time.sleep(0.02)
    child.kill()
    err = child.stderr.read()
    if err:
        print(f"stderr: {err[:400]}", file=sys.stderr)

    ok = seen["initialize"] and seen["heartbeat"] and seen["shutdown"]
    if want_snapshot:
        ok = ok and (seen["snapshot"] or 0) > 0
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
