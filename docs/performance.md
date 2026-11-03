# Performance

How long Flash takes to show hints, how it is measured, and how to reproduce
the numbers.

## Start with the log

The first step of any performance work is a day of ordinary use, read from
the resident's own logs before and after the change:

```sh
mise run bench:log-summary                  # ~/Library/Logs/Flash/flash.log*
mise run bench:log-summary -- --hours 8     # only the last eight hours
mise run bench:log-summary -- path/to/flash.log.1 path/to/flash.log
```

It prints, with nearest-rank percentiles, every distribution a performance
audit otherwise computes by hand: the `[latency]` lines by kind; the
`hints_visible` target activations by app, with the prepared-model hit rate,
hit and miss latencies and the misses by `miss_reason`; the `hints_empty`
activations by app and path; `[plugin] slow catalog publish` by plugin;
`[apple] refresh` by catalog; `[plugin] initialized` startup by plugin; the
`[mode] active_border_frame` window-list reads on main by reason;
`[poll] overrun` by registration; `[watchdog] main_busy` stalls and
`main_hitch` hitches; `[window] placed` move times and writes by app;
and the
warnings and errors by kind, per hour. Everything but the `[latency]`,
startup and warning lines needs `[debug] log_level = "debug"` (the border
reads `"trace"`). Attach the before and after reports to the change; the
tables below are the fixtures' numbers, the report is the user's.

## What is measured

Every hint activation logs one line when its hints reach the screen:

```text
[latency] hints_visible ms=12.4 origin=key prepared=hit targets=42 class=native surface=targets bundle=com.apple.Notes outcome=hit miss_reason=-
```

- **Start:** the timestamp of the input that asked for hints. For a key the
  keyboard tap swallowed (`f` in NORMAL) it is the key event's own
  timestamp; for a native hotkey, the Carbon hotkey event's time; for a
  `flash` CLI command, the moment its request reached the resident's socket.
  The CLI process's own startup is not included ([CLI round trip](#cli-round-trip)).
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
- `surface` names the activation: `targets` (`mouse target`), `screen`,
  `scroll`, `grid`, `bigram` (`mouse bigram`), and `mouse_dock`,
  `mouse_menubar` and `mouse_notifications` for `mouse dock`,
  `mouse menubar` and `mouse notifications`, and `window_switcher` for
  `window switch`, whose `targets` is its number of windows.
- `bundle` is the app the hints are for (`-` when unknown).
- `outcome` says how the app's own hints were obtained: `hit` (the prepared
  model), `miss` (a walk), `retried` (a degenerate first walk was walked
  again, after the readiness ladder or the 150-ms settle; see
  [prepared models](prepared-model.md)), `empty` (the app yielded nothing
  and only status-bar segments were shown) or `none` (the grid).
  `prepared` is kept beside it for existing parsers.
- `miss_reason` says why the prepared model could not serve the activation,
  `-` for a hit and for surfaces that never consult it: `absent` (the app
  was never walked since its model was dropped), `focus` (a focus change
  discarded it and the focus walk had not landed), `invalidated` (an AX
  event or a Flash action moved the dirty token), `config`, `occluded` (the
  window list no longer matched what the walk saw), `expired` (older than its
  freshness window and maintenance had not replaced it), `degenerate` (fresh
  but empty or collapsed), `suppressed` (no model because Flash chose not to
  warm the app: an AX event storm, the empty-walk gate or an on-demand
  declaration) or `provider` (a volatile provider such as tmux owned the
  hints). `mise run bench:hints-summary -- --by-bundle` and
  `bench:log-summary` break the misses down by it.

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
most recently used apps in memory: `flash resident status --json` reports each app's
count, empty count and nearest-rank p50/p95 over the activations that showed
hints (`hints`; see [commands](commands.md)), and `flash resident doctor` warns
(`hint_activations`) about an app with at least 5 recent activations of which
a fifth or more were empty, or whose p95 exceeds 500 ms.

