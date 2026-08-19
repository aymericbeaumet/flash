#!/usr/bin/env python3
"""Protocol conformance driver for Flash plugins, any language.

Speaks the wire contract from docs/plugin-protocol.md against a plugin
process — self-contained, no imports from any plugin's shim. Probes, in
order:

  initialize (protocol v3)      must reply ok:true
  heartbeat (id -1)             must reply (negative-id decode)
  event notification            carries doubles incl. a negative origin in
                                front_window_frame — the decoder-crash probe
                                (a correct plugin ignores it silently)
  unknown request (id 7)        must reply with id 7 — proves the read loop
                                survived the doubles frame and that id'd
                                requests are never silently dropped
  sources.snapshot (--snapshot) must return >0 candidates; round-trip is
                                timed and printed
  shutdown                      must reply, then exit

Exits non-zero when any probe fails. Usage, from anywhere:
    python3 Scripts/plugin-protocol-smoke.py [--snapshot] [--seconds N] -- <argv...>
    python3 Scripts/plugin-protocol-smoke.py -- python3 main.py
    python3 Scripts/plugin-protocol-smoke.py --snapshot -- bun run main.ts
"""
import os
import struct
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# Minimal MessagePack codec — the subset the protocol uses (nil/bool/int/
# float/str/array/map). Deliberately independent of every shim so the driver
# can grade them.
# ---------------------------------------------------------------------------


def encode(obj):
    out = bytearray()
    _encode_into(obj, out)
    return bytes(out)


def _encode_into(obj, out):
    if obj is None:
        out.append(0xC0)
    elif obj is True:
        out.append(0xC3)
    elif obj is False:
        out.append(0xC2)
    elif isinstance(obj, int):
        if 0 <= obj <= 0x7F:
            out.append(obj)
        elif -32 <= obj < 0:
            out.append(obj & 0xFF)
        else:
            out.append(0xD3)
            out += struct.pack(">q", obj)
    elif isinstance(obj, float):
        out.append(0xCB)
        out += struct.pack(">d", obj)
    elif isinstance(obj, str):
        raw = obj.encode("utf-8")
        if len(raw) < 32:
            out.append(0xA0 | len(raw))
        else:
            out.append(0xDB)
            out += struct.pack(">I", len(raw))
        out += raw
    elif isinstance(obj, (list, tuple)):
        if len(obj) < 16:
            out.append(0x90 | len(obj))
        else:
            out.append(0xDD)
            out += struct.pack(">I", len(obj))
        for item in obj:
            _encode_into(item, out)
    elif isinstance(obj, dict):
        if len(obj) < 16:
            out.append(0x80 | len(obj))
        else:
            out.append(0xDF)
            out += struct.pack(">I", len(obj))
        for key, value in obj.items():
            _encode_into(key, out)
            _encode_into(value, out)
    else:
        raise TypeError(f"unencodable value: {obj!r}")


def decode(buf, pos=0):
    b = buf[pos]
    pos += 1
    if b == 0xC0:
        return None, pos
    if b == 0xC2:
        return False, pos
    if b == 0xC3:
        return True, pos
    if b <= 0x7F:
        return b, pos
    if b >= 0xE0:
        return b - 256, pos
    if 0xA0 <= b <= 0xBF:
        n = b & 0x1F
        return buf[pos : pos + n].decode("utf-8"), pos + n
    if b == 0xD9:
        n = buf[pos]
        return buf[pos + 1 : pos + 1 + n].decode("utf-8"), pos + 1 + n
    if b == 0xDA:
        (n,) = struct.unpack_from(">H", buf, pos)
        return buf[pos + 2 : pos + 2 + n].decode("utf-8"), pos + 2 + n
    if b == 0xDB:
        (n,) = struct.unpack_from(">I", buf, pos)
        return buf[pos + 4 : pos + 4 + n].decode("utf-8"), pos + 4 + n
    if b == 0xCC:
        return buf[pos], pos + 1
    if b == 0xCD:
        return struct.unpack_from(">H", buf, pos)[0], pos + 2
    if b == 0xCE:
        return struct.unpack_from(">I", buf, pos)[0], pos + 4
    if b == 0xCF:
        return struct.unpack_from(">Q", buf, pos)[0], pos + 8
    if b == 0xD0:
        return struct.unpack_from(">b", buf, pos)[0], pos + 1
    if b == 0xD1:
        return struct.unpack_from(">h", buf, pos)[0], pos + 2
    if b == 0xD2:
        return struct.unpack_from(">i", buf, pos)[0], pos + 4
    if b == 0xD3:
        return struct.unpack_from(">q", buf, pos)[0], pos + 8
    if b == 0xCA:
        return struct.unpack_from(">f", buf, pos)[0], pos + 4
    if b == 0xCB:
        return struct.unpack_from(">d", buf, pos)[0], pos + 8
    if 0x90 <= b <= 0x9F:
        return _decode_array(buf, pos, b & 0x0F)
    if b == 0xDC:
        (n,) = struct.unpack_from(">H", buf, pos)
        return _decode_array(buf, pos + 2, n)
    if b == 0xDD:
        (n,) = struct.unpack_from(">I", buf, pos)
        return _decode_array(buf, pos + 4, n)
    if 0x80 <= b <= 0x8F:
        return _decode_map(buf, pos, b & 0x0F)
    if b == 0xDE:
        (n,) = struct.unpack_from(">H", buf, pos)
        return _decode_map(buf, pos + 2, n)
    if b == 0xDF:
        (n,) = struct.unpack_from(">I", buf, pos)
        return _decode_map(buf, pos + 4, n)
    raise ValueError(f"unhandled msgpack byte 0x{b:02x}")


