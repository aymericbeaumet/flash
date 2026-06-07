#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))
from flash_plugin import FlashPlugin, cli_action


def ntn(args):
    return ["ntn", *args]


ACTIONS = {
    "login": cli_action(lambda args: ntn(["login"]), timeout=300),
    "version": cli_action(lambda args: ntn(["--version"])),
    "api": cli_action(lambda args: ntn(["api", *args])),
    "workers": cli_action(lambda args: ntn(["workers", *args])),
    "run": cli_action(ntn),
}


if __name__ == "__main__":
    FlashPlugin("notion", ACTIONS).serve()
