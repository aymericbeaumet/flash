<script lang="ts">
  import Icon from "./Icon.svelte";
  import PageHeader from "./PageHeader.svelte";
  import { store } from "./store.svelte";
  import { router } from "./router.svelte";
  import { paths } from "./routes";
  import type { CommandInfo, PluginInfo } from "./types";
  import { bytes, duration } from "./format";
  import { now } from "./clock.svelte";

  let { plugins, commands = [], filter = "", sampledAt, onresample }: { plugins: PluginInfo[]; commands?: CommandInfo[]; filter?: string; sampledAt?: number; onresample: () => void } = $props();
  let query = $state("");
  let health = $state("all");
  let selectedID = $state<string | null>(null);
  let detailDialog: HTMLDialogElement;

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
  /** The selected plugin's commands, from the one command catalog the snapshot carries. */
  const selectedCommands = $derived(selected ? commands.filter((command) => command.source_kind === "plugin" && command.source === selected.id) : []);
  $effect(() => {
    if (!detailDialog) return;
    if (selected && !detailDialog.open) detailDialog.showModal();
    else if (!selected && detailDialog.open) detailDialog.close();
  });
  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    return plugins.filter((plugin) =>
      (health === "all" || (health === "running" ? isRunning(plugin) : hasError(plugin))) &&
      (!q || [plugin.id, plugin.name, plugin.description, plugin.origin, plugin.state, plugin.activation].join(" ").toLowerCase().includes(q)),
    ).sort((a, b) => a.id.localeCompare(b.id));
  });
  const detailEntries = $derived.by(() => selected ? Object.entries(selected).sort(([a], [b]) => a.localeCompare(b)) : []);
  function formatValue(value: unknown): string {
    if (value == null) return "—";
    if (typeof value === "object") return JSON.stringify(value, null, 2);
    return String(value);
  }
  function onDetailClose() {
    selectedID = null;
    if (filter) router.replace(paths.plugins());
  }
</script>

