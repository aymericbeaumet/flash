#!/usr/bin/env python3
"""World-clock query evaluator, in Python (one of the deliberately non-Rust
official plugins exercising the language-agnostic wire protocol; see
docs/plugin-protocol.md and AGENTS.md — Rust stays the default).

Additive evaluator for `time`, `time <place>`, and `time in <place>`: bare
`time` answers with the local and UTC clocks, a place resolves against the
IANA zone names (`tokyo`, `new york`, `america/new_york`, …). Every ZoneInfo
is constructed once at startup so query evaluation is pure in-memory
arithmetic — the evaluator contract bans I/O on the query path.
"""
import os
import sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo, available_timezones

sys.dont_write_bytecode = True  # never litter the (signed) bundle with .pyc
sys.path.insert(
    0,
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "_python_flash_plugin"),
)
from flashplugin import Plugin

MAX_ANSWERS = 4

plugin = Plugin()

# alias (lowercase, spaces) -> canonical zone name. Built once at startup;
# the city tail ("new york") and the full path ("america/new_york") both
# resolve. First zone wins a duplicate city name (sorted order keeps the
# common America/... spellings ahead of the exotic ones).
ALIASES = {}
ZONES = {}
for zone_name in sorted(available_timezones()):
    if zone_name.startswith(("Etc/", "SystemV/")) and zone_name != "Etc/UTC":
        continue  # offset aliases add noise, not places
    ZONES[zone_name] = ZoneInfo(zone_name)
    full = zone_name.lower().replace("_", " ")
    city = full.rsplit("/", 1)[-1]
    for alias in (full, city):
        ALIASES.setdefault(alias, zone_name)
ALIASES.setdefault("utc", "Etc/UTC")


def answer(now, label, tz):
    local = now.astimezone(tz)
    offset = local.strftime("%z")  # "+0200"
    title = f"{local.strftime('%H:%M %a')} — {label}"
    return {
        "title": title,
        "subtitle": f"UTC{offset[:3]}:{offset[3:]}",
        "effect": {"type": "copy_text", "text": title},
    }


def matches(place):
    """Zone names whose alias exactly equals or prefixes `place`, exact first."""
    exact = [zone for alias, zone in ALIASES.items() if alias == place]
    prefixed = [
        zone
        for alias, zone in sorted(ALIASES.items())
        if alias.startswith(place) and alias != place
    ]
    seen = set()
    return [z for z in exact + prefixed if not (z in seen or seen.add(z))]


def on_query(params):
    query = params.get("query", "").strip().lower()
    if query != "time" and not query.startswith(("time ", "time in ")):
        return []
    place = query[len("time"):].strip()
    if place.startswith("in "):
        place = place[len("in "):].strip()
    now = datetime.now(timezone.utc)
    if not place:
        local = datetime.now().astimezone().tzinfo
        return [answer(now, "local", local), answer(now, "Etc/UTC", ZONES["Etc/UTC"])]
    if len(place) < 2:
        return []
    return [answer(now, zone, ZONES[zone]) for zone in matches(place)[:MAX_ANSWERS]]


if __name__ == "__main__":
    plugin.log("info", f"[timezones] zone index warmed count={len(ZONES)}")
    plugin.serve(on_query=on_query)
