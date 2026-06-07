#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))
from flash_plugin import FlashPlugin, cli_action


def slack(args):
    return ["slack", *args]


ACTIONS = {
    "login": cli_action(lambda args: slack(["login"]), timeout=300),
    "version": cli_action(lambda args: slack(["version"])),
    "run": cli_action(slack),
}


if __name__ == "__main__":
    FlashPlugin("slack", ACTIONS).serve()
