# Telemetry

Flash speaks [OpenTelemetry](https://opentelemetry.io/) both ways, and both
are off until you turn them on:

- **In:** an OTLP/HTTP receiver on `127.0.0.1:4318` takes metrics, logs and
  traces from any program on your Mac that exports OpenTelemetry — Claude
  Code, a local service, a script. Any received metric becomes a status-format
  value, `#{flash.otel:<metric>}`, so it can sit in the bar, a desktop widget
  or a [monitor](monitors.md) that alerts on it. The help's telemetry page
  (`flash telemetry show`) lists everything received.
- **Recorded:** `flash metrics record` adds a measurement from a script, a
  mapping or the command line, without a collector: it reads like a received
  metric and exports with Flash's own.
- **Out:** an OTLP/HTTP exporter sends Flash's own metrics, the ones you
  record, traces and, if you ask, logs to the collector or backend you name.

Flash is not a telemetry backend: the receiver keeps a short, bounded window
in memory for the bar and the page. Point a real collector (the
OpenTelemetry Collector, Grafana Alloy, a vendor agent) at your programs as
well when you want storage, dashboards or queries.

## Quick start: Claude Code in the bar

Turn the receiver on in `~/.config/flash/flash.toml`:

```toml
[telemetry.receiver]
enabled = true
```

Start Claude Code with its telemetry exported to Flash. These variables are
Claude Code's own ([monitoring usage](https://code.claude.com/docs/en/monitoring-usage));
put them in your shell profile or Claude Code's `settings.json` `env`:

```sh
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf   # http/json works too
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318
export OTEL_METRIC_EXPORT_INTERVAL=10000           # 10 s; the default is 60 s
# Optional: its events (prompts redacted unless you opt in) on the page.
export OTEL_LOGS_EXPORTER=otlp
```

Claude Code exports, among others, `claude_code.cost.usage` (USD),
`claude_code.token.usage` (tokens, with `type` `input`, `output`,
`cacheRead` or `cacheCreation`), `claude_code.session.count`,
`claude_code.lines_of_code.count` (`type` `added` or `removed`),
`claude_code.commit.count`, `claude_code.pull_request.count`,
`claude_code.code_edit_tool.decision` and `claude_code.active_time.total`
(seconds, `type` `user` or `cli`). Each point carries `session.id` and, for
cost and tokens, `model`. They are counters with delta temporality by default,
so Flash keeps their running totals.

A bar segment showing today's spend and the output-token rate, only while
Claude Code reports:

```toml
[statusbar]
template = """
#[align=right]#{?flash.otel.total:claude_code.cost.usage,#[label]Claude#[default] \
$#{e|+|f|2:#{flash.otel.total:claude_code.cost.usage},0} \
#{e|*|f|0:#{flash.otel.rate:claude_code.token.usage[type=output]},60} tok/min · ,}%H:%M
"""
```

A monitor that alerts when the spend crosses $10, and again at $25:

```toml
[monitors.claude_spend]
value = "#{e|+|f|2:#{flash.otel.total:claude_code.cost.usage},0}"
message = "Claude Code spend"
detail = "#{flash.otel.total:claude_code.token.usage} tokens"
warning = 10
error = 25
```

`total` counts from the first point Flash received for each session, so it
is the spend since Flash started listening, across every session; quitting
Flash starts it again. Filter one model with
`#{flash.otel.total:claude_code.cost.usage[model=claude-opus-*]}`.

## Reading metrics in a status format

```text
#{flash.otel:<metric>}
#{flash.otel.<field>:<metric>[<attribute>=<value>][<attribute>!=<value>]…}
```

The whole text inside `#{…}` is one value name, so it works wherever a value
does: in the bar, a text popup, a widget, a monitor's `value`, `message` or
`detail`, a conditional (`#{?flash.otel:m,…,…}`), a comparison or tmux
arithmetic (`#{e|*|f|1:#{flash.otel.rate:m},60}`). tmux itself reads it as an
unknown value and expands it to nothing.

A filter keeps the series whose attribute matches: `[type=input]`. `!=`
excludes, `*` in the value matches any run of characters, and an empty value
matches a missing attribute (`[agent.name=]`). Filters see the resource's
attributes (`service.name`), the instrumentation scope's, and the point's own,
the point's winning a clash. Values cannot contain `]`.

When several series match, they combine: values and totals add up, `min` and
`max` take the extreme, percentiles merge the buckets. Filter down to one
series to read a gauge that does not add, such as a temperature.

| Field | Gauge | Sum (counter) | Histogram, exponential histogram | Summary |
| --- | --- | --- | --- | --- |
| *(none)*, `latest` | Latest value | Latest point: the cumulative value, or the last delta | Mean of the latest window | Mean of the latest window |
| `rate` | Change per second between the last two points | Increase per second over the latest interval | Observations per second | Observations per second |
| `total` | — | Running total | — | — |
| `count` | — | — | Observations, running | Observations, running |
| `sum` | — | — | Sum of observations, running | Sum, running |
| `min`, `max` | Over the retained points | — | As reported | Quantiles 0 and 1, when reported |
| `mean` | Over the retained points | — | Of the latest window | Of the latest window |
| `p50`, `p95`, `p99.9`, … | — | — | Interpolated in the latest window's buckets | The reported quantile, for one series |

A field a kind does not have, a metric nothing sent and a filter nothing
matches all expand to nothing, which a monitor reads as *unknown*. Numbers
are written plainly — `42`, `0.25`, at most six decimals — so round them
with arithmetic (`#{e|+|f|2:…,0}`).

How each temporality is kept:

- A **cumulative** sum's total is its reported value; when the sender
  restarts (a new start time, or a monotonic value going down) the earlier
  run's value is carried, so the total keeps rising.
- A **delta** sum adds each point to a running total from the first point
  Flash received. A point no newer than the latest — a retried export — is
  ignored, so nothing counts twice.
- A histogram's **window** is its latest delta point, or the difference
  between its two latest cumulative points; mean and percentiles read it.
- A **rate** is per second over the latest reporting interval. A series that
  has not reported for two and a half intervals (at least 10 s) is *quiet*
  and its rate is 0: delta exporters such as Claude Code send nothing while
  nothing happens.

`flash config check` and the configuration alert report a malformed form
(`#{flash.otel.median:m}`) and any `#{flash.otel…}` read while the receiver
is off.

### Cost

A surface or monitor re-evaluates only when a metric it reads receives a
point or one of its series goes quiet; other metrics arriving wake nothing.
The quiet deadline rides the shared clock at `low` priority, armed only while
something reads a received metric. Values are computed from memory under one
lock, on the status controller's queue.

## Recording metrics

`metrics record` puts one measurement into the same store the receiver
fills, receiver on or off:

```sh
flash metrics record --name=<metric> --value=<number> [--kind=gauge|counter|histogram] [--unit=<unit>] [--attributes=<key=value,...>]
```

| Kind | Each value is | Read as |
| --- | --- | --- |
| `gauge` (default) | The current value | `#{flash.otel:m}` is the latest |
| `counter` | An increment, 0 or more | `#{flash.otel.total:m}` adds them up; `.rate` is per second |
| `histogram` | One observation | `.count`, `.mean`, `.max`, `.p95`, over OpenTelemetry's default buckets |

A name is lowercase dotted words in the OpenTelemetry style
(`build.duration`, `disk.free`): each a letter, then letters, digits or `_`.
Names starting with `flash.` are Flash's own and refused. Attributes are
`key=value` pairs, keys named the same way and values at most 256
characters, at most 16 of them, so one script cannot turn a metric into an
unbounded number of series. A recorded metric carries `service.name=flash`
and the scope `flash.metrics.record`, which filters can match. A name
recorded as another kind starts over as that kind.

End to end, a nightly build reports its duration, the bar shows the last
one, and a monitor alerts when a build runs long:

```sh
start=$(date +%s); make all; end=$(date +%s)
flash metrics record --name=build.duration --value=$((end - start)) --kind=histogram --unit=s
```

```toml
[statusbar]
template = "#[align=right]build #{flash.otel.max:build.duration}s"

[monitors.slow_build]
value = "#{flash.otel.max:build.duration}"
warning = 600
message = "Build took over 10 minutes"
notify = true
```

Flash's own metrics, `flash.hints.latency` or `flash.plugin.request.duration`,
read the same way once a status format or monitor names them
(`#{flash.otel.p95:flash.hints.latency}`): from then on Flash keeps them in
the store as well. Until something reads them they cost nothing there.

## The receiver

```toml
[telemetry.receiver]
enabled = false
port = 4318          # 1–65535; not the help server's port
max_series = 1000    # 1–10000
max_points = 60      # 2–1000 history points per series
max_logs = 1000      # 0–100000
max_spans = 1000     # 0–100000
token = ""           # when set, required as Authorization: Bearer <token>
```

It listens on `127.0.0.1` only — the socket is bound to the loopback
address, not every address — and takes OTLP/HTTP as the specification
defines it:

| Request | Answer |
| --- | --- |
| `POST /v1/metrics`, `/v1/logs`, `/v1/traces` with `Content-Type: application/x-protobuf` or `application/json` | 200, an empty `Export…ServiceResponse` in the same encoding |
| Some points, records or spans invalid (a histogram whose buckets do not match its bounds, a point without a value, a span id of the wrong length) | 200 with `partial_success`: how many were rejected and why; the rest are kept |
| A body that does not decode | 400 |
| Another path | 404; another method, 405 with `Allow: POST` |
| A body over 4 MiB as sent, or over 16 MiB once inflated | 413 |
| Another `Content-Type`, or a `Content-Encoding` other than `gzip` or `identity` | 415 |
| More than eight requests decoding at once | 503 with `Retry-After: 1`, which senders retry |
| A `Host` other than `127.0.0.1:<port>` or `localhost:<port>`, an `Origin` from another site, a cross-site `Sec-Fetch-Site`, or Flash's own exporter | 403 |
| With `token` set, a request without `Authorization: Bearer <token>`, or with another | 401, before anything is decoded or counted |

Every error carries a `google.rpc.Status` with a message. Bodies may be
gzip-compressed and sent with a length or chunked; `Expect: 100-continue` is
answered. OTLP/JSON's hex trace and span ids and integer enums are read, and
unknown fields are ignored. Requests are decoded on a background queue,
never the main thread; each answer closes its connection.

A web page in your browser cannot use it: browsers send an `Origin` with
every cross-site request, a page can only send form encodings without a
preflight, and the receiver sends no CORS headers, so a page can neither
write metrics nor read an answer. A page that rebinds its own hostname to
127.0.0.1 still sends that hostname as `Host`. Any program on your Mac, under
any account, can send it data, as it could write to any other loopback port.
A received metric can drive a [monitor](monitors.md) whose `run` executes a
command, so set `token` before you run anything from one: senders pass it as
`OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"`, and the rest are
refused. The token is never shown, logged or exported; the help's state says
only whether one is set. The receiver stays opt-in and the token optional,
but `flash resident doctor` warns (`telemetry_receiver`) when the receiver
is on without a token while a monitor whose `value` reads a `#{flash.otel…}`
metric has a `run`: it names those monitors, and the fix is the token or
dropping the `run`.

What it keeps lives in memory only, never on disk. A new series beyond
`max_series` evicts the one updated least recently; each series keeps its
last `max_points` points for the page's sparklines (a gauge's values, a sum's
increments, a histogram's window counts); log records and spans beyond their
bound drop the oldest. Lowering a bound trims at once; turning the receiver
off or quitting Flash forgets everything.

## The exporter

```toml
[telemetry.exporter]
endpoint = ""                       # e.g. "https://otlp.example.com" — empty: off
protocol = "http/protobuf"          # or "http/json"
compression = "none"                # or "gzip"
headers = {}                        # { "x-api-key" = "…" }
service_name = "flash"
signals = ["metrics", "traces"]     # add "logs" to export log records
interval = 30                       # seconds, 1–3600
```

Each signal is posted to `<endpoint>/v1/<signal>`, as
`OTEL_EXPORTER_OTLP_ENDPOINT` works. Use `https://` for a remote collector:
macOS refuses plain HTTP to named hosts. An endpoint must not carry a user,
password, query or fragment; put credentials in `headers`, which are
explicit values only — Flash never reads `OTEL_EXPORTER_OTLP_HEADERS` or any
other environment variable for them — sent to that endpoint alone
(redirects are refused), never logged, and shown on the help pages by name
only. An endpoint that is Flash's own receiver is reported and the exporter
stays off: Flash's telemetry would feed back into itself. The receiver also
refuses anything Flash's exporter sends.

**Metrics** (cumulative; histograms in milliseconds with bounds 1, 2, 5, 10,
25, 50, 100, 250, 500, 1000, 2500, 5000 and 10000):

| Metric | Kind | Attributes |
| --- | --- | --- |
| `flash.plugin.request.duration` | histogram, ms | `plugin`, `method`, `outcome` (`ok`, `error`, `timeout`, `late`) |
| `flash.plugin.spawn.duration` | histogram, ms | `plugin` |
| `flash.plugin.restarts` | counter | `plugin` |
| `flash.plugin.errors` | counter | `plugin` |
| `flash.hints.latency` | histogram, ms | `origin` (`key`, `hotkey`, `cli`), `surface`, `outcome`, `app_class` (`native`, `browser`, `electron`, `other`) |
| `flash.monitor.value` | gauge | `monitor` |
| `flash.monitor.level` | gauge: -1 unknown, 0 ok, 1 warning, 2 error | `monitor` |
| `flash.telemetry.dropped` | counter | `signal`, `reason` (`queue_full`, `export_failed`, `rejected`, `encoding`) |

**Traces.** Every user interaction already has a trace id
([observability](observability.md#following-one-interaction)). One that
reaches a plugin, shows hints or logs a line at the exported level becomes a
trace: a root `flash.interaction` span (attributes `flash.trace`, the id the
log file uses, and `flash.origin`) with child spans for each plugin request
(`plugin <method>`, a client span, failed when the request was) and for the
hints appearing (`hints visible` or `hints empty`, from the input's own
timestamp to the frame). The root covers its children and is sent once its
interaction has been idle for a second. Trace ids are random per launch in
their high half, the interaction id in the low half.

**Logs**, only with `"logs"` in `signals`: the log file's lines at
`[debug] log_level`, with their level as severity, `fields` and
`flash.source` as attributes, and the interaction's trace and span ids.
Plugin stderr is never exported. Log text can name app bundle identifiers
and commands Flash's command line could not run; see
[privacy](privacy.md#opentelemetry).

Every batch shares one resource: `service.name`, `service.version`, a random
`service.instance.id` per launch, `process.pid`, `os.type`; no host or user
name.

Nothing is sent while nothing changes. The first record after a send arms
one flush `interval` later on the shared clock, at `low` priority; a flush
sends every metric stream when any changed, and up to 512 log records and
512 spans, coming back a second later while more are queued. Recording takes
a lock and an append, never I/O: encoding and sending run on the exporter's
queue. Queues hold 2048 log records and 2048 spans and 512 metric streams;
what does not fit is dropped and counted in `flash.telemetry.dropped`.

A send that fails with 429, 502, 503, 504 or a connection error is retried
after 1 s, doubling to at most five minutes (or the server's `Retry-After`),
six times, while that signal's new data keeps queuing; any other error
drops the batch. A partial success counts its rejected items as dropped.
The first failure of a streak logs a warning (`[telemetry] export
failing`), the rest debug lines, and recovery logs once.

## The telemetry page

`flash telemetry show` opens the help's telemetry page (`/telemetry`). It
shows the receiver — listening or not, its address, requests, accepted and
rejected items per signal, refusals and their last reason — and the exporter
— endpoint, protocol, signals, header names, sent and dropped items,
failures and the last error. Below them, every received metric with each
series' attributes, latest value, rate, total or percentiles and a
sparkline of its history, with the status-format snippet that reads it; the
recent log records; and recent traces as compact waterfalls. It follows the
resident like every help page; its data is `/api/telemetry`, and the status
is `/api/state`'s `telemetry` object.
