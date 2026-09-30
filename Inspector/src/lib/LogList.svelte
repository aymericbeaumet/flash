<script lang="ts">
  import { flushSync } from "svelte";
  import Icon from "./Icon.svelte";
  import type { LogRecord } from "./types";
  import { logSearchText, timestamp } from "./format";

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
  let copied = $state(false);
  let copyError = $state("");
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
    copied = false;
    copyError = "";
  }
  async function copySelected() {
    const record = selected;
    if (!record) return;
    copied = false;
    copyError = "";
    try {
      await navigator.clipboard.writeText(recordJSON(record));
      if (selected === record) copied = true;
    } catch {
      if (selected === record) copyError = "Copy failed. Select the record text below to copy it manually.";
    }
  }
</script>

<div class="logs">
  <div class="toolbar">
    <input type="search" aria-label="Search logs" placeholder="Search messages, sources, or fields…" bind:value={query} />
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
      <div class="detail-bar"><span class="level level-{selected.level || 'info'}">{selected.level || "info"}</span><strong>{selected.source || "Record details"}</strong><span class="detail-time">{timestamp(selected.time_unix_ms)}</span><button class="copy" onclick={copySelected}><Icon name={copied ? "check" : "clipboard"} size={13} />{copied ? "Copied" : "Copy JSON"}</button><button class="close" aria-label="Close log details" onclick={() => selected = null}><Icon name="close" size={15} /></button></div>
      {#if copyError}<p class="copy-error" role="alert">{copyError}</p>{/if}
      <pre>{recordJSON(selected)}</pre>
      <span class="sr-status" role="status">{copied ? "Record copied to clipboard." : ""}</span>
    </section>
  {/if}
</div>

<style>
  .logs { display: flex; flex-direction: column; height: 100%; min-height: 0; }
  .toolbar { flex-shrink: 0; padding: 14px 16px; }
  .toolbar input, .toolbar select, .toolbar button { font-size: 11px; min-height: 33px; }
  .toolbar input { max-width: none; flex: 1; min-width: 180px; }
  .source-filter { max-width: 170px; }
  .tail-button { display: flex; align-items: center; gap: 7px; color: var(--muted); }
  .tail-button i { width: 6px; height: 6px; border-radius: 50%; background: #bb974e; }
  .tail-button.following { color: var(--accent); background: #f1f6eb; }
  .tail-button.following i { background: #5b9761; }
  .log-caption { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 10px 17px; font-size: 10px; color: var(--muted); flex-shrink: 0; }
  .log-caption button { margin-left: 10px; border: 0; min-height: 0; padding: 0; color: var(--accent); background: none; font-size: 10px; text-decoration: underline; }
  .header, .row { display: grid; grid-template-columns: 103px 54px minmax(90px, .25fr) minmax(180px, 1fr) 12px; gap: 13px; align-items: center; padding: 0 17px; }
  .header { min-height: 34px; background: #f8faf5; border-top: 1px solid var(--border-soft); border-bottom: 1px solid var(--border); color: var(--muted); font-size: 9px; text-transform: uppercase; letter-spacing: .08em; flex-shrink: 0; }
  .viewport { flex: 1; overflow: auto; min-height: 90px; position: relative; }
  .spacer { position: relative; width: 100%; min-width: 600px; }
  .rows { position: absolute; top: 0; left: 0; right: 0; }
  .row { width: 100%; height: 36px; min-height: 36px; text-align: left; border: 0; border-bottom: 1px solid var(--border-soft); border-radius: 0; cursor: pointer; background: #fff; }
  .row:hover { background: #f7f9f2; }
  .row.selected { background: #eaf2e1; }
  .row > :global(svg) { color: #97a38e; }
  .time { color: var(--muted); font: 10px var(--mono); white-space: nowrap; }
  .source { color: var(--accent); font: 10px var(--mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .message { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: 11px var(--mono); }
  .fields { margin-left: 14px; color: #7b857a; font-size: 10px; }
  .level { display: inline-block; text-align: center; border-radius: 4px; padding: 3px 4px; text-transform: uppercase; font-size: 8px; letter-spacing: .04em; font-weight: 600; color: var(--muted); background: #f0f2ed; }
  .level-info { color: #47704b; background: #edf3e6; }
  .level-debug { color: #5e737d; background: #eef3f6; }
  .level-warn { color: #9a701a; background: #fcf3d9; }
  .level-error, .level-fatal { color: var(--danger); background: #fbe9e3; }
  .detail { flex: 0 0 auto; max-height: 43%; display: flex; flex-direction: column; border-top: 1px solid #c4d2bb; min-height: 0; background: #fafcf7; }
  .detail-bar { display: flex; gap: 10px; align-items: center; padding: 10px 16px; flex-shrink: 0; border-bottom: 1px solid var(--border-soft); }
  .detail-bar strong { font-size: 11px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .detail-time { font: 9px var(--mono); color: var(--muted); }
  .detail-bar button { min-height: 28px; padding: 4px 8px; font-size: 10px; display: flex; align-items: center; justify-content: center; gap: 5px; }
  .detail-bar .copy { margin-left: auto; white-space: nowrap; }
  .detail-bar .close { padding: 4px; }
  .detail pre { margin: 0; padding: 15px 18px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; font-size: 10px; }
  .copy-error { font-size: 10px; color: var(--danger); padding: 8px 17px 0; }
  .sr-status { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
  .empty { font-size: 12px; }
  @media (max-width: 850px) { .header, .row { gap: 9px; padding-left: 13px; padding-right: 13px; grid-template-columns: 91px 49px minmax(75px, .25fr) minmax(160px, 1fr) 12px; }.detail-time { display: none; }.source-filter { max-width: 140px; } }
  @media (max-width: 640px) { .log-caption { flex-wrap: wrap; gap: 3px; }.toolbar { gap: 7px; }.toolbar input { flex-basis: 100%; }.header { grid-template-columns: 91px 49px 75px minmax(160px, 1fr) 12px; overflow: hidden; }.header span { white-space: nowrap; } }
  .print-rows { display: none; }
  @media print {
    .logs { display: block; height: auto; }
    .toolbar, .viewport, .header, .detail, .log-caption > span:last-child { display: none; }
    .log-caption { padding: 0 0 8px; }
    .print-rows { display: block; }
    .print-row { display: grid; grid-template-columns: 90px 44px minmax(80px, .25fr) minmax(0, 1fr); gap: 10px; padding: 4px 0; border-bottom: 1px solid var(--border-soft); break-inside: avoid; }
    .print-row .source, .print-row .message { overflow: visible; white-space: normal; overflow-wrap: anywhere; }
    .print-row .fields { display: block; margin: 2px 0 0; }
  }
</style>
