#!/usr/bin/env python3
"""Contacts plugin — surfaces macOS Address Book entries in flashlight.

Reads contacts via `osascript` against the running Contacts.app the
first time the plugin starts and again whenever flash forwards a
`focus.changed` event tied to the Contacts bundle. Activating a
candidate opens Contacts.app and selects the picked person.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))
from flash_plugin import FlashPlugin  # noqa: E402

PLUGIN_ID = "contacts"
SOURCE_ID = f"plugin.{PLUGIN_ID}"

LIST_SCRIPT = """
on safeName(p)
  try
    set n to name of p
    if n is missing value then return ""
    return n
  on error
    return ""
  end try
end safeName

tell application "Contacts"
  if not (running) then return ""
  set acc to {}
  repeat with p in people
    set n to my safeName(p)
    if n is not "" then set end of acc to n
  end repeat
  set AppleScript's text item delimiters to linefeed
  return acc as text
end tell
"""

SELECT_SCRIPT_TEMPLATE = """
tell application "Contacts"
  activate
  set candidates to every person whose name is {name}
  if (count of candidates) > 0 then
    set the selection to (item 1 of candidates)
  end if
end tell
"""


def applescript_quote(value):
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def list_contacts(plugin):
    result = plugin.run_cli(["/usr/bin/osascript", "-e", LIST_SCRIPT], timeout=30)
    if not result["ok"]:
        plugin.log("warn", f"[contacts] list failed: {result['stderr']}")
        return []
    return [line.strip() for line in result["stdout"].splitlines() if line.strip()]


def emit_candidates(plugin):
    names = list_contacts(plugin)
    candidates = []
    seen = set()
    for name in names:
        if name in seen:
            continue
        seen.add(name)
        candidates.append({
            "kind": "contact",
            "source_id": SOURCE_ID,
            "source": PLUGIN_ID,
            "name": name,
            "subtitle": "Contact",
            "payload": json.dumps({"contact": name}),
        })
    plugin.emit_snapshot(candidates=candidates, source_id=SOURCE_ID)


def open_contacts_app(plugin, args):
    return plugin.run_cli(["/usr/bin/open", "-b", "com.apple.AddressBook"], timeout=10)


def refresh_action(plugin, args):
    plugin.run_in_background(emit_candidates, plugin)
    return {"ok": True, "stdout": "contacts refresh queued", "stderr": "", "status": 0}


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
    name = payload.get("contact") or candidate.get("name") or ""
    if not name:
        return {"did_resolve": False}
    script = SELECT_SCRIPT_TEMPLATE.format(name=applescript_quote(name))
    proc = _plugin.run_cli(["/usr/bin/osascript", "-e", script], timeout=10)
    return {"did_resolve": bool(proc["ok"])}


ACTIONS = {
    "open": lambda plugin, args, params: open_contacts_app(plugin, args),
    "refresh": lambda plugin, args, params: refresh_action(plugin, args),
}


def main():
    plugin = FlashPlugin(PLUGIN_ID, ACTIONS)

    def on_event(_plugin, name, _payload):
        if name in ("flash.started", "apps.launched", "config.changed"):
            plugin.run_in_background(emit_candidates, plugin)

    plugin.on_event = on_event
    plugin.on_resolve_candidate = resolve_candidate
    # osascript on Contacts can block for several seconds on first
    # launch; running on a worker keeps the serve loop's heartbeats
    # responsive.
    plugin.run_in_background(emit_candidates, plugin)
    plugin.serve()


if __name__ == "__main__":
    main()
