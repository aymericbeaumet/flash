<script lang="ts">
  import Icon from "./Icon.svelte";
  import type { ClipboardEntry } from "./types";

  let { entries }: { entries: ClipboardEntry[] } = $props();
  let query = $state("");
  let copied = $state<string | null>(null);
  let copying = $state<string | null>(null);
  let copyError = $state("");
  let requestID = 0;

  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    return entries.map((entry, index) => ({ ...entry, index })).filter((entry) => !q || (entry.preview + " " + entry.value).toLowerCase().includes(q));
  });

  async function copy(entry: ClipboardEntry) {
    const request = ++requestID;
    copying = entry.value;
    copied = null;
    copyError = "";
    try {
      await navigator.clipboard.writeText(entry.value);
      if (request === requestID) copied = entry.value;
    } catch {
      if (request === requestID) copyError = "The browser could not copy this entry. Allow clipboard access, or expand the entry and select its text to copy manually.";
    } finally {
      if (request === requestID) copying = null;
    }
  }
</script>

<div class="page">
  <div class="page-heading"><p class="eyebrow">Inspect</p><h1>Clipboard</h1><p>Find something you copied earlier and put it back on your clipboard. This history comes from your running clipboard plugin.</p></div>
  <div class="privacy-note"><Icon name="shield" size={16} /><span>History is provided by your local Flash instance.</span><a href="#docs/privacy">About clipboard privacy</a></div>
  {#if copyError}<div class="notice error" role="alert">{copyError}</div>{/if}
  <div class="sr-status" role="status" aria-live="polite">{copied !== null ? "Entry copied to your clipboard." : ""}</div>
  <div class="surface clipboard">
    <div class="toolbar"><input type="search" aria-label="Search clipboard history" placeholder="Search clipboard history…" bind:value={query} /><span class="count">{filtered.length} of {entries.length} entries</span></div>
    {#if filtered.length}
      <div class="entries">
        {#each filtered as entry (entry.index + entry.value)}
          <article class="entry" class:copied={copied === entry.value}>
            <span class="entry-number">{String(entry.index + 1).padStart(2, "0")}</span>
            <div class="entry-content">
              <p class="preview">{entry.preview || entry.value || "Empty entry"}</p>
              <div class="entry-meta"><span>{entry.value.length.toLocaleString()} characters</span>{#if entry.value.includes("\n")}<span>{entry.value.split("\n").length} lines</span>{/if}</div>
              <details><summary>View full text</summary><pre>{entry.value || "(empty)"}</pre></details>
            </div>
            <button class="copy-button" disabled={copying !== null} onclick={() => copy(entry)} aria-label={copied === entry.value ? "Entry copied" : `Copy clipboard entry ${entry.index + 1}`}><Icon name={copied === entry.value ? "check" : "clipboard"} size={14} />{copying === entry.value ? "Copying…" : copied === entry.value ? "Copied" : "Copy"}</button>
          </article>
        {/each}
      </div>
    {:else}
      <div class="empty"><span class="empty-icon"><Icon name="clipboard" size={25} /></span><strong>{entries.length ? "No matching entries" : "Your clipboard history is empty"}</strong><p>{entries.length ? "Try another word or clear the search." : "Copy some text in another app. If nothing appears, check that the clipboard plugin is running."}</p>{#if entries.length}<button onclick={() => query = ""}>Clear search</button>{:else}<a href="#plugins/clipboard">Check clipboard plugin <span>→</span></a>{/if}</div>
    {/if}
  </div>
</div>

<style>
  .privacy-note { display: flex; align-items: flex-start; gap: 8px; color: var(--muted); font-size: 11px; margin-bottom: 22px; }
  .privacy-note :global(svg) { flex-shrink: 0; margin-top: 1px; }
  .privacy-note a { margin-left: auto; white-space: nowrap; }
  .clipboard { overflow: hidden; }
  .entry { display: grid; grid-template-columns: 27px minmax(0, 1fr) auto; align-items: start; gap: 16px; padding: 21px 23px; border-bottom: 1px solid var(--border-soft); }
  .entry:last-child { border-bottom: 0; }
  .entry.copied { background: #f5f9ef; }
  .entry-number { color: #9aa59b; font: 11px var(--mono); padding-top: 4px; }
  .preview { font: 12px/1.7 var(--mono); display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; overflow-wrap: anywhere; }
  .entry-meta { display: flex; gap: 12px; font-size: 10px; color: var(--muted); margin-top: 8px; }
  details { margin-top: 8px; }
  summary { cursor: pointer; width: fit-content; font-size: 11px; color: var(--accent); }
  pre { margin: 12px 0 0; padding: 14px; background: var(--bg); border: 1px solid var(--border-soft); border-radius: 7px; white-space: pre-wrap; overflow-wrap: anywhere; max-height: 350px; }
  .copy-button { display: flex; align-items: center; gap: 6px; min-height: 31px; font-size: 11px; padding: 5px 10px; color: var(--accent); }
  .empty-icon { display: flex; justify-content: center; color: #92a18f; margin-bottom: 15px; }
  .empty p { max-width: 420px; margin: 0 auto; font-size: 13px; }
  .empty a, .empty button { display: inline-block; margin-top: 17px; font-size: 12px; }
  .sr-status { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
  @media (max-width: 640px) { .entry { padding: 18px 14px; gap: 10px; grid-template-columns: 19px minmax(0, 1fr) auto; }.privacy-note { flex-wrap: wrap; }.privacy-note a { margin-left: 24px; } }
</style>
