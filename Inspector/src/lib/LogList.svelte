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

  function fieldText(l: LogRecord): string {
    if (!l.fields || Object.keys(l.fields).length === 0) return "";
    return " " + JSON.stringify(l.fields);
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

  <div class="viewport" use:measure onscroll={onScroll}>
    <div class="spacer" style="height: {totalHeight}px">
      <div class="rows" style="transform: translateY({topPad}px)">
        {#each slice as l (startIndex + slice.indexOf(l))}
          <div class="row">
            <span class="ts">{timestamp(l.time_unix_ms)}</span>
            <span class="lvl lvl-{l.level || 'info'}">{l.level || "info"}</span>
            <span class="src" title={l.source || "-"}>{l.source || "-"}</span>
            <span class="msg" title={(l.message || "") + fieldText(l)}>
              {(l.message || "") + fieldText(l)}
            </span>
          </div>
        {/each}
      </div>
    </div>
  </div>
</div>

<style>
  .logs {
    display: grid;
    grid-template-rows: auto minmax(0, 1fr);
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
    grid-template-columns: 180px 60px minmax(160px, 0.4fr) minmax(280px, 1fr);
    gap: 8px;
    align-items: center;
    border-bottom: 1px solid var(--border-soft);
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
</style>
