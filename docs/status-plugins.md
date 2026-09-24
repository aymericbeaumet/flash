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
templates. Each also publishes a popup-free `label` for a named popup: yellow section
name plus a grey metric. CPU/MEM/DSK percentages use two digits plus `%`, capped at 99;
battery charge can reach 100%, and detailed reports retain the actual values.
NET uses four cells for aggregate download + upload on the default-route
interface (`1.2M`, ` 12K`), in decimal
bytes per second. Counting the default route avoids double-counting VPN traffic.
The labels contain no links or inline popups, so surrounding template bindings
own clicks and hover. [Raw numeric segments](#raw-numeric-segments) carry the
same figures without markup. The maintained configuration shows `details` in PTY pagers;
no third-party monitoring application is required. All five accept `[plugin.<id>] summary_mode = "compact" | "full"`,
default to compact, and warn before falling back from an invalid value.

| Plugin | Nominal fast path | Slower path | Additional surface |
| --- | --- | --- | --- |
| `cpu` | CPU ticks every second (`host_processor_info`, in-process) | GPU metadata every 15 seconds (`ioreg`) | `:cpu [refresh]` |
| `memory` | Memory composition every second (`host_statistics64` + `sysctl`, in-process) | — | `:memory [refresh]` |
| `disks` | I/O counters every three seconds (`ioreg`) | Mounted-volume capacity every 30 seconds | `:disks [refresh]` |
| `network` | Default-interface traffic every second (`NET_RT_IFLIST2` sysctl, in-process) | Interface, route, address, and SSID discovery every 30 seconds | `:network [refresh]`, `network.addresses` |
| `power` | Battery/power snapshot on `core:power.changed`, with a 60-second safety poll | Health collected during refreshes with a 30-second TTL; explicit `refresh` forces it | `:power [refresh]` |

Every monitor retains 20 fast samples for its chart. The one-second samplers
read kernel counters through the SDK's `flash_plugin::sys` module (the unsafe
FFI lives in the SDK, never in a plugin) instead of forking a CLI per sample;
`disks` runs `ioreg` every three seconds, reducing its scheduled subprocesses
by two-thirds compared with one-second polling; `cpu` uses it only for GPU
metadata and caches the logical CPU count. CPU is the only
fixed-period loop: it subtracts the sample duration before sleeping, and its
first sample brackets one period so the initial publish carries a real figure.
The other monitors use the SDK interval primitive, whose delay begins after the
awaited callback completes, so their cadence is nominal rather than a wall-
clock guarantee.

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

Standard detail layouts target 50 terminal columns. Long external names, paths
and addresses wrap in the pager.
Use `[statusbar] popup_max_width = 480` for the standard 13-point font: it fits
50 content columns with 10-point padding and a one-point border. The longest
cached Codex report has 27 content rows; the pager reserves one additional
footer row. Taller content scrolls in the pager. Smaller widths wrap more lines.
See [status popups](status-popups.md) for the presentation boundary.

Keep the ownership boundaries intact:

- Register sampling cadences with the host (`ctx.interval`) instead of arming a
  timer: one clock drives every monitor, so their wake-ups coalesce.
- `system` owns destructive and session-level system actions, not telemetry.
- `caffeinate` alone owns sleep-assertion lifecycle.
- Core owns date/time rendering; `answers` provides timezone lookup.
- Weather remains separate because it requires an explicit network/location
  policy.

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
charging. `network.address` follows the 30-second discovery pass and stays
empty for an IPv6-only default route. `cpu.uptime` is one `CLOCK_MONOTONIC`
read per CPU sample through the `nix` crate, which `network` already uses for
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
`wifi_info` host capability: background polling is passive, and only the
explicit `:network refresh` action may request Location authorization.

## Adjacent AI usage status

`aiproviders` is adjacent to, not part of, the local system-monitor suite. It
publishes `claude_label`/`claude_details` and `codex_label`/`codex_details`.
Cld/Cdx labels show the remaining weekly quota with an unpadded percentage capped at 99, followed by `↻`
and the time until the weekly window resets (for example `53%↻5d`). Model-specific quotas stay in
details: Fable under Claude, and the separate `codex_bengalfox` rate-limit
bucket as Astra under Codex. “Astra” is a local presentation alias, not app-server schema
terminology. Grok remains a launcher only; do not add quota polling that reads
or mutates unsupported credential stores.

