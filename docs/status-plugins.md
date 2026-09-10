# Status plugins

Flash's status bar is a host-rendered surface fed by named plugin segments.
Plugins publish text and rich marker values through `Context.status`; the host
accepts only names declared by the plugin manifest, updates a plugin's segment
set atomically, and coalesces notifications before rendering. Hovering never
runs plugin work: inline popup content arrives in the same status value, and a
live update re-hit-tests the stationary pointer and replaces the existing popup
in place.

Planned resident-plugin reloads preserve each last status segment for at most
10 seconds while replacement values arrive. Republishing replaces it immediately;
an explicit empty value clears it. Stop, error, removal, and configuration
replacement clear immediately. This avoids blinking during a normal hot reload
without keeping failed telemetry indefinitely. Development builds stage binaries
outside watched plugin directories and replace only changed code or signing
identity; rebuilding unchanged plugins must not trigger resident reloads.

## System-monitor ownership

The local system-monitor suite is deliberately split by resource. Each plugin
owns `summary` and `details`; the summary embeds the details with
`inline_status_popup`, while the standalone details segment supports custom
templates. Each also publishes a popup-free `label` for a named popup: yellow section
name plus a grey fixed-width metric. CPU/MEM/DSK/BAT percentages use two digits plus `%`, capped at 99;
detailed reports retain the actual values. NET uses four cells for aggregate
download + upload on the default-route interface (`1.2M`, ` 12K`), in decimal
bytes per second. Counting the default route avoids double-counting VPN traffic.
The labels contain no links or inline popups, so surrounding template bindings
own clicks and hover. The maintained configuration uses native `details` popups;
no third-party monitoring application is required. All five accept `[plugin.<id>] summary_mode = "compact" | "full"`,
default to compact, and warn before falling back from an invalid value.

| Plugin | Nominal fast path | Slower path | Additional surface |
| --- | --- | --- | --- |
| `cpu` | CPU sample every second, compensating for `iostat` collection time | GPU metadata every 15 seconds | `:cpu [refresh]` |
| `memory` | Memory composition every second | — | `:memory [refresh]` |
| `disks` | I/O counters every second | Mounted-volume capacity every 30 seconds | `:disks [refresh]` |
| `network` | Default-interface traffic every second | Interface, route, address, and SSID discovery every 30 seconds | `:network [refresh]`, `network.addresses` |
| `power` | Battery/power snapshot every second | Battery health every 30 seconds and on `core:power.changed` | `:power [refresh]` |

Every monitor retains 20 fast samples for its chart. CPU is the only fixed-
period loop: it subtracts the blocking sample duration before sleeping. The
other monitors use the SDK interval primitive, whose delay begins after the
awaited callback completes, so their cadence is nominal rather than a wall-
clock guarantee.

Keep the ownership boundaries intact:

- `system` owns destructive and session-level system actions, not telemetry.
- `caffeinate` alone owns sleep-assertion lifecycle.
- Core owns date/time rendering; `timezones` provides timezone lookup.
- Weather remains separate because it requires an explicit network/location
  policy.

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

## Markup and sandbox boundary

Externally sourced labels must pass through `escape_status_text` before they
enter a rich status value. Do not escape intentional `#[...]` markup. The shared format/style compiler preserves escaped literal hashes across
expansion. Rendering, fitting, interactions, and terminal serialization consume
typed styled runs; do not reinterpret literal text as markup in a later pass. Variable and alias syntax inside a plugin-published value is literal
text, not template syntax.

The monitor suite stays helperless and deny-default. It may use unprivileged
macOS commands, IOKit metadata, `getifaddrs`, and narrow host capabilities, but
must not grow a privileged resident helper. SMC CPU/GPU temperatures, fan
control, CPU/GPU frequency, and S.M.A.R.T. health therefore remain out of
scope; battery temperature reported by the power APIs is ordinary health data.

`network` intentionally has no broad `network` capability. Route discovery
uses `/usr/sbin/netstat -rn -f inet[6]`, traffic uses `netstat -bI`, and local
addresses use `getifaddrs`. Do not replace route discovery with `/sbin/route`,
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

The plugin republishes a sanitized last-good cache at startup, refreshes
Anthropic usage at a ten-minute TTL and OpenAI usage at a two-minute TTL, and
rerenders relative reset labels once per minute. Quota labels show an unpadded
dash once the cache is older than twice the provider TTL; cached detail tables
remain available for inspection. Popup hover and status layout
must remain pure reads of that state.

Claude OAuth refresh preserves the complete credential document. Keychain writes
use hex-encoded password data on `security -i` stdin, followed by read-back
verification. Never pass credential JSON to a trailing `security ... -w` on stdin:
that option prompts on the terminal and can save an empty password. Secrets must
remain off subprocess argv and diagnostic output. An already empty credential
requires signing in again through Claude Code.

## Feed headlines

`feed` owns the `summary` segment, selected with
`#{flash.plugin.feed.summary}`. Set `[plugin.feed] url` to an RSS feed URL;
without one, the plugin makes no network requests. `refresh_interval` defaults
to 300 seconds and `cycle_interval` to 30 seconds. Article content uses
`#[cyc]`/`#[nocyc]` for a 0.8-second upward slide. The title, domain, and
outbound arrow move together while the label stays still.
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
for this feed; the default label is `FEED`. The summary owns its label so the
whole row shares one popup region, including short titles after rotation.

Hovering the label, article title, domain, or arrow opens a terminal-rendered preview of its opening
lines from `content:encoded`, falling back to `description`. Paragraph breaks,
headings, lists, quotations, emphasis, and code retain their structure. The
excerpt is bounded to 12 logical lines and 900 visible characters; longer
articles end with an ellipsis. Click the label to pin the preview, or
Option-click any of its links; normal clicks preserve each link destination.

For AGGR, the feed's article body is also the content of its Markdown export.
The plugin prepares the excerpt during the background feed refresh; hovering
only presents the existing terminal document and starts no fetch or child
process. External text is escaped before adding styles, and truncation
preserves complete style markers. URL marker values are escaped separately.

## Validation

Run focused crate tests while iterating, then the repository-wide plugin gate:

```bash
CARGO_TARGET_DIR=build/plugin-target cargo test --manifest-path Plugins/<id>/Cargo.toml
./Scripts/test-plugins.sh --lane all
```

For host popup or layout changes, finish with `./Scripts/install.sh --dev` and
manually verify a stationary hover while the segment updates.
