<script lang="ts">
  import type { PluginInfo } from "./types";
  import { bytes, duration, percent } from "./format";

  let { plugins }: { plugins: PluginInfo[] } = $props();

  let selectedID = $state<string | null>(null);

  const selected = $derived(plugins.find((p) => p.id === selectedID) ?? null);

  // Exhaustive key/value dump of the selected plugin (#90): every field
  // the runtime exposes, including ones without a dedicated column, so the
  // detail view never hides something useful for debugging.
  const detailEntries = $derived.by(() => {
    if (!selected) return [] as [string, string][];
    return Object.entries(selected)
      .filter(([k]) => k !== "commands")
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([k, v]) => [k, formatValue(v)] as [string, string]);
  });

  function formatValue(v: unknown): string {
    if (v == null) return "—";
    if (Array.isArray(v)) return v.length ? v.join(", ") : "—";
    if (typeof v === "object") return JSON.stringify(v);
    return String(v);
  }

  function stateClass(state: string): string {
    if (state === "ready" || state === "running") return "ok";
    if (state === "starting" || state === "installing") return "warn";
    if (state.includes("error") || state === "failed" || state === "crashed") return "err";
    return "";
  }
</script>

<div class="plugins" class:has-detail={selected}>
  <div class="list">
    <table>
      <thead>
        <tr>
          <th>ID</th>
          <th>State</th>
          <th>CPU</th>
          <th>RAM</th>
          <th>PID</th>
          <th>HB</th>
          <th>Cmds</th>
          <th>Origin</th>
        </tr>
      </thead>
      <tbody>
        {#each plugins as p (p.id)}
          <tr
            class:selected={p.id === selectedID}
            onclick={() => (selectedID = p.id === selectedID ? null : p.id)}
          >
            <td>{p.id} <span class="dim">{p.version}</span></td>
            <td><span class="badge {stateClass(p.state)}">{p.state}</span></td>
            <td>{percent(p.cpu_percent)}</td>
            <td>{bytes(p.memory_bytes)}</td>
            <td>{p.pid ?? "—"}</td>
            <td>{p.heartbeat_age_ms != null ? `${p.heartbeat_age_ms}ms` : "—"}</td>
            <td>{p.command_count ?? 0}</td>
            <td>{p.origin ?? "—"}</td>
          </tr>
        {/each}
        {#if plugins.length === 0}
          <tr><td colspan="8" class="dim">no plugins loaded</td></tr>
        {/if}
      </tbody>
    </table>
  </div>

  {#if selected}
    <aside class="detail">
      <header>
        <strong>{selected.id}</strong>
        <button class="close" onclick={() => (selectedID = null)}>✕</button>
      </header>
      {#if selected.description}
        <p class="desc">{selected.description}</p>
      {/if}
      <div class="metrics">
        <div><span class="k">CPU</span><span>{percent(selected.cpu_percent)}</span></div>
        <div><span class="k">Memory</span><span>{bytes(selected.memory_bytes)}</span></div>
        <div><span class="k">Uptime</span><span>{duration(selected.uptime_ms)}</span></div>
      </div>

      <h4>All fields</h4>
      <dl>
        {#each detailEntries as [k, v]}
          <dt>{k}</dt>
          <dd>{v}</dd>
        {/each}
      </dl>

      {#if selected.commands && selected.commands.length}
        <h4>Commands ({selected.commands.length})</h4>
        <ul class="cmds">
          {#each selected.commands as c}
            <li>
              <code>:{c.command} {c.subcommand}</code>
              <span class="dim">{c.description}</span>
            </li>
          {/each}
        </ul>
      {/if}
    </aside>
  {/if}
</div>

<style>
  .plugins {
    height: 100%;
    min-height: 0;
    display: grid;
    grid-template-columns: 1fr;
  }
  .plugins.has-detail {
    grid-template-columns: minmax(0, 1fr) minmax(280px, 360px);
  }
  .list {
    overflow: auto;
    min-height: 0;
  }
  table {
    width: 100%;
    border-collapse: collapse;
  }
  th,
  td {
    padding: 3px 8px;
    border-bottom: 1px solid var(--border-soft);
    text-align: left;
    white-space: nowrap;
  }
  th {
    color: var(--accent);
    position: sticky;
    top: 0;
    background: var(--bg);
  }
  tbody tr {
    cursor: pointer;
  }
  tbody tr:hover {
    background: var(--panel);
  }
  tbody tr.selected {
    background: var(--panel-strong);
  }
  .dim {
    color: var(--muted);
  }
  .badge {
    border-radius: 4px;
    padding: 1px 6px;
    background: #26313b;
  }
  .badge.ok { color: #10222d; background: var(--accent); }
  .badge.warn { color: #2d2200; background: #ffd166; }
  .badge.err { color: #fff3f2; background: #d9574f; }
  .detail {
    overflow: auto;
    min-height: 0;
    border-left: 1px solid var(--border);
    padding: 10px 12px;
    background: var(--panel);
  }
  .detail header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .close {
    min-width: 0;
    padding: 0 6px;
  }
  .desc {
    color: var(--muted);
    margin: 6px 0;
  }
  .metrics {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 6px;
    margin: 8px 0;
  }
  .metrics > div {
    display: grid;
    gap: 2px;
    background: var(--bg);
    border: 1px solid var(--border-soft);
    border-radius: 6px;
    padding: 6px;
  }
  .metrics .k {
    color: var(--accent);
    font-size: 10px;
    text-transform: uppercase;
  }
  h4 {
    margin: 12px 0 4px;
    color: var(--accent);
    font-size: 11px;
  }
  dl {
    display: grid;
    grid-template-columns: minmax(90px, auto) 1fr;
    gap: 2px 10px;
    margin: 0;
  }
  dt {
    color: var(--muted);
  }
  dd {
    margin: 0;
    word-break: break-word;
  }
  ul.cmds {
    margin: 0;
    padding-left: 0;
    list-style: none;
  }
  ul.cmds li {
    display: grid;
    gap: 1px;
    padding: 3px 0;
    border-bottom: 1px solid var(--border-soft);
  }
  code {
    color: #8bd3ff;
  }
</style>
