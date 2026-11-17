<script lang="ts">
  import { paths } from "./routes";
  import { now } from "./clock.svelte";
  import { ago, clockTime, duration } from "./format";
  import MonitorGauge from "./MonitorGauge.svelte";
  import { formatNumber, lastRunText, monitorCounts, runSteps, severities, sortMonitors, stateLabels, thresholds, type MonitorState } from "./monitors";
  import PageHeader from "./PageHeader.svelte";
  import SourceBadge from "./SourceBadge.svelte";
  import { sourceFromOrigin } from "./source";
  import type { EventMonitorInfo, MonitorInfo } from "./types";

  let { monitors, loaded }: { monitors: (MonitorInfo | EventMonitorInfo)[] | undefined; loaded: boolean } = $props();
  const values = $derived((monitors ?? []).filter((monitor): monitor is MonitorInfo => monitor.kind !== "event"));
  const events = $derived((monitors ?? []).filter((monitor): monitor is EventMonitorInfo => monitor.kind === "event"));
  const list = $derived(values);
  let show = $state<"all" | MonitorState | "disabled">("all");
  const sorted = $derived(sortMonitors(list));
  const shown = $derived(sorted.filter((monitor) => show === "all" || (show === "disabled" ? !monitor.enabled : monitor.enabled && monitor.state === show)));
  const counts = $derived(monitorCounts(list));
  const disabled = $derived(list.filter((monitor) => !monitor.enabled).length);
  const manual = paths.docs("monitors");
  const stateClass = (monitor: MonitorInfo) => (monitor.enabled ? monitor.state : "disabled");
</script>

