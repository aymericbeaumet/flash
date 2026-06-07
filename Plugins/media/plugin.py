#!/usr/bin/env python3
"""Media plugin — posts macOS system media key events so any
media-aware app responds: Firefox+YouTube, Safari+Netflix, Spotify,
Music, Podcasts, TV, etc. Falls back to per-app AppleScript when
PyObjC isn't available (e.g., a Homebrew Python without it).
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))
from flash_plugin import FlashPlugin  # noqa: E402


# NSSystemDefined media key codes. Documented in IOKit's
# IOHIDUsageTables.h under NX_KEYTYPE_*. Posting these as
# NSSystemDefined events makes the system route the command to
# whichever app currently owns media playback — same path used by the
# F8/F9/F10 keys on Apple keyboards.
NX_KEYTYPE_PLAY = 16
NX_KEYTYPE_NEXT = 17
NX_KEYTYPE_PREVIOUS = 18
NX_KEYTYPE_FAST = 19
NX_KEYTYPE_REWIND = 20


def _try_post_media_key(key_code):
    try:
        from AppKit import NSEvent, NSSystemDefined  # type: ignore
        from Quartz import CGEventPost, kCGHIDEventTap  # type: ignore
    except Exception:
        return False
    for state in (0x0A, 0x0B):  # NX_KEYDOWN, NX_KEYUP
        data1 = (key_code << 16) | (state << 8)
        event = NSEvent.otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2_(
            NSSystemDefined,
            (0, 0),
            0xA00,
            0,
            0,
            None,
            8,  # NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1,
            -1,
        )
        if event is None:
            return False
        CGEventPost(kCGHIDEventTap, event.CGEvent())
    return True


VOLUME_STEP = 10  # percent

# AppleScript fallback targets — used only for the now-playing
# query/status actions and when PyObjC isn't available.
PLAYERS = [
    {"name": "Spotify", "bundle": "com.spotify.client", "has_artist": True},
    {"name": "Music", "bundle": "com.apple.Music", "has_artist": True},
    {"name": "TV", "bundle": "com.apple.TV", "has_artist": False},
    {"name": "Podcasts", "bundle": "com.apple.podcasts", "has_artist": False},
]


def osascript(plugin, source, timeout=10):
    return plugin.run_cli(["/usr/bin/osascript", "-e", source], timeout=timeout)


def app_running(plugin, app_name):
    result = osascript(
        plugin,
        f'tell application "System Events" to (name of processes) contains "{app_name}"',
    )
    return result["ok"] and result["stdout"].strip().lower() == "true"


def app_state(plugin, app_name):
    if not app_running(plugin, app_name):
        return None
    result = osascript(plugin, f'tell application "{app_name}" to player state as text')
    if not result["ok"]:
        return None
    return result["stdout"].strip().lower() or None


def pick_player(plugin, prefer_playing=True):
    running = [p for p in PLAYERS if app_running(plugin, p["name"])]
    if prefer_playing:
        for player in running:
            if app_state(plugin, player["name"]) == "playing":
                return player
    return running[0] if running else None


def applescript_command(plugin, command, *, prefer_playing=True):
    player = pick_player(plugin, prefer_playing=prefer_playing)
    if player is None:
        return {
            "ok": False,
            "stdout": "",
            "stderr": "no supported media app is running",
            "status": 1,
        }
    result = osascript(plugin, f'tell application "{player["name"]}" to {command}')
    if result["ok"] and not result["stdout"].strip():
        result["stdout"] = f"{player['name']}: {command}"
    return result


def media_action(plugin, key_code, applescript_fallback):
    if _try_post_media_key(key_code):
        return {"ok": True, "stdout": "", "stderr": "", "status": 0}
    return applescript_command(plugin, applescript_fallback)


def play(plugin, args):
    return media_action(plugin, NX_KEYTYPE_PLAY, "play")


def pause(plugin, args):
    return media_action(plugin, NX_KEYTYPE_PLAY, "pause")


def toggle(plugin, args):
    return media_action(plugin, NX_KEYTYPE_PLAY, "playpause")


def next_track(plugin, args):
    return media_action(plugin, NX_KEYTYPE_NEXT, "next track")


def previous_track(plugin, args):
    return media_action(plugin, NX_KEYTYPE_PREVIOUS, "previous track")


def volume_up(plugin, args):
    return osascript(
        plugin,
        f"set volume output volume "
        f"((output volume of (get volume settings)) + {VOLUME_STEP})",
    )


def volume_down(plugin, args):
    return osascript(
        plugin,
        f"set volume output volume "
        f"(((output volume of (get volume settings)) - {VOLUME_STEP}) max 0)",
    )


def mute(plugin, args):
    return osascript(
        plugin,
        "set volume output muted (not output muted of (get volume settings))",
    )


def get_current(plugin, args):
    player = pick_player(plugin, prefer_playing=True)
    if player is None:
        return {
            "ok": False,
            "stdout": "",
            "stderr": "no supported media app is running",
            "status": 1,
        }
    state = app_state(plugin, player["name"]) or "unknown"
    fields = ["name of current track as text"]
    if player["has_artist"]:
        fields.append("artist of current track as text")
    joiner = ' & " — " & '
    app_name = player["name"]
    script = (
        f'tell application "{app_name}"\n'
        "  try\n"
        f"    return {joiner.join(fields)}\n"
        "  on error\n"
        '    return ""\n'
        "  end try\n"
        "end tell"
    )
    result = osascript(plugin, script)
    track = result["stdout"].strip() if result["ok"] else ""
    summary = f"{player['name']} [{state}]"
    if track:
        summary = f"{summary}: {track}"
    return {"ok": True, "stdout": summary, "stderr": "", "status": 0}


def status(plugin, args):
    lines = []
    for player in PLAYERS:
        state = (
            app_state(plugin, player["name"])
            if app_running(plugin, player["name"])
            else "not running"
        )
        lines.append(f"{player['name']}: {state or 'unknown'}")
    vol = osascript(plugin, "output volume of (get volume settings)")
    muted = osascript(plugin, "output muted of (get volume settings)")
    if vol["ok"]:
        muted_flag = muted["stdout"].strip().lower() == "true" if muted["ok"] else False
        lines.append(f"volume: {vol['stdout'].strip()}%{' (muted)' if muted_flag else ''}")
    return {"ok": True, "stdout": "\n".join(lines), "stderr": "", "status": 0}


ACTIONS = {
    "play": lambda plugin, args, params: play(plugin, args),
    "pause": lambda plugin, args, params: pause(plugin, args),
    "toggle": lambda plugin, args, params: toggle(plugin, args),
    "next": lambda plugin, args, params: next_track(plugin, args),
    "previous": lambda plugin, args, params: previous_track(plugin, args),
    "volumeup": lambda plugin, args, params: volume_up(plugin, args),
    "volumedown": lambda plugin, args, params: volume_down(plugin, args),
    "mute": lambda plugin, args, params: mute(plugin, args),
    "get": lambda plugin, args, params: get_current(plugin, args),
    "status": lambda plugin, args, params: status(plugin, args),
    "run": lambda plugin, args, params: plugin.run_cli(["/usr/bin/osascript", *args]),
}


if __name__ == "__main__":
    FlashPlugin("media", ACTIONS).serve()
