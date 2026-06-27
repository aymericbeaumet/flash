<script lang="ts">
  import type { CommandInfo } from "./types";

  let { commands }: { commands: CommandInfo[] } = $props();

  let query = $state("");

  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    const rows = q
      ? commands.filter(
          (c) =>
            c.name.toLowerCase().includes(q) ||
            c.source.toLowerCase().includes(q) ||
            (c.description ?? "").toLowerCase().includes(q),
        )
      : commands;
    return [...rows].sort((a, b) => {
      if (a.source_kind !== b.source_kind) return a.source_kind === "core" ? -1 : 1;
      if (a.source !== b.source) return a.source.localeCompare(b.source);
      return a.name.localeCompare(b.name);
    });
  });
</script>

<div class="commands">
  <div class="toolbar">
    <strong>Commands</strong>
    <input type="search" placeholder="filter by name, source, description" bind:value={query} />
    <span class="count">{filtered.length}/{commands.length}</span>
  </div>
  <div class="list">
    <table>
      <thead>
        <tr>
          <th>Command</th>
          <th>Source</th>
          <th>Description</th>
        </tr>
      </thead>
      <tbody>
        {#each filtered as c (c.name + c.source)}
          <tr>
            <td><code>{c.name}</code></td>
            <td>
              <span class="src {c.source_kind}">{c.source}</span>
            </td>
            <td class="desc">{c.description || ""}</td>
          </tr>
        {/each}
        {#if filtered.length === 0}
          <tr><td colspan="3" class="dim">no commands</td></tr>
        {/if}
      </tbody>
    </table>
  </div>
</div>

<style>
  .commands {
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
    width: min(420px, 40vw);
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
  .src {
    border-radius: 4px;
    padding: 1px 6px;
    white-space: nowrap;
  }
  .src.core {
    color: #10222d;
    background: var(--accent);
  }
  .src.plugin {
    color: #c2ccd6;
    background: #2b3038;
  }
  .desc {
    color: var(--muted);
  }
  .dim {
    color: var(--muted);
  }
</style>
