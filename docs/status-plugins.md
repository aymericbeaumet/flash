# Status plugins

Flash's status bar is a host-rendered surface fed by named plugin segments.
Plugins publish text and rich marker values through `Context.status`; the host
accepts only names declared by the plugin manifest, updates a plugin's segment
set atomically, and coalesces notifications before rendering. Hovering never
runs plugin work: inline popup content arrives in the same status value, and a
live update re-hit-tests the stationary pointer and refreshes a hovered pager
in place. Focused pagers hold their content stable until reopening or Command-R.

Planned resident-plugin reloads preserve each last status segment for at most
10 seconds while replacement values arrive. Republishing replaces it immediately;
an explicit empty value clears it. Stop, error, removal, and configuration
replacement clear immediately. This avoids blinking during a normal hot reload
without keeping failed telemetry indefinitely. Development builds stage binaries
outside watched plugin directories and replace only changed code or signing
identity; rebuilding unchanged plugins must not trigger resident reloads.
Ordinary status updates render in place with only a 100 ms crossfade: only
`#[cyc]` content opts into the upward carousel transition, and a pooled layer
reused for an ordinary metric must clear that transition first. Carousels are a
host primitive: a plugin publishes a `StatusCarousel` (lines plus a cycle) and
Flash owns the rotation, exactly as it does for `#{cycle:}` script sources.

## System-monitor ownership

The local system-monitor suite is deliberately split by resource. Each plugin
owns `summary` and `details`; every summary carries its preview through
`StatusValue::with_preview`, while the standalone details segment supports custom
templates. Each also publishes a popup-free `label`: the metric alone, with no section
name, no colour, and no padding. The host trims a status value, so a leading
space would not survive. The template supplies the name, the colour, and the
width, for example `#[label]CPU#[default] #{p-3:flash.plugin.cpu.label}`.
CPU/MEM/DSK percentages use two digits plus `%` (`p-3`), capped at 99;
battery charge can reach 100%, and detailed reports retain the actual values.
NET is the aggregate download + upload on the default-route
interface (`1.2M`, `12K`); `p-4` reserves its four cells, in decimal
bytes per second. Counting the default route avoids double-counting VPN traffic.
The labels contain no links or inline popups, so surrounding template bindings
own the name, the colour, clicks, and hover. `summary` remains the plugin's own
one-token line (name, metric, and in `full` mode the chart). [Raw numeric segments](#raw-numeric-segments) carry the
same figures without markup. The maintained configuration shows `details` in PTY pagers;
no third-party monitoring application is required. All five accept `[plugin.<id>] summary_mode = "compact" | "full"`,
default to compact, and warn before falling back from an invalid value.

| Plugin | Nominal fast path | Slower path | Additional surface |
| --- | --- | --- | --- |
| `cpu` | CPU ticks every second (`host_processor_info`, in-process) | GPU metadata every 15 seconds (`ioreg`) | `:cpu [refresh]` |
| `memory` | Memory composition every second (`host_statistics64` + `sysctl`, in-process) | — | `:memory [refresh]` |
| `disks` | I/O counters every three seconds (`ioreg`) | Mounted volumes re-read on `core:volumes.changed`; free space every 30 seconds (`df`) | `:disks [refresh]` |
| `network` | Default-interface traffic every second while a traffic segment is shown (`NET_RT_IFLIST2` sysctl, in-process) | Interface, route, address, and SSID discovery at start and on `core:network.changed`; no poll | `:network [refresh]`, `network.addresses` |
| `power` | Battery/power snapshot on `core:power.changed` (IOKit power-source notification); no poll | Health collected during refreshes with a 30-second TTL; explicit `refresh` forces it | `:power [refresh]` |

Every monitor retains 20 fast samples for its chart. The one-second samplers
read kernel counters through the SDK's `flash_plugin::sys` module (the unsafe
FFI lives in the SDK, never in a plugin) instead of forking a CLI per sample;
`disks` runs `ioreg` every three seconds, reducing its scheduled subprocesses
by two-thirds compared with one-second polling; `cpu` uses it only for GPU
metadata and caches the logical CPU count. Every monitor samples on a host
cadence (`ctx.interval`), and a tick that lands while the previous sample still
runs is skipped rather than queued. CPU's first sample brackets one period —
a host deadline it awaits (`ctx.wait`), not a sleep — so the initial publish
carries a real figure.

The monitors are status-bound, so the host runs them only while a surface shows
one of their segments — except once a command such as `:cpu show` has started one,
when it keeps running unobserved. Their cadences therefore also follow
`core:status.observed`: cancelled while none of the plugin's segments is shown,
re-armed with an immediate sample as soon as one is. Unobserved, `:cpu show`,
`:memory show` or `:disks show` samples before it answers.