Claude and Codex use the same stacked quota sections: remaining percentage and
bar, used percentage, reset delay and usage pace. Reset details retain two units
(`1h 30m`) while the status label stays compact. Pace compares the used share
with the elapsed share of that window, in percentage points; missing reset data
is unavailable, and an elapsed reset says `Awaiting refresh` until new data
arrives. Missing provider/model windows remain explicit instead of implying
unused quota. The largest Codex report is 26 lines when fresh or 27 when cached.

The plugin republishes a sanitized last-good cache at startup. One timer runs
each minute to rerender relative labels and check the independent fetch TTLs: ten minutes
for Anthropic and two minutes for OpenAI. Only changed rendered segments publish.
Quota labels show an unpadded dash once the cache is older than twice the provider
TTL; cached details remain available for inspection. Popup hover and status
layout are pure reads of that state and perform no authentication or API calls.
The plugin is status-bound, so it is resident only while the bar or a popup
shows one of its segments. A chat-launcher bang such as `!claude` still starts
it on demand, and a started process keeps the quota timer, including its
credential reads, until it exits.

Claude Code's credentials are read-only by default. The plugin reads the
`Claude Code-credentials` Keychain item, or `~/.claude/.credentials.json`, and
uses the stored access token until it expires. It then marks the Claude quota
cached or unavailable with a `Token expired · run Claude Code to renew it`
hint, and rereads the store every five minutes until Claude Code has renewed
the token. `[plugin.aiproviders] refresh_claude_code_credentials = true` opts
into renewing the token with Claude Code's OAuth client two minutes before
expiry and writing the rotation back to Claude Code's store. Rotating another
app's refresh token can sign that app out.

An opted-in refresh preserves the complete credential document. Keychain writes
use hex-encoded password data on `security -i` stdin, followed by read-back
verification. Never pass credential JSON to a trailing `security ... -w` on stdin:
that option prompts on the terminal and can save an empty password. Secrets must
remain off subprocess argv and diagnostic output. An already empty credential
requires signing in again through Claude Code.

## Feed headlines

`feed` owns the `summary` and `label` segments, selected with
`#{flash.plugin.feed.summary}` and `#{flash.plugin.feed.label}`. Set
`[plugin.feed] url` to an RSS feed URL;
without one, the plugin makes no network requests. `refresh_interval` defaults
to 300 seconds and `cycle_interval` to 30 seconds. The plugin publishes every
article in the window as one host-rotated carousel; Flash rotates it, keeps the
visible headline until its scheduled rotation across refreshes, and slides the
title, domain, and outbound arrow together through the full bar height while
the label stays still as the carousel's prefix. The plugin wakes only when the
oldest article leaves the window.
Other metrics update without this transition, including when pooled layers are reused.

Only items with a valid publication date within the rolling last 24 hours
participate, newest first. Missing dates and future dates are excluded.
Rotation also expires old items during a failed refresh; a transient network
or parse failure retains the remaining last-good items, while a successful
empty feed clears the segment.

Only the linked title shrinks, ending in an ellipsis while reserving the domain
and outbound arrow. The feed stays before the notch or, without one, before
the actual centre component; its arrow and click target remain visible. RSS item links
open the feed's article page; an Atom `link rel="via"` extension supplies the
original article link when present. For AGGR, this means the title opens the
archived snapshot and the arrow opens the publisher. Set `label = "AGGR"`
for this feed; the default label is `FEED`. Each carousel line owns its
preview, so the title, domain, and arrow share one popup region.

`label` carries the same rotating headlines with the same still prefix and
cadence, but no outbound arrow and no inline preview, and its title and domain
form one link to the feed item rather than three separate targets. Binding
`label` instead of `summary` hands hover to the surrounding template, so a
configuration can wrap it in its own `#[popup=…]` and point that popup at any
terminal command it likes — a feed reader, a script, anything. The plugin does
not decide what hovering a headline shows; the configuration does. The still
prefix stays outside the item link, so a template link wrapping the segment
addresses the feed itself: clicking the prefix opens the feed, clicking the
headline or its domain opens that item.

```toml
# A popup the configuration owns end to end.
"@left" = "#[popup=feed]#[link=https://example.com]#{flash.plugin.feed.label}#[nolink]#[nopopup]"

[terminal.feed]
command = ["newsboat", "-u", "status/newsboat/urls", "-C", "status/newsboat/config"]
persistent = true
working_directory = "."
```

Hovering the article title, domain, or arrow opens a terminal-rendered preview of its opening
lines from `content:encoded`, falling back to `description`. Paragraph breaks,
headings, lists, quotations, emphasis, and code retain their structure. The
excerpt is bounded to 12 logical lines and 900 visible characters; longer
articles end with an ellipsis. Option-click any of its links to pin the
preview; normal clicks preserve each link destination.

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
