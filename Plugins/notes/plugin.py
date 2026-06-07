#!/usr/bin/env python3
"""Notes plugin — surfaces macOS Notes entries in flashlight."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))
from flash_plugin import FlashPlugin  # noqa: E402

PLUGIN_ID = "notes"
SOURCE_ID = f"plugin.{PLUGIN_ID}"

# Notes' AppleScript exposes `every note` against the default account.
# Multi-account setups iterate accounts to avoid missing notes that
# live outside the iCloud default. ID is captured so the resolve path
# can re-open the exact note even when titles collide.
LIST_SCRIPT = """
tell application "Notes"
  if not (running) then return ""
  set output to {}
  repeat with acc in accounts
    try
      repeat with n in notes of acc
        set the end of output to ((id of n as text) & tab & (name of n as text))
      end repeat
    end try
  end repeat
  set AppleScript's text item delimiters to linefeed
  return output as text
end tell
"""

SELECT_SCRIPT_TEMPLATE = """
tell application "Notes"
  activate
  try
    show note id {note_id}
  end try
end tell
"""


def applescript_quote(value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def list_notes(plugin):
    result = plugin.run_cli(["/usr/bin/osascript", "-e", LIST_SCRIPT], timeout=30)
    if not result["ok"]:
        plugin.log("warn", f"[notes] list failed: {result['stderr']}")
        return []
    notes = []
    for line in result["stdout"].splitlines():
        line = line.strip()
        if not line or "\t" not in line:
            continue
        note_id, title = line.split("\t", 1)
        note_id = note_id.strip()
        title = title.strip()
        if not note_id or not title:
            continue
        notes.append({"id": note_id, "title": title})
    return notes


def emit_candidates(plugin):
    notes = list_notes(plugin)
    candidates = []
    seen = set()
    for note in notes:
        key = note["id"]
        if key in seen:
            continue
        seen.add(key)
        candidates.append({
            "kind": "note",
            "source_id": SOURCE_ID,
            "source": PLUGIN_ID,
            "name": note["title"],
            "subtitle": "Note",
            "payload": json.dumps(note),
        })
    plugin.emit_snapshot(candidates=candidates, source_id=SOURCE_ID)


def open_notes_app(plugin, args):
    return plugin.run_cli(["/usr/bin/open", "-b", "com.apple.Notes"], timeout=10)


def refresh_action(plugin, args):
    plugin.run_in_background(emit_candidates, plugin)
    return {"ok": True, "stdout": "notes refresh queued", "stderr": "", "status": 0}


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
    note_id = payload.get("id")
    if not note_id:
        return {"did_resolve": False}
    script = SELECT_SCRIPT_TEMPLATE.format(note_id=applescript_quote(note_id))
    proc = _plugin.run_cli(["/usr/bin/osascript", "-e", script], timeout=10)
    return {"did_resolve": bool(proc["ok"])}


ACTIONS = {
    "open": lambda plugin, args, params: open_notes_app(plugin, args),
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
