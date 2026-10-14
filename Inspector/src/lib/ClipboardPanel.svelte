<script lang="ts">
  import Icon from "./Icon.svelte";
  import { linkSegments } from "./linkify";
  import type { ClipboardEntry } from "./types";

  let { entries }: { entries: ClipboardEntry[] } = $props();
  let query = $state("");
  let copied = $state<string | null>(null);
  let copying = $state<string | null>(null);
  let removed = $state<string[]>([]);
  let notice = $state("");
  let zoomed = $state<{ src: string; alt: string } | null>(null);
  let requestID = 0;

  // The zoomed image closes with Escape as well as a click.
  $effect(() => {
    if (!zoomed) return;
    const close = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      zoomed = null;
    };
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  });

  const visible = $derived(entries.filter((entry) => entry.id && !removed.includes(entry.id)));
  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    return visible.map((entry, index) => ({ ...entry, index })).filter((entry) => !q || haystack(entry).includes(q));
  });

  function haystack(entry: ClipboardEntry): string {
    return [entry.kind, entry.preview, entry.value, entry.mime ?? "", ...(entry.files ?? [])].join("\n").toLowerCase();
  }

  function imageURL(entry: ClipboardEntry): string | null {
    if (!entry.mime || !/^[0-9a-f]{32}$/.test(entry.id)) return null;
    return `/api/clipboard/${entry.id}`;
  }

  function kindLabel(kind: string): string {
    switch (kind) {
      case "image": return "Image";
      case "html": return "Formatted";
      case "files": return "Files";
      default: return "Text";
    }
  }

  async function copy(entry: ClipboardEntry) {
    const request = ++requestID;
    copying = entry.id;
    copied = null;
    notice = "";
    try {
      const mime = entry.mime;
      const url = imageURL(entry);
      if (mime && url && (entry.kind === "image" || entry.kind === "files")) {
        const response = await fetch(url);
        if (!response.ok) throw new Error("missing image");
        const blob = await response.blob();
        await navigator.clipboard.write([new ClipboardItem({ [mime]: blob })]);
      } else if (entry.kind === "html" && entry.html) {
        await navigator.clipboard.write([
          new ClipboardItem({
            "text/html": new Blob([entry.html], { type: "text/html" }),
            "text/plain": new Blob([entry.value], { type: "text/plain" }),
          }),
        ]);
      } else {
        await navigator.clipboard.writeText(entry.value);
      }
      if (request === requestID) copied = entry.id;
    } catch {
      if (request === requestID) notice = "The browser could not copy this entry. Allow clipboard access, or expand the entry and select its text to copy manually.";
    } finally {
      if (request === requestID) copying = null;
    }
  }

  async function remove(entry: ClipboardEntry) {
    if (!/^[0-9a-f]{32}$/.test(entry.id) || removed.includes(entry.id)) return;
    removed = [...removed, entry.id];
    notice = "";
    copied = null;
    try {
      const response = await fetch(`/api/clipboard/${entry.id}`, { method: "DELETE" });
      if (!response.ok) throw new Error(String(response.status));
    } catch {
      removed = removed.filter((id) => id !== entry.id);
      notice = "Could not delete this entry.";
    }
  }
</script>

