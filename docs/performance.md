# Performance

How long Flash takes to show hints, how it is measured, and how to reproduce
the numbers.

## What is measured

Every hint activation logs one line when its hints reach the screen:

```text
[latency] hints_visible ms=12.4 origin=key prepared=hit targets=42 class=native surface=targets bundle=com.apple.Notes outcome=hit
```

- **Start:** the timestamp of the input that asked for hints. For a key the
  keyboard tap swallowed (`f` in NORMAL) it is the key event's own
  timestamp; for a native hotkey, the Carbon hotkey event's time; for a
  `flash` CLI verb, the moment the AppleEvent reached the resident. The CLI
  process's own startup is not included.
- **End:** the completion of the Core Animation transaction that commits the
  hint layers. The window server shows a commit on the next display refresh,
  so the screen lags the logged value by at most one frame (8.3 ms at 120 Hz,
  16.7 ms at 60 Hz).
- `prepared=hit` means the hints came straight from the focused app's
  prepared model (see [prepared models](prepared-model.md)); `miss` means the
  activation walked the app. The grid walks nothing and logs `none`.
- `class` groups apps by runtime: `native` (AppKit/SwiftUI), `browser`
  (any app that handles http and https), `electron` (other Chromium apps) and
  `other`.
- `surface` names the activation: `targets` (`mouse_target`), `screen`,
  `scroll`, `grid`, `mouse_dock`, `mouse_menubar`, `mouse_notifications`.
- `bundle` is the app the hints are for (`-` when unknown).
- `outcome` says how the app's own hints were obtained: `hit` (the prepared
  model), `miss` (a walk), `retried` (a degenerate first walk was walked
  again, after the readiness ladder or the 150-ms settle; see
  [prepared models](prepared-model.md)), `empty` (the app yielded nothing
  and only status-bar segments were shown) or `none` (the grid).
  `prepared` is kept beside it for existing parsers.

An activation that ends with nothing to draw logs instead, with no UI:

```text
[latency] hints_empty ms=1502.3 bundle=com.tinyspeck.slackmacgap path=prepared_model_refresh origin=key surface=targets
```

`ms` is how long Flash took to give up, and `path` names where: the
`[discover] complete` path of the final walk, or `no_context`,
`accessibility_denied`, `accessibility_revoked`, `screen_scope`,
`no_scroll_areas` or `no_targets` (system surfaces). An activation replaced
or cancelled before it drew logs neither line.

Both lines are logged at `info`, once per activation, and carry the
interaction's trace id. The probe runs after the hints are drawn; nothing is
added to the keyboard tap's swallow decision.

The resident also keeps the last 50 target activations of each of the 32
most recently used apps in memory: `flash status --json` reports each app's
count, empty count and nearest-rank p50/p95 over the activations that showed
hints (`hints`; see [commands](commands.md)), and `flash doctor` warns
(`hint_activations`) about an app with at least 5 recent activations of which
a fifth or more were empty, or whose p95 exceeds 500 ms.

## Running the benchmark

The benchmark drives the installed resident against the same fixtures the
integration oracles use: an AppKit window, a Firefox page and an Electron
window.

1. Install the build to measure: `./Scripts/install.sh --dev`.
2. Enable the debug inspector, which the benchmark polls for hint state:
   `[debug] http_inspector_enabled = true` (or run `:logs` once).
3. For the default `key` trigger, enable advanced mode (an all-mode
   `leave_mode` or `enter_normal_mode` mapping) so `f` opens hints in NORMAL.
   `--trigger=cli` measures `flash mouse_target` instead.
4. Run it from an unlocked session and leave the keyboard and mouse alone:

```sh
./Scripts/benchmark-hints.sh --class=all --runs=30
./Scripts/benchmark-hints.sh --class=native --runs=50 --trigger=cli
```

For each class the script runs `Scripts/test-integration-<class>.sh` with
`--bench=N`. The oracle launches its fixture, runs two unmeasured warm-up
activations, then N measured ones: bring the fixture forward, post the
trigger, wait for `/api/state` to show a finished hint layout (the first poll
waits 300 ms so polling does not load the main thread mid-activation), and
dismiss with `flash hints_dismiss`. The script then reads the
`[latency] hints_visible` lines logged inside each class's measurement window
from `~/Library/Logs/Flash/flash.log*`, counts each trace once, and prints
p50, p95 (nearest rank) and max milliseconds with the prepared-model hit
count and the empty activations (`hints_empty`, left out of the
percentiles). `Scripts/hints-latency-summary.py` does the parsing
(`python3 Scripts/test-hints-latency-summary.py` tests it). Outside the
benchmark, the same script summarizes ordinary use per app, busiest first:

