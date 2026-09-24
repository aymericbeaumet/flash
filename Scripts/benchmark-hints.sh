#!/usr/bin/env bash
set -euo pipefail

# Time how long the installed Flash resident takes to show hints, per app
# class, and print p50/p95/max. See docs/performance.md for the method.
#
# Each class reuses its integration script's setup (build, sign and install
# the oracle and fixture) and runs the oracle in bench mode: bring the fixture
# forward, post the trigger, wait for hints through the debug inspector's
# /state, dismiss them, repeat. Flash logs one `[latency] hints_visible` line
# per activation; this script reads them from ~/Library/Logs/Flash/flash.log*
# by trace id, within the window each oracle measured.
#
# Usage:
#   ./Scripts/benchmark-hints.sh [--runs=N] [--class=native|browser|electron|all]
#                                [--trigger=key|cli] [--skip-npm-ci]
#                                [--large-table=ROWS]
#
#   --runs=N        measured activations per class (default 30), after two
#                   unmeasured warm-up runs
#   --class=...     which fixtures to measure (default all)
#   --trigger=key   press f in NORMAL (default; needs advanced mode), or
#   --trigger=cli   run `flash mouse_target`
#   --skip-npm-ci   reuse the Electron fixture's installed dependencies
#   --large-table=ROWS  native only: time the fixture's ROWS-row table window
#                   instead of its control window
#
# Requirements: an installed resident (Scripts/install.sh --dev), the debug
# inspector enabled ([debug] http_inspector_enabled = true, or run :logs once),
# an unlocked console session, and the integration scripts' own requirements
# (the "Flash Dev" signing identity, Firefox for browser, npm for electron).
# Leave the keyboard and mouse alone while it runs.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

RUNS=30
CLASS=all
TRIGGER=key
SKIP_NPM_CI=0
LARGE_TABLE=
for arg in "$@"; do
  case "$arg" in
    --runs=*) RUNS="${arg#--runs=}" ;;
    --class=*) CLASS="${arg#--class=}" ;;
    --trigger=*) TRIGGER="${arg#--trigger=}" ;;
    --skip-npm-ci) SKIP_NPM_CI=1 ;;
    --large-table=*) LARGE_TABLE="${arg#--large-table=}" ;;
    -h | --help)
      sed -n '4,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg (see --help)" >&2
      exit 2
      ;;
  esac
done

if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "--runs must be a positive integer" >&2
  exit 2
fi
if [[ -n "$LARGE_TABLE" ]] && ! [[ "$LARGE_TABLE" =~ ^[1-9][0-9]*$ ]]; then
  echo "--large-table must be a positive integer" >&2
  exit 2
fi
case "$CLASS" in
  all) CLASSES=(native browser electron) ;;
  native | browser | electron) CLASSES=("$CLASS") ;;
  *)
    echo "--class must be native, browser, electron or all" >&2
    exit 2
    ;;
esac
case "$TRIGGER" in
  key | cli) ;;
  *)
    echo "--trigger must be key or cli" >&2
    exit 2
    ;;
esac

FLASH_CLI="${FLASH_CLI:-$HOME/.local/bin/flash}"
LOG_DIR="$HOME/Library/Logs/Flash"
STATE_URL="http://127.0.0.1:4242/state"

echo "==> Preflight"
if [[ ! -x "$FLASH_CLI" ]]; then
  echo "ERROR: $FLASH_CLI not found. Install Flash first: ./Scripts/install.sh --dev" >&2
  exit 1
fi
if ! "$FLASH_CLI" status >/dev/null; then
  echo "ERROR: the Flash resident did not answer 'flash status'." >&2
  exit 1
fi
if ! curl -fsS -o /dev/null --max-time 2 "$STATE_URL"; then
  cat <<MSG >&2
ERROR: the debug inspector is not reachable at $STATE_URL.
Set [debug] http_inspector_enabled = true in your flash.toml, or run :logs once.
MSG
  exit 1
fi

WINDOWS=()
for class in "${CLASSES[@]}"; do
  echo
  echo "==> $class: $RUNS runs (trigger: $TRIGGER)"
  bench_args=("--bench=$RUNS" "--bench-trigger=$TRIGGER")
  if [[ "$class" == electron && $SKIP_NPM_CI -eq 1 ]]; then
    bench_args+=(--skip-npm-ci)
  fi
  if [[ "$class" == native && -n "$LARGE_TABLE" ]]; then
    bench_args+=(--fixture-large-table "$LARGE_TABLE")
  fi
  output="$(mktemp -t "flash-bench-$class")"
  "./Scripts/test-integration-$class.sh" "${bench_args[@]}" | tee "$output"
  start="$(sed -n 's/.*bench measure_start_ms=\([0-9][0-9]*\).*/\1/p' "$output" | tail -n 1)"
  end="$(sed -n 's/.*bench measure_end_ms=\([0-9][0-9]*\).*/\1/p' "$output" | tail -n 1)"
  rm -f "$output"
  if [[ -z "$start" || -z "$end" ]]; then
    echo "ERROR: the $class oracle printed no measurement window" >&2
    exit 1
  fi
  WINDOWS+=("--window=$class:$start:$end")
done

# The resident writes its log asynchronously; let the last lines land.
sleep 1
echo
echo "==> [latency] hints_visible: trigger to Core Animation commit (macOS $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string))"
python3 Scripts/hints-latency-summary.py --origin="$TRIGGER" "${WINDOWS[@]}" "$LOG_DIR"/flash.log*
