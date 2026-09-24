# Performance

How long Flash takes to show hints, how it is measured, and how to reproduce
the numbers.

## What is measured

Every hint activation logs one line when its hints reach the screen:

```text
[latency] hints_visible ms=12.4 origin=key prepared=hit targets=42 class=native surface=targets
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

The line is logged at `info`, once per activation, and carries the
interaction's trace id. The probe runs after the hints are drawn; nothing is
added to the keyboard tap's swallow decision.

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
trigger, wait for `/state` to show a finished hint layout (the first poll
waits 300 ms so polling does not load the main thread mid-activation), and
dismiss with `flash hints_dismiss`. The script then reads the
`[latency] hints_visible` lines logged inside each class's measurement window
from `~/Library/Logs/Flash/flash.log*`, counts each trace once, and prints
p50, p95 (nearest rank) and max milliseconds with the prepared-model hit
count. `Scripts/hints-latency-summary.py` does the parsing
(`python3 Scripts/test-hints-latency-summary.py` tests it).

## Results

Trigger to Core Animation commit, `key` trigger, 30 runs per class.

| Class | Fixture | p50 ms | p95 ms | max ms | Prepared hits |
| --- | --- | --- | --- | --- | --- |
| native | Flash Native Fixture (AppKit) | TBD | TBD | TBD | TBD |
| browser | Firefox, browser fixture page | TBD | TBD | TBD | TBD |
| electron | Electron fixture | TBD | TBD | TBD | TBD |

Machine: TBD. macOS: TBD. Flash commit: TBD.

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

Results: TBD.

## Experiment: pruning offscreen web subtrees (not adopted)

The walk skips a native element whose frame lies wholly outside the visible
clip, with all of its descendants. Inside an `AXWebArea` it never does, because
a web node can render outside the frame it reports (CSS transforms,
`overflow: visible`, fixed and sticky positioning), so a pruned container
could hide a visible link. The candidate change lets that prune run inside web
areas for Chromium and WebKit, where long pages (feeds, reference docs) spend
most of a walk on offscreen containers. Gecko stays unpruned. The walk's
behaviour is unchanged until the change passes the checks below.

Validate a build carrying the candidate:

```sh
./Scripts/test-integration-browser.sh                      # every Tests/BrowserSnapshots fixture
./Scripts/test-integration-browser.sh --update-allow-list  # must suggest no new entry
./Scripts/test-integration-electron.sh                     # Chromium web areas, real clicks
./Scripts/benchmark-hints.sh --class=browser --runs=30     # before and after
./Scripts/benchmark-hints.sh --class=electron --runs=30    # before and after
```

The browser oracle compares Flash with Vimium-FF in Firefox, so for this
experiment build the prune for Gecko too; the same rule then meets every
fixture in `Tests/BrowserSnapshots`. The Electron oracle is the Chromium
check. There is no WebKit oracle: open the same fixture pages in Safari and
compare the hints by hand.

Adopt it only with zero new misses: no new `vimiumOnly` divergence on any
fixture, no new allow-list entry, and every expected Electron target still
found and clicked. It must also make the browser or Electron walks measurably
faster. A single new miss rejects it.

## Not measured, by design

- **Pixels.** Flash never reads the screen, so it has no OCR, vision or
  contour stage to time (or to be slow).
- **CLI start-up.** `origin=cli` starts at the AppleEvent's arrival; the
  `flash` process launch before it depends on the shell and is excluded.
- **Display latency.** The last frame (at most one refresh) is the window
  server's, not Flash's.