<div class="page">
  <PageHeader id="monitors" title="Monitors" purpose="The values Flash watches on this Mac, worst first." {manual} live>
    {#snippet help()}
      <p>A monitor samples a status-format <strong>expression</strong> every interval and compares the value with its <strong>warning</strong> and <strong>error</strong> thresholds. <strong>Direction</strong> says which way is worse: <code>above</code> when a higher value is worse, <code>below</code> when a lower one is.</p>
      <p>Bundled monitors show as Built-in; yours come from <code>[monitors.&lt;name&gt;]</code> tables in your configuration. The dial marks the warning and error thresholds across its coloured bands.</p>
      <p>A monitor with a <strong>run</strong> calls it on each rise, or on each change when it has no thresholds. A monitor with an <strong>event</strong> watches host events instead of a value, the names a plugin's <code>listen</code> takes, and runs on each one.</p>
    {/snippet}
  </PageHeader>

  {#if list.length}
    <div class="summary" role="group" aria-label="Show monitors by state">
      <button type="button" class="tile" class:active={show === "all"} aria-pressed={show === "all"} onclick={() => (show = "all")}><strong>{list.length}</strong><span>All</span></button>
      {#each severities as state}<button type="button" class="tile tile-{state}" class:zero={counts[state] === 0} class:active={show === state} aria-pressed={show === state} onclick={() => (show = show === state ? "all" : state)}><i class="lamp lamp-{state}" aria-hidden="true"></i><strong>{counts[state]}</strong><span>{stateLabels[state]}</span></button>{/each}
      {#if disabled}<button type="button" class="tile" class:active={show === "disabled"} aria-pressed={show === "disabled"} onclick={() => (show = show === "disabled" ? "all" : "disabled")}><i class="lamp lamp-disabled" aria-hidden="true"></i><strong>{disabled}</strong><span>Disabled</span></button>{/if}
    </div>
    <div class="cards" aria-live="polite">
      {#each shown as monitor (monitor.id)}
        <article class="surface card card-{stateClass(monitor)}" aria-labelledby="monitor-{monitor.id}">
          <header class="card-head">
            <i class="lamp lamp-{stateClass(monitor)}" aria-hidden="true"></i>
            <div class="names"><h2 id="monitor-{monitor.id}">{monitor.name}</h2><code>{monitor.id}</code></div>
            <span class="badge {monitor.enabled ? (monitor.state === 'unknown' ? 'neutral' : monitor.state) : 'neutral'}">{monitor.enabled ? stateLabels[monitor.state] : "Disabled"}</span>
          </header>
          <div class="reading">
            <MonitorGauge {monitor} />
            <div class="value">
              <strong class="display value-{stateClass(monitor)}">{monitor.value == null ? "—" : monitor.display || formatNumber(monitor.value)}</strong>
              {#each thresholds(monitor) as mark}<span class="threshold threshold-{mark.state}"><i aria-hidden="true"></i>{mark.state} {monitor.direction} <b>{formatNumber(mark.value)}</b></span>{:else}<span class="threshold">no thresholds</span>{/each}
              <span class="direction">{monitor.direction === "above" ? "Higher is worse" : "Lower is worse"}</span>
            </div>
          </div>
          {#if monitor.message || monitor.detail}<p class="message message-{stateClass(monitor)}">{monitor.message}{#if monitor.detail}<span class="detail">{monitor.detail}</span>{/if}</p>{/if}
          <dl>
            <dt>{monitor.enabled ? `In ${stateLabels[monitor.state] === "OK" ? "OK" : stateLabels[monitor.state].toLowerCase()}` : "Since"}</dt><dd><span class="mono">{duration(Math.max(0, now() - monitor.since_ms))}</span> <span class="muted">since {clockTime(monitor.since_ms)}</span></dd>
            <dt>Last alert</dt><dd>{#if monitor.last_alert_ms != null}<span class="mono">{ago(monitor.last_alert_ms, now())}</span> <span class="muted">at {clockTime(monitor.last_alert_ms)}</span>{:else}<span class="muted">Never</span>{/if}</dd>
            <dt>Samples</dt><dd><span class="mono">every {formatNumber(monitor.interval_s)} s</span></dd>
            {#if monitor.run}<dt>Runs</dt><dd><span class="mono">{monitor.runs}</span> {#if monitor.last_run_ms != null}<span class="muted">last {ago(monitor.last_run_ms, now())}</span>{/if}</dd>{/if}
            {#if monitor.run && monitor.last_run}<dt>Last run</dt><dd class:failed={monitor.last_run.status === "failed"}>{lastRunText(monitor.last_run)}</dd>{/if}
            <dt>Source</dt><dd><SourceBadge {...sourceFromOrigin(monitor.origin)} /></dd>
          </dl>
          <code class="expression well" title="Expression">{monitor.expression}</code>
          {#each runSteps(monitor.run) as step, index}<code class="expression well" title="Run, step {index + 1}">{step}</code>{/each}
          {#if monitor.last_run?.status === "failed" && monitor.last_run.output}<pre class="expression well output" title="Output">{monitor.last_run.output}</pre>{/if}
        </article>
      {/each}
    </div>
  {:else if !loaded}
    <div class="surface empty"><strong>Waiting for Flash</strong><p>Monitors appear with the first snapshot from the resident.</p></div>
  {:else}
    <div class="surface empty">
      <strong>No monitors to show</strong>
      <p>Flash reports no monitors. Monitors are configured with <code>[monitors.&lt;name&gt;]</code> tables in your configuration; each one samples an expression and compares it with its thresholds.</p>
      <p class="empty-links"><a href={manual}>Monitors documentation →</a><a href="/state#config-editor">Open your configuration →</a></p>
    </div>
  {/if}
  {#if events.length}
    <h2 class="section">Events</h2>
    <div class="cards">
      {#each events as monitor (monitor.id)}
        <article class="surface card card-{monitor.enabled ? 'ok' : 'disabled'}" aria-labelledby="monitor-{monitor.id}">
          <header class="card-head">
            <i class="lamp lamp-{monitor.enabled ? 'ok' : 'disabled'}" aria-hidden="true"></i>
            <div class="names"><h2 id="monitor-{monitor.id}">{monitor.name}</h2><code>{monitor.id}</code></div>
            <span class="badge neutral">{monitor.enabled ? "Listening" : "Disabled"}</span>
          </header>
          {#if monitor.message}<p class="message">{monitor.message}</p>{/if}
          <dl>
            <dt>Events</dt><dd><span class="mono">{monitor.event.join(", ")}</span></dd>
            {#if monitor.app}<dt>App</dt><dd><span class="mono">{monitor.app}</span></dd>{/if}
            <dt>Runs</dt><dd><span class="mono">{monitor.runs}</span> {#if monitor.last_run_ms != null}<span class="muted">last {ago(monitor.last_run_ms, now())} at {clockTime(monitor.last_run_ms)}</span>{:else}<span class="muted">not yet</span>{/if}</dd>
            {#if monitor.last_run}<dt>Last run</dt><dd class:failed={monitor.last_run.status === "failed"}>{lastRunText(monitor.last_run)}</dd>{/if}
            <dt>Source</dt><dd><SourceBadge {...sourceFromOrigin(monitor.origin)} /></dd>
          </dl>
          {#each runSteps(monitor.run) as step, index}<code class="expression well" title="Run, step {index + 1}">{step}</code>{/each}
          {#if monitor.last_run?.status === "failed" && monitor.last_run.output}<pre class="expression well output" title="Output">{monitor.last_run.output}</pre>{/if}
        </article>
      {/each}
    </div>
  {/if}
</div>

<style>
  .summary { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 18px; }
  .tile { display: flex; align-items: center; gap: 10px; min-width: 120px; min-height: 44px; padding: 6px 14px; border: 1px solid var(--border); border-radius: 6px; background: var(--panel); box-shadow: var(--engrave); color: var(--muted); font-size: 13px; }
  .tile:hover { border-color: var(--border-strong); color: var(--text); background: var(--raised); }
  .tile.active { border-color: var(--accent); color: var(--text); background: var(--raised); box-shadow: inset 0 -2px 0 var(--accent), var(--engrave); }
  .tile strong { font: 600 20px var(--mono); color: var(--text); font-variant-numeric: tabular-nums; }
  .tile.zero { opacity: .55; }
  .tile-error:not(.zero) { border-color: rgba(229, 115, 94, .45); }
  .tile-error:not(.zero) strong { color: var(--danger); }
  .tile-warning:not(.zero) { border-color: rgba(227, 165, 63, .45); }
  .tile-warning:not(.zero) strong { color: var(--amber); }
  /* An indicator lamp: the state's colour in a brass bezel. */
  .lamp { display: inline-block; flex: none; width: 10px; height: 10px; border-radius: 50%; background: var(--faint); box-shadow: 0 0 0 2px var(--panel), 0 0 0 3px var(--accent-dim); }
  .lamp-ok { background: var(--verdigris); }
  .lamp-warning { background: var(--amber); }
  .lamp-error { background: var(--danger); }
  .lamp-unknown { background: var(--steel); opacity: .7; }
  .lamp-disabled { background: transparent; box-shadow: inset 0 0 0 1px var(--faint), 0 0 0 2px var(--panel), 0 0 0 3px var(--border-strong); }
  .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 12px; }
  .card { display: flex; flex-direction: column; gap: 12px; min-width: 0; padding: 14px 16px 16px; border-top: 2px solid var(--border-strong); }
  .card-error { border-top-color: var(--danger); }
  .card-warning { border-top-color: var(--amber); }
  .card-ok { border-top-color: rgba(111, 181, 163, .6); }
  .card-unknown { border-top-color: var(--steel); }
  .card-disabled { opacity: .72; }
  .card-head { display: flex; align-items: center; gap: 10px; }
  .names { flex: 1; min-width: 0; }
  .names h2 { font-size: 15px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .names code { font-size: 12px; color: var(--muted); }
  .reading { display: flex; align-items: center; gap: 14px; }
  .value { display: flex; flex-direction: column; gap: 3px; min-width: 0; }
  .display { font: 600 26px/1.15 var(--mono); color: var(--text); font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
  .value-error { color: var(--danger); }
  .value-warning { color: var(--amber); }
  .value-unknown, .value-disabled { color: var(--muted); }
  .threshold { display: flex; align-items: center; gap: 7px; font: 12px var(--mono); color: var(--muted); }
  .threshold i { width: 10px; height: 2px; background: var(--faint); }
  .threshold b { color: var(--text); font-weight: 600; }
  .threshold-warning i { background: var(--amber); }
  .threshold-error i { background: var(--danger); }
  .direction { font-size: 12px; color: var(--muted); }
  .message { font-size: 13px; padding: 6px 10px; border-radius: 4px; background: var(--raised); color: var(--text); }
  .message-error { background: var(--danger-soft); }
  .message-warning { background: var(--amber-soft); }
  .detail { display: block; margin-top: 2px; font: 600 12px var(--mono); overflow-wrap: anywhere; }
  dl { display: grid; grid-template-columns: 92px minmax(0, 1fr); gap: 5px 12px; margin: 0; font-size: 13px; padding-top: 10px; border-top: 1px solid var(--border-soft); }
  dt { color: var(--muted); }
  dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
  .mono { font-family: var(--mono); font-size: 12px; }
  .expression { display: block; padding: 7px 10px; font-size: 12px; color: var(--code); overflow-x: auto; white-space: nowrap; }
  .expression + .expression { margin-top: 4px; }
  dd.failed { color: var(--danger); }
  .output { margin: 4px 0 0; white-space: pre-wrap; max-height: 12em; overflow-y: auto; color: var(--muted); }
  .section { margin: 22px 0 10px; font-size: 14px; color: var(--muted); }
  .empty p { max-width: 560px; margin: 6px auto 0; font-size: 13px; }
  .empty-links { display: flex; flex-wrap: wrap; justify-content: center; gap: 8px 20px; }
  @media (max-width: 640px) { .cards { grid-template-columns: minmax(0, 1fr); } .reading { flex-wrap: wrap; } }
  @media print { .summary { display: none; } .cards { grid-template-columns: repeat(2, minmax(0, 1fr)); } .card { break-inside: avoid; box-shadow: none; } }
</style>
