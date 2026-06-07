#!/usr/bin/env python3
"""Reminders plugin — surfaces uncompleted macOS Reminders entries in flashlight."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))
from flash_plugin import FlashPlugin  # noqa: E402

PLUGIN_ID = "reminders"
SOURCE_ID = f"plugin.{PLUGIN_ID}"

# Only uncompleted reminders are surfaced — completed ones generally
# aren't actionable from a quick-launch context. Each row is
# `id<TAB>list<TAB>title` so resolve can locate the source list.
LIST_SCRIPT = """
tell application "Reminders"
  if not (running) then return ""
  set output to {}
  repeat with l in lists
    try
      repeat with r in (reminders of l whose completed is false)
        set the end of output to ((id of r as text) & tab & (name of l as text) & tab & (name of r as text))
      end repeat
    end try
  end repeat
  set AppleScript's text item delimiters to linefeed
  return output as text
end tell
"""

SELECT_SCRIPT_TEMPLATE = """
tell application "Reminders"
  activate
  try
    show reminder id {reminder_id}
  end try
end tell
"""


def applescript_quote(value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def list_reminders(plugin):
    result = plugin.run_cli(["/usr/bin/osascript", "-e", LIST_SCRIPT], timeout=30)
    if not result["ok"]:
        plugin.log("warn", f"[reminders] list failed: {result['stderr']}")
        return []
    reminders = []
    for line in result["stdout"].splitlines():
        line = line.strip()
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        rid, list_name, title = (p.strip() for p in parts)
        if not rid or not title:
            continue
        reminders.append({"id": rid, "list": list_name, "title": title})
    return reminders


def emit_candidates(plugin):
    items = list_reminders(plugin)
    candidates = []
    seen = set()
    for item in items:
        key = item["id"]
        if key in seen:
            continue
        seen.add(key)
        candidates.append({
            "kind": "reminder",
            "source_id": SOURCE_ID,
            "source": PLUGIN_ID,
            "name": item["title"],
            "subtitle": f"Reminder — {item['list']}",
            "payload": json.dumps(item),
        })
    plugin.emit_snapshot(candidates=candidates, source_id=SOURCE_ID)


def open_reminders_app(plugin, args):
    return plugin.run_cli(["/usr/bin/open", "-b", "com.apple.reminders"], timeout=10)


def refresh_action(plugin, args):
    plugin.run_in_background(emit_candidates, plugin)
    return {"ok": True, "stdout": "reminders refresh queued", "stderr": "", "status": 0}


def resolve_candidate(_plugin, candidate):
    raw = candidate.get("payload")
    payload = {}
    if isinstance(raw, str):
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {}
    elif isinstance(raw, dict):
        payload = raw
    rid = payload.get("id")
    if not rid:
        return {"did_resolve": False}
    script = SELECT_SCRIPT_TEMPLATE.format(reminder_id=applescript_quote(rid))
    proc = _plugin.run_cli(["/usr/bin/osascript", "-e", script], timeout=10)
    return {"did_resolve": bool(proc["ok"])}


ACTIONS = {
    "open": lambda plugin, args, params: open_reminders_app(plugin, args),
    "refresh": lambda plugin, args, params: refresh_action(plugin, args),
}


def main():
    plugin = FlashPlugin(PLUGIN_ID, ACTIONS)

    def on_event(_plugin, name, _payload):
        if name in ("flash.started", "apps.launched", "config.changed"):
            plugin.run_in_background(emit_candidates, plugin)

    plugin.on_event = on_event
    plugin.on_resolve_candidate = resolve_candidate
    plugin.run_in_background(emit_candidates, plugin)
    plugin.serve()


if __name__ == "__main__":
    main()
