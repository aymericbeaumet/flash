# Plugin performance

Flash keeps one sandboxed child per resident plugin. The process boundary is
intentional: it gives each integration an explicit capability profile,
independent crash recovery, bounded requests, and deterministic lifecycle.
Official plugins are all native Rust binaries so that isolation no longer
requires six language runtimes or host-injected SDK bridges.

## Baseline and target

The pre-migration installed-app snapshot had nine resident non-Rust children
using roughly 84 MiB RSS / 117 MiB physical footprint; Flash plus all plugin
children was roughly 188–190 MiB physical. The steady-state target after the
Rust migration is at most 130 MiB physical for the same enabled plugin set.

On the maintainer's Apple Silicon machine, a post-migration `plugin-dev`
direct-process run (2026-09-02, five cold samples per plugin) measured all 32
executables at 111,424 KiB aggregate median RSS. Per-plugin cold-initialize
p95 values were 1.8–7.6 ms and settled ping p95 values were 0.12–0.35 ms. This is a
deliberately conservative aggregate—on-demand plugins do not all coexist in a
normal session—and excludes the resident host and seatbelt wrapper.

The matching installed dev app measured 126.3 MiB physical footprint for Flash
plus its 28 fully warmed resident plugin children, down from roughly 188–190
MiB before the migration. All 28 initialized concurrently in 219 ms, the
slowest handshake took 26 ms, and none timed out. Treat these figures as a
machine-specific reference, not a portable guarantee.

The five system-monitor plugins added on 2026-09-04 (`cpu`, `memory`, `disks`,
`network`, and `power`) measured 15,336 KiB aggregate median RSS across 20
samples each. Their cold-initialize p95 values were 2.09–2.30 ms and settled
ping p95 values were 0.19–0.22 ms. The same build's 36 direct plugin binaries
measured 121,504 KiB aggregate median RSS across five samples.

Use these regression budgets when changing the runtime or an official plugin:

| Metric | Budget |
| --- | ---: |
| direct cold initialize, p95 | 100 ms |
| idle ping round trip, p95 | 5 ms |
| synchronous query evaluator round trip | 50 ms protocol deadline |
| catalog decode/store | warn at 50 ms |
| queued outbound transport | 256 frames / 20 MiB |
| full installed steady-state footprint | 130 MiB physical |

These are regression tripwires, not protocol promises. Hardware, signing,
seatbelt compilation, TCC state, and debug versus release builds all affect
absolute startup numbers.

## Measuring

Build the native-architecture binaries, then run the report-only benchmark:

```bash
./Scripts/benchmark-plugins.py --build --samples 5
./Scripts/benchmark-plugins.py --samples 10 --json > plugin-benchmark.json
./Scripts/benchmark-plugins.py --plugin firefox --plugin safari --samples 20
```

It launches each official executable from a clean data directory, measures
the protocol initialize round trip, lets post-initialize startup settle,
measures an idle ping, samples RSS/thread count, then
shuts the child down through stdin EOF. It does not enforce thresholds in CI;
compare like-for-like builds and machines. The installed-app measurement is
the final authority for total footprint because it includes real seatbelt
profiles, resident/on-demand policy, catalogs, and host state.

Host logs provide phase data for real launches: `install_ms`,
`resolution_ms`, `sandbox_ms`, `spawn_ms`, initialize `elapsed_ms`, and
`startup_total_ms`. Catalog publication logs only when decode/store takes at
least 50 ms.

## Hot-path rules

- Plugin stdout decoding and stdin writes stay off the lifecycle queue.
  Writes are FIFO and bounded; a stalled child is restarted instead of
  freezing every lifecycle operation.
- The shared SDK uses one current-thread Tokio executor per child. Events keep
  wire order and interval callbacks do not overlap themselves; startup and
  request callbacks may overlap and must coordinate shared refresh state.
  Async I/O and `spawn_blocking` retain concurrency without multiplying idle
  worker threads.
- Full catalog replacements that are semantically unchanged do not advance
  the store generation, timestamp, or subscriber notifications.
- Browser refreshes are single-flight, publish only changed rows, and log
  state transitions or rate-limited warnings instead of every poll.
- Debug plugin logs remain available in the log file but do not invalidate
  status/inspector snapshots.
- The NDJSON frame collector scans appended bytes once and compacts the
  consumed prefix once per append.

Do not trade the child-process boundary for an in-process ABI or shared
daemon merely to reduce memory. That would collapse the sandbox and crash
containment guarantees and create a second plugin architecture.
