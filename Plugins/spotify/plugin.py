#!/usr/bin/env python3
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))
from flash_plugin import FlashPlugin, cli_action


DATA_DIR = Path(os.environ["FLASH_PLUGIN_DATA_DIR"])
SPOTIFY_CONFIG = DATA_DIR / "config" / "spotify-player"
SPOTIFY_CACHE = DATA_DIR / "cache" / "spotify-player"


def spotify(args):
    SPOTIFY_CONFIG.mkdir(parents=True, exist_ok=True)
    SPOTIFY_CACHE.mkdir(parents=True, exist_ok=True)
    return [
        "spotify_player",
        "--config-folder",
        str(SPOTIFY_CONFIG),
        "--cache-folder",
        str(SPOTIFY_CACHE),
        *args,
    ]


def search(args):
    return spotify(["search", " ".join(args)])


ACTIONS = {
    "login": cli_action(lambda args: spotify(["authenticate"]), timeout=300),
    "status": cli_action(lambda args: spotify(["--version"])),
    "pause": cli_action(lambda args: spotify(["playback", "pause"])),
    "play": cli_action(lambda args: spotify(["playback", "play"])),
    "toggle": cli_action(lambda args: spotify(["playback", "play-pause"])),
    "next": cli_action(lambda args: spotify(["playback", "next"])),
    "previous": cli_action(lambda args: spotify(["playback", "previous"])),
    "search": cli_action(search),
    "run": cli_action(spotify),
}


if __name__ == "__main__":
    FlashPlugin("spotify", ACTIONS).serve()
