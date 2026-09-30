<script lang="ts">
  import Icon from "./Icon.svelte";
  import { paths } from "./routes";
  import type { PluginInfo } from "./types";
  import { bytes, duration } from "./format";
  import { now } from "./clock.svelte";

  let { plugins, filter = "" }: { plugins: PluginInfo[]; filter?: string } = $props();
  let query = $state("");
  let health = $state("all");
  let selectedID = $state<string | null>(null);

  $effect(() => { query = filter; selectedID = filter || null; health = "all"; });

  function isRunning(plugin: PluginInfo) { return plugin.state === "running" || plugin.state === "ready"; }
  function hasError(plugin: PluginInfo) { return !!plugin.last_error || ["failed", "crashed", "error"].includes(plugin.state); }
  function label(value: string) { return value.replaceAll("_", " "); }
  function stateClass(plugin: PluginInfo) {
    if (hasError(plugin)) return "error";
    if (isRunning(plugin)) return "";
    if (["starting", "launching", "installing"].includes(plugin.state)) return "working";
    return "neutral";
  }
  const runningCount = $derived(plugins.filter(isRunning).length);
  const errorCount = $derived(plugins.filter(hasError).length);
  const selected = $derived(plugins.find((plugin) => plugin.id === selectedID) ?? null);
  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    return plugins.filter((plugin) =>
      (health === "all" || (health === "running" ? isRunning(plugin) : hasError(plugin))) &&
      (!q || [plugin.id, plugin.name, plugin.description, plugin.origin, plugin.state, plugin.activation].join(" ").toLowerCase().includes(q)),
    ).sort((a, b) => a.id.localeCompare(b.id));
  });
  const detailEntries = $derived.by(() => selected ? Object.entries(selected).filter(([key]) => key !== "commands").sort(([a], [b]) => a.localeCompare(b)) : []);
  function formatValue(value: unknown): string {
    if (value == null) return "—";
    if (typeof value === "object") return JSON.stringify(value, null, 2);
    return String(value);
  }
</script>

