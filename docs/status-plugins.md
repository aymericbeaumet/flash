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
The host also owns stepping one by hand: a scroll over the run moves to the
previous or next line and restarts its dwell
([status format](status-format.md#jobs-sources-and-flash-styles)), with
nothing for the plugin to publish or handle.

Every value a plugin publishes is computed by the plugin itself, with nothing
else to install. The programs behind a segment's hover are separate: a
`[popup.<name>]` runs whatever terminal program you choose (btop under the
system values, tokscale under the AI quotas, or nothing), and the bar values,
widgets and [monitors](monitors.md) read the plugin segments whether or not a
popup exists.

## System-monitor ownership

The local system figures come from one plugin, `sysinfo`, split inside into
five domains — `cpu`, `memory`, `disks`, `network` and `power` — whose
segments carry the domain as a prefix (`cpu_summary`, `power_details`). Each
domain owns a `summary` and a `details` segment; every summary carries its
preview through `StatusValue::with_preview`, while the standalone details
segment supports custom templates. Each also publishes a popup-free `label`
(`cpu_label`): the metric alone, with no section name, no colour, and no
padding. The host trims a status value, so a leading
space would not survive. The template supplies the name, the colour, and the
width, for example `#[label]CPU#[default] #{p-3:flash.plugin.sysinfo.cpu_label}`.
CPU/MEM/DSK percentages use two digits plus `%` (`p-3`), capped at 99;
battery charge can reach 100%, and detailed reports retain the actual values.
NET is the aggregate download + upload on the default-route
interface (`1.2M`, `12K`); `p-4` reserves its four cells, in decimal
bytes per second. Counting the default route avoids double-counting VPN traffic.
The labels contain no links or inline popups, so surrounding template bindings
own the name, the colour, clicks, and hover. `summary` remains the plugin's own
one-token line (name, metric, and in `full` mode the chart). [Raw numeric segments](#raw-numeric-segments) carry the
same figures without markup. The maintained configuration shows `details` in PTY pagers;
no third-party monitoring application is required. The five domains read one
`[plugins.sysinfo] summary_mode = "compact" | "full"`, default to compact, and
warn once before falling back from an invalid value.

| Domain | Nominal fast path | Slower path | Command |
| --- | --- | --- | --- |
| `cpu` | CPU ticks every second (`host_processor_info`, in-process) | GPU utilization every 15 seconds (IOKit registry, in-process) | `:sysinfo cpu` |
| `memory` | Memory composition every second (`host_statistics64` + `sysctl`, in-process) | — | `:sysinfo memory` |
| `disks` | I/O counters every three seconds (IOKit registry, in-process) | Mounted volumes re-read on `core:volumes.changed`; free space every 30 seconds (`getfsstat` + `statfs`, in-process) | `:sysinfo disks` |
| `network` | Default-interface traffic every second while a traffic segment is shown (`NET_RT_IFLIST2` sysctl, in-process) | Interface, route (`NET_RT_DUMP2` sysctl, in-process), address, and SSID discovery at start and on `core:network.changed`; no poll | `:sysinfo network`; the `network.addresses` catalog |
| `power` | Battery/power snapshot on `core:power.changed` (IOKit power-source notification; IOPowerSources, in-process); no poll | Health from the battery's IOKit registry entry during refreshes, with a 30-second TTL; an explicit refresh forces it | `:sysinfo power` |

`:sysinfo refresh` refreshes every domain at once (the Wi-Fi name included)
and answers with one line of their summaries.

Every domain retains 20 fast samples for its chart. No domain spawns a
process: each reads the kernel and system frameworks through the SDK's
`flash_plugin::sys` module (the unsafe FFI lives in the SDK, never in a
plugin), the same interfaces the CLIs they replaced read, so a busy exec
policy daemon cannot stall a sample. `cpu` reads GPU utilization from the
module's IOKit registry reader and caches the logical CPU count; `disks` reads
the `IOBlockStorageDriver` statistics `ioreg` prints and the local volumes
`df -l` lists; `power` reads the IOPowerSources snapshot `pmset -g batt`
prints and the `AppleSmartBattery` registry entry; `network` reads its default
route from the routing table `netstat -rn` walks. Every domain samples on a
host cadence (`ctx.interval`), and a tick
that lands while the previous sample still runs is skipped rather than queued.
CPU's first sample brackets one period —
a host deadline it awaits (`ctx.wait`), not a sleep — so the initial publish
carries a real figure.

`sysinfo` publishes the `network.addresses` catalog, so the host keeps it
resident; what follows observation is each domain's sampling. The plugin
partitions `core:status.observed` by prefix and feeds each domain its own
segments, so a domain's cadences are cancelled while none of its segments is
shown — by a surface or an enabled [monitor](monitors.md) — and re-armed
with an immediate sample as soon as one is: a bar that shows only `cpu_label`
samples CPU alone. Unobserved, `:sysinfo cpu`, `:sysinfo memory` or
`:sysinfo disks` samples before it answers.

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
  domain, so their wake-ups coalesce.
- Core owns the process values (`flash.top_cpu`, `flash.top_mem`,
  `flash.focused_app_details`) and the system commands (`screen lock`,
  `system sleep`, …); no plugin samples the process table or signals pids.
- Core owns the keep-awake power assertions (`caffeinate on`,
  `#{flash.caffeinate}`); no plugin holds the Mac awake.
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
| `sysinfo` · CPU sample | 1 s while a `cpu_` segment is observed | high | A one-second figure ticks visibly |
| `sysinfo` · first CPU-sample bracket | One 1 s wait per process | high | The first figure on screen waits on it |
| `sysinfo` · GPU sample | 15 s while a `cpu_` segment is observed | normal | Nobody watches it tick |
| `sysinfo` · memory sample | 1 s while a `memory_` segment is observed | high | A one-second figure ticks visibly |
| `sysinfo` · network traffic | 1 s while a traffic segment is shown | high | One-second rates tick visibly |
| `sysinfo` · disk I/O activity | 3 s while a `disks_` segment is observed | normal | A tenth of a second is invisible at three seconds |
| `terminals` · tmux inventory settle | 100 ms quiet, 1 s at most, after a control-mode change | high | It redraws the session and window segments |
| `terminals` · tmux window-title settle | 300 ms quiet, 10 s at most | normal | Catalog only |
| `terminals` · tmux socket retry | 5, 15, 60 s backoff | low | A retry nobody waits on |
| `terminals` · tmux observer reattach | 1, 5, 15, 60 s backoff | low | A retry nobody waits on |
| `terminals` · remote tmux hosts | 5 s, retried 15–60 s | low | A remote pull over SSH |
| `answers` · ECB rates | 6 h, retried every 15 min | low | A remote pull |
| `feed` · articles | `refresh_interval` (300 s default) | low | A remote pull |
| `aiproviders` · quotas | 60 s while a quota segment is shown; Codex and Grok fetch at most every 2 min, 5 min after a failure | low | A file read and remote pulls |
| `browsers` · settles | 300 ms–1 s windows, AX bursts up to 10 s | normal | Catalogs nobody watches refresh |
| `browsers` · Firefox tab selection beats | 120–250 ms inside one selection | high | The user waits on the switch |

## Raw numeric segments

Alongside the styled labels, each domain publishes plain values without
markup, so templates, numeric format markers and widgets can scale, chart or
compare them. They reuse the samples and discovery results above and add no
collection, timer or subprocess. They travel in the same publish-if-changed
frame as the styled segments, so an unchanged frame stays off the wire.

| Segment | Value | Example |
| --- | --- | --- |
| `#{flash.plugin.sysinfo.cpu_percent}` | Total CPU, integer 0–100 | `23` |
| `#{flash.plugin.sysinfo.cpu_history}` | Retained CPU totals, integers, oldest first | `12 18 23` |
| `#{flash.plugin.sysinfo.cpu_load}` | One-minute load average, two decimals | `3.47` |
| `#{flash.plugin.sysinfo.cpu_uptime}` | Time since boot, sleep included, two units | `3d 4h` |
| `#{flash.plugin.sysinfo.memory_percent}` | Used memory, integer 0–100 | `68` |
| `#{flash.plugin.sysinfo.memory_history}` | Retained memory percentages, oldest first | `67 68 68` |
| `#{flash.plugin.sysinfo.disks_percent}` | Startup-volume usage, integer 0–100 | `57` |
| `#{flash.plugin.sysinfo.disks_read_bps}`, `write_bps` | Aggregate disk rates, whole bytes/s | `1572864` |
| `#{flash.plugin.sysinfo.disks_read}`, `write` | The same rates in binary units | `1.5 MiB/s` |
| `#{flash.plugin.sysinfo.network_down_bps}`, `up_bps` | Default-route rates, whole bytes/s | `48213` |
| `#{flash.plugin.sysinfo.network_down_history}`, `up_history` | Retained rates, whole bytes/s, oldest first | `0 1536 48213` |
| `#{flash.plugin.sysinfo.network_address}` | First IPv4 address of the default-route interface | `192.168.1.20` |
| `#{flash.plugin.sysinfo.power_percent}` | Battery charge, integer 0–100 | `73` |
| `#{flash.plugin.sysinfo.power_state}` | `charging`, `discharging`, `charged` or `ac` | `charging` |

Histories hold the same 20 samples as the charts and are space-separated.
Percentages round to the nearest integer and reach 100; the 99 cap belongs to
the fixed-width labels. An empty value clears the segment, because unknown is
not zero: a desktop without a battery clears `power_percent`, and a rate
before its second sample or after its stale window clears with its history,
while an idle disk or link publishes `0`. `power_state` prefers the battery's
own reading; `ac` covers a desktop and a battery held on the adapter without
charging. `network_address` follows discovery (at start and on each
`core:network.changed`) and stays empty for an IPv6-only default route.
`cpu_uptime` is one `CLOCK_MONOTONIC` read per CPU sample through the `nix`
crate, which the network domain already uses for `getifaddrs`; Darwin derives
that clock from `kern.boottime`, so it counts sleep, as `uptime(1)` does.

## Top processes

The process tables and the focused app's figures are core values, not plugin
segments: `#{flash.top_cpu}`, `#{flash.top_mem}` and
`#{flash.focused_app_details}`, with `[statusbar] top_count` rows per table.
Flash samples them through libproc on a background queue, on the same host
clock (`core:process_top` every 2 s, `core:process_focused` every 10 s and
`core:process_focus_settle` 300 ms after a focus change), only while a
surface reads them; see [process values](status-format.md#process-values).
The `processes.processes` flashlight source lists every process and asks
before it terminates one.

## Refresh and failure invariants

Each domain performs an initial refresh and keeps its last-good state across
transient collection failures. Publish only when the rendered value changes,
and latch a repeated failure until a successful collection clears it. Valid
hardware absence is data rather than failure—for example, a desktop without a
battery publishes the battery-not-installed surface.

Disk and network rates and histories still expire after their bounded stale
windows. Retaining last-good metadata must not leave an inactive collector
looking active indefinitely.

An explicit `:sysinfo refresh` must not wait behind a background sample. It
attempts each collector non-blockingly and keeps the cached report where the
collector is occupied. The disks, network and power domains express this with
`RefreshGate::try_run`; CPU and memory use equivalent per-collector try-locks.
Background/event producers may wait for the gate when the eventual newest
snapshot matters.

Keep high-frequency measurement separate from discovery and health work:
GPU utilization, disk capacity, and battery health follow their own slower
cadence or TTL rather than every fast sample. `disks` re-reads capacity off
the plugin's executor (`spawn_blocking`), because `statfs` touches every local
file system. Power events refresh the charge and source immediately while
respecting the health TTL, so a burst of notifications copies the battery's
registry properties once.

## Markup and sandbox boundary

Externally sourced labels enter a rich status value only through
`Markup::text`, which doubles literal hashes; intentional `#[...]` markup uses
`Markup::raw` and is never escaped. The shared format/style compiler preserves escaped literal hashes across
expansion. Rendering, fitting, interactions, and terminal serialization consume
typed styled runs; do not reinterpret literal text as markup in a later pass. Variable and alias syntax inside a plugin-published value is literal
text, not template syntax.

`sysinfo` stays helperless and deny-default. It may use unprivileged
macOS commands, IOKit metadata, `getifaddrs`, and narrow host capabilities, but
must not grow a privileged resident helper, and its profile runs no executable
but its own. It keeps one sandbox allowance, powerd's
`com.apple.PowerManagement.control` service: without it IOPowerSources still
names the providing source but silently lists no battery. It is the only
bundled manifest with a `sandbox.mach` entry. SMC CPU/GPU temperatures, fan
control, CPU/GPU frequency, and S.M.A.R.T. health therefore remain out of
scope; battery temperature reported by the power APIs is ordinary health data.

`sysinfo` intentionally has no broad `network` capability. Route discovery
reads the first `default` row `netstat -rn -f inet` (else `inet6`) would print,
from the `NET_RT_DUMP2` routing sysctl; traffic uses in-process interface
counters, and local addresses use `getifaddrs`. Do not replace route discovery
with `/sbin/route` or a routing socket, which require a broad system-socket
grant. SSID reads go through the narrow
`wifi_info` host capability: event-driven discovery reads passively, and only
the explicit `:sysinfo refresh` action may request Location authorization.

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

Set `[plugins.feed] url` to an RSS feed URL; without one, the plugin makes no
network requests. `refresh_interval` defaults to 300 seconds and `cycle_interval`
to 30 seconds. RSS responses are limited to 32 MiB, including streamed responses
without a declared content length. The plugin publishes every article in the window as one
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
archived snapshot and the arrow opens the publisher. The parenthesised domain
is the item's RSS `<source>` text when the feed names one, so the feed decides
how a publisher reads (AGGR writes `youtube.com/@channel`); otherwise it is
the original link's host without `www.`. Each `summary` line owns
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

## AI quotas

`aiproviders` publishes one segment per provider, `claude`, `codex` and
`grok`. Each carries only the weekly quota left and the time to its reset
(`6%↻22h`, `9%↻1d`, `47%↻30min`), with no name, colour or padding, so the
template owns the rest:

```toml
[statusbar]
template = "#[label]Cld#[default] #{flash.plugin.aiproviders.claude} #[label]Cdx#[default] #{flash.plugin.aiproviders.codex} #[label]Grk#[default] #{flash.plugin.aiproviders.grok}"
```

Each provider is read with what its own CLI already stored, so the segments
need nothing else; wrapping them in `#[popup=…]` adds a hover running the
program of your choice, such as tokscale in the
[example status strip](examples/statusbar/flash.toml).

- Claude: a read-only request to Anthropic's usage endpoint with the OAuth
  access token Claude Code already stored (its login Keychain item, else
  `~/.claude/.credentials.json`); the seven-day window is the quota. Flash
  never writes those credentials and never uses the refresh token; an
  expired token keeps the last reading until running `claude` renews it.
- Codex: the installed `codex app-server --stdio`, asked for
  `account/rateLimits/read`; the window of a day or longer is the quota.
- Grok: a read-only request to Grok's billing endpoint with the access token
  already in `~/.grok/auth.json` (`grok_auth_file`). Flash never writes that
  file and never uses its refresh token; an expired token keeps the last
  reading until running `grok` renews it.

A reading stays until a newer sample replaces it: a missing file, a failed
fetch or an expired token never turns it into a dash. Every window is weekly,
so once a stored reset passes the quota shows full (`99%`, capped like the
system labels) and counts down to the following reset. An em dash means the
provider has never produced a weekly window. The percentage left is 100 minus
the used percentage rounded down; the countdown is minutes under an hour,
hours under a day, then calendar days. Readings persist in the plugin's data
directory (`quotas.json`, mode 0600: percentages, reset, fetch and retry
times, never tokens), so a restarted plugin shows them at once.

Each quota refreshes only while a status surface shows its own segment, on a
one-minute host cadence; a newly shown segment refreshes at once. Codex and
Grok reuse a reading for two minutes and wait five after a failed fetch.
Starting the plugin for a chat bang reads no quota.

## Validation

Run focused crate tests while iterating, then the repository-wide plugin gate:

```bash
mise run test:plugin <id>
mise run test:plugins
```

For host popup or layout changes, finish with `mise run install:dev` and
manually verify a stationary hover while the segment updates.