def _decode_array(buf, pos, n):
    out = []
    for _ in range(n):
        value, pos = decode(buf, pos)
        out.append(value)
    return out, pos


def _decode_map(buf, pos, n):
    out = {}
    for _ in range(n):
        key, pos = decode(buf, pos)
        value, pos = decode(buf, pos)
        out[key] = value
    return out, pos


def frame(obj):
    payload = encode(obj)
    return struct.pack(">I", len(payload)) + payload


# The decoder-crash probe: a frame every correct plugin must PARSE (then
# ignore — it is an unsubscribed notification with no id). Doubles with a
# negative origin are exactly what the host emits for a window on a display
# left of the primary; hand-rolled decoders have crashed on them before.
DOUBLES_EVENT = {
    "jsonrpc": "2.0",
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
    child.stdin.write(frame(DOUBLES_EVENT))
    # Doubles inside an id'd request: a decoder that drops undecodable frames
    # silently (instead of replying or crashing loudly) turns this into a
    # missing id-7 reply — the exact host-side symptom is a request hung to
    # its deadline.
    child.stdin.write(
        frame(
            {
                "jsonrpc": "2.0",
                "id": 7,
                "method": "driver.unknown",
                "params": {"x": -1912.5, "y": 982.0},
            }
        )
    )
    snapshot_sent_at = time.monotonic()
    if want_snapshot:
        child.stdin.write(
            frame({"jsonrpc": "2.0", "id": 2, "method": "sources.snapshot", "params": {}})
        )
    child.stdin.flush()

    os.set_blocking(child.stdout.fileno(), False)
    deadline = time.time() + seconds
    buf = b""
    seen = {
        "initialize": False,
        "heartbeat": False,
        "unknown": False,
        "snapshot": None,
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
                child.stdin.write(
                    frame({"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": {}})
                )
                child.stdin.flush()
            except OSError:
                pass
            shutdown_sent = True
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
            if method is not None and mid is not None:
                # Plugin→host request (id + method): NAK it like a host that
                # doesn't offer the capability, interleaved with the pending
                # host→plugin requests — SDKs must tolerate this without
                # confusing the reply with their own request stream.
                print(f"host-rpc: {method} -> NAK")
                try:
                    child.stdin.write(
                        frame(
                            {
                                "jsonrpc": "2.0",
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
                seen["initialize"] = result.get("ok") is True
            elif mid == -1:
                seen["heartbeat"] = True
                print("heartbeat: replied")
            elif mid == 7:
                # Any reply counts — the contract is "id'd requests are never
                # silently dropped", not a particular error shape.
                seen["unknown"] = True
                print(f"unknown-method: replied {msg.get('result', {})}")
            elif mid == 2:
                elapsed_ms = (time.monotonic() - snapshot_sent_at) * 1000
                candidates = msg.get("result", {}).get("candidates") or []
                seen["snapshot"] = len(candidates)
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
    if want_snapshot and not seen["snapshot"]:
        failures.append("snapshot")
    print("PASS" if not failures else f"FAIL: {', '.join(failures)}")
    sys.exit(0 if not failures else 1)


if __name__ == "__main__":
    main()
