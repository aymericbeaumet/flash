#!/usr/bin/env python3
"""Conformance probe, in Python. See ../README.md — the normative behavior
contract all seven per-language probes follow. Test fixture only: driven by
Scripts/plugin-protocol-spec.py --probes, never shipped."""
import json
import os
import sys
import threading
import time

sys.dont_write_bytecode = True
from flashplugin import Plugin, config, fail, ok, unhandled  # host-injected PYTHONPATH

SOURCE = "conformance.items"
TARGET_PID = 4242

plugin = Plugin()
last_event = ""


def j(value):
    """Compact JSON with non-ASCII kept raw (the message-field encoder)."""
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def conformance_config():
    section = config().get("conformance")
    return section if isinstance(section, dict) else {}


def catalog():
    conf = conformance_config()
    if conf.get("empty_catalog") is True:
        return []
    count = conf.get("catalog_rows")
    if isinstance(count, int):
        pad = "x" * int(conf.get("row_pad") or 0)
        return [{"source": SOURCE, "title": f"row-{i}{pad}"} for i in range(1, count + 1)]
    return [
        {"source": SOURCE, "title": "alpha", "metadata": {"k": "v1"}},
        {"source": SOURCE, "title": "béta ⚡ 名前"},
        {
            "source": SOURCE,
            "title": "gamma",
            "url": "https://example.com/g",
            "effect": {"type": "open", "url": "https://example.com/g"},
        },
    ]


def answer(title, subtitle=None):
    out = {"title": title}
    if subtitle is not None:
        out["subtitle"] = subtitle
    out["effect"] = {"type": "copy_text", "text": title}
    return out


def on_start():
    if conformance_config().get("skip_publish") is True:
        return
    plugin.publish(catalog())


def on_event(name, payload):
    global last_event
    last_event = name


def on_evaluate(params):
    query = params.get("query") or ""
    if query == "conf:one":
        return [answer("one", "s")]
    if query == "conf:unicode":
        return [answer("héllo ⚡ 世界")]
    if query == "conf:many":
        return [answer(f"a{i}") for i in range(1, 18)]
    return []


def on_search(params):
    query = params.get("query") or ""
    return [row for row in catalog() if query in row["title"]]


def on_hints(params):
    return [
        {
            "id": "t1",
            "frame": {"x": -10.5, "y": 20, "width": 30, "height": 40},
            "role": "AXLink",
            "label": "one",
        },
        {
            "id": "t2",
            "frame": {"x": 0, "y": 0, "width": 10, "height": 10},
            "role": "FlashTerminalLink",
            "label": "two",
        },
    ]


def on_resolve(params):
    row = params.get("row") or {}
    if row.get("title") == "alpha":
        return ok(target_pid=TARGET_PID)
    return unhandled()


def on_action(params):
    name = params.get("name") or ""
    if name == "conf_performed":
        return ok(target_pid=TARGET_PID)
    if name == "conf_failed":
        return fail("conformance failure probe")
    return unhandled()


def on_navigate(params):
    if params.get("url") == "conformance://ok":
        return ok()
    return unhandled()


# subcommand -> (host method, params builder over args)
HOST_ARMS = {
    "ping": ("host.ping", lambda args: {}),
    "fetch": ("host.fetch", lambda args: {"url": arg(args, 0)}),
    "open": ("host.open", lambda args: {"url": arg(args, 0)}),
    "clipboard": ("host.clipboard_write", lambda args: {"text": arg(args, 0)}),
    "notify": ("host.notify", lambda args: {"message": arg(args, 0)}),
    "storage-set": ("host.storage_set", lambda args: {"key": arg(args, 0), "value": arg(args, 1)}),
    "storage-get": ("host.storage_get", lambda args: {"key": arg(args, 0)}),
    "media": ("host.post_media_key", lambda args: {"key_code": int_arg(args, 0, 16)}),
    "ps": ("host.process_table", lambda args: {}),
    "signal": ("host.signal", lambda args: {"pid": int_arg(args, 0, TARGET_PID)}),
    "keys": (
        "host.post_keys",
        lambda args: {"pid": TARGET_PID, "keys": [{"key_code": 4, "modifiers": ["command"]}]},
    ),
    "global-key": ("host.post_global_key", lambda args: {"key_code": 4, "modifiers": ["command"]}),
    "ax-snapshot": ("host.ax_snapshot", lambda args: {"pid": TARGET_PID, "roots": "app"}),
    "activate": ("host.activate", lambda args: {"pid": TARGET_PID}),
    "normal-mode-target": ("host.normal_mode_target", lambda args: {}),
}


def arg(args, index, default=""):
    return args[index] if index < len(args) else default


def int_arg(args, index, default):
    try:
        return int(arg(args, index))
    except ValueError:
        return default


def on_command(params):
    subcommand = params.get("subcommand") or ""
    args = [str(a) for a in params.get("args") or []]
    if subcommand == "echo":
        return ok(message=j({"args": args, "raw": params.get("raw") or ""}))
    if subcommand == "env":
        return ok(message=j(dict(os.environ)))
    if subcommand == "env-has":
        return ok(message="present" if arg(args, 0) in os.environ else "absent")
    if subcommand == "config":
        return ok(message=j(config()))
    if subcommand == "state":
        return ok(message=last_event)
    if subcommand == "target-pid":
        return ok(target_pid=TARGET_PID)
    if subcommand == "toast":
        return ok(message="hello from conformance")
    if subcommand == "sleep":
        time.sleep(int_arg(args, 0, 0) / 1000.0)
        return ok()
    if subcommand == "crash":
        os._exit(int_arg(args, 0, 1))
    if subcommand == "exit-after-reply":
        threading.Timer(0.25, os._exit, args=(int_arg(args, 0, 0),)).start()
        return ok()
    if subcommand == "stderr":
        sys.stderr.write("x" * (int_arg(args, 0, 0) * 1024))
        sys.stderr.flush()
        return ok()
    if subcommand == "log":
        plugin.log(arg(args, 0, "info"), " ".join(args[1:]))
        return ok()
    if subcommand == "status":
        plugin.status({arg(args, 0): arg(args, 1)})
        return ok()
    if subcommand == "publish-extra":
        plugin.publish(catalog() + [{"source": SOURCE, "title": "delta"}])
        return ok()
    if subcommand in HOST_ARMS:
        method, build = HOST_ARMS[subcommand]
        return ok(message=j(plugin.call_host(method, build(args))))
    return fail(f"unsupported subcommand: {subcommand}")


if __name__ == "__main__":
    plugin.serve(
        on_start=on_start,
        on_event=on_event,
        on_evaluate=on_evaluate,
        on_search=on_search,
        on_hints=on_hints,
        on_resolve=on_resolve,
        on_command=on_command,
        on_action=on_action,
        on_navigate=on_navigate,
        on_shutdown=lambda: plugin.log("info", "conformance shutdown"),
    )
