#!/usr/bin/env python3
"""Record tmux 3.7b format results using a disposable, explicitly named server."""

import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true", help="update the checked-in expected results")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    corpus_path = root / "Tests/StatusFormatFixtures/tmux-3.7b.json"
    corpus = json.loads(corpus_path.read_text())
    env = dict(os.environ, LC_ALL="en_US.UTF-8", TZ="UTC")
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)
    pinned = root / "build/tmux-oracle/bin/tmux"
    executable = os.environ.get("TMUX_ORACLE", str(pinned) if pinned.exists() else "tmux")
    if os.environ.get("FLASH_REQUIRE_TMUX_ORACLE") == "1":
        stamp = Path(executable).resolve().parent.parent / ".flash-build"
        expected = f"3.7b-2.11.3-{platform.machine()}"
        if not stamp.exists() or stamp.read_text().strip() != expected:
            raise SystemExit(f"Expected pinned tmux/Unicode oracle {expected}; run Scripts/build-tmux-oracle.sh")
    version = subprocess.check_output([executable, "-V"], env=env, text=True).strip()
    if version != "tmux 3.7b":
        raise SystemExit(f"Expected tmux 3.7b, found {version}")
    socket = "flash-format-oracle-" + uuid.uuid4().hex
    command = [executable, "-L", socket, "-f", "/dev/null"]

    def tmux(*argv):
        return subprocess.check_output(command + list(argv), env=env, text=True)

    try:
        tmux("new-session", "-d", "-s", "oracle", "exec sleep 120")
        previous = set()
        for case in corpus:
            options = case.get("options", {})
            for key in previous - options.keys():
                tmux("set-option", "-gu", key)
            for key, value in options.items():
                tmux("set-option", "-g", key, value)
            previous = set(options)
            output = tmux("display-message", "-p", case["format"]).removesuffix("\n")
            if args.record:
                case["expected"] = output
            elif output != case.get("expected"):
                raise SystemExit(f"Oracle drift for {case['format']!r}: {output!r} != {case.get('expected')!r}")
    finally:
        subprocess.run(command + ["kill-server"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if args.record:
        corpus_path.write_text(json.dumps(corpus, ensure_ascii=False, indent=2) + "\n")
    print(f"Verified {len(corpus)} formats against {version} on an isolated socket")


if __name__ == "__main__":
    main()
