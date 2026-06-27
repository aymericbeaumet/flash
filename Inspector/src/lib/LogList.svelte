<script lang="ts">
  import type { LogRecord } from "./types";
  import { logSearchText, timestamp } from "./format";

  let { logs }: { logs: LogRecord[] } = $props();

  const ROW_HEIGHT = 24;
  const OVERSCAN = 20;

  let query = $state("");
  let level = $state("");
  let paused = $state(false);
  let viewport = $state<HTMLDivElement | null>(null);
  let scrollTop = $state(0);
  let viewportHeight = $state(400);
  let selected = $state<LogRecord | null>(null);
  let copied = $state(false);

  const levels = ["trace", "debug", "info", "warn", "error", "fatal"];

  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    if (!q && !level) return logs;
    return logs.filter(
      (l) => (!level || l.level === level) && (!q || logSearchText(l).includes(q)),
    );
  });

  // When not paused and anchored at the bottom, keep following new rows.
  $effect(() => {
    // Touch `filtered` so this re-runs as logs stream in.
    filtered.length;
    if (paused || !viewport) return;
    queueMicrotask(() => {
      if (viewport) viewport.scrollTop = viewport.scrollHeight;
    });
  });

  const totalHeight = $derived(filtered.length * ROW_HEIGHT);
  const startIndex = $derived(Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - OVERSCAN));
  const visibleCount = $derived(Math.ceil(viewportHeight / ROW_HEIGHT) + OVERSCAN * 2);
  const endIndex = $derived(Math.min(filtered.length, startIndex + visibleCount));
  const slice = $derived(filtered.slice(startIndex, endIndex));
  const topPad = $derived(startIndex * ROW_HEIGHT);

  function onScroll() {
    if (!viewport) return;
    scrollTop = viewport.scrollTop;
    const atBottom =
      viewport.scrollTop + viewport.clientHeight >= viewport.scrollHeight - ROW_HEIGHT;
    // Scrolling up pauses the live tail; scrolling back to the bottom resumes.
    paused = !atBottom;
  }

  function measure(node: HTMLDivElement) {
    viewport = node;
    const ro = new ResizeObserver(() => (viewportHeight = node.clientHeight));
    ro.observe(node);
    return { destroy: () => ro.disconnect() };
  }

  function jumpToBottom() {
    paused = false;
    if (viewport) viewport.scrollTop = viewport.scrollHeight;
  }

  function recordJSON(l: LogRecord): string {
    return JSON.stringify(l, null, 2);
  }

  function fieldsPreview(l: LogRecord): string {
    if (!l.fields) return "";
    const entries = Object.entries(l.fields);
    if (entries.length === 0) return "";
    return entries
      .map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`)
      .join("  ");
  }

  function selectRow(l: LogRecord) {
    selected = selected === l ? null : l;
    copied = false;
  }

  async function copySelected() {
    if (!selected) return;
    try {
      await navigator.clipboard.writeText(recordJSON(selected));
      copied = true;
      setTimeout(() => (copied = false), 1200);
    } catch {
      copied = false;
    }
  }
</script>

<div class="logs">
  <div class="toolbar">
    <strong>Logs</strong>
    <input type="search" placeholder="search message, source, fields" bind:value={query} />
    <select bind:value={level}>
      <option value="">all levels</option>
      {#each levels as l}
        <option value={l}>{l}</option>
      {/each}
    </select>
    <button class:active={paused} onclick={jumpToBottom} title="Resume live tail">
      {paused ? "Resume ▼" : "Live"}
    </button>
    <span class="count">{filtered.length}/{logs.length}{paused ? " · paused" : ""}</span>
  </div>

  <div class="header">
    <span>time</span>
    <span>level</span>
    <span>source</span>
    <span>message</span>
    <span>fields</span>
  </div>

  <div class="viewport" use:measure onscroll={onScroll}>
    <div class="spacer" style="height: {totalHeight}px">
      <div class="rows" style="transform: translateY({topPad}px)">
        {#each slice as l (startIndex + slice.indexOf(l))}
          <div
            class="row"
            class:selected={selected === l}
            onclick={() => selectRow(l)}
            role="button"
            tabindex="0"
            onkeydown={(e) => e.key === "Enter" && selectRow(l)}
          >
            <span class="ts">{timestamp(l.time_unix_ms)}</span>
            <span class="lvl lvl-{l.level || 'info'}">{l.level || "info"}</span>
            <span class="src" title={l.source || "-"}>{l.source || "-"}</span>
            <span class="msg" title={l.message || ""}>{l.message || ""}</span>
            <span class="fields" title={fieldsPreview(l)}>{fieldsPreview(l)}</span>
          </div>
        {/each}
      </div>
    </div>
  </div>

  {#if selected}
    <div class="detail">
      <div class="detail-bar">
        <strong>Record</strong>
        <button onclick={copySelected}>{copied ? "Copied ✓" : "Copy JSON"}</button>
        <button onclick={() => (selected = null)} title="Close">✕</button>
      </div>
      <pre>{recordJSON(selected)}</pre>
    </div>
  {/if}
</div>

<style>
  .logs {
    display: grid;
    grid-template-rows: auto auto minmax(0, 1fr) auto;
    height: 100%;
    min-height: 0;
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
    width: min(520px, 42vw);
  }
  .count {
    margin-left: auto;
    color: var(--muted);
  }
  button.active {
    color: var(--bg);
    background: var(--accent);
    border-color: var(--accent);
    font-weight: 700;
  }
  .header {
    display: grid;
    grid-template-columns: 180px 60px minmax(140px, 0.28fr) minmax(220px, 0.5fr) minmax(160px, 0.5fr);
    gap: 8px;
    padding: 4px 10px;
    border-bottom: 1px solid var(--border);
    background: var(--panel);
    color: var(--muted);
    font-size: 10px;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .viewport {
    overflow: auto;
    position: relative;
    padding: 0 10px;
  }
  .spacer {
    position: relative;
    width: 100%;
  }
  .rows {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    will-change: transform;
  }
  .row {
    height: 24px;
    display: grid;
    grid-template-columns: 180px 60px minmax(140px, 0.28fr) minmax(220px, 0.5fr) minmax(160px, 0.5fr);
    gap: 8px;
    align-items: center;
    border-bottom: 1px solid var(--border-soft);
    cursor: pointer;
  }
  .row:hover {
    background: var(--border-soft);
  }
  .row.selected {
    background: var(--border);
  }
  .ts {
    color: var(--muted);
    white-space: nowrap;
  }
  .src {
    color: var(--accent);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .msg {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .fields {
    color: var(--muted);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    font-size: 11px;
  }
  .lvl {
    display: inline-block;
    width: 52px;
    text-align: center;
    border-radius: 4px;
    padding: 1px 4px;
    font-weight: 700;
    text-transform: uppercase;
    font-size: 10px;
  }
  .lvl-trace { color: #9aa4ad; background: #20262d; }
  .lvl-debug { color: #c2ccd6; background: #26313b; }
  .lvl-info { color: #10222d; background: var(--accent); }
  .lvl-warn { color: #2d2200; background: #ffd166; }
  .lvl-error { color: #fff3f2; background: #d9574f; }
  .lvl-fatal { color: #fff7fb; background: #b21e59; }
  .detail {
    border-top: 1px solid var(--border);
    background: var(--panel);
    max-height: 38%;
    display: grid;
    grid-template-rows: auto minmax(0, 1fr);
    min-height: 0;
  }
  .detail-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 10px;
    border-bottom: 1px solid var(--border-soft);
  }
  .detail pre {
    margin: 0;
    padding: 8px 10px;
    overflow: auto;
    font-size: 12px;
    line-height: 1.45;
    white-space: pre;
  }
</style>