{#snippet linked(text: string)}{#each linkSegments(text) as segment}{#if segment.href}<a href={segment.href} target="_blank" rel="noopener noreferrer">{segment.text}</a>{:else}{segment.text}{/if}{/each}{/snippet}

<div class="page">
  <div class="page-heading"><p class="eyebrow">Inspect</p><h1>Clipboard</h1><p>Find something you copied earlier and put it back on your clipboard, or delete it from this history. Images, formatted text, and files are kept along with plain text.</p></div>
  <div class="privacy-note"><Icon name="shield" size={16} /><span>History is provided by your local Flash instance.</span><a href="/docs/privacy">About clipboard privacy</a></div>
  {#if notice}<div class="notice error" role="alert">{notice}</div>{/if}
  <div class="sr-status" role="status" aria-live="polite">{copied !== null ? "Entry copied to your clipboard." : ""}</div>
  <div class="surface clipboard">
    <div class="toolbar"><input type="search" aria-label="Search clipboard history" placeholder="Search clipboard history…" bind:value={query} /><span class="count">{filtered.length} of {visible.length} entries</span></div>
    {#if filtered.length}
      <div class="entries">
        {#each filtered as entry (entry.id)}
          <article class="entry" class:copied={copied === entry.id}>
            <span class="entry-number">{String(entry.index + 1).padStart(2, "0")}</span>
            <div class="entry-content">
              <p class="preview">{@render linked(entry.preview || entry.value || kindLabel(entry.kind))}</p>
              <div class="entry-meta"><span class="badge neutral">{kindLabel(entry.kind)}</span>{#if entry.mime}<span>{entry.mime}</span>{/if}{#if entry.value}<span>{entry.value.length.toLocaleString()} characters</span>{/if}{#if entry.files?.length}<span>{entry.files.length} {entry.files.length === 1 ? "file" : "files"}</span>{/if}</div>
              {#if imageURL(entry)}{@const src = imageURL(entry) ?? ""}<button type="button" class="image-button" aria-label="Zoom into this image" onclick={() => (zoomed = { src, alt: entry.preview || "Copied image" })}><img class="clip-image" {src} alt={entry.preview || "Copied image"} /></button>{/if}
              {#if entry.kind === "html" && entry.html}<iframe class="clip-html" sandbox="" srcdoc={entry.html} title="Formatted clipboard entry" referrerpolicy="no-referrer"></iframe>{/if}
              {#if entry.files?.length}<ul class="files">{#each entry.files as file (file)}<li>{file}</li>{/each}</ul>{/if}
              {#if entry.value}<details><summary>View plain text</summary><pre>{@render linked(entry.value)}</pre></details>{/if}
            </div>
            <div class="entry-actions">
              <button type="button" class="copy-button" disabled={copying !== null} onclick={() => copy(entry)} aria-label={copied === entry.id ? "Entry copied" : `Copy clipboard entry ${entry.index + 1}`}><Icon name={copied === entry.id ? "check" : "clipboard"} size={14} />{copying === entry.id ? "Copying…" : copied === entry.id ? "Copied" : "Copy"}</button>
              <button type="button" class="delete-button" onclick={() => remove(entry)} aria-label={`Delete clipboard entry ${entry.index + 1}`}><Icon name="close" size={14} />Delete</button>
            </div>
          </article>
        {/each}
      </div>
    {:else}
      <div class="empty"><span class="empty-icon"><Icon name="clipboard" size={25} /></span><strong>{visible.length ? "No matching entries" : "Your clipboard history is empty"}</strong><p>{visible.length ? "Try another word or clear the search." : "Copy something in another app. If nothing appears, check that the clipboard plugin is running."}</p>{#if visible.length}<button type="button" onclick={() => query = ""}>Clear search</button>{:else}<a href="/plugins/clipboard">Check clipboard plugin <span>→</span></a>{/if}</div>
    {/if}
  </div>
</div>

{#if zoomed}
  <button type="button" class="zoom" aria-label="Close the zoomed image" onclick={() => (zoomed = null)}><img src={zoomed.src} alt={zoomed.alt} /></button>
{/if}

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
  .entry-meta { display: flex; flex-wrap: wrap; gap: 8px 12px; align-items: center; font-size: 10px; color: var(--muted); margin-top: 8px; }
  .preview a, pre a { color: var(--accent); text-decoration: underline; text-underline-offset: 2px; }
  .image-button { display: block; padding: 0; margin: 0; min-height: 0; border: 0; background: none; cursor: zoom-in; }
  .zoom { position: fixed; inset: 0; z-index: 60; display: grid; place-items: center; padding: 32px; margin: 0; border: 0; border-radius: 0; background: rgba(24, 28, 22, .82); cursor: zoom-out; }
  .zoom img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 8px; box-shadow: 0 18px 48px rgba(0, 0, 0, .35); background: #fff; }
  .clip-image { display: block; max-width: 100%; max-height: 240px; margin-top: 12px; border: 1px solid var(--border-soft); border-radius: 7px; object-fit: contain; background: #fff; }
  .clip-html { display: block; width: 100%; height: 180px; margin-top: 12px; border: 1px solid var(--border-soft); border-radius: 7px; background: #fff; }
  .files { margin: 12px 0 0; padding-left: 18px; font: 11px/1.6 var(--mono); overflow-wrap: anywhere; }
  details { margin-top: 8px; }
  summary { cursor: pointer; width: fit-content; font-size: 11px; color: var(--accent); }
  pre { margin: 12px 0 0; padding: 14px; background: var(--bg); border: 1px solid var(--border-soft); border-radius: 7px; white-space: pre-wrap; overflow-wrap: anywhere; max-height: 350px; }
  .entry-actions { display: flex; flex-direction: column; gap: 6px; }
  .copy-button, .delete-button { display: flex; align-items: center; gap: 6px; min-height: 31px; font-size: 11px; padding: 5px 10px; }
  .copy-button { color: var(--accent); }
  .delete-button { color: var(--danger); }
  .empty-icon { display: flex; justify-content: center; color: #92a18f; margin-bottom: 15px; }
  .empty p { max-width: 420px; margin: 0 auto; font-size: 13px; }
  .empty a, .empty button { display: inline-block; margin-top: 17px; font-size: 12px; }
  .sr-status { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
  @media (max-width: 640px) { .entry { padding: 18px 14px; gap: 10px; grid-template-columns: 19px minmax(0, 1fr); }.entry-actions { grid-column: 1 / -1; flex-direction: row; }.privacy-note { flex-wrap: wrap; }.privacy-note a { margin-left: 24px; } }
  @media print {
    .privacy-note a, .entry-actions { display: none; }
    .clipboard { overflow: visible; border: 0; }
    .entry { grid-template-columns: 27px minmax(0, 1fr); padding: 12px 0; break-inside: avoid; }
    .clip-html { height: auto; min-height: 80px; }
  }
</style>