```sh
python3 Scripts/hints-latency-summary.py --by-bundle ~/Library/Logs/Flash/flash.log*
```

## Results

Trigger to Core Animation commit, `key` trigger, 20 runs per class, every run
showing hints (no empty activations).

| Class | Fixture | p50 ms | p95 ms | max ms | Prepared hits |
| --- | --- | --- | --- | --- | --- |
| native | Flash Native Fixture (AppKit) | 20.6 | 23.9 | 26.0 | 1/20 |
| browser | Firefox, browser fixture page | 12.9 | 15.5 | 15.9 | 1/20 |
| electron | Electron fixture | 9.3 | 15.4 | 15.6 | 1/20 |

Machine: Apple M4 Pro. macOS: 26.6.2. Flash commit: 6127ba4.

Only the first run of each class was served from a prepared model; the rest
walked the fixture on the key path, so these numbers include a full walk of a
small page. Activations served from a prepared model cost about 0.15 ms (see
below).

In the resident after the Gecko linger (same machine, ordinary use), three
focus changes into Firefox each found its tree ready on the first readiness
probe and walked it in 9.8–11.9 ms, with no empty walks. That page had 25
targets, fewer than the pages behind the numbers below, so it is not a
like-for-like comparison.

## Walk costs already known

Before the benchmark existed, debug logs (`[discover] pipeline` and
`[discover] complete`, at `[debug] log_level = "debug"`) recorded what
discovery costs. From one day of ordinary use on an Apple M4 Pro, macOS 26.6
(1,645 walks):

| Path | Walks | p50 ms | p95 ms |
| --- | --- | --- | --- |
| Activation served from the prepared model | 7 | 0.15 | 0.39 |
| Activation that refreshed the prepared model first | 39 | 113 | 344 |
| Activation walked without a model (uncached providers) | 5 | 77 | 185 |

Background prepared-model walks per app (off the key path, targets > 0):

| App | Walks | p50 ms | p95 ms | Targets (p50) |
| --- | --- | --- | --- | --- |
| Firefox | 406 | 110 | 314 | 52 |
| Messages | 115 | 102 | 192 | 37 |
| Slack (Electron) | 69 | 52 | 85 | 112 |
| Chrome | 48 | 11 | 48 | 23 |
| WhatsApp | 37 | 46 | 88 | 44 |

Each of those Firefox walks woke Gecko's accessibility and switched it off
again, which discards its tree; the walks that came back empty caught it being
rebuilt. The mode now stays on while Firefox is focused (see
[prepared models](prepared-model.md)); the Firefox row is due to be measured
again.

Almost all of a walk is the Accessibility collection itself (`collect_ms`);
visibility filtering, deduplication and label assignment add well under a
millisecond. That is why Flash walks ahead of time: when the prepared model
is fresh, an activation only draws.

## Long native tables

A native table or outline is walked through its visible rows
(`AXVisibleRows`) instead of every row. A scrolled-off row used to cost one
batched Accessibility read before the offscreen prune dropped it, so a long
list paid for all of its rows on every walk; now it costs two list reads
(`AXRows` and `AXVisibleRows`) however long it is. Web tables keep every
row. The hints are the same, except that a row the table has scrolled out of
its clip but which still lies inside the window (under a toolbar, say) no
longer gets a hint over the control that covers it.

The native fixture has a 5,000-row table for measuring this: with
`--large-table=ROWS` the benchmark opens it in front of the fixture's control
window, scrolled to the middle, and times `f` over it. Compare a build before
and after the change:

```sh
./Scripts/benchmark-hints.sh --class=native --runs=30 --large-table=5000
```

Results after the change (20 runs, commit 6127ba4): p50 69.5 ms, p95 81.9 ms,
max 86.0 ms, no empty activations. No build from before the change was
measured, so this is a reference point rather than a comparison.

## Experiment: pruning offscreen web subtrees (not adopted)