<div class="page">
  <PageHeader id="plugins" title="Plugins" purpose="What runs alongside Flash: health, resources and commands." manual={paths.docs("plugins")} live>
    {#snippet help()}
      <p>Flash starts each plugin as a child process and talks to it over standard input and output. A <strong>resident</strong> plugin runs for the life of Flash; an <strong>on demand</strong> one starts when something needs it. Select a plugin to inspect its commands, published status values and latest diagnostic.</p>
      <p>CPU time and memory change without an event, so they read as of the last snapshot; Resample in a plugin's details takes a fresh one.</p>
    {/snippet}
  </PageHeader>
  <div class="overview" role="list" aria-label="Plugin health">
    <div role="listitem"><span class="eyebrow">Loaded</span><strong>{plugins.length}</strong><span>plugins discovered</span></div>
    <div role="listitem" class:ok={runningCount > 0}><span class="eyebrow">Running</span><strong>{runningCount}</strong><span>processes active</span></div>
    <div role="listitem" class:attention={errorCount > 0}><span class="eyebrow">Need attention</span><strong>{errorCount}</strong><span>{errorCount ? "with errors to inspect" : "no reported errors"}</span></div>
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
          <button class="plugin-card" aria-haspopup="dialog" aria-controls="plugin-detail" onclick={() => selectedID = plugin.id}>
            <span class="card-heading"><i class="lamp lamp-{stateClass(plugin) || 'ok'}" aria-hidden="true"></i><span class="plugin-title"><strong>{plugin.name || plugin.id}</strong><code>{plugin.id}{plugin.version ? ` · ${plugin.version}` : ""}</code></span><span class="badge {stateClass(plugin)}">{label(plugin.state)}</span></span>
            <span class="card-description">{plugin.description || "No description provided."}</span>
            <span class="card-metrics"><span><span class="metric-label">CPU time</span><strong>{duration(plugin.cpu_time_ms)}</strong></span><span><span class="metric-label">Memory</span><strong>{bytes(plugin.memory_bytes)}</strong></span><span><span class="metric-label">Commands</span><strong>{plugin.command_count ?? 0}</strong></span></span>
            <span class="card-footer"><span>{label(plugin.activation || "resident")}{plugin.origin ? ` · ${plugin.origin}` : ""}</span><span class="details-link">Inspect details<Icon name="chevron" size={12} /></span></span>
            {#if plugin.last_error}<span class="card-error">{plugin.last_error}</span>{/if}
          </button>
        {/each}
      </div>
    {:else}
      <div class="empty"><strong>{plugins.length ? "No plugins match" : "No plugins loaded"}</strong><p>{plugins.length ? "Try another search or health filter." : "Enabled plugins will appear here when Flash discovers them."}</p>{#if query || health !== "all"}<button onclick={() => { query = ""; health = "all"; }}>Clear filters</button>{/if}</div>
    {/if}
  </div>

</div>

<dialog class="surface detail-modal" id="plugin-detail" aria-labelledby="plugin-detail-title" bind:this={detailDialog} onclose={onDetailClose}>
  {#if selected}
    <section class="detail">
      <header><div><p class="eyebrow">Plugin details</p><h2 id="plugin-detail-title">{selected.name || selected.id} <span class="badge {stateClass(selected)}">{label(selected.state)}</span></h2><p class="detail-description">{selected.description || selected.id}</p></div><button type="button" class="close" aria-label="Close plugin details" onclick={() => detailDialog.close()}><Icon name="close" size={17} /></button></header>
      {#if selected.last_error}<div class="notice error"><strong>Last reported error</strong><pre>{selected.last_error}</pre></div>{/if}
      <div class="detail-metrics">
        <div><span>CPU time</span><strong>{duration(selected.cpu_time_ms)}</strong></div><div><span>Memory</span><strong>{bytes(selected.memory_bytes)}</strong></div><div><span>Uptime</span><strong>{selected.started_at_unix_ms == null ? "—" : duration(Math.max(0, now() - selected.started_at_unix_ms))}</strong></div><div><span>Process ID</span><strong>{selected.pid ?? "—"}</strong></div><div><span>Restarts</span><strong>{selected.restart_count ?? 0}</strong></div><div><span>Sources</span><strong>{selected.source_count ?? 0}</strong></div>
      </div>
      <p class="sampled">CPU time and memory as of {sampledAt ? new Date(sampledAt).toLocaleTimeString() : "the last snapshot"}; they change without an event, so Flash samples them with each update. <button onclick={onresample}>Resample</button>{#if store.refreshError}<span class="resample-error" role="alert">{store.refreshError}</span>{/if}</p>
      <div class="detail-columns">
        <section><h3>Commands <span class="badge neutral">{selectedCommands.length}</span></h3>{#if selectedCommands.length}<div class="command-list">{#each selectedCommands as command (command.name)}<a href={paths.commands(command.name)}><code>{command.name}</code><span>{command.description || "No description provided."}</span><Icon name="chevron" size={13} /></a>{/each}</div>{:else}<p class="detail-empty">This plugin does not register commands.</p>{/if}</section>
        <section><h3>Live status</h3>{#if selected.status_segments && Object.keys(selected.status_segments).length}<dl class="status-segments">{#each Object.entries(selected.status_segments) as [key, value]}<dt>{key}</dt><dd>{value || "—"}</dd>{/each}</dl>{:else}<p class="detail-empty">No status segments published.</p>{/if}{#if selected.last_log}<h4>Latest diagnostic</h4><pre class="last-log">{selected.last_log}</pre>{/if}</section>
      </div>
      <details class="runtime-fields"><summary>All runtime fields <span>{detailEntries.length}</span></summary><dl>{#each detailEntries as [key, value]}<dt>{key}</dt><dd><pre>{formatValue(value)}</pre></dd>{/each}</dl></details>
    </section>
  {/if}
</dialog>

<style>
  .overview { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; margin-bottom: 14px; }
  .overview > div { display: flex; align-items: baseline; flex-wrap: wrap; gap: 2px 10px; padding: 10px 14px; border: 1px solid var(--border); border-top: 2px solid var(--border-strong); border-radius: 6px; background: var(--panel); box-shadow: var(--engrave); }
  .overview > div > strong { font: 600 22px/1.2 var(--mono); order: -1; }
  .overview > div > span:last-child { flex-basis: 100%; font-size: 12px; color: var(--muted); }
  .overview .ok { border-top-color: rgba(111, 181, 163, .6); }
  .overview .attention { border-top-color: var(--danger); }
  .overview .attention > strong { color: var(--danger); }
  .plugin-browser { overflow: hidden; }
  .plugin-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(290px, 1fr)); gap: 10px; padding: 12px; background: var(--inset); }
  .plugin-card { display: flex; flex-direction: column; text-align: left; border: 1px solid var(--border); border-radius: 6px; padding: 12px 14px; min-width: 0; background: var(--panel); box-shadow: var(--engrave); }
  .plugin-card:hover { border-color: var(--accent-dim); background: var(--raised); }
  .card-heading { display: flex; align-items: center; gap: 10px; width: 100%; }
  .lamp { display: inline-block; flex: none; width: 9px; height: 9px; border-radius: 50%; background: var(--faint); box-shadow: 0 0 0 2px var(--panel), 0 0 0 3px var(--accent-dim); }
  .lamp-ok { background: var(--verdigris); }
  .lamp-working { background: var(--amber); }
  .lamp-error { background: var(--danger); }
  .plugin-title { min-width: 0; flex: 1; }
  .plugin-title strong { display: block; font-size: 14px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .plugin-title code { display: block; font-size: 12px; color: var(--muted); margin-top: 1px; overflow-wrap: anywhere; }
  .card-description { color: var(--muted); font-size: 13px; margin: 10px 0 12px; line-height: 1.55; flex: 1; }
  .card-metrics { display: grid; grid-template-columns: repeat(3, 1fr); width: 100%; gap: 10px; padding: 8px 0 10px; border-top: 1px solid var(--border-soft); }
  .metric-label { display: block; font: 12px var(--mono); letter-spacing: .06em; text-transform: uppercase; color: var(--faint); margin-bottom: 2px; }
  .card-metrics strong { font: 13px var(--mono); }
  .card-footer { border-top: 1px solid var(--border-soft); padding-top: 8px; width: 100%; display: flex; justify-content: space-between; gap: 6px; font-size: 12px; color: var(--muted); }
  .card-footer > span:first-child { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
  .details-link { display: flex; align-items: center; gap: 3px; flex-shrink: 0; color: var(--accent); }
  .card-error { display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; overflow-wrap: anywhere; margin-top: 10px; padding: 6px 8px; background: var(--danger-soft); color: var(--danger); border-radius: 4px; font: 12px/1.5 var(--mono); }
  .detail-modal { width: min(960px, calc(100vw - 32px)); max-width: none; max-height: calc(100dvh - 32px); margin: auto; padding: 0; overflow: auto; color: var(--text); font: inherit; box-shadow: 0 24px 60px rgba(0, 0, 0, .6); }
  .detail-modal::backdrop { background: rgba(4, 6, 8, .7); }
  .detail { padding: 22px; }
  .detail header { display: flex; align-items: flex-start; gap: 20px; margin-bottom: 18px; }
  .detail header h2 { display: flex; align-items: center; flex-wrap: wrap; gap: 12px; margin-top: 6px; }
  .detail-description { color: var(--muted); font-size: 13px; margin-top: 6px; }
  .close { display: flex; align-items: center; justify-content: center; min-height: 32px; padding: 6px; margin-left: auto; }
  .notice pre { margin: 7px 0 0; font-size: 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
  .detail-metrics { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); border: 1px solid var(--border-soft); border-radius: 5px; background: var(--inset); box-shadow: var(--well); margin-bottom: 8px; }
  .sampled { color: var(--muted); font-size: 12px; margin: 0 0 22px; }
  .sampled button { min-height: 28px; padding: 1px 10px; margin-left: 6px; font-size: 12px; }
  .resample-error { display: block; margin-top: 6px; color: var(--danger); }
  .detail-metrics > div { padding: 10px 14px; border-right: 1px solid var(--border-soft); }
  .detail-metrics > div:last-child { border-right: 0; }
  .detail-metrics span { display: block; color: var(--faint); font: 12px var(--mono); letter-spacing: .06em; text-transform: uppercase; }
  .detail-metrics strong { display: block; font: 14px var(--mono); margin-top: 4px; overflow-wrap: anywhere; }
  .detail-columns { display: grid; grid-template-columns: 1fr 1fr; gap: 28px; }
  h3 { font: 600 12px var(--mono); letter-spacing: .12em; text-transform: uppercase; margin-bottom: 10px; display: flex; align-items: center; gap: 8px; }
  h4 { margin-top: 16px; font: 500 12px var(--mono); letter-spacing: .1em; text-transform: uppercase; color: var(--muted); }
  .command-list a { position: relative; display: block; border-bottom: 1px solid var(--border-soft); padding: 8px 20px 8px 0; text-decoration: none; }
  .command-list a:first-child { padding-top: 0; }
  .command-list code { font-size: 13px; color: var(--accent); }
  .command-list a > span { display: block; color: var(--muted); font-size: 12px; margin-top: 2px; }
  .command-list :global(svg) { position: absolute; top: 10px; right: 0; color: var(--faint); }
  .detail-empty { color: var(--muted); font-size: 13px; }
  .status-segments { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 18px; font-size: 13px; margin: 0; }
  .status-segments dt { color: var(--muted); font-family: var(--mono); font-size: 12px; }
  .status-segments dd { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font-family: var(--mono); font-size: 12px; }
  .last-log { font-size: 12px; color: var(--muted); white-space: pre-wrap; overflow-wrap: anywhere; background: var(--inset); border: 1px solid var(--border-soft); border-radius: 5px; padding: 10px; max-height: 170px; margin: 8px 0 0; }
  .runtime-fields { border-top: 1px solid var(--border); margin-top: 22px; padding-top: 14px; }
  .runtime-fields summary { cursor: pointer; color: var(--accent); font-size: 13px; min-height: 32px; display: flex; align-items: center; }
  .runtime-fields summary span { color: var(--muted); font: 12px var(--mono); margin-left: 6px; }
  .runtime-fields dl { display: grid; grid-template-columns: minmax(130px, .3fr) minmax(0, 1fr); gap: 0 20px; font-size: 12px; }
  .runtime-fields dt, .runtime-fields dd { padding: 6px 0; border-bottom: 1px solid var(--border-soft); margin: 0; overflow-wrap: anywhere; }
  .runtime-fields dt { color: var(--muted); font-family: var(--mono); }
  .runtime-fields pre { margin: 0; font-size: 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
  .empty button { margin-top: 15px; font-size: 12px; }
  @media (max-width: 1050px) { .detail-metrics { grid-template-columns: repeat(3, 1fr); } .detail-metrics > div:nth-child(3) { border-right: 0; } .detail-metrics > div:nth-child(-n+3) { border-bottom: 1px solid var(--border-soft); } }
  @media (max-width: 650px) { .overview > div { padding: 10px; } .plugin-grid { padding: 8px; grid-template-columns: minmax(0, 1fr); } .detail { padding: 18px 14px; } .detail-columns { grid-template-columns: 1fr; gap: 20px; } .detail-metrics > div { padding: 10px; } }
  @media print {
    .overview { overflow: visible; break-inside: avoid; }
    .details-link, .close, .sampled button { display: none; }
    .plugin-browser { overflow: visible; border: 0; }
    .plugin-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; padding: 0; background: none; }
    .plugin-card { break-inside: avoid; }
    .detail { break-inside: auto; }
  }
</style>
