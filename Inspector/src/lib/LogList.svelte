<script lang="ts">
  import { flushSync } from "svelte";
  import Icon from "./Icon.svelte";
  import type { LogRecord } from "./types";
  import { logSearchText, timestamp } from "./format";
  import { copyText } from "./toasts.svelte";

  // The field is the page's search, so opening the page lands the cursor there.
  function focusOnMount(node: HTMLInputElement) {
    node.focus({ preventScroll: true });
  }

  let { logs }: { logs: LogRecord[] } = $props();
  const ROW_HEIGHT = 36;
  const OVERSCAN = 12;
  const levels = ["trace", "debug", "info", "warn", "error", "fatal"];
  let query = $state("");
  let level = $state("");
  let source = $state("");
  let following = $state(true);
  let viewport = $state<HTMLDivElement | null>(null);
  let scrollTop = $state(0);
  let viewportHeight = $state(400);
  let selected = $state<LogRecord | null>(null);
  // The viewport renders only the visible rows; printing renders every
  // filtered record once, beside it, for the length of the print.
  let printing = $state(false);
  $effect(() => {
    const before = () => flushSync(() => { printing = true; });
    const after = () => { printing = false; };
    window.addEventListener("beforeprint", before);
    window.addEventListener("afterprint", after);
    return () => { window.removeEventListener("beforeprint", before); window.removeEventListener("afterprint", after); };
  });

  const sources = $derived([...new Set(logs.map((record) => record.source).filter((value): value is string => !!value))].sort());
  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    return logs.filter((record) => (!level || (record.level || "info") === level) && (!source || record.source === source) && (!q || logSearchText(record).includes(q)));
  });

  $effect(() => {
    filtered;
    if (!following || !viewport) return;
    queueMicrotask(() => { if (following && viewport) viewport.scrollTop = viewport.scrollHeight; });
  });

  const visibleCount = $derived(Math.ceil(viewportHeight / ROW_HEIGHT) + OVERSCAN * 2);
  const startIndex = $derived(Math.max(0, Math.min(filtered.length - visibleCount, Math.floor(scrollTop / ROW_HEIGHT) - OVERSCAN)));
  const slice = $derived(filtered.slice(startIndex, startIndex + visibleCount));

  function onScroll() {
    if (!viewport) return;
    scrollTop = viewport.scrollTop;
    following = viewport.scrollTop + viewport.clientHeight >= viewport.scrollHeight - ROW_HEIGHT;
  }
  function measure(node: HTMLDivElement) {
    viewport = node;
    viewportHeight = node.clientHeight;
    const observer = new ResizeObserver(() => viewportHeight = node.clientHeight);
    observer.observe(node);
    return { destroy: () => observer.disconnect() };
  }
  function toggleFollowing() {
    following = !following;
    if (following && viewport) viewport.scrollTop = viewport.scrollHeight;
  }
  function clearFilters() { query = ""; level = ""; source = ""; }
  function recordJSON(record: LogRecord) { return JSON.stringify(record, null, 2); }
  function fieldsPreview(record: LogRecord) {
    return Object.entries(record.fields ?? {}).map(([key, value]) => `${key}=${typeof value === "string" ? value : JSON.stringify(value)}`).join("  ");
  }
  function selectRow(record: LogRecord) {
    selected = selected === record ? null : record;
  }
  function copySelected() {
    if (selected) void copyText(recordJSON(selected), "the record as JSON", "Select the record text below and copy it instead.");
  }
</script>

