<script lang="ts">
  import type { MappingsState, MappingRow } from "./types";

  let { mappings }: { mappings: MappingsState } = $props();

  let query = $state("");

  const scopeOrder: Record<string, number> = { all: 0, normal: 1, insert: 2 };

  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    const rows: MappingRow[] = mappings.rows ?? [];
    const matched = q
      ? rows.filter(
          (r) =>
            r.key.toLowerCase().includes(q) ||
            r.action.toLowerCase().includes(q) ||
            r.scope.toLowerCase().includes(q),
        )
      : rows;
    return [...matched].sort((a, b) => {
      const s = (scopeOrder[a.scope] ?? 9) - (scopeOrder[b.scope] ?? 9);
      if (s !== 0) return s;
      return a.key.localeCompare(b.key);
    });
  });
</script>

<div class="maps">
  <div class="toolbar">
    <strong>Mappings</strong>
    {#if mappings.normal_leader}
      <span class="leader">leader <code>{mappings.normal_leader}</code></span>
    {/if}
    <input type="search" placeholder="filter by key, action, scope" bind:value={query} />
    <span class="count">{filtered.length}/{(mappings.rows ?? []).length}</span>
  </div>
  <div class="list">
    <table>
      <colgroup>
        <col class="scope-column" />
        <col class="key-column" />
        <col />
      </colgroup>
      <thead>
        <tr><th>Scope</th><th>Key</th><th>Action</th></tr>
      </thead>
      <tbody>
        {#each filtered as r}
          <tr>
            <td><span class="scope {r.scope}">{r.scope}</span></td>
            <td><code>{r.key}</code></td>
            <td class="action">{r.action}</td>
          </tr>
        {/each}
        {#if filtered.length === 0}
          <tr><td colspan="3" class="dim">no mappings</td></tr>
        {/if}
      </tbody>
    </table>
  </div>
</div>

<style>
  .maps {
    height: 100%;
    min-height: 0;
    display: grid;
    grid-template-rows: auto minmax(0, 1fr);
  }
  .toolbar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 10px;
    border-bottom: 1px solid var(--border);
    background: var(--panel);
  }
  .toolbar input {
    flex: 1 1 360px;
    width: min(360px, 36vw);
    min-width: 0;
    max-width: 360px;
  }
  .leader {
    color: var(--muted);
    font-size: 12px;
  }
  .leader code {
    color: #8bd3ff;
  }
  .count {
    margin-left: auto;
    color: var(--muted);
  }
  .list {
    overflow: auto;
    min-height: 0;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    table-layout: fixed;
  }
  .scope-column {
    width: 90px;
  }
  .key-column {
    width: 150px;
  }
  th,
  td {
    padding: 3px 8px;
    border-bottom: 1px solid var(--border-soft);
    text-align: left;
    vertical-align: top;
  }
  th {
    color: var(--accent);
    position: sticky;
    top: 0;
    background: var(--bg);
  }
  code {
    color: #8bd3ff;
    white-space: nowrap;
  }
  .scope {
    border-radius: 4px;
    padding: 1px 6px;
    font-size: 11px;
    white-space: nowrap;
    background: #2b3038;
    color: #c2ccd6;
  }
  .scope.all {
    color: #10222d;
    background: var(--accent);
  }
  .scope.normal {
    color: #cfe8b0;
    background: #2c3a22;
  }
  .scope.insert {
    color: #e8c8a0;
    background: #3a2f22;
  }
  .action {
    color: var(--muted);
    overflow-wrap: anywhere;
  }
  .dim {
    color: var(--muted);
  }
</style>
