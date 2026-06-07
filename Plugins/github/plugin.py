#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))
from flash_plugin import FlashPlugin, cli_action


def gh(args):
    return ["gh", *args]


def issues(args):
    if args:
        return gh(["issue", "list", *args])
    return gh(["issue", "list", "--json", "number,title,state,url", "--limit", "20"])


def prs(args):
    if args:
        return gh(["pr", "list", *args])
    return gh(["pr", "list", "--json", "number,title,state,url", "--limit", "20"])


ACTIONS = {
    "login": cli_action(lambda args: gh(["auth", "login", "--web"]), timeout=300),
    "status": cli_action(lambda args: gh(["auth", "status"])),
    "issues": cli_action(issues),
    "prs": cli_action(prs),
    "run": cli_action(gh),
}


if __name__ == "__main__":
    FlashPlugin("github", ACTIONS).serve()