Details add context using the same snapshots and histories, without additional
collection:

- CPU shows recent average/peak usage and load per logical CPU, with the
  1/5/15-minute load windows identified.
- Memory shows free, wired and compressed bytes as shares of physical memory,
  plus unused swap. Its used count includes cached and reclaimable pages; it
  is not a memory-pressure measurement.
- Disks show read/write totals since device reset and each visible volume's
  used, total and free space. Volume names and mount paths occupy separate rows.
- Network shows receive/send totals for the current default-route interface,
  plus recent peaks. An interface change cannot retain another interface's totals.
- Battery shows design and full-charge capacities in mAh alongside health,
  cycles, temperature and adapter power. Only raw capacity fields are used;
  IOKit's percentage-valued `MaxCapacity` is not an mAh fallback.

Standard detail layouts target 50 terminal columns, the default
`[popup] min_width` of 480 points at the 13-point font with 10-point padding
and a one-point border. A longer external name, path or address widens the
popup up to `max_width` (750 points, 80 columns) and wraps past it. The pager
reserves one footer row. Taller content scrolls in the pager. Smaller widths
wrap more lines.
See [popups](popups.md) for the presentation boundary.

Keep the ownership boundaries intact:

- Register sampling cadences with the host (`ctx.interval`) instead of arming a
  timer, at the priority the [scheduling](#scheduling) table gives: one clock drives every
  monitor, so their wake-ups coalesce.
- `system` owns destructive and session-level system actions, not telemetry.
- `caffeinate` alone owns sleep-assertion lifecycle.
- Core owns date/time rendering; `answers` provides timezone lookup.
- Weather remains separate because it requires an explicit network/location
  policy.

## Scheduling

No plugin arms a timer or sleeps to schedule work. Every cadence, deadline and
wait is registered with the host clock at an explicit priority (see
[runtime ownership](architecture.md)): `high` for a value on screen that the
user watches change, `normal` for ordinary sampling and settles, `low` for
remote pulls, retries and backoffs. Cadences behind a segment register only
while a surface shows it.

| Plugin · registration | Cadence or deadline | Priority | Why |
| --- | --- | --- | --- |
| `cpu` · CPU sample | 1 s while observed | high | A one-second figure ticks visibly |
| `cpu` · first-sample bracket | One 1 s wait per process | high | The first figure on screen waits on it |
| `cpu` · GPU sample | 15 s while observed | normal | Nobody watches it tick |
| `memory` · sample | 1 s while observed | high | A one-second figure ticks visibly |
| `network` · traffic | 1 s while a traffic segment is shown | high | One-second rates tick visibly |
| `disks` · I/O activity | 3 s while observed | normal | A tenth of a second is invisible at three seconds |
| `processes` · top tables | 2 s while `top_cpu`/`top_mem` is shown | high | A table someone has open |
| `processes` · focused app | 10 s while `focused_app_details` is shown | normal | A tenth of a second is invisible at ten seconds |
| `processes` · focus settle | 300 ms after a focus change | high | The placeholder on screen waits on it |
| `tmux` · inventory settle | 100 ms quiet, 1 s at most, after a control-mode change | high | It redraws the session and window segments |
| `tmux` · window-title settle | 300 ms quiet, 10 s at most | normal | Catalog only |
| `tmux` · socket retry | 5, 15, 60 s backoff | low | A retry nobody waits on |
| `tmux` · observer reattach | 1, 5, 15, 60 s backoff | low | A retry nobody waits on |
| `tmux` · remote hosts | 5 s, retried 15–60 s | low | A remote pull over SSH |
| `answers` · ECB rates | 6 h, retried every 15 min | low | A remote pull |
| `feed` · articles | `refresh_interval` (300 s default) | low | A remote pull |
| `browsers`, `kitty`, `windows` · settles | 300 ms–1 s windows, AX bursts up to 10 s | normal | Catalogs nobody watches refresh |
| `browsers` · Firefox tab selection beats | 120–250 ms inside one selection | high | The user waits on the switch |

`caffeinate` registers nothing: a timed assertion is bounded by
`caffeinate -t` itself and ends on the process's exit event.

## Raw numeric segments

Alongside the styled labels, each monitor publishes plain values without
markup, so templates, numeric format markers and widgets can scale, chart or
compare them. They reuse the samples and discovery results above and add no
collection, timer or subprocess. They travel in the same publish-if-changed
frame as the styled segments, so an unchanged frame stays off the wire.

| Segment | Value | Example |
| --- | --- | --- |
| `#{flash.plugin.cpu.percent}` | Total CPU, integer 0–100 | `23` |
| `#{flash.plugin.cpu.history}` | Retained CPU totals, integers, oldest first | `12 18 23` |
| `#{flash.plugin.cpu.load}` | One-minute load average, two decimals | `3.47` |
| `#{flash.plugin.cpu.uptime}` | Time since boot, sleep included, two units | `3d 4h` |
| `#{flash.plugin.memory.percent}` | Used memory, integer 0–100 | `68` |
| `#{flash.plugin.memory.history}` | Retained memory percentages, oldest first | `67 68 68` |
| `#{flash.plugin.disks.percent}` | Startup-volume usage, integer 0–100 | `57` |
| `#{flash.plugin.disks.read_bps}`, `write_bps` | Aggregate disk rates, whole bytes/s | `1572864` |
| `#{flash.plugin.disks.read}`, `write` | The same rates in binary units | `1.5 MiB/s` |
| `#{flash.plugin.network.down_bps}`, `up_bps` | Default-route rates, whole bytes/s | `48213` |
| `#{flash.plugin.network.down_history}`, `up_history` | Retained rates, whole bytes/s, oldest first | `0 1536 48213` |
| `#{flash.plugin.network.address}` | First IPv4 address of the default-route interface | `192.168.1.20` |
| `#{flash.plugin.power.percent}` | Battery charge, integer 0–100 | `73` |
| `#{flash.plugin.power.state}` | `charging`, `discharging`, `charged` or `ac` | `charging` |

Histories hold the same 20 samples as the charts and are space-separated.
Percentages round to the nearest integer and reach 100; the 99 cap belongs to
the fixed-width labels. An empty value clears the segment, because unknown is
not zero: a desktop without a battery clears `power.percent`, and a rate
before its second sample or after its stale window clears with its history,
while an idle disk or link publishes `0`. `power.state` prefers the battery's
own reading; `ac` covers a desktop and a battery held on the adapter without
charging. `network.address` follows discovery (at start and on each
`core:network.changed`) and stays empty for an IPv6-only default route.
`cpu.uptime` is one `CLOCK_MONOTONIC` read per CPU sample through the `nix` crate, which `network` already uses for
`getifaddrs`; Darwin derives that clock from `kern.boottime`, so it counts
sleep, as `uptime(1)` does.

## Top processes

The `processes` plugin publishes conky's `${top}` tables as two status
segments, one row per process, busiest first:

| Segment | Rows ranked by | Value column |
| --- | --- | --- |
| `#{flash.plugin.processes.top_cpu}` | CPU, as a share of one core averaged over the last sample period | `12.5%` |
| `#{flash.plugin.processes.top_mem}` | Resident memory | `1.2 GiB` |

Each row is a name column 15 cells wide (longer names end in `…`) and a
right-aligned value; ties rank by name, then pid, so equal figures never
shuffle rows. The value is a multi-line table, so it reads best in a desktop
widget or a named popup; the bar joins its lines.

```toml
[plugin.processes]
top_count = 5 # rows per table, an integer from 1 to 20
```

An invalid `top_count` logs a warning and uses 5. Sampling is scoped to
observation: the host reports which of the plugin's segments a surface shows
(`core:status.observed`, see the [protocol](plugin-protocol.md#status-observation)),
and the plugin registers its two-second sample with the host clock only while
`top_cpu` or `top_mem` is among them. A table that stops being shown is
cleared, so showing it again never reads stale figures. Rows come from
`host.process_table`, the plugin's one process model, so no subprocess runs.

`#{flash.plugin.processes.focused_app_details}` follows the same rule. Focus
changes only record which app is focused until the segment is observed; while
it is, the plugin samples that app once a focus burst settles and every ten
seconds for its CPU figure, which has no change event. The `!kill` process
catalog has no cadence at all: it refreshes when an app launches or quits and
when the flashlight opens.

## Refresh and failure invariants

Each monitor performs an initial refresh and keeps its last-good state across
transient collection failures. Publish only when the rendered value changes,
and latch a repeated failure until a successful collection clears it. Valid
hardware absence is data rather than failure—for example, a desktop without a
battery publishes the battery-not-installed surface.

Disk and network rates and histories still expire after their bounded stale
windows. Retaining last-good metadata must not leave an inactive collector
looking active indefinitely.

An explicit `refresh` command must not wait behind a background sample. It
attempts the collector non-blockingly and returns the cached report when the
collector is occupied. `disks`, `network`, and `power` express this with
`RefreshGate::try_run`; CPU and memory use equivalent per-collector try-locks.
Background/event producers may wait for the gate when the eventual newest
snapshot matters.

Keep high-frequency measurement separate from discovery and health work.
Independent collectors that become due together—CPU/GPU, disk I/O/capacity,
and power/health—run concurrently so their timeouts do not stack.
Power events refresh the charge and source immediately while respecting the
health TTL, so a burst of notifications does not repeatedly spawn `ioreg`.

## Markup and sandbox boundary

Externally sourced labels enter a rich status value only through
`Markup::text`, which doubles literal hashes; intentional `#[...]` markup uses
`Markup::raw` and is never escaped. The shared format/style compiler preserves escaped literal hashes across
expansion. Rendering, fitting, interactions, and terminal serialization consume
typed styled runs; do not reinterpret literal text as markup in a later pass. Variable and alias syntax inside a plugin-published value is literal
text, not template syntax.

The monitor suite stays helperless and deny-default. It may use unprivileged
macOS commands, IOKit metadata, `getifaddrs`, and narrow host capabilities, but
must not grow a privileged resident helper. SMC CPU/GPU temperatures, fan
control, CPU/GPU frequency, and S.M.A.R.T. health therefore remain out of
scope; battery temperature reported by the power APIs is ordinary health data.

`network` intentionally has no broad `network` capability. Route discovery
uses `/usr/sbin/netstat -rn -f inet[6]`, traffic uses in-process interface counters,
and local addresses use `getifaddrs`. Do not replace route discovery with `/sbin/route`,
which requires a broad system-socket grant. SSID reads go through the narrow
`wifi_info` host capability: event-driven discovery reads passively, and only
the explicit `:network refresh` action may request Location authorization.

## Feed headlines

`feed` publishes `summary` and `label`. Neither prints a section name. The
template writes the name, its colour, the link on that name, and the hover:

```toml
[statusbar]
template = "#[align=left]#[popup=feed]#[link=https://example.com]#[label]aggr#[default]#[nolink]#[nopopup] #[popup=feed-article]#{flash.plugin.feed.label}#[nopopup]"

[popup.feed]
command = ["newsboat", "-u", "status/newsboat/urls", "-C", "status/newsboat/config"]
persistent = true
cwd = "."

[popup.feed-article]
command = ["newsboat-article", "$FLASH_STATUS_LINK"]
cwd = "."
```

Set `[plugin.feed] url` to an RSS feed URL; without one, the plugin makes no
network requests. `refresh_interval` defaults to 300 seconds and `cycle_interval`
to 30 seconds. The plugin publishes every article in the window as one
host-rotated carousel; Flash rotates the headline, keeps the visible line until
its scheduled rotation across refreshes, and slides the title and domain
through the full bar height. A name written in the template stays still,
because it is not part of the carousel. The refresh cadence, driven by the
host clock, is the plugin's only timer: an article that leaves the window
drops out at the next refresh.
Other metrics update without this transition, including when pooled layers are reused.

Only items with a valid publication date within the rolling last 24 hours
participate, newest first. Missing dates and future dates are excluded.
A failed refresh still expires old items; a transient network
or parse failure retains the remaining last-good items, while a successful
empty feed clears the segment.

Only the linked title shrinks, ending in an ellipsis while reserving the domain
and outbound arrow. The feed stays before the notch or, without one, before
the actual centre component; its arrow and click target remain visible. RSS item links
open the feed's article page; an Atom `link rel="via"` extension supplies the
original article link when present. For AGGR, this means the title opens the
archived snapshot and the arrow opens the publisher. Each `summary` line owns
its preview, so the title, domain, and arrow share one popup region.

`label` is the same rotating headlines with no outbound arrow and no inline
preview. Its title and domain form one link to the feed item rather than three
separate targets. A `#[popup=…]` around that segment is the hover, so the
configuration points it at any command it likes — a feed reader, a script,
anything. The plugin does not decide what hovering a headline shows. When that
command contains `$FLASH_STATUS_LINK`, Flash expands it to the item link as
the process starts. A template
link around the name addresses the feed itself: clicking the name opens the
feed, clicking the headline or its domain opens that item.

Hovering a `summary` title, domain, or arrow opens a terminal-rendered preview of its opening
lines from `content:encoded`, falling back to `description`. Paragraph breaks,
headings, lists, quotations, emphasis, and code retain their structure. The
excerpt is bounded to 12 logical lines and 900 visible characters; longer
articles end with an ellipsis. Right-click a linked span to pin the
preview; left-click preserves each link destination.

For AGGR, the feed's article body is also the content of its Markdown export.
The plugin prepares the excerpt during the background feed refresh; hovering
opens an owned `less` process over that cached excerpt, without fetching or
starting another collector. The registry removes the pager and its private
snapshot on dismissal. External text is escaped before adding styles, and
truncation preserves complete style markers. URL marker values are escaped separately.

## Validation

Run focused crate tests while iterating, then the repository-wide plugin gate:

```bash
CARGO_TARGET_DIR=build/plugin-target cargo test --manifest-path Plugins/<id>/Cargo.toml
./Scripts/test-plugins.sh --lane all
```

For host popup or layout changes, finish with `./Scripts/install.sh --dev` and
manually verify a stationary hover while the segment updates.
