# Status plugins

Flash's status bar is a host-rendered surface fed by named plugin segments.
Plugins publish text and rich marker values through `Context.status`; the host
accepts only names declared by the plugin manifest, updates a plugin's segment
set atomically, and coalesces notifications before rendering. Hovering never
runs plugin work: inline popup content arrives in the same status value, and a
live update re-hit-tests the stationary pointer and replaces the existing popup
in place.

## System-monitor ownership

The local system-monitor suite is deliberately split by resource. Each plugin
owns exactly `summary` and `details`; the summary embeds the details with
`inline_status_popup`, while the standalone details segment supports custom
templates. All five accept `[plugin.<id>] summary_mode = "compact" | "full"`,
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
owns one unified `summary`/`details` pair: Fable is nested under Claude, and the
separate `codex_bengalfox` rate-limit bucket is presented as Astra beneath
OpenAI. “Astra” is a local presentation alias, not app-server schema
terminology. Grok remains a launcher only; do not add quota polling that reads
or mutates unsupported credential stores.

The plugin republishes a sanitized last-good cache at startup, refreshes
Anthropic usage at a ten-minute TTL and OpenAI usage at a two-minute TTL, and
rerenders relative reset labels once per minute. Popup hover and status layout
must remain pure reads of that state.

## Validation

Run focused crate tests while iterating, then the repository-wide plugin gate:

```bash
CARGO_TARGET_DIR=build/plugin-target cargo test --manifest-path Plugins/<id>/Cargo.toml
./Scripts/test-plugins.sh --lane all
```

For host popup or layout changes, finish with `./Scripts/install.sh --dev` and
manually verify a stationary hover while the segment updates.