## Running the benchmark

The benchmark drives the installed resident against the same fixtures the
integration oracles use: an AppKit window, a Firefox page and an Electron
window.

1. The task installs the current tree as the dev resident first
   (`install:dev`), so it measures the build you are looking at.
2. Enable the debug inspector, which the benchmark polls for hint state:
   `[debug] http_inspector_enabled = true` (or run `:logs` once).
3. For the default `key` trigger, enable advanced mode (an all-mode
   `mode leave` or `mode normal` mapping) so `f` opens hints in NORMAL.
   `--trigger=cli` measures `flash mouse target` instead.
4. Run it from an unlocked session and leave the keyboard and mouse alone:

```sh
mise run bench:hints -- --class=all --runs=30
mise run bench:hints -- --class=native --runs=50 --trigger=cli
```

For each class the benchmark runs that class's integration fixture
(`mise run test:integration:<class>`) with `--bench=N`. The oracle launches its fixture, runs two unmeasured warm-up
activations, then N measured ones: bring the fixture forward, post the
trigger, wait for `/api/state` to show a finished hint layout (the first poll
waits 300 ms so polling does not load the main thread mid-activation), and
dismiss with `flash hints dismiss`. The script then reads the
`[latency] hints_visible` lines logged inside each class's measurement window
from `~/Library/Logs/Flash/flash.log*`, counts each trace once, and prints
p50, p95 (nearest rank) and max milliseconds with the prepared-model hit
count and the empty activations (`hints_empty`, left out of the
percentiles). `Scripts/hints-latency-summary.py` does the parsing
(`mise run test:hints-summary` tests it). Outside the
benchmark, the same parser summarizes ordinary use per app, busiest first:

```sh
mise run bench:hints-summary -- --by-bundle ~/Library/Logs/Flash/flash.log*
```

## Prepared-model hit rate

The number to beat is the share of target activations the prepared model
served in ordinary use, per app (`mise run bench:hints-summary -- --by-bundle`,
or the activations table of `bench:log-summary`). A hit costs about 0.15 ms
of discovery; a miss walks the app on the key path.

Baseline, 2026-10-21, 11 h of ordinary use on an Apple M4 Pro before the
slow-walk rule changed: 24 of 86 target activations were hits (28%). Slack
hit p50 18.5 ms against miss p50 70.7 / p95 229 ms; Firefox hit 17.4 ms
against miss 90.7 / p95 286 / max 489 ms. The cause was the background-walk
budget: a flat 50 ms, which 58% of Slack's, 75% of Firefox's and 98% of
WhatsApp's background walks exceeded, each one cancelling maintenance so the
model expired 1.5 s later and nothing re-armed it before the next focus
change. The budget is now a tenth of the app's maintenance interval (150 ms
at the 1.5 s floor), and a slow walk doubles that interval instead of
cancelling maintenance (see [prepared models](prepared-model.md)). A
background-walk cost threshold is a fraction of the model's freshness window,
never an absolute number of milliseconds: the apps hints matter for
(Electron, Gecko, Catalyst) walk in 50–100 ms. Measure the rule against this
baseline with the same command after a day of use; `miss_reason` says what
the remaining misses are.

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
mise run bench:hints -- --class=native --runs=30 --large-table=5000
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
mise run test:integration:browser                          # every Tests/BrowserSnapshots fixture
mise run test:integration:browser -- --update-allow-list   # must suggest no new entry
mise run test:integration:electron                         # Chromium web areas, real clicks
mise run bench:hints -- --class=browser --runs=30          # before and after
mise run bench:hints -- --class=electron --runs=30         # before and after
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
| Clipboard watcher | Flash's core history is active | 0.5 s (no pasteboard notification exists) | normal |
| Secure input | Always: while the flag is on the tap gets no keys, so nothing else can see it | 2 s; an off tick reads the flag alone | low |
| Process values | A visible surface reads `flash.top_cpu`, `flash.top_mem` or `flash.focused_app_details` | Tables 2 s; the focused app 10 s and 300 ms after a focus change | high (the focused app's 10 s normal) |
| Menu-bar reveal probe | The pointer is in the top band | 80 ms (no reveal notification exists) | system |
| Plugin liveness sweep | A plugin runs | 30 s; pings only a plugin silent for 60 s | low |
| Prepared-model maintenance | The frontmost app has a model | Before its 1.5–30 s freshness ceiling; skipped after 60 s without input | normal |
| Prepared-model debounce and readiness | AX events or a focus change since the last walk | 80 ms after the last event; 50–750 ms readiness steps | normal |
| Restart backoffs | A plugin crashed, or a persistent popup's program exited | Plugin 1–30 s; popup 0.1 s, then 1–30 s | low (a popup's first step high) |
| Event debounces and coalescers | A config, plugin-file, application-directory, network or volume change | 100–500 ms after it | normal |