The walk skips a native element whose frame lies wholly outside the visible
clip, with all of its descendants (`skipsOffscreenSubtree`). Inside an
`AXWebArea` it never does: a web node can render outside the frame it reports
(fixed positioning, CSS transforms, `overflow: visible`), so a skipped
container could hide a visible control. The experiment let the prune run
inside web areas, per engine, for containers more than a whole clip away (one
clip height above or below, one clip width beside), and was rejected for both
engines it could be measured on.

The adoption rule: zero new misses — no new `vimiumOnly` divergence on any
fixture, no new allow-list entry, every expected Electron target still found
and clicked — and measurably faster browser or Electron walks. A single new
miss rejects it.

Method. The browser oracle used to walk with an unbounded clip, which no prune
can meet; it now walks with the clip narrowed to the Firefox window
(`FirefoxHarness.clippedToWalkedWindow`), as the resident does, and matches
the unclipped baseline exactly. The repository's fixtures fit within about two
viewports, where a prune a whole clip away never fires, so each oracle also ran
a probe page kept outside the repository: a toolbar and links on screen, then
twelve 820-pt sections of twenty links each, with a `position: fixed` "Chat"
button declared inside the sixth section and a fixed "Back to top" link inside
the footer. The Electron probe had the same shape, with the fixture's
"Electron Primary" button fixed inside its offscreen footer.

Results on an Apple M4 Pro, macOS 26.6.2, Firefox 156.0.1 and the pinned
Electron 44.4.5. Chromium walk times are the Electron oracle's
`electron_discover`, one walk per run. The browser oracle times no walk, so
the Gecko column counts the AX nodes a walk of the probe reads, without and
with the prune, in a Firefox showing it in a 1280 × 976 window:

| Engine | Fixture | Misses before | Misses after | Walk before → after |
| --- | --- | --- | --- | --- |
| Gecko | 7 repository fixtures | 0 | 0 | prune never fires |
| Gecko | probe | 0 (29 of 29 matched) | 2 ("Chat with us", "Back to top") | 844 → 208 AX nodes |
| Chromium | Electron fixture | 0 | 0 | 13.2 → 13.3 ms |
| Chromium | Electron probe | 0 | 0 | 153 → 139 ms |

The Electron oracle also reports the fixture's `<select>` option "First" as
an unexpected target, before and after alike.

- **Gecko** reports each container's own layout box: the probe's footer lies
  about 10,000 pt below the window, 109 pt tall, while its fixed link is on
  screen. The prune would skip three quarters of that page's nodes and loses
  both fixed controls, on every retry. Rejected: two new misses. Declaring a
  modal, a chat launcher or a back-to-top link inside an ordinary container is
  common, and AX does not say which containers hold fixed or transformed
  descendants.