<div class="page">
  <div class="page-heading"><p class="eyebrow">Your Flash</p><h1>Plugins</h1><p>The capabilities running alongside Flash. Inspect each plugin's health, resource usage, and available commands.</p></div>
  <div class="overview">
    <div><span class="eyebrow">Loaded</span><strong>{plugins.length}</strong><span>plugins discovered</span></div>
    <div><span class="eyebrow">Running</span><strong>{runningCount}<i class="running-dot"></i></strong><span>processes active</span></div>
    <div class:attention={errorCount > 0}><span class="eyebrow">Need attention</span><strong>{errorCount}</strong><span>{errorCount ? "with errors to inspect" : "no reported errors"}</span></div>
    <a href="/docs/plugins"><span class="guide-icon"><Icon name="plugins" size={23} /></span><strong>Make Flash your own</strong><span>Read the plugin guide <Icon name="arrow" size={14} /></span></a>
  </div>
  <div class="surface plugin-browser">
    <div class="toolbar">
      <input type="search" aria-label="Search plugins" placeholder="Search plugins…" bind:value={query} />
      <div class="segmented" aria-label="Plugin health">
        {#each [{ id: "all", label: "All" }, { id: "running", label: "Running" }, { id: "errors", label: "Needs attention" }] as item}<button class:active={health === item.id} aria-pressed={health === item.id} onclick={() => health = item.id}>{item.label}</button>{/each}
      </div>
      <span class="count">{filtered.length} {filtered.length === 1 ? "plugin" : "plugins"}</span>
    </div>
    {#if filtered.length}
      <div class="plugin-grid">
        {#each filtered as plugin (plugin.id)}
          <button class="plugin-card" class:selected={plugin.id === selectedID} aria-expanded={plugin.id === selectedID} aria-controls="plugin-detail" onclick={() => selectedID = selectedID === plugin.id ? null : plugin.id}>
            <span class="card-heading"><span class="plugin-icon"><Icon name="plugins" size={19} /></span><span class="plugin-title"><strong>{plugin.name || plugin.id}</strong><code>{plugin.id}{plugin.version ? ` · ${plugin.version}` : ""}</code></span><span class="badge {stateClass(plugin)}">{label(plugin.state)}</span></span>
            <span class="card-description">{plugin.description || "No description provided."}</span>
            <span class="card-metrics"><span><span class="metric-label">CPU time</span><strong>{duration(plugin.cpu_time_ms)}</strong></span><span><span class="metric-label">Memory</span><strong>{bytes(plugin.memory_bytes)}</strong></span><span><span class="metric-label">Commands</span><strong>{plugin.command_count ?? plugin.commands?.length ?? 0}</strong></span></span>
            <span class="card-footer"><span>{label(plugin.activation || "resident")}{plugin.origin ? ` · ${plugin.origin}` : ""}</span><span class="details-link">{plugin.id === selectedID ? "Close details" : "Inspect"}<Icon name="chevron" size={12} /></span></span>
            {#if plugin.last_error}<span class="card-error">{plugin.last_error}</span>{/if}
          </button>
        {/each}
      </div>
    {:else}
      <div class="empty"><strong>{plugins.length ? "No plugins match" : "No plugins loaded"}</strong><p>{plugins.length ? "Try another search or health filter." : "Enabled plugins will appear here when Flash discovers them."}</p>{#if query || health !== "all"}<button onclick={() => { query = ""; health = "all"; }}>Clear filters</button>{/if}</div>
    {/if}
  </div>

  {#if selected}
    <section class="surface detail" id="plugin-detail" aria-label={selected.id + " details"}>
      <header><div><p class="eyebrow">Plugin details</p><h2>{selected.name || selected.id} <span class="badge {stateClass(selected)}">{label(selected.state)}</span></h2><p class="detail-description">{selected.description || selected.id}</p></div><button class="close" aria-label="Close plugin details" onclick={() => selectedID = null}><Icon name="close" size={17} /></button></header>
      {#if selected.last_error}<div class="notice error"><strong>Last reported error</strong><pre>{selected.last_error}</pre></div>{/if}
      <div class="detail-metrics">
        <div><span>CPU time</span><strong>{duration(selected.cpu_time_ms)}</strong></div><div><span>Memory</span><strong>{bytes(selected.memory_bytes)}</strong></div><div><span>Uptime</span><strong>{selected.started_at_unix_ms == null ? "—" : duration(Math.max(0, now() - selected.started_at_unix_ms))}</strong></div><div><span>Process ID</span><strong>{selected.pid ?? "—"}</strong></div><div><span>Restarts</span><strong>{selected.restart_count ?? 0}</strong></div><div><span>Sources</span><strong>{selected.source_count ?? 0}</strong></div>
      </div>
      <div class="detail-columns">
        <section><h3>Commands <span class="badge neutral">{selected.commands?.length ?? 0}</span></h3>{#if selected.commands?.length}<div class="command-list">{#each selected.commands as command}<a href={paths.commands(`:${command.command} ${command.subcommand}`.trim())}><code>:{command.command} {command.subcommand}</code><span>{command.description || "No description provided."}</span><Icon name="chevron" size={13} /></a>{/each}</div>{:else}<p class="detail-empty">This plugin does not register commands.</p>{/if}</section>
        <section><h3>Live status</h3>{#if selected.status_segments && Object.keys(selected.status_segments).length}<dl class="status-segments">{#each Object.entries(selected.status_segments) as [key, value]}<dt>{key}</dt><dd>{value || "—"}</dd>{/each}</dl>{:else}<p class="detail-empty">No status segments published.</p>{/if}{#if selected.last_log}<h4>Latest diagnostic</h4><pre class="last-log">{selected.last_log}</pre>{/if}</section>
      </div>
      <details class="runtime-fields"><summary>All runtime fields <span>{detailEntries.length}</span></summary><dl>{#each detailEntries as [key, value]}<dt>{key}</dt><dd><pre>{formatValue(value)}</pre></dd>{/each}</dl></details>
    </section>
  {/if}
</div>

<style>
  .overview { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)) minmax(180px, 1.4fr); margin-bottom: 27px; border: 1px solid var(--border); border-radius: 11px; background: #fff; overflow: hidden; }
  .overview > div { padding: 21px 23px; border-right: 1px solid var(--border); display: flex; flex-direction: column; }
  .overview > div > strong { display: flex; align-items: center; gap: 10px; font-size: 29px; font-weight: 500; line-height: 1.4; margin: 7px 0 1px; }
  .overview > div > span:last-child { font-size: 10px; color: var(--muted); }
  .running-dot { display: inline-block; width: 7px; height: 7px; background: #589165; border-radius: 50%; }
  .overview .attention > strong { color: var(--danger); }
  .overview > a { padding: 19px 23px; background: #edf3e6; display: flex; flex-direction: column; justify-content: center; text-decoration: none; }
  .guide-icon { margin-bottom: 6px; }
  .overview a strong { font-size: 12px; font-weight: 600; }
  .overview a > span:last-child { display: flex; align-items: center; gap: 6px; margin-top: 5px; font-size: 11px; }
  .plugin-browser { overflow: hidden; }
  .plugin-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(290px, 1fr)); gap: 14px; padding: 18px; background: #fbfcf9; }
  .plugin-card { display: flex; flex-direction: column; text-align: left; border: 1px solid var(--border); border-radius: 9px; padding: 19px; min-width: 0; background: #fff; }
  .plugin-card:hover, .plugin-card.selected { border-color: #8dab7d; background: #fff; }
  .plugin-card.selected { box-shadow: 0 0 0 2px #b7cba23b; }
  .card-heading { display: flex; align-items: center; gap: 10px; width: 100%; }
  .plugin-icon { display: flex; align-items: center; justify-content: center; color: var(--accent); background: #edf2e8; border-radius: 7px; width: 33px; height: 33px; flex-shrink: 0; }
  .plugin-title { min-width: 0; flex: 1; }
  .plugin-title strong { display: block; font-size: 13px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .plugin-title code { display: block; font-size: 9px; color: var(--muted); margin-top: 3px; overflow-wrap: anywhere; }
  .badge.working { background: #fff3d3; color: #8c6b27; }
  .card-description { color: var(--muted); font-size: 11px; margin: 15px 0 18px; line-height: 1.7; flex: 1; }
  .card-metrics { display: grid; grid-template-columns: repeat(3, 1fr); width: 100%; gap: 12px; padding-bottom: 15px; }
  .metric-label { display: block; font-size: 9px; color: var(--muted); margin-bottom: 4px; }
  .card-metrics strong { font: 12px var(--mono); }
  .card-footer { border-top: 1px solid var(--border-soft); padding-top: 11px; width: 100%; display: flex; justify-content: space-between; gap: 6px; font-size: 9px; color: var(--muted); }
  .card-footer > span:first-child { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
  .details-link { display: flex; align-items: center; gap: 3px; flex-shrink: 0; color: var(--accent); }
  .card-error { display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; overflow-wrap: anywhere; margin-top: 12px; padding: 8px; background: #fff0eb; color: var(--danger); border-radius: 5px; font: 10px/1.6 var(--mono); }
  .detail { margin-top: 24px; padding: 26px; scroll-margin-top: 20px; }
  .detail header { display: flex; align-items: flex-start; gap: 20px; margin-bottom: 22px; }
  .detail header h2 { display: flex; align-items: center; flex-wrap: wrap; gap: 12px; margin-top: 7px; }
  .detail-description { color: var(--muted); font-size: 12px; margin-top: 8px; }
  .close { display: flex; align-items: center; justify-content: center; min-height: 30px; padding: 6px; margin-left: auto; }
  .notice pre { margin: 7px 0 0; font-size: 11px; white-space: pre-wrap; overflow-wrap: anywhere; }
  .detail-metrics { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); border: 1px solid var(--border); border-radius: 8px; background: #fafbf7; margin-bottom: 26px; }
  .detail-metrics > div { padding: 13px 16px; border-right: 1px solid var(--border); }
  .detail-metrics > div:last-child { border-right: 0; }
  .detail-metrics span { display: block; color: var(--muted); font-size: 10px; }
  .detail-metrics strong { display: block; font: 13px var(--mono); margin-top: 7px; overflow-wrap: anywhere; }
  .detail-columns { display: grid; grid-template-columns: 1fr 1fr; gap: 32px; }
  h3 { font-size: 14px; margin-bottom: 13px; display: flex; align-items: center; gap: 8px; }
  h4 { margin-top: 18px; font-size: 11px; color: var(--muted); }
  .command-list a { position: relative; display: block; border-bottom: 1px solid var(--border-soft); padding: 10px 20px 10px 0; text-decoration: none; }
  .command-list a:first-child { padding-top: 0; }
  .command-list code { font-size: 11px; }
  .command-list a > span { display: block; color: var(--muted); font-size: 10px; margin-top: 3px; }
  .command-list :global(svg) { position: absolute; top: 12px; right: 0; }
  .detail-empty { color: var(--muted); font-size: 12px; }
  .status-segments { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 8px 18px; font-size: 11px; margin: 0; }
  .status-segments dt { color: var(--muted); }
  .status-segments dd { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
  .last-log { font-size: 10px; color: var(--muted); white-space: pre-wrap; overflow-wrap: anywhere; background: var(--bg); border-radius: 6px; padding: 10px; max-height: 170px; }
  .runtime-fields { border-top: 1px solid var(--border); margin-top: 27px; padding-top: 18px; }
  .runtime-fields summary { cursor: pointer; color: var(--accent); font-size: 12px; }
  .runtime-fields summary span { color: var(--muted); font-size: 10px; margin-left: 6px; }
  .runtime-fields dl { display: grid; grid-template-columns: minmax(130px, .3fr) minmax(0, 1fr); gap: 0 20px; font-size: 11px; }
  .runtime-fields dt, .runtime-fields dd { padding: 8px 0; border-bottom: 1px solid var(--border-soft); margin: 0; overflow-wrap: anywhere; }
  .runtime-fields dt { color: var(--muted); }
  .runtime-fields pre { margin: 0; font-size: 10px; white-space: pre-wrap; overflow-wrap: anywhere; }
  .empty button { margin-top: 15px; font-size: 12px; }
  @media (max-width: 1050px) { .overview { grid-template-columns: repeat(3, 1fr); }.overview > a { display: none; }.overview > div:last-of-type { border-right: 0; }.detail-metrics { grid-template-columns: repeat(3, 1fr); }.detail-metrics > div:nth-child(3) { border-right: 0; }.detail-metrics > div:nth-child(-n+3) { border-bottom: 1px solid var(--border); } }
  @media (max-width: 650px) { .overview > div { padding: 16px 12px; }.overview .eyebrow { font-size: 8px; }.plugin-grid { padding: 12px; grid-template-columns: minmax(0, 1fr); }.detail { padding: 20px 16px; }.detail-columns { grid-template-columns: 1fr; gap: 24px; }.detail-metrics > div { padding: 12px; } }
  @media print {
    .overview { grid-template-columns: repeat(3, minmax(0, 1fr)); overflow: visible; break-inside: avoid; }
    .overview > a, .details-link, .close { display: none; }
    .overview > div:nth-child(3) { border-right: 0; }
    .plugin-browser { overflow: visible; border: 0; }
    .plugin-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; padding: 0; background: none; }
    .plugin-card { break-inside: avoid; }
    .detail { break-inside: auto; }
  }
</style>