<div class="logs">
  <div class="toolbar">
    <input type="search" aria-label="Search logs" placeholder="Search messages, sources, or fields…" use:focusOnMount bind:value={query} />
    <select aria-label="Filter log level" bind:value={level}><option value="">All levels</option>{#each levels as item}<option value={item}>{item}</option>{/each}</select>
    <select class="source-filter" aria-label="Filter log source" bind:value={source}><option value="">All sources</option>{#each sources as item}<option value={item}>{item}</option>{/each}</select>
    <button class="tail-button" class:following aria-pressed={following} onclick={toggleFollowing} title={following ? "Pause automatic scrolling" : "Resume automatic scrolling"}><i></i>{following ? "Pause tail" : "Resume tail"}</button>
  </div>
  <div class="log-caption"><span>{filtered.length.toLocaleString()} of {logs.length.toLocaleString()} records{#if query || level || source}<button onclick={clearFilters}>Clear filters</button>{/if}</span><span>{following ? "Following new records" : "Tail paused · new records still arrive"}</span></div>
  <div class="header" aria-hidden="true"><span>Time</span><span>Level</span><span>Source</span><span>Message & fields</span><span></span></div>
  <div class="viewport" use:measure onscroll={onScroll} aria-label="Log records">
    {#if filtered.length}
      <div class="spacer" style:height={`${filtered.length * ROW_HEIGHT}px`}>
        <div class="rows" style:transform={`translateY(${startIndex * ROW_HEIGHT}px)`}>
          {#each slice as record, index (startIndex + index)}
            <button class="row" class:selected={selected === record} aria-expanded={selected === record} aria-controls="log-detail" onclick={() => selectRow(record)}>
              <span class="time" title={timestamp(record.time_unix_ms)}>{record.time_unix_ms ? timestamp(record.time_unix_ms).slice(11) : "—"}</span>
              <span class="level level-{record.level || 'info'}">{record.level || "info"}</span>
              <span class="source" title={record.source || "Unknown source"}>{record.source || "—"}</span>
              <span class="message" title={[record.message, fieldsPreview(record)].filter(Boolean).join("\n")}><span>{record.message || "(no message)"}</span>{#if fieldsPreview(record)}<span class="fields">{fieldsPreview(record)}</span>{/if}</span>
              <Icon name="chevron" size={12} />
            </button>
          {/each}
        </div>
      </div>
    {:else}
      <div class="empty"><strong>{logs.length ? "No matching records" : "Listening for activity"}</strong><p>{logs.length ? "Change the filters to see more of the log." : "New records appear here as Flash and its plugins work."}</p></div>
    {/if}
  </div>
  {#if printing}
    <div class="print-rows">
      {#each filtered as record}<div class="print-row"><span class="time">{record.time_unix_ms ? timestamp(record.time_unix_ms).slice(11) : "—"}</span><span class="level level-{record.level || 'info'}">{record.level || "info"}</span><span class="source">{record.source || "—"}</span><span class="message">{record.message || "(no message)"}{#if fieldsPreview(record)}<span class="fields">{fieldsPreview(record)}</span>{/if}</span></div>{/each}
    </div>
  {/if}
  {#if selected}
    <section class="detail" id="log-detail" aria-label="Selected log record">
      <div class="detail-bar"><span class="level level-{selected.level || 'info'}">{selected.level || "info"}</span><strong>{selected.source || "Record details"}</strong><span class="detail-time">{timestamp(selected.time_unix_ms)}</span><button class="copy" onclick={copySelected}><Icon name="clipboard" size={13} />Copy JSON</button><button class="close" aria-label="Close log details" onclick={() => selected = null}><Icon name="close" size={15} /></button></div>
      <pre>{recordJSON(selected)}</pre>
    </section>
  {/if}
</div>

<style>
  .logs { display: flex; flex-direction: column; flex: 1; min-width: 0; min-height: 0; }
  .toolbar { flex-shrink: 0; padding: 10px 12px; }
  .toolbar input, .toolbar select, .toolbar button { font-size: 12px; min-height: 32px; }
  .toolbar input { max-width: none; flex: 1; min-width: 180px; }
  .source-filter { max-width: 170px; }
  .tail-button { display: flex; align-items: center; gap: 7px; color: var(--muted); }
  .tail-button i { width: 7px; height: 7px; border-radius: 50%; background: var(--amber); }
  .tail-button.following { color: var(--verdigris); border-color: rgba(111, 181, 163, .35); background: var(--verdigris-soft); }
  .tail-button.following i { background: var(--verdigris); }
  .log-caption { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 6px 14px; font: 12px var(--mono); color: var(--muted); flex-shrink: 0; }
  .log-caption button { margin-left: 10px; border: 0; min-height: 0; padding: 0; color: var(--accent); background: none; font-size: 12px; text-decoration: underline; }
  .header, .row { display: grid; grid-template-columns: 108px 60px minmax(90px, .25fr) minmax(180px, 1fr) 12px; gap: 12px; align-items: center; padding: 0 14px; }
  .header { min-height: 30px; background: var(--raised); border-top: 1px solid var(--border-soft); border-bottom: 1px solid var(--border); color: var(--muted); font: 500 12px var(--mono); text-transform: uppercase; letter-spacing: .08em; flex-shrink: 0; }
  .viewport { flex: 1; overflow: auto; min-width: 0; min-height: 0; position: relative; background: var(--inset); }
  .spacer { position: relative; width: 100%; min-width: 600px; }
  .rows { position: absolute; top: 0; left: 0; right: 0; }
  .row { width: 100%; height: 36px; min-height: 36px; text-align: left; border: 0; border-bottom: 1px solid var(--border-soft); border-radius: 0; cursor: pointer; background: transparent; color: var(--text); }
  .row:hover { background: var(--hover); }
  .row.selected { background: var(--raised); box-shadow: inset 2px 0 0 var(--accent); }
  .row > :global(svg) { color: var(--faint); }
  .time { color: var(--muted); font: 12px var(--mono); white-space: nowrap; }
  .source { color: var(--accent); font: 12px var(--mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .message { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: 12px var(--mono); }
  .fields { margin-left: 14px; color: var(--muted); }
  .level { display: inline-block; text-align: center; border-radius: 3px; padding: 0 4px; text-transform: uppercase; font: 600 12px/1.6 var(--mono); letter-spacing: .02em; color: var(--muted); background: rgba(166, 157, 139, .08); }
  .level-info { color: var(--verdigris); background: var(--verdigris-soft); }
  .level-debug, .level-trace { color: var(--steel); background: var(--steel-soft); }
  .level-warn { color: var(--amber); background: var(--amber-soft); }
  .level-error, .level-fatal { color: var(--danger); background: var(--danger-soft); }
  .detail { flex: 0 0 auto; max-height: 43%; display: flex; flex-direction: column; border-top: 1px solid var(--accent-dim); min-height: 0; background: var(--panel); }
  .detail-bar { display: flex; gap: 10px; align-items: center; padding: 8px 14px; flex-shrink: 0; border-bottom: 1px solid var(--border-soft); }
  .detail-bar strong { font: 600 12px var(--mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .detail-time { font: 12px var(--mono); color: var(--muted); }
  .detail-bar button { min-height: 30px; padding: 4px 8px; font-size: 12px; display: flex; align-items: center; justify-content: center; gap: 5px; }
  .detail-bar .copy { margin-left: auto; white-space: nowrap; }
  .detail-bar .close { padding: 4px; }
  .detail pre { margin: 0; padding: 12px 16px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; font-size: 12px; color: var(--text); }
  .empty { font-size: 13px; }
  @media (max-width: 850px) { .header, .row { gap: 9px; padding-left: 12px; padding-right: 12px; grid-template-columns: 96px 56px minmax(75px, .25fr) minmax(160px, 1fr) 12px; }.detail-time { display: none; }.source-filter { max-width: 140px; } }
  @media (max-width: 640px) { .log-caption { flex-wrap: wrap; gap: 3px; }.toolbar { gap: 7px; }.toolbar input { flex-basis: 100%; }.header { grid-template-columns: 96px 56px 75px minmax(160px, 1fr) 12px; overflow: hidden; }.header span { white-space: nowrap; } }
  .print-rows { display: none; }
  @media print {
    .logs { display: block; height: auto; flex: none; }
    .toolbar, .viewport, .header, .detail, .log-caption > span:last-child { display: none; }
    .log-caption { padding: 0 0 8px; }
    .print-rows { display: block; }
    .print-row { display: grid; grid-template-columns: 90px 50px minmax(80px, .25fr) minmax(0, 1fr); gap: 10px; padding: 4px 0; border-bottom: 1px solid var(--border-soft); break-inside: avoid; }
    .print-row .source, .print-row .message { overflow: visible; white-space: normal; overflow-wrap: anywhere; }
    .print-row .fields { display: block; margin: 2px 0 0; }
  }
</style>
