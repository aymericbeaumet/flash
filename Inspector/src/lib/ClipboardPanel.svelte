<script lang="ts">
  import type { ClipboardEntry } from "./types";

  let { entries }: { entries: ClipboardEntry[] } = $props();

  let query = $state("");
  let copied = $state(-1);

  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    return q
      ? entries.filter(
          (e) =>
            e.preview.toLowerCase().includes(q) ||
            e.value.toLowerCase().includes(q),
        )
      : entries;
  });

  // Served from localhost, so navigator.clipboard is available (secure context).
  async function copy(e: ClipboardEntry, i: number) {
    try {
      await navigator.clipboard.writeText(e.value);
      copied = i;
      setTimeout(() => {
        if (copied === i) copied = -1;
      }, 1200);
    } catch {
      copied = -1;
    }
  }
</script>

<div class="clip">
  <div class="toolbar">
    <strong>Clipboard</strong>
    <input type="search" placeholder="filter history" bind:value={query} />
    <span class="count">{filtered.length}/{entries.length}</span>
  </div>
  <div class="list">
    {#each filtered as e, i (e.value + i)}
      <button class="row" onclick={() => copy(e, i)} title="click to copy">
        <span class="idx">{i + 1}</span>
        <span class="preview">{e.preview || "(empty)"}</span>
        <span class="action">{copied === i ? "copied ✓" : "copy"}</span>
      </button>
    {/each}
    {#if filtered.length === 0}
      <p class="empty">{entries.length === 0 ? "No clipboard history yet." : "No matches."}</p>
    {/if}
  </div>
</div>

<style>
  .clip {
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
    padding: 6px;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .row {
    display: grid;
    grid-template-columns: 28px minmax(0, 1fr) auto;
    align-items: center;
    gap: 10px;
    width: 100%;
    text-align: left;
    padding: 6px 8px;
    border: 1px solid transparent;
    border-radius: 5px;
    background: transparent;
  }
  .row:hover {
    border-color: var(--border);
    background: var(--panel);
  }
  .idx {
    color: var(--muted);
    font-size: 11px;
    text-align: right;
  }
  .preview {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: var(--mono, ui-monospace, monospace);
    color: var(--text);
  }
  .action {
    font-size: 11px;
    color: var(--accent);
    opacity: 0;
  }
  .row:hover .action {
    opacity: 1;
  }
  .empty {
    color: var(--muted);
    padding: 12px;
  }
</style>