Bundled plugins register cadences only for values no event reports, and only
while something can see them: `sysinfo`'s CPU, memory and disk domains
sample while a status surface shows one of their segments, its network
traffic while a traffic segment is shown, the remote tmux hosts listed in
`[plugins.terminals] ssh_hosts`, and the `feed` and `answers` refreshes. Network
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

Slack is not scheduling class. A handler runs on the queue that registered
it, at that queue's quality of service, and under CPU load the kernel starves
utility-class threads first: with the clock and the plugin transport on
`.utility` queues, the 80 ms `system` reveal probe fired at 150–1,821 ms gaps
(`[poll] overrun skipped=core:menu_bar_reveal`), plugin `ping` replies took
80 ms against a 3 ms median, and the same catalog decode took 295 ms on a
utility thread against 32 ms. The clock, the plugin lifecycle, reader,
writer and deadline queues, the AX broker, the reveal probe and the process
table now run `.userInitiated`; catalog decode runs on a per-plugin utility
queue that carries no replies (see [runtime ownership](architecture.md)).

## Footprint

Flash runs all day, so what it costs at rest matters as much as how fast it
answers. Measured on an Apple M4 Pro, macOS 26.6, with the dev resident at rest
(no input for a minute), the status bar on and ticking at 1 Hz with metrics, a
clock, links and popups, `log_level = "trace"`, and ten bundled plugins:

| Process | CPU | Idle wake-ups | Footprint |
| --- | --- | --- | --- |
| Flash, before the two fixes below | 2.1–2.3% | 1.6–5.8/s | 53 MB |
| Bundled plugins, together | under 0.2% | under 1/s | 96 MB |
| Your popups' programs (btop, tokscale, newsboat, a dashboard) | 2.5–4.3% | up to 24/s | 81 MB |

Where Flash's own time went, from `sample` over 10 seconds:

- **The secure-input poll**, about 0.5%: every 2 s it walked the IORegistry,
  read every running app's bundle identifier on the main thread (about 10 ms
  of main each time) and read the focused element through Accessibility,
  although an off flag decides nothing. An off tick now reads the flag alone.
- **The status bar's 1 Hz publish**, about 1%: evaluating the template on the
  bar's queue, then laying it out and drawing it on main. The dev build ran
  Flash's own modules unoptimized; `StatusBarCostBenchmarkTests` (opt-in,
  `FLASH_BENCH=1 swift test --filter StatusBarCostBenchmarkTests`) puts one
  publish at 0.64 ms of evaluation and 0.84 ms of layout unoptimized, and
  0.16 ms and 0.27 ms with `-O`. `Package.swift`'s `optimizedInDebug` now
  builds `flash`, `FlashCore`, `FlashProviders` and `FlashTerminal` with `-O`
  in the debug configuration too, so the dev resident and `swift test` run
  optimized code; a release build always did. What remains is Core
  Animation's text drawing of the runs that changed.
