#!/usr/bin/env bash
# Read-only footprint snapshot of the running Flash resident and its children.
#
# Usage: Scripts/measure-footprint.sh [sample-seconds] [log-window-minutes]
#
# Reports host/children CPU, idle wakeups, context switches, memory, file
# descriptors, and log-derived health (main-thread stalls, tap re-enables,
# lines per minute by level). Run before and after a performance change on
# the same build configuration; compare like for like.
set -euo pipefail

sample_seconds=${1:-10}
log_minutes=${2:-30}
log_dir="$HOME/Library/Logs/Flash"

host_pids=$(pgrep -f 'Flash.*\.app/Contents/MacOS/flash$' || true)
host_pid=${host_pids%%$'\n'*}
if [[ -z "$host_pid" ]]; then
  echo "No running Flash resident found." >&2
  exit 1
fi
echo "host pid: $host_pid ($(ps -o comm= -p "$host_pid"))"
echo "sampling ${sample_seconds}s..."

# top prints an initial instantaneous sample; the last block is the delta.
interval=$(( sample_seconds / 2 ))
[[ "$interval" -ge 1 ]] || interval=1
# idlew is per sample interval; csw would be cumulative, so it is omitted.
top_output=$(top -l 3 -s "$interval" -stats pid,cpu,idlew,mem,command 2>/dev/null)
last_block=$(printf '%s\n' "$top_output" | awk '/^PID/{n++} n==3')

children=$(pgrep -P "$host_pid" | tr '\n' ' ')
printf '%s\n' "$last_block" | awk -v host="$host_pid" -v kids=" $children " -v secs="$interval" '
  NR==1 { print "(idlew is per " secs "s interval)"; print; next }
  {
    if ($1 == host) { host_line = $0; next }
    if (index(kids, " " $1 " ") > 0) {
      kid_cpu += $2; kid_idlew += $3; kid_n++
      mem = $4; unit = substr(mem, length(mem)); val = substr(mem, 1, length(mem)-1)
      if (unit == "M") val *= 1024; else if (unit == "G") val *= 1048576; else if (unit == "K") val *= 1
      kid_mem += val
    }
  }
  END {
    print host_line
    printf "children: %d procs  cpu=%.1f%%  idlew=%d (%.1f/s)  mem=%.0fM\n",
      kid_n, kid_cpu, kid_idlew, kid_idlew/secs, kid_mem/1024
  }'

fd_total=$(lsof -p "$host_pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
fd_dir=$(lsof -p "$host_pid" 2>/dev/null | awk '$5=="DIR"' | wc -l | tr -d ' ')
fd_pipe=$(lsof -p "$host_pid" 2>/dev/null | awk '$5=="PIPE"' | wc -l | tr -d ' ')
threads=$(ps -M "$host_pid" | tail -n +2 | wc -l | tr -d ' ')
echo "host fds: $fd_total (dir=$fd_dir pipe=$fd_pipe)  threads: $threads"

if [[ -d "$log_dir" ]]; then
  python3 - "$log_minutes" "$log_dir"/flash.log.2 "$log_dir"/flash.log.1 "$log_dir"/flash.log <<'PY'
import collections, json, os, sys, time
window_ms = int(sys.argv[1]) * 60_000
def lines():
    for path in sys.argv[2:]:
        if os.path.exists(path):
            with open(path, errors="replace") as handle:
                yield from handle
now_ms = int(time.time() * 1000)
levels = collections.Counter()
stalls, tap = [], 0
minutes = set()
for line in lines():
    try:
        record = json.loads(line)
    except ValueError:
        continue
    ts = record.get("time_unix_ms", 0)
    if now_ms - ts > window_ms:
        continue
    minutes.add(ts // 60_000)
    levels[record.get("level", "?")] += 1
    message = record.get("message", "")
    if "main_thread_stall" in message:
        stalls.append(message.split("ms=")[-1])
    elif "[tap] re-enabled" in message:
        tap += 1
span = max(1, len(minutes))
total = sum(levels.values())
mix = " ".join(f"{k}={v}" for k, v in levels.most_common())
print(f"log ({sys.argv[1]} min window): {total / span:.0f} lines/min  {mix}")
print(f"watchdog stalls: {len(stalls)} {stalls}  tap re-enables: {tap}")
PY
fi
