#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))
from flash_plugin import FlashPlugin, cli_action


def linear(args):
    return ["linear", *args]


def query(args):
    if args:
        return linear(["issue", "query", "--search", " ".join(args), "--json"])
    return linear(["issue", "query", "--all-teams", "--json", "--limit", "20"])


ACTIONS = {
    "login": cli_action(lambda args: linear(["auth", "login"]), timeout=300),
    "mine": cli_action(lambda args: linear(["issue", "mine", *args])),
    "query": cli_action(query),
    "start": cli_action(lambda args: linear(["issue", "start", *args]), timeout=300),
    "view": cli_action(lambda args: linear(["issue", "view", *args])),
    "pr": cli_action(lambda args: linear(["issue", "pr", *args]), timeout=300),
    "create": cli_action(lambda args: linear(["issue", "create", *args]), timeout=300),
    "run": cli_action(linear),
}


if __name__ == "__main__":
    FlashPlugin("linear", ACTIONS).serve()
