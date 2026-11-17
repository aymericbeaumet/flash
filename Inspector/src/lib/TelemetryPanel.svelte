<script lang="ts">
  import { now } from "./clock.svelte";
  import { ago, clockTime } from "./format";
  import Icon from "./Icon.svelte";
  import PageHeader from "./PageHeader.svelte";
  import { paths } from "./routes";
  import { classify, contractError, describeFailure, requestJSON, withRetry } from "./request";
  import SectionHead from "./SectionHead.svelte";
  import {
    fetchDelay, filterMetrics, formatDuration, formatRate, formatValue, isDistribution, isTelemetryData, kindLabel,
    recentLogs, seriesLabel, severityLevel, shortTrace, snippets, sortSeries, sparklinePath, traceGroups,
  } from "./telemetry";
  import type { SignalCounts, TelemetryData, TelemetryLog, TelemetryState } from "./types";
  import { copyText } from "./toasts.svelte";

  let { telemetry, loaded }: { telemetry: TelemetryState | undefined; loaded: boolean } = $props();

  const receiver = $derived(telemetry?.receiver);
  const exporter = $derived(telemetry?.exporter);
  const revision = $derived(receiver?.revision ?? 0);
  const manual = paths.docs("telemetry");

  // `/api/telemetry` is fetched on arrival and again when the receiver's
  // revision moves, at most once a second; a burst of exports is one fetch.
  let data = $state<TelemetryData | null>(null);
  let failure = $state("");
  let timer: ReturnType<typeof setTimeout> | undefined;
  let lastFetchAt = 0;
  let inFlight = false;
  let queued = false;
  const requests = new AbortController();

  async function load() {
    if (inFlight) { queued = true; return; }
    inFlight = true;
    lastFetchAt = Date.now();
    try {
      const value = await withRetry((signal) => requestJSON("/api/telemetry", { signal }), { signal: requests.signal, retries: 2 });
      if (!isTelemetryData(value)) throw contractError("/api/telemetry did not return metrics, logs and spans");
      data = value;
      failure = "";
    } catch (error) {
      if (classify(error).kind !== "aborted") failure = describeFailure(error);
    } finally {
      inFlight = false;
      if (queued) { queued = false; schedule(); }
    }
  }
  function schedule() {
    if (timer || requests.signal.aborted) return;
    timer = setTimeout(() => { timer = undefined; void load(); }, fetchDelay(lastFetchAt, Date.now()));
  }
  $effect(() => { void revision; schedule(); });
  $effect(() => () => { requests.abort(); clearTimeout(timer); });

  let query = $state("");
  let traceFilter = $state("");
  /** The expanded record, by identity: it stays open across refetches. */
  let openLog = $state("");
  const logKey = (record: TelemetryLog) => [record.time_ms, record.trace_id, record.span_id, record.service, record.body.slice(0, 200)].join("\u0000");
  let tracesSection = $state<HTMLElement>();

  const metrics = $derived(filterMetrics(data?.metrics ?? [], query));
  const seriesCount = $derived((data?.metrics ?? []).reduce((total, metric) => total + metric.series.length, 0));
  const logs = $derived(recentLogs(data?.logs ?? [], traceFilter));
  const shownLogs = $derived(logs.slice(0, 200));
  const traces = $derived(traceGroups(data?.spans ?? [], 50, traceFilter));
  const traceCount = $derived(new Set((data?.spans ?? []).map((span) => span.trace_id)).size);
  const signals = ["metrics", "logs", "traces"] as const;

  function perSignal(counts: SignalCounts | undefined): string {
    if (!counts) return "—";
    return signals.map((signal) => counts[signal].toLocaleString()).join(" / ");
  }
  const refusals = $derived(Object.entries(receiver?.refused ?? {}).sort(([a], [b]) => a.localeCompare(b)));
  const receiverState = $derived(!receiver?.enabled ? "off" : receiver.listening ? "ok" : receiver.error ? "error" : "warning");
  const exporterState = $derived(!exporter?.enabled ? (exporter?.blocked ? "warning" : "off") : exporter.retrying.length || exporter.last_error && !exporter.last_success_ms ? "warning" : "ok");

  function copy(text: string) {
    void copyText(text, text);
  }
  function showTrace(id: string) {
    traceFilter = id;
    void Promise.resolve().then(() => tracesSection?.scrollIntoView({ block: "start", behavior: "smooth" }));
  }
  function attributes(record: Record<string, string>): [string, string][] {
    return Object.entries(record).sort(([a], [b]) => a.localeCompare(b));
  }