- **The inspector's snapshots**, only while a help page is open: each state
  change rebuilt `/api/state` on main, 18.6 ms at the median in a live log
  (4,018 snapshots, 70 s of main). The configuration's JSON (built as text,
  then parsed back), its sources and mapping rows, and the static core command
  catalog were rebuilt every time; they are now built once per configuration
  and once per process. `InspectorSnapshotBenchmarkTests` (opt-in,
  `FLASH_BENCH=1 swift test --filter InspectorSnapshotBenchmarkTests`) puts a
  default-configuration snapshot at 4.24 ms before and 0.79 ms after.

Memory: Flash's live heap is about 34 MB, of which the plugins' published
catalogs (about 20,000 rows: the bang lists, browser history and bookmarks,
emoji) are the largest share, each row a `Candidate` with its own metadata
dictionary. Plugin AppleScript now uses fixed host-owned templates through
`host.applescript`: plugin processes no longer map a separate OSA runtime on
their first script. This removes the previous per-plugin runtime cost (about
17 MB in each measured browser/shortcuts process); current savings depend on
which integrations run. A plugin's dirty
memory beyond its live heap is fragmentation left by its startup work, which
`malloc_zone_pressure_relief` cannot return while live data shares the pages.

Persistent popups keep their programs running while hidden, and their CPU
counts on your Mac even though it is not Flash's: btop redraws on its own
interval whether or not its popup shows. `[popup.<name>] pause_hidden = true`
stops such a process while its popup is hidden and continues it when the
popup shows, at the price of a stale first frame
([popups](popups.md#lifecycles)). The bundled `emojis` and `snippets`
plugins no longer hold a child at all: they publish their catalog and exit,
and the host keeps the rows
([plugin performance](plugin-performance.md#publish-then-exit-plugins)).

To measure a change, compare like with like: the same build configuration,
the same log level, after a minute of rest. Everything below is read-only and
never restarts the resident:

```sh
pid=$(pgrep -f 'Flash.*\.app/Contents/MacOS/flash$' | head -1)
mise run bench:footprint -- 30          # CPU, wake-ups, threads, log health
footprint -p "$pid" | head -3           # physical footprint
sample "$pid" 10 -file /tmp/flash.sample  # where idle CPU goes
heap "$pid" | head -40                  # live heap by type
for child in $(pgrep -P "$pid"); do footprint -p "$child" | head -2 | tail -1; done
```

| Measure, at rest with the bar on | Budget |
| --- | --- |
| Flash CPU | Under 1% |
| Flash idle wake-ups | Under 5 per second |
| Flash footprint | Under 60 MB |
| Each bundled plugin | Under 0.1% CPU; under 5 MB unless it scripts apps or holds a large catalog |

## Plugin publishes

The host decodes every `publish` in full on its catalog queue, so the cost of
a catalog is paid on every publish of it. `PluginPublishBenchmarkTests`
times the phases for one synthetic frame the size of the browsers plugin's
former tab-plus-history catalog (3,187 rows, 1.4 MB): parsing the frame,
counting the catalog bytes, validating the rows into candidates, and the
store's comparison against an identical catalog. The byte count used to be a
second serialization of the rows; it is now read off the frame, and the
browsers plugin publishes its tab sources apart from its history and bookmark
sources, so a tab switch publishes tens of rows instead of thousands (see
[plugin performance](plugin-performance.md#hot-path-rules)).

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

`mise run bench:footprint` samples the running resident read-only: it
never launches, restarts or stops Flash. Measure each state on the same build
and log level (`trace` logging adds its own cost), after a minute of rest,
with the keyboard and mouse idle:

```sh
mise run install:dev                        # the build to measure
# 1. Baseline: the bar on, every [widgets.*] table removed or enabled = false.
mise run bench:footprint -- 30
footprint -p "$(pgrep -f 'Flash.*\.app/Contents/MacOS/flash$' | head -1)" | head -3
# 2. Add docs/examples/widgets/system-panel.toml, save, show the desktop.
mise run bench:footprint -- 30
footprint -p "$(pgrep -f 'Flash.*\.app/Contents/MacOS/flash$' | head -1)" | head -3
# 3. Cover the widget with a maximized window, wait 10 seconds.
mise run bench:footprint -- 30
```

Compare the host line of step 2 with step 1: `%CPU`, and `IDLEW` divided by the
printed interval, give the CPU and wakeup deltas; the `footprint` totals give
the memory delta, divided by the number of widgets. Step 3 must match step 1.
The children line covers plugins; the host line includes Flash's own
two-second process-table sample, which runs only while a table is visible.

## Window moves

A `window move` is a handful of Accessibility round trips into the target
app on Flash's window-layout queue, after the keypress has been routed on
main. Reads are cheap; what a user sees is the writes, because each one that
changes the frame makes the app lay the window out and draw it again, and the
frames in between are what stutter. Read-only probes on an Apple M4 Pro,
macOS 26.6, against the apps running in an ordinary session (median of 25):

| Round trip | ms |
| --- | --- |
| Focused, main and window list in one batch (`resolveWindow`) | 0.04–0.15 |
| Focused window alone | 0.02–0.05 |
| Window position and size in one batch | 0.03–0.11 |
| `AXEnhancedUserInterface` read, or its settability | 0.02–0.05 |
| `CGWindowListCopyWindowInfo`, on-screen windows (median, p90, max) | 0.7, 4.9, 10.8 |

`AXEnhancedUserInterface` read `true` for Slack, Chrome and the other
Chromium and Electron apps, because Flash turns it on to read their content;
every move of those apps switches it off and back on. An element read
through an app element does not inherit the app's messaging timeout: against
an app whose main thread was blocked, the app element gave up at its 0.3 s
and the window element read through it at the process default, 1.5 s.

What a move costs, before and after the change that planned its writes
(an app without enhanced UI, left half to right half):

| Step | Before | After |
| --- | --- | --- |
| Main thread: target app | frontmost app plus one window-list read | frontmost app |
| Resolve the window, read its frame | 2 | 2 |
| Enhanced UI read, settability | 2 | 1 (settability only when on) |
| Frame writes | 3 (size, position, size) | 1 (position) |
| Read-back | 1 | 1 |
| Already in place (a second `maximized`) | 8 round trips, 3 writes | 2 reads |
| App not answering Accessibility | 4 timeouts (6 s) | 1 timeout (1.5 s) |

Grows move first and shrinks resize first, so a window is no longer clamped
by the display edge mid-move; the read-back's corrections now write only what
missed. `mise run bench:log-summary` reports `[window] placed` per app:
the time from the request reaching the layout queue to the read-back, and
the writes each move took. It needs `[debug] log_level = "debug"`.

## CLI round trip

`flash <words>` is a process start-up, then one round trip to the resident:
connect to its socket, `hello`, the request, the reply. `mise run bench:cli`
times both halves with the installed CLI against the running resident:
`flash --help` (start-up alone; it never contacts the resident) and `flash
resident status` (start-up plus the round trip and the status report). It
never starts a resident.

On an Apple M4 Pro, macOS 26.6, 30 to 40 runs each, milliseconds at the
median (nearest rank):

| Transport | Start-up | `resident status` | The round trip adds |
| --- | --- | --- | --- |
| Apple Event (before), the installed dev CLI and resident | 8.4 | 23.4 | 15.0 |
| Apple Event (before), the same debug build as below | 6.8 | 28.4 | 21.6 |
| Socket (after), a debug build against `IPCServer` serving the resident's runner | 8.9 | 14.0 | 5.1 |

The Apple Event leg was an `AESendMessage` through the Apple Event manager
and the resident's main-thread handler; the socket's is a connect, two short
lines each way and one hop to main to run the command. The socket rows ran
`IPCServer` with the resident's own `runInvocation` in the test host, so its
status report covers an idle delegate; re-run `mise run bench:cli` after
`install:dev` for the installed resident's number. Both legs exclude the
command's own work, which is the same code either way.

A cold start, `flash` with no resident running, adds the resident's launch:
Launch Services opens the bundle and the CLI waits for the socket to appear,
at most 15 s ([IPC protocol](ipc-protocol.md#limits-and-timeouts)).

## Browser help

The help should feel instant: a page change inside a frame or two, typing
that never waits on a frame, and a tab left open that costs Flash and the
browser next to nothing while the status bar keeps changing.

```sh
mise run bench:help                  # the running resident, 5 runs
mise run bench:help -- --runs 10 --chrome "/Applications/Chromium.app/Contents/MacOS/Chromium"
mise run bench:help -- --server-only
```

`bench:help` reads the help's token, times 20 sequential requests to the
page, the bundled manual, `/api/state`, `/api/logs` and `/api/traces` (and a
revalidation of each validator), then drives headless Chrome over its
DevTools protocol, never shown: a cold load (fresh browser context) and a
reload of `/docs/normal-mode`, 10 s of an open tab with the stream pushing
(main-thread time and bytes received), two passes over eight pages (the
largest manual pages, mappings, commands, clipboard and logs: the app's
render plus layout per hop), and typing into the top search and the
mappings, commands and logs searches (each keystroke's update and layout).
It only reads. On the resident side, every snapshot's main-thread cost is a
`[latency] inspector_snapshot ms=… sections=…` line at `trace`, which
`mise run bench:log-summary` reports by kind.

### Results

2026-10-23, Apple M4 Pro, macOS 26.6.2, with other builds running. The
release page against a stand-in server replaying a recorded live state
(181 KB: 192 mappings, 12 plugins, 100 clipboard previews), a status bar
change every 400 ms (plugin samples every fifth), four log lines a second
and 440 clipboard entries; headless Chromium 156 and Firefox 150 at
1440×900, before and after interleaved, medians of 6 runs (navigation:
36 hops per page). Server rows are the real `DebugServer` in a test
process serving the same state.

| Measure | Chromium before | Chromium after | Firefox before | Firefox after |
| --- | ---: | ---: | ---: | ---: |
| Cold load: documentation and live data rendered | 85 ms | 70 ms | 187 ms | 159 ms |
| Cold load: main-thread script | 75 ms | 36 ms | – | – |
| Cold load of `/mappings`: data rendered | 88 ms | 70 ms | 80 ms | 76 ms |
| Reload: bytes fetched | 2,081 KiB | 595 KiB | 2,081 KiB | 1,623 KiB |
| Reload: documentation and live data rendered | 72 ms | 58 ms | 184 ms | 148 ms |
| Open tab, idle: main-thread time | 53.5 ms/s | 3.1 ms/s | – | – |
| Open tab, idle: state received in 10 s | 4,402 KiB | 413 KiB | 4,402 KiB | 413 KiB |
| Page change, all pages: median / p90 | 21.8 / 38.5 ms | 16.6 / 24.5 ms | 33 / 57 ms | 26 / 39 ms |
| Page change to the longest manual page (`commands`) | 49 ms | 24 ms | 68 ms | 32 ms |
| Typing in the mappings search: per key, median / max | 9.2 / 15.4 ms | 4.2 / 7.9 ms | 11 / 27 ms | 3 / 7 ms |
| Typing in the log search: per key, median | 5.2 ms | 2.4 ms | 10 ms | 5 ms |
| `/api/state` reply (181 KB), p50 | 2.9 ms | 0.3 ms | | |
| `/api/logs` reply (2,000 lines), p50 | 6.2 ms | 0.6 ms | | |
| Page or manual revalidation | full reply | 304 in 0.3 ms | | |

Firefox reports no long tasks or DevTools metrics, hence the dashes. On the
live resident before the change, with one Firefox tab open, the status bar
took 567 whole snapshots in 271 s (2.1 a second) at 6.4 ms p50 and 13 ms p90
of main thread each; a status bar push now rebuilds only the bar and its
popup anchors, a tenth of a whole snapshot in a test resident.

### What made it slow, and what changed

- **Every push rehashed the manual.** The sidebar's new-and-updated marks
  hashed each page's Markdown, over 1 MB, twice on every snapshot: 26 ms a
  second of an idle tab. The build writes each page's hash into `docs.json`;
  a plugin guide's hash is remembered by its text.
- **Every push resent and recomputed everything.** A status bar change sent
  the whole 181 KB state, and the page's deep reactive copy of it invalidated
  every derived value: the search index, the mapping table, the
  configuration document. A stream now sends the whole state once, then a
  `patch` of the sections whose encoding changed; the page keeps state and
  logs as immutable values, so only what reads a changed section recomputes,
  and shows what arrived once per frame (log lines at most five times a
  second). A hidden tab gets no frames and renders nothing.
- **The resident rebuilt the whole snapshot on main for a status bar
  change.** Status bar, popup and widget changes name their sections
  (`DebugServer.StateScope`); the snapshot rebuilds those over the last one.
  Encoding happens once per snapshot, off main, per section; `/api/state`,
  `/api/logs` and a new stream send cached bytes instead of encoding again
  per request. A clipboard history page is encoded off main too.
- **Long manual pages mounted a reactive block per node.** The resident's
  help builds the rendered tree with plain DOM calls; a page's render is
  prepared while its link is pointed at or focused.
- **Searches redid per keystroke what depends only on the data**: the
  mapping fields' normalization and plugin descriptions (a scan of every
  command per row), `localeCompare` sorts, log and clipboard search text,
  clipboard sizes. They are prepared once per data.
- **Loads fetched what they did not need.** The page no longer fetches
  `/api/logs` next to the stream that sends them, loads the manual on a live
  page only when idle, fetches the search sections as the search field takes
  focus, and revalidates the page and the manual with their `ETag`s.
- **Small things**: a forced layout at router start, the clipboard list's
  first 100 rows (50 now fill a tall window), the raw snapshot encoded while
  its section was closed, the help server's queue at utility priority.

### Guards

- `Inspector/budget.test.ts` (in `mise run test:inspector`) holds the
  committed page to 460 KiB, 135 KiB gzipped (425 and 123 KiB now).
- `DebugServerTests`: a patch carries only changed sections and a stream
  without a state gets it whole; a scoped change rebuilds only its sections;
  cached replies never wait on main (the requests block it) and cost under
  half of one encoding of a large state; the page and the manual answer 304
  to their validators, and runtime data is `no-store`.
- `InspectorStatePushTests`: a status bar, popup or widget change takes no
  whole snapshot; any other change does.
- `Inspector/state-patch.test.ts` and `docs.test.ts`: how a page applies,
  skips or recovers from a patch, and that every bundled page carries its
  hash.

### Considered and not done

- **Compression.** The help is loopback-only: gzipping the page and the
  manual made Chromium's cold load slower (225 against 94 ms to the rendered
  page) and saved no time, since nothing crosses a network.
- **Splitting the bundle or the manual.** Chromium compiles and runs the
  whole page in about 35 ms and parses the 1.6 MB manual in a few; lazy
  chunks inside one file, or a manual fetched page by page, would add
  machinery for little. The manual's size grows with the documentation: it
  is the next thing to split if it doubles.
- **Virtualized mappings and commands.** A few hundred rows render in a
  frame; the logs list is already windowed and clipboard history renders in
  steps as it scrolls.
- **`content-visibility` on long pages.** It would skip laying out what is
  off screen, but an anchor link into a long page then lands on estimated
  positions.

## Not measured, by design

- **Pixels.** Flash never reads the screen, so it has no OCR, vision or
  contour stage to time (or to be slow).
- **CLI start-up in the latency line.** `origin=cli` starts at the
  request's arrival; the `flash` process launch before it depends on the
  shell and is excluded there, and measured on its own below.
- **Display latency.** The last frame (at most one refresh) is the window
  server's, not Flash's.