- **Chromium** reports offscreen nodes clipped to the web area: every
  offscreen section, list and link is a zero-height strip along the viewport's
  edge (the probe's footer is 900 × 0 at its bottom). A zero-size frame is
  never skipped, so the prune never fires; the fixed button survived for that
  reason, and the timing difference is run-to-run noise. Rejected: nothing to
  gain.
- **WebKit** (Safari) has no oracle and was not attempted.

The prune stays native-only and the per-engine gate was removed. To rerun a
candidate, run the oracles before and after, with the probe page added to the
fixtures:

```sh
./Scripts/test-integration-browser.sh                      # every Tests/BrowserSnapshots fixture
./Scripts/test-integration-browser.sh --update-allow-list  # must suggest no new entry
./Scripts/test-integration-electron.sh                     # Chromium web areas, real clicks
./Scripts/benchmark-hints.sh --class=browser --runs=30     # before and after
./Scripts/benchmark-hints.sh --class=electron --runs=30    # before and after
```

## Idle wake-ups

An idle resident reacts to events; what remains periodic is ahead-of-time
work whose source has no change notification, and all of it rides the one
`PollScheduler` clock (see [runtime ownership](architecture.md)):

| Wake-up | When it exists | Cadence | Priority |
| --- | --- | --- | --- |
| Status time and carousel rotations | A visible surface shows time or a carousel | The next boundary of the finest unit shown: second, minute or day; each rotation | high |
| Status jobs and named sources | A visible surface reads them | Their configured `interval` | normal (high when a clock tick falls inside its slack) |
| Plugin cadences and deadlines (`poll`) | A plugin registered one | The plugin's period or deadline | The plugin's: high, normal or low ([table](status-plugins.md#scheduling)) |
| Clipboard watcher | A plugin subscribes to `core:clipboard.changed` | 0.5 s (no pasteboard notification exists) | normal |
| Menu-bar reveal probe | The pointer is in the top band | 80 ms (no reveal notification exists) | system |
| Plugin liveness sweep | A plugin runs | 30 s; pings only a plugin silent for 60 s | low |
| Prepared-model maintenance | The frontmost app has a model | Before its 1.5–30 s freshness ceiling; skipped after 60 s without input | normal |
| Prepared-model debounce and readiness | AX events or a focus change since the last walk | 80 ms after the last event; 50–750 ms readiness steps | normal |
| Restart backoffs | A plugin crashed, or a persistent popup's program exited | Plugin 1–30 s; popup 0.1 s, then 1–30 s | low (a popup's first step high) |
| Event debounces and coalescers | A config, plugin-file, application-directory, network or volume change | 100–500 ms after it | normal |

Bundled plugins register cadences only for values no event reports, and only
while something can see them: `cpu`, `memory`, `disks`, `processes` and
`aiproviders` samples while a status surface shows their segments, `network`
traffic while a traffic segment is shown, the remote tmux hosts listed in
`[plugin.tmux] ssh_hosts`, and the `feed` and `answers` refreshes. Network
discovery follows `core:network.changed`, the disk mount set
`core:volumes.changed`, the local tmux inventory the control-mode
notifications of each server a client is attached to, and the window, tab and
terminal catalogs the `core:ax.changed` notifications that can change them;
none of those polls. The [HTTP inspector](observability.md#http-inspector)
has no cadence either: its state is pushed on the changes it shows.

Priority is the slack a wake-up tolerates: 5 ms (`system`), 25 ms (`high`),
100 ms (`normal`) or 1 s (`low`). The looser it is, the more often the kernel
folds it into an interrupt it was already taking, so idle cost falls with it;
a wake-up shared by several registrations takes the tightest of their slacks.
Every one of them is held while the displays sleep, the session is locked or
switched out, or the system sleeps, and resumes with one catch-up tick.
Waiting for a child process ends on its kernel exit event, never a sleep loop,
and main-thread stalls are measured by the run loop itself, with no ping.

## Widgets budget

[Desktop widgets](widgets.md) must cost close to nothing while you work. They
add no timer: they are evaluated by the bar's controller on its one
`PollScheduler` deadline, re-evaluate only when a value they read changes, and
draw meters and sparklines while parsing the text they already have. Against a
bar-only baseline of the same build, with the
[system panel example](examples/widgets/README.md) visible on the desktop:

| Measure | Budget |
| --- | --- |
| Timers | None added: widgets tick on the bar's `PollScheduler` deadline |
| Host idle CPU | +0.3 percentage points or less |
| Host idle wakeups | +0.2 per second or less |
| Host memory | Under 5 MB per widget |
| Every widget covered by a window | Zero work: equal to the baseline |

`Scripts/measure-footprint.sh` samples the running resident read-only: it
never launches, restarts or stops Flash. Measure each state on the same build
and log level (`trace` logging adds its own cost), after a minute of rest,
with the keyboard and mouse idle:

```sh
./Scripts/install.sh --dev                  # the build to measure
# 1. Baseline: the bar on, every [widgets.*] table removed or enabled = false.
./Scripts/measure-footprint.sh 30
footprint -p "$(pgrep -f 'Flash.*\.app/Contents/MacOS/flash$' | head -1)" | head -3
# 2. Add docs/examples/widgets/system-panel.toml, save, show the desktop.
./Scripts/measure-footprint.sh 30
footprint -p "$(pgrep -f 'Flash.*\.app/Contents/MacOS/flash$' | head -1)" | head -3
# 3. Cover the widget with a maximized window, wait 10 seconds.
./Scripts/measure-footprint.sh 30
```

Compare the host line of step 2 with step 1: `%CPU`, and `IDLEW` divided by the
printed interval, give the CPU and wakeup deltas; the `footprint` totals give
the memory delta, divided by the number of widgets. Step 3 must match step 1.
The children line covers plugins; the system panel adds only the `processes`
plugin's two-second sample, which runs only while a table is visible.

## Not measured, by design

- **Pixels.** Flash never reads the screen, so it has no OCR, vision or
  contour stage to time (or to be slow).
- **CLI start-up.** `origin=cli` starts at the AppleEvent's arrival; the
  `flash` process launch before it depends on the shell and is excluded.
- **Display latency.** The last frame (at most one refresh) is the window
  server's, not Flash's.
