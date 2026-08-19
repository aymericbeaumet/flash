"""Minimal Flash plugin protocol shim for Python (stdlib only).

Speaks the wire contract from docs/plugin-protocol.md: length-prefixed
MessagePack over stdio (4-byte big-endian length + one value), protocol v3
lifecycle (initialize/heartbeat/shutdown), and request dispatch. Hand-rolls
the MessagePack subset the protocol needs — nil/bool/int/str/array/map —
so a plugin author needs nothing beyond /usr/bin/python3.
"""
import os
import struct
import sys


def encode(obj):
    if obj is None:
        return b"\xc0"
    if obj is True:
        return b"\xc3"
    if obj is False:
        return b"\xc2"
    if isinstance(obj, int):
        if 0 <= obj <= 127:
            return struct.pack("B", obj)
        if -32 <= obj < 0:
            return struct.pack("b", obj)
        return b"\xd3" + struct.pack(">q", obj)
    if isinstance(obj, str):
        raw = obj.encode()
        if len(raw) < 32:
            return struct.pack("B", 0xA0 | len(raw)) + raw
        return b"\xdb" + struct.pack(">I", len(raw)) + raw
    if isinstance(obj, (list, tuple)):
        head = (
            struct.pack("B", 0x90 | len(obj))
            if len(obj) < 16
            else b"\xdc" + struct.pack(">H", len(obj))
        )
        return head + b"".join(encode(x) for x in obj)
    if isinstance(obj, dict):
        head = (
            struct.pack("B", 0x80 | len(obj))
            if len(obj) < 16
            else b"\xde" + struct.pack(">H", len(obj))
        )
        return head + b"".join(encode(k) + encode(v) for k, v in obj.items())
    raise TypeError(f"unencodable: {type(obj)}")


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
        return buf[pos : pos + n].decode("utf-8", "replace"), pos + n
    if b == 0xD9:
        n = buf[pos]
        return buf[pos + 1 : pos + 1 + n].decode("utf-8", "replace"), pos + 1 + n
    if b == 0xDA:
        (n,) = struct.unpack(">H", buf[pos : pos + 2])
        return buf[pos + 2 : pos + 2 + n].decode("utf-8", "replace"), pos + 2 + n
    if b == 0xDB:
        (n,) = struct.unpack(">I", buf[pos : pos + 4])
        return buf[pos + 4 : pos + 4 + n].decode("utf-8", "replace"), pos + 4 + n
    if 0x80 <= b <= 0x8F or b in (0xDE, 0xDF):
        if b <= 0x8F:
            n = b & 0x0F
        elif b == 0xDE:
            (n,) = struct.unpack(">H", buf[pos : pos + 2])
            pos += 2
        else:
            (n,) = struct.unpack(">I", buf[pos : pos + 4])
            pos += 4
        out = {}
        for _ in range(n):
            k, pos = decode(buf, pos)
            v, pos = decode(buf, pos)
            out[k] = v
        return out, pos
    if 0x90 <= b <= 0x9F or b in (0xDC, 0xDD):
        if b <= 0x9F:
            n = b & 0x0F
        elif b == 0xDC:
            (n,) = struct.unpack(">H", buf[pos : pos + 2])
            pos += 2
        else:
            (n,) = struct.unpack(">I", buf[pos : pos + 4])
            pos += 4
        out = []
        for _ in range(n):
            v, pos = decode(buf, pos)
            out.append(v)
        return out, pos
    if b in (0xCC, 0xD0):
        return buf[pos], pos + 1
    if b in (0xCD, 0xD1):
        return struct.unpack(">H", buf[pos : pos + 2])[0], pos + 2
    if b in (0xCE, 0xD2):
        return struct.unpack(">I", buf[pos : pos + 4])[0], pos + 4
    if b in (0xCF, 0xD3):
        return struct.unpack(">q", buf[pos : pos + 8])[0], pos + 8
    if b == 0xCA:
        return struct.unpack(">f", buf[pos : pos + 4])[0], pos + 4
    if b == 0xCB:
        return struct.unpack(">d", buf[pos : pos + 8])[0], pos + 8
    raise ValueError(f"unhandled msgpack byte 0x{b:02x}")


PROTOCOL_VERSION = 3


class Plugin:
    """Blocking single-threaded serve loop. Enough for command-style
    plugins; a sources plugin would publish its warm catalog before
    replying to initialize (see the readiness gate in the protocol doc)."""

    def __init__(self, published_sources=()):
        self.published_sources = list(published_sources)
        self._out = sys.stdout.buffer

    def send(self, obj):
        payload = encode(obj)
        self._out.write(struct.pack(">I", len(payload)) + payload)
        self._out.flush()

    def respond(self, request_id, result):
        self.send({"jsonrpc": "2.0", "id": request_id, "result": result})

    def log(self, level, message):
        self.send(
            {
                "jsonrpc": "2.0",
                "method": "flash.log",
                "params": {"level": level, "message": message, "fields": {}},
            }
        )

    def serve(self, on_command):
        stdin = sys.stdin.buffer
        while True:
            header = stdin.read(4)
            if len(header) < 4:
                return  # host closed stdin — exit
            (n,) = struct.unpack(">I", header)
            payload = stdin.read(n)
            msg, _ = decode(payload)
            method = msg.get("method")
            request_id = msg.get("id")
            if method == "initialize":
                version = msg.get("params", {}).get("protocol_version")
                if version != PROTOCOL_VERSION:
                    self.respond(
                        request_id,
                        {"ok": False, "error": f"protocol {version} != {PROTOCOL_VERSION}"},
                    )
                    return
                self.respond(
                    request_id,
                    {
                        "ok": True,
                        "protocol_version": PROTOCOL_VERSION,
                        "published_sources": self.published_sources,
                    },
                )
            elif method == "heartbeat":
                self.respond(request_id, {"ok": True})
            elif method == "shutdown":
                self.respond(request_id, {"ok": True})
                return
            elif method == "command.invoke":
                self.respond(request_id, on_command(msg.get("params", {})))
            elif request_id is not None:
                self.respond(
                    request_id, {"ok": False, "error": f"unsupported method {method}"}
                )


def data_dir():
    return os.environ.get("FLASH_PLUGIN_DATA_DIR", ".")