</script>

<div class="page">
  <PageHeader id="telemetry" title="Telemetry" purpose="OpenTelemetry Flash received on this Mac, and what it sends of its own." {manual} live>
    {#snippet help()}
      <p>The <strong>receiver</strong> takes OTLP/HTTP (protobuf or JSON) on <code>127.0.0.1</code> only and keeps metrics, log records and spans in memory, never on disk. Any status format reads a received metric: <code>#{"{"}flash.otel:&lt;metric&gt;{"}"}</code> in the bar, a widget or a <code>[monitors.&lt;name&gt;]</code> value.</p>
      <p>The <strong>exporter</strong> sends Flash's own metrics, spans and, if you add them, log records to the endpoint you configured. Header values never appear here, only their names.</p>
    {/snippet}
  </PageHeader>

  <div class="status-row">
    <section class="surface status status-{receiverState}" aria-labelledby="receiver-title">
      <header><i class="lamp lamp-{receiverState}" aria-hidden="true"></i><h2 id="receiver-title">Receiver</h2><span class="badge {receiverState === 'off' ? 'neutral' : receiverState}">{!receiver?.enabled ? "Off" : receiver.listening ? "Listening" : receiver.error ? "Failed" : "Starting"}</span></header>
      {#if receiver?.enabled}
        <dl>
          <dt>Endpoint</dt><dd>{#if receiver.endpoint}<code>{receiver.endpoint}</code>{:else if receiver.error}<span class="bad">{receiver.error}</span>{:else}<span class="muted">port {receiver.port}</span>{/if}</dd>
          <dt>Requests</dt><dd class="mono" title="metrics / logs / traces">{perSignal(receiver.requests)}</dd>
          <dt>Accepted</dt><dd class="mono" title="data points / log records / spans">{perSignal(receiver.accepted)}</dd>
          <dt>Rejected</dt><dd class="mono" class:bad={signals.some((signal) => receiver.rejected[signal] > 0)}>{perSignal(receiver.rejected)}</dd>
          <dt>Refused</dt><dd>{#if refusals.length}<span class="mono">{refusals.map(([status, count]) => `${status} ×${count}`).join(" · ")}</span>{#if receiver.last_refusal}<span class="muted block">last: {receiver.last_refusal}</span>{/if}{:else}<span class="muted">none</span>{/if}</dd>
          <dt>Holding</dt><dd class="mono">{receiver.series} series · {receiver.logs} logs · {receiver.spans} spans{#if receiver.evicted_series}<span class="muted"> · {receiver.evicted_series} evicted</span>{/if}</dd>
          <dt>Last</dt><dd>{#if receiver.last_received_ms}<span class="mono">{ago(receiver.last_received_ms, now())}</span> <span class="muted">at {clockTime(receiver.last_received_ms)}</span>{:else}<span class="muted">nothing yet</span>{/if}</dd>
        </dl>
      {:else}
        <p class="off-note">Off. Set <code>enabled = true</code> under <code>[telemetry.receiver]</code> and point a sender at <code>http://127.0.0.1:{receiver?.port ?? 4318}</code>.</p>
      {/if}
    </section>
    <section class="surface status status-{exporterState}" aria-labelledby="exporter-title">
      <header><i class="lamp lamp-{exporterState}" aria-hidden="true"></i><h2 id="exporter-title">Exporter</h2><span class="badge {exporterState === 'off' ? 'neutral' : exporterState}">{exporter?.enabled ? (exporter.retrying.length ? "Retrying" : "Sending") : exporter?.blocked ? "Blocked" : "Off"}</span></header>
      {#if exporter?.enabled || exporter?.blocked}
        <dl>
          <dt>Endpoint</dt><dd><code>{exporter.endpoint}</code>{#if exporter.blocked}<span class="warn block">Stays off: {exporter.blocked}</span>{/if}</dd>
          <dt>Sends</dt><dd><span class="mono">{exporter.signals.join(", ") || "nothing"}</span> <span class="muted">· {exporter.protocol}{exporter.compression !== "none" ? ` · ${exporter.compression}` : ""} · every {exporter.interval_s} s while something changed</span></dd>
          <dt>Service</dt><dd class="mono">{exporter.service_name}</dd>
          <dt>Headers</dt><dd>{#if exporter.headers.length}<span class="mono">{exporter.headers.join(", ")}</span> <span class="muted">(values hidden)</span>{:else}<span class="muted">none</span>{/if}</dd>
          <dt>Sent</dt><dd class="mono" title="data points / log records / spans">{perSignal(exporter.sent)}</dd>
          <dt>Dropped</dt><dd class="mono" class:bad={signals.some((signal) => exporter.dropped[signal] > 0)}>{perSignal(exporter.dropped)}</dd>
          <dt>Failures</dt><dd>{#if exporter.failures}<span class="mono">{exporter.failures}</span>{#if exporter.retrying.length}<span class="warn"> · retrying {exporter.retrying.join(", ")}</span>{/if}{#if exporter.last_error}<span class="muted block">last: {exporter.last_error}</span>{/if}{:else}<span class="muted">none</span>{/if}</dd>
          <dt>Last sent</dt><dd>{#if exporter.last_success_ms}<span class="mono">{ago(exporter.last_success_ms, now())}</span> <span class="muted">at {clockTime(exporter.last_success_ms)}</span>{:else}<span class="muted">not yet</span>{/if}</dd>
        </dl>
      {:else}
        <p class="off-note">Off. Set <code>endpoint</code> under <code>[telemetry.exporter]</code> to an OTLP/HTTP collector to send Flash's own metrics and traces.</p>
      {/if}
    </section>
  </div>

  {#if failure}<div class="failure surface" role="alert"><strong>Could not read received telemetry.</strong><span class="detail">{failure}</span><button type="button" onclick={() => void load()}>Try again</button></div>{/if}

  {#if !loaded}
    <div class="surface empty"><strong>Waiting for Flash</strong><p>Telemetry appears with the first snapshot from the resident.</p></div>
  {:else if !receiver?.enabled && !(data?.metrics.length || data?.logs.length || data?.spans.length)}
    <div class="surface empty">
      <strong>The receiver is off</strong>
      <p>Turn it on to read any OpenTelemetry sender's metrics in the bar, widgets and monitors — Claude Code's token and cost counters, for one:</p>
      <pre class="well snippet-block">[telemetry.receiver]
enabled = true</pre>
      <p class="empty-links"><a href={manual}>Telemetry documentation →</a><a href="/state#config-editor">Open your configuration →</a></p>
    </div>
  {:else}
    <section class="block" aria-labelledby="metrics">
      <SectionHead title="Metrics" id="metrics" count={data ? `${metrics.length} of ${data.metrics.length} · ${seriesCount} series` : undefined}>
        {#snippet help()}<p>One row per series: a metric with one set of attributes. <strong>Latest</strong> is a gauge's or sum's last point and a histogram's latest mean; <strong>rate</strong> is per second over the latest reporting interval and drops to 0 once the sender goes quiet; <strong>total</strong> is a sum's running total. The sparkline shows each point: a gauge's values, a sum's increments, a histogram's observations. Copy a snippet into the bar, a widget or a monitor.</p>{/snippet}
        {#snippet actions()}<input type="search" bind:value={query} placeholder="Filter metrics and attributes…" aria-label="Filter metrics and attributes" />{/snippet}
      </SectionHead>
      {#if !data}
        <div class="surface empty small">Loading…</div>
      {:else if !data.metrics.length}
        <div class="surface empty small">No metrics received yet{#if receiver?.endpoint}. Point a sender at <code>{receiver.endpoint}</code>{/if}.</div>
      {:else if !metrics.length}
        <div class="surface empty small">No metric matches “{query}”.</div>
      {:else}
        <div class="surface table-wrap">
          <table class="data-table metrics">
            <thead><tr><th scope="col">Series</th><th scope="col" class="num">Latest</th><th scope="col" class="num">Rate</th><th scope="col" class="num">Total</th><th scope="col" class="num">p50 · p90 · p99</th><th scope="col">History</th><th scope="col">Updated</th></tr></thead>
            {#each metrics as metric (metric.name)}
              <tbody>
                <tr class="metric-row">
                  <th scope="rowgroup" colspan="7">
                    <div class="metric-head">
                      <code class="metric-name">{metric.name}</code>
                      <span class="badge neutral">{kindLabel(metric)}</span>
                      {#if metric.unit}<span class="unit">{metric.unit}</span>{/if}
                      <span class="series-count">{metric.series.length} series</span>
                      {#if metric.description}<span class="description">{metric.description}</span>{/if}
                      <span class="snippets">{#each snippets(metric) as snippet}<button type="button" class="snippet" title="Copy this status-format value" onclick={() => copy(snippet)}><Icon name="copy" size={12} /><code>{snippet}</code></button>{/each}</span>
                    </div>
                  </th>
                </tr>
                {#each sortSeries(metric.series) as item}
                  {@const label = seriesLabel(item)}
                  {@const distribution = isDistribution(metric.kind)}
                  <tr class:quiet={item.quiet}>
                    <td class="series-cell"><span class="attributes">{label.attributes || "no attributes"}</span>{#if label.service}<span class="service">{label.service}</span>{/if}</td>
                    <td class="num mono strong" title={distribution ? "Mean of the latest window" : "Latest point"}>{formatValue(item.latest)}</td>
                    <td class="num mono">{formatRate(item.rate)}</td>
                    <td class="num mono">{#if distribution}<span title="Observations">{formatValue(item.count)}</span>{#if item.sum != null}<span class="muted block" title="Sum of observations">Σ {formatValue(item.sum)}</span>{/if}{:else}{formatValue(item.total)}{/if}</td>
                    <td class="num mono">{#if distribution}{formatValue(item.p50)} · {formatValue(item.p90)} · {formatValue(item.p99)}{:else}<span class="muted">—</span>{/if}</td>
                    <td>{#if item.history.length > 1}<svg class="spark" width="96" height="22" viewBox="0 0 96 22" role="img" aria-label="{item.history.length} points, latest {formatValue(item.history[item.history.length - 1])}"><path d={sparklinePath(item.history, 96, 22, 2)} /></svg>{:else}<span class="muted">—</span>{/if}</td>
                    <td class="updated"><span class="mono">{ago(item.updated_ms, now())}</span>{#if item.quiet}<span class="badge neutral quiet-badge" title="No point for two and a half reporting intervals: its rate reads 0">quiet</span>{/if}</td>
                  </tr>
                {/each}
              </tbody>
            {/each}
          </table>
        </div>
      {/if}
    </section>

    <section class="block" aria-labelledby="received-logs">
      <SectionHead title="Logs" id="received-logs" count={data ? `${logs.length}${traceFilter ? ` in trace ${shortTrace(traceFilter)}` : ""}` : undefined}>
        {#snippet help()}<p>The most recent log records senders exported, newest first. Select one for its attributes; a trace id shows that trace's spans below.</p>{/snippet}
      </SectionHead>
      {#if !data}
        <div class="surface empty small">Loading…</div>
      {:else if !logs.length}
        <div class="surface empty small">{traceFilter ? "No log records in this trace." : "No log records received yet."}</div>
      {:else}
        <ul class="surface log-list">
          {#each shownLogs as record, position (position)}
            {@const level = severityLevel(record)}
            {@const key = logKey(record)}
            <li class:open={openLog === key}>
              <button type="button" class="log-row" aria-expanded={openLog === key} onclick={() => (openLog = openLog === key ? "" : key)}>
                <span class="time mono">{clockTime(record.time_ms)}</span>
                <span class="level level-{level}">{record.severity || level}</span>
                <span class="service">{record.service || "—"}</span>
                <span class="body">{record.event ? `${record.event} ` : ""}{record.body || "(no body)"}</span>
              </button>
              {#if openLog === key}
                <div class="log-detail well">
                  {#if record.body}<p class="full-body">{record.body}</p>{/if}
                  <dl>
                    {#if record.event}<dt>event</dt><dd><code>{record.event}</code></dd>{/if}
                    {#if record.scope}<dt>scope</dt><dd><code>{record.scope}</code></dd>{/if}
                    {#if record.trace_id}<dt>trace</dt><dd><button type="button" class="link" onclick={() => showTrace(record.trace_id)}><code>{record.trace_id}</code></button>{#if record.span_id}<span class="muted"> span {record.span_id}</span>{/if}</dd>{/if}
                    {#each attributes(record.attributes) as [key, value]}<dt>{key}</dt><dd><code>{value}</code></dd>{/each}
                  </dl>
                </div>
              {/if}
            </li>
          {/each}
        </ul>
        {#if logs.length > shownLogs.length}<p class="cap-note muted">Showing the newest {shownLogs.length} of {logs.length}.</p>{/if}
      {/if}
    </section>

    <section class="block" aria-labelledby="traces" bind:this={tracesSection}>
      <SectionHead title="Traces" id="traces" count={data ? (traceFilter ? `trace ${shortTrace(traceFilter)}` : `${Math.min(traceCount, 50)} of ${traceCount}`) : undefined}>
        {#snippet help()}<p>Received spans by trace, newest first, as a waterfall: each bar starts and ends where its span did within the trace, indented under its parent. Failed spans are red. Up to 50 traces are shown.</p>{/snippet}
        {#snippet actions()}{#if traceFilter}<button type="button" class="chip" onclick={() => (traceFilter = "")}><code>{shortTrace(traceFilter)}</code> <Icon name="close" size={12} /> Show all</button>{/if}{/snippet}
      </SectionHead>
      {#if !data}
        <div class="surface empty small">Loading…</div>
      {:else if !traces.length}
        <div class="surface empty small">{traceFilter ? "This trace's spans are not held (any more)." : "No spans received yet."}</div>
      {:else}
        <div class="traces">
          {#each traces as trace (trace.traceId)}
            <article class="surface trace" class:trace-error={trace.error}>
              <header class="trace-head">
                <strong>{trace.name}</strong>
                {#if trace.services.length}<span class="muted">{trace.services.join(", ")}</span>{/if}
                <span class="mono">{formatDuration(trace.duration)}</span>
                <span class="muted mono">{trace.rows.length} span{trace.rows.length === 1 ? "" : "s"} · {ago(trace.start, now())}</span>
                {#if trace.error}<span class="badge error">error</span>{/if}
                <button type="button" class="link trace-id" title="Show only this trace and its logs" onclick={() => (traceFilter = trace.traceId)}><code>{shortTrace(trace.traceId)}</code></button>
              </header>
              <ol class="waterfall">
                {#each trace.rows as row (row.span.span_id)}
                  <li class:failed={row.span.status === "error"}>
                    <span class="span-name" style="padding-left: {Math.min(row.depth, 8) * 14}px" title={`${row.span.name}${row.span.status_message ? ` — ${row.span.status_message}` : ""}`}>{row.span.name}{#if row.span.service && trace.services.length > 1}<span class="span-service">{row.span.service}</span>{/if}</span>
                    <span class="track" aria-hidden="true"><i style="left: {row.offset}%; width: {row.width}%"></i></span>
                    <span class="span-duration mono">{formatDuration(row.span.duration_ms)}</span>
                  </li>
                {/each}
              </ol>
            </article>
          {/each}
        </div>
      {/if}
    </section>
  {/if}
</div>

<style>
  .status-row { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; margin-bottom: 18px; }
  .status { padding: 12px 16px 14px; border-top: 2px solid var(--border-strong); min-width: 0; }
  .status-ok { border-top-color: rgba(111, 181, 163, .6); }
  .status-warning { border-top-color: var(--amber); }
  .status-error { border-top-color: var(--danger); }
  .status header { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
  .status h2 { font-size: 15px; flex: 1; }
  .lamp { display: inline-block; flex: none; width: 10px; height: 10px; border-radius: 50%; background: var(--faint); box-shadow: 0 0 0 2px var(--panel), 0 0 0 3px var(--accent-dim); }
  .lamp-ok { background: var(--verdigris); }
  .lamp-warning { background: var(--amber); }
  .lamp-error { background: var(--danger); }
  .lamp-off { background: transparent; box-shadow: inset 0 0 0 1px var(--faint), 0 0 0 2px var(--panel), 0 0 0 3px var(--border-strong); }
  dl { display: grid; grid-template-columns: 84px minmax(0, 1fr); gap: 5px 12px; margin: 0; font-size: 13px; }
  dt { color: var(--muted); }
  dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
  .mono { font-family: var(--mono); font-size: 12px; font-variant-numeric: tabular-nums; }
  .block { display: block; }
  .bad { color: var(--danger); }
  .warn { color: var(--amber); }
  .off-note { font-size: 13px; color: var(--muted); }
  .failure { margin-bottom: 14px; border-radius: 6px; }
  .empty p { max-width: 600px; margin: 6px auto 0; font-size: 13px; }
  .empty.small { padding: 18px 20px; font-size: 13px; }
  .empty-links { display: flex; flex-wrap: wrap; justify-content: center; gap: 8px 20px; }
  .snippet-block { display: inline-block; margin: 10px auto 0; padding: 8px 14px; text-align: left; color: var(--code); }
  section.block { margin-bottom: 22px; }
  section.block :global(input[type="search"]) { min-width: 240px; min-height: 30px; padding: 4px 10px; font-size: 13px; }

  .metrics .num { text-align: right; white-space: nowrap; }
  .metrics th.num { text-align: right; }
  .metric-row th { padding: 10px 14px 6px; background: var(--panel); text-transform: none; letter-spacing: 0; font: inherit; color: var(--text); border-bottom: 1px solid var(--border-soft); border-top: 1px solid var(--border); }
  tbody:first-of-type .metric-row th { border-top: 0; }
  .metric-head { display: flex; align-items: center; flex-wrap: wrap; gap: 6px 10px; }
  .metric-name { font-size: 13px; font-weight: 600; color: var(--accent-strong); }
  .unit, .series-count { font: 12px var(--mono); color: var(--muted); }
  .description { font-size: 12px; color: var(--muted); }
  .snippets { display: flex; flex-wrap: wrap; gap: 4px; margin-left: auto; }
  .snippet { display: inline-flex; align-items: center; gap: 5px; min-height: 24px; padding: 1px 7px; font-size: 12px; color: var(--muted); background: var(--inset); }
  .snippet code { font-size: 12px; }
  .snippet:hover { color: var(--accent); }
  .series-cell { min-width: 220px; max-width: 460px; }
  .attributes { display: block; font: 12px var(--mono); color: var(--code); overflow-wrap: anywhere; }
  .service { font-size: 12px; color: var(--muted); }
  .strong { color: var(--text); font-weight: 600; }
  .muted.block, .warn.block { display: block; }
  .spark { display: block; overflow: visible; }
  .spark path { fill: none; stroke: var(--verdigris); stroke-width: 1.4; stroke-linejoin: round; stroke-linecap: round; }
  tr.quiet td { opacity: .55; }
  tr.quiet .spark path { stroke: var(--steel); }
  .updated { white-space: nowrap; }
  .quiet-badge { margin-left: 6px; }

  .log-list { list-style: none; margin: 0; padding: 0; max-height: 520px; overflow: auto; }
  .log-list li { border-bottom: 1px solid var(--border-soft); }
  .log-list li:last-child { border-bottom: 0; }
  .log-row { display: grid; grid-template-columns: 72px 64px minmax(80px, 160px) minmax(0, 1fr); align-items: baseline; gap: 10px; width: 100%; min-height: 32px; padding: 5px 14px; border: 0; border-radius: 0; background: transparent; text-align: left; font-size: 13px; color: var(--text); }
  .log-row:hover, .open .log-row { background: var(--hover); }
  .time { color: var(--muted); }
  .level { display: inline-block; text-align: center; border-radius: 3px; padding: 0 4px; text-transform: uppercase; font: 600 12px/1.6 var(--mono); color: var(--muted); background: rgba(166, 157, 139, .08); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .level-info { color: var(--verdigris); background: var(--verdigris-soft); }
  .level-debug, .level-trace { color: var(--steel); background: var(--steel-soft); }
  .level-warn { color: var(--amber); background: var(--amber-soft); }
  .level-error, .level-fatal { color: var(--danger); background: var(--danger-soft); }
  .log-row .service { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .body { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .log-detail { margin: 0 14px 10px; padding: 10px 12px; font-size: 13px; }
  .full-body { white-space: pre-wrap; overflow-wrap: anywhere; margin-bottom: 8px; }
  .link { min-height: 0; padding: 0; border: 0; background: none; color: var(--accent); }
  .link:hover { background: none; color: var(--accent-strong); text-decoration: underline; }
  .cap-note { margin-top: 6px; font-size: 12px; }
  .chip { display: inline-flex; align-items: center; gap: 6px; min-height: 28px; padding: 2px 10px; font-size: 12px; color: var(--accent); border-color: var(--accent-dim); background: var(--accent-soft); }

  .traces { display: flex; flex-direction: column; gap: 10px; }
  .trace { padding: 10px 14px 12px; border-left: 2px solid var(--border-strong); }
  .trace-error { border-left-color: var(--danger); }
  .trace-head { display: flex; align-items: center; flex-wrap: wrap; gap: 4px 12px; margin-bottom: 8px; font-size: 13px; }
  .trace-head strong { font-weight: 600; }
  .trace-id { margin-left: auto; }
  .waterfall { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 3px; }
  .waterfall li { display: grid; grid-template-columns: minmax(140px, 32%) minmax(0, 1fr) 72px; align-items: center; gap: 10px; font-size: 12px; }
  .span-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: var(--mono); color: var(--code); }
  .span-service { margin-left: 8px; color: var(--muted); font-family: var(--sans); }
  .track { position: relative; height: 10px; border-radius: 2px; background: var(--inset); box-shadow: var(--well); }
  .track i { position: absolute; top: 1px; bottom: 1px; min-width: 2px; border-radius: 2px; background: var(--accent-dim); }
  .failed .track i { background: var(--danger); }
  .failed .span-name { color: var(--danger); }
  .span-duration { text-align: right; color: var(--muted); }
  @media (max-width: 900px) { .status-row { grid-template-columns: minmax(0, 1fr); } .log-row { grid-template-columns: 64px 56px minmax(0, 1fr); } .log-row .service { display: none; } }
  @media print { .snippets, .chip, .trace-id { display: none; } .log-list { max-height: none; } .trace { break-inside: avoid; } }
</style>
