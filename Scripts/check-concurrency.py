#!/usr/bin/env python3
"""Hold the `flash` module's data-race diagnostics to a count that only falls.

`FlashCore`, `FlashProviders` and `FlashTerminal` compile under complete
concurrency checking (Package.swift). `flash` compiles under targeted checking
only: this rebuilds it with `-strict-concurrency=complete`, counts the
diagnostics the compiler raises in `Sources/flash`, and compares the total
with the committed baseline (Scripts/concurrency-baseline.txt, one
`count<TAB>file` line per file).

- A higher total fails and lists the files that rose.
- A lower total fails too, asking for `--write`: the gain is recorded so the
  next change cannot spend it.
- The per-file counts only say where to look: code that moves between files
  with the same total passes.

The build goes to its own scratch directory (build/concurrency), so it never
invalidates `.build`. A diagnostic prints only when its file compiles, so the
build products there are removed first and every run compiles from clean; the
dependency checkouts stay.

Swift 6.3 sometimes crashes in its `SendNonSendable` pass under complete
checking, in a different function each time. A build that ends that way is
resumed, not restarted: the files already compiled have printed their
diagnostics, and the rest print theirs on the next attempt.

Standard library only; runs under `python3 -I`.

Usage:
  check-concurrency.py [--write]
"""

import collections
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRATCH = ROOT / "build" / "concurrency"
BASELINE = ROOT / "Scripts" / "concurrency-baseline.txt"
MODE = "complete"
# What SwiftPM fetched, kept across runs; everything else is a build product.
FETCHED = {"artifacts", "checkouts", "repositories", "workspace-state.json"}
ATTEMPTS = 4
COMPILER_CRASH = "failed due to signal"
DIAGNOSTIC = re.compile(r"^/.*?/(Sources/flash/[^:]+):(\d+):(\d+): warning: (.*)$")
HEADER = (
    f"# flash under -strict-concurrency={MODE}: diagnostics per file.\n"
    "# Written by `mise run check:concurrency -- --write`; never edited by hand.\n"
)


def diagnostics(output):
    """The distinct diagnostics in a build log, as a count per source file.

    The compiler repeats a diagnostic for every job that type-checks its
    file, so the same location and message count once.
    """
    seen = set()
    for line in output.splitlines():
        match = DIAGNOSTIC.match(line)
        if match:
            seen.add(match.groups())
    return collections.Counter(path for path, _, _, _ in seen)


def read_baseline(text):
    counts = collections.Counter()
    for number, line in enumerate(text.splitlines(), start=1):
        if not line or line.startswith("#"):
            continue
        count, separator, path = line.partition("\t")
        if not separator or not count.isdigit() or not path:
            raise ValueError(f"{BASELINE.name}:{number}: expected '<count>\\t<file>'")
        counts[path] = int(count)
    return counts


def write_baseline(counts):
    rows = "".join(f"{counts[path]}\t{path}\n" for path in sorted(counts))
    BASELINE.write_text(HEADER + rows)


def changes(before, after):
    """The files whose count moved, as (path, before, after), largest rise first."""
    moved = [
        (path, before[path], after[path])
        for path in set(before) | set(after)
        if before[path] != after[path]
    ]
    return sorted(moved, key=lambda row: (row[1] - row[2], row[0]))


def build():
    for entry in SCRATCH.glob("*"):
        if entry.name in FETCHED:
            continue
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry)
        else:
            entry.unlink()
    command = [
        "swift", "build", "--force-resolved-versions",
        "--scratch-path", str(SCRATCH), "--target", "flash",
        "-Xswiftc", f"-strict-concurrency={MODE}",
        "-Xswiftc", "-no-warnings-as-errors",
    ]  # fmt: skip
    output = ""
    for attempt in range(1, ATTEMPTS + 1):
        result = subprocess.run(
            command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        output += result.stdout
        if result.returncode == 0:
            return output
        if COMPILER_CRASH not in result.stdout or attempt == ATTEMPTS:
            break
        print(f"check-concurrency: the compiler crashed; resuming (attempt {attempt + 1})")
    errors = [line for line in result.stdout.splitlines() if "error:" in line]
    print("\n".join(errors[:40] or result.stdout.splitlines()[-40:]))
    sys.exit(f"check-concurrency: the build failed ({result.returncode})")


def main(arguments):
    if arguments not in ([], ["--write"]):
        sys.exit("Usage: check-concurrency.py [--write]")
    after = diagnostics(build())
    total = sum(after.values())
    if arguments == ["--write"]:
        write_baseline(after)
        print(f"check-concurrency: recorded {total} diagnostics in {len(after)} files")
        return
    try:
        before = read_baseline(BASELINE.read_text())
    except (OSError, ValueError) as error:
        sys.exit(f"check-concurrency: {error}")
    recorded = sum(before.values())
    if total == recorded:
        print(f"check-concurrency: {total} diagnostics, as recorded")
        return
    for path, was, now in changes(before, after):
        print(f"  {was:>4} -> {now:<4} {path}")
    if total > recorded:
        sys.exit(
            f"check-concurrency: {total} diagnostics, {total - recorded} more than the "
            f"{recorded} recorded. Fix the new ones: the count only falls."
        )
    sys.exit(
        f"check-concurrency: {total} diagnostics, {recorded - total} fewer than the "
        f"{recorded} recorded. Record the gain: mise run check:concurrency -- --write"
    )


if __name__ == "__main__":
    main(sys.argv[1:])
