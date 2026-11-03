<script lang="ts">
  import { withToken } from "./access";
  import { paths } from "./routes";
  import { flushSync, onDestroy, onMount, tick, untrack } from "svelte";
  import { collectHistory, fetchHistory, grownLimit, HistoryLoadError, parseClipboardPage, renderStep, withUnreached, type HistoryCursor } from "./clipboard-history";
  import ClipboardRegisters from "./ClipboardRegisters.svelte";
  import Icon from "./Icon.svelte";
  import { linkSegments } from "./linkify";
  import PageHeader from "./PageHeader.svelte";
  import { describeFailure, requestJSON, withRetry } from "./request";
  import SectionHead from "./SectionHead.svelte";
  import { store } from "./store.svelte";
  import { copiedToast, copyFailedToast, failedToast } from "./toast";
  import { toasts } from "./toasts.svelte";
  import type { ClipboardEntry, ClipboardRegister } from "./types";

  let { entries, registers, nextOffset, total }: { entries: ClipboardEntry[]; registers: ClipboardRegister[]; nextOffset: number | null; total: number } = $props();
  // Replaced whole by each load, never changed in place: no deep proxy over thousands of entries.
  let history = $state.raw<ClipboardEntry[]>([]);
  let retained = $state(0);
  let loading = $state(false);
  /** A transient failure being retried, described. */
  let retrying = $state("");
  /** A load that stopped: what failed, and where a retry resumes. */
  let failure = $state("");
  let resume = $state<HistoryCursor | null>(null);
  /** Entries listed from an earlier load that the last one did not reach. */
  let unreached = $state(0);
  let displayLimit = $state(renderStep);
  /** The row after the last rendered one: coming into view renders more. */
  let sentinel = $state<HTMLElement>();
  let query = $state("");
  let kind = $state("all");
  let copied = $state<string | null>(null);
  let copying = $state<string | null>(null);
  let pinning = $state<string | null>(null);
  let removed = $state<string[]>([]);
  let zoomed = $state<{ src: string; alt: string } | null>(null);
  let selected = $state<string | null>(null);
  let expanded = $state<string | null>(null);
  let dimensions = $state<Record<string, string>>({});
  let list = $state<HTMLElement>();
  let requestID = 0;
  let historyGeneration = 0;
  let historyRequest: AbortController | null = null;
  let firstPageKey = "";
  let initialized = false;

  $effect(() => {
    const key = `${entries.map((entry) => entry.id).join(",")}:${nextOffset ?? "end"}:${total}`;
    if (key === firstPageKey) return;
    firstPageKey = key;
    if (!initialized) {
      initialized = true;
      history = [...entries];
      retained = total;
    }
    void load(null);
  });
  // A load that stopped while Flash was away resumes once the stream is back.
  $effect(() => {
    if (!store.connected) return;
    untrack(() => { if (failure && !loading) void load(resume); });
  });
  onDestroy(() => { historyGeneration += 1; historyRequest?.abort(); });
  // j or k from anywhere on the page outside a field enters the list.
  onMount(() => {
    const enter = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || (event.key !== "j" && event.key !== "k")) return;
      const target = event.target;
      if (target instanceof HTMLElement && (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName))) return;
      if (target instanceof Node && list?.contains(target)) return;
      event.preventDefault();
      select(displayed.some((entry) => entry.id === selected) ? selected ?? undefined : displayed[0]?.id);
    };
    window.addEventListener("keydown", enter);
    return () => window.removeEventListener("keydown", enter);
  });
  onMount(() => {
    const showAll = () => flushSync(() => { displayLimit = Number.MAX_SAFE_INTEGER; });
    const restore = () => { displayLimit = renderStep; };
    window.addEventListener("beforeprint", showAll);
    window.addEventListener("afterprint", restore);
    return () => {
      window.removeEventListener("beforeprint", showAll);
      window.removeEventListener("afterprint", restore);
    };
  });

  /** One page, retried with backoff while the failure can pass on its own. */
  function pageFetcher(signal: AbortSignal) {
    return (offset: number) => withRetry(
      (attempt) => requestJSON(`/api/clipboard/history?offset=${offset}`, { signal: attempt }).then(parseClipboardPage),
      { signal, onRetry: (error, attempt, delay) => { retrying = `${describeFailure(error)}. Retrying in ${(delay / 1000).toFixed(1)} s (${attempt} of 3)…`; } },
    );
  }

  /** Loads the history from the top, or resumes a load that stopped. Entries
   * already listed stay until the load reaches or replaces them. */
  async function load(from: HistoryCursor | null) {
    historyRequest?.abort();
    const controller = new AbortController();
    historyRequest = controller;
    const generation = ++historyGeneration;
    const previous = history;
    loading = true;
    failure = "";
    retrying = "";
    const apply = (loaded: ClipboardEntry[], next: number | null, count: number) => {
      if (generation !== historyGeneration) return;
      retrying = "";
      history = withUnreached(loaded, previous, next === null);
      unreached = history.length - loaded.length;
      retained = count;
    };
    try {
      if (from) await collectHistory(from.entries, from.nextOffset, pageFetcher(controller.signal), apply, controller.signal, from.total);
      else await fetchHistory(pageFetcher(controller.signal), apply, controller.signal);
      if (generation === historyGeneration && !controller.signal.aborted) {
        resume = null;
        unreached = 0;
        removed = removed.filter((id) => history.some((entry) => entry.id === id));
      }
    } catch (error) {
      if (generation !== historyGeneration || controller.signal.aborted) return;
      if (error instanceof HistoryLoadError) {
        if (error.failure.kind === "aborted") return;
        history = withUnreached(error.cursor.entries, previous, false);
        unreached = history.length - error.cursor.entries.length;
        resume = error.cursor;
        const at = error.cursor.nextOffset ?? 0;
        failure = at === 0
          ? `Could not load clipboard history. ${describeFailure(error.failure)}.`
          : `Loaded ${error.cursor.entries.length} of ${retained || error.cursor.total}; stopped at entry ${at + 1}. ${describeFailure(error.failure)}.`;
      } else {
        failure = `Could not load clipboard history. ${describeFailure(error)}.`;
      }
    } finally {
      if (generation === historyGeneration) { loading = false; retrying = ""; }
    }
  }

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

  const kinds = [{ id: "all", label: "All" }, { id: "text", label: "Text" }, { id: "image", label: "Images" }, { id: "html", label: "Formatted" }, { id: "files", label: "Files" }];
  const visible = $derived(history.filter((entry) => entry.id && !removed.includes(entry.id)));
  /** An entry as listed, with its number in the history. */
  type Listed = ClipboardEntry & { index: number };
  const kindCounts = $derived(visible.reduce<Record<string, number>>((counts, entry) => ({ ...counts, [kindOf(entry)]: (counts[kindOf(entry)] ?? 0) + 1 }), {}));
  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    return visible.flatMap((entry, index) => ((kind === "all" || kindOf(entry) === kind) && (!q || haystack(entry).includes(q)) ? [{ ...entry, index }] : []));
  });
  const displayed = $derived(filtered.slice(0, displayLimit));
  $effect(() => { void query; void kind; displayLimit = renderStep; });
  // Infinite loading: the sentinel near the viewport renders one more step.
  // Reconnecting after each step re-reads it, so a short list keeps filling
  // until the sentinel leaves the margin or every entry shows.
  $effect(() => {
    const target = sentinel;
    void displayLimit;
    if (!target || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver((records) => {
      if (records.some((record) => record.isIntersecting)) displayLimit = grownLimit(displayLimit, filtered.length);
    }, { rootMargin: "600px 0px" });
    observer.observe(target);
    return () => observer.disconnect();
  });

  function kindOf(entry: ClipboardEntry): string {
    return ["image", "html", "files"].includes(entry.kind) ? entry.kind : "text";
  }

  /** What a search matches, built once per entry: a keystroke filters the whole history. */
  const haystacks = new WeakMap<ClipboardEntry, string>();
  function haystack(entry: ClipboardEntry): string {
    let text = haystacks.get(entry);
    if (text === undefined) {
      text = [entry.kind, entry.preview, entry.value ?? "", entry.mime ?? "", ...(entry.files ?? [])].join("\n").toLowerCase();
      haystacks.set(entry, text);
    }
    return text;
  }

  function imageURL(entry: ClipboardEntry): string | null {
    if (!entry.mime || !/^[0-9a-f]{32}$/.test(entry.id)) return null;
    return withToken(`/api/clipboard/${entry.id}`);
  }

  function kindLabel(entry: ClipboardEntry): string {
    switch (kindOf(entry)) {
      case "image": return "Image";
      case "html": return "Formatted";
      case "files": return "Files";
      default: return "Text";
    }
  }

  const count = new Intl.NumberFormat();
  /** An entry's text size by id, counted once: a long entry is not split on every render. */
  const textSizes = new Map<string, string>();
  function textSize(entry: ClipboardEntry, value: string): string {
    let text = textSizes.get(entry.id);
    if (text === undefined) {
      let lines = 1;
      for (let at = value.indexOf("\n"); at >= 0; at = value.indexOf("\n", at + 1)) lines += 1;
      text = `${count.format(value.length)} ch${lines > 1 ? ` · ${lines} ln` : ""}`;
      textSizes.set(entry.id, text);
    }
    return text;
  }

  /** What the entry weighs: characters and lines, pixels, or files. */
  function size(entry: ClipboardEntry): string {
    const parts: string[] = [];
    if (dimensions[entry.id]) parts.push(dimensions[entry.id]);
    if (entry.mime) parts.push(entry.mime.replace(/^image\//, "").toUpperCase());
    if (entry.files?.length) parts.push(`${entry.files.length} ${entry.files.length === 1 ? "file" : "files"}`);
    if (entry.value && kindOf(entry) !== "files") parts.push(textSize(entry, entry.value));
    return parts.join(" · ") || "—";
  }

  function measure(entry: ClipboardEntry, event: Event) {
    const image = event.currentTarget as HTMLImageElement;
    if (image.naturalWidth && !dimensions[entry.id]) dimensions = { ...dimensions, [entry.id]: `${image.naturalWidth}×${image.naturalHeight}` };
  }

  async function copy(entry: Listed) {
    const request = ++requestID;
    copying = entry.id;
    copied = null;
    toasts.clear("clipboard");
    try {
      const mime = entry.mime;
      const url = imageURL(entry);
      // The snapshot's rows carry previews only; the text arrives with the
      // history page this entry is on.
      if (entry.value === undefined && !(mime && url)) throw new Error("its text is still loading");
      if (mime && url && (entry.kind === "image" || entry.kind === "files")) {
        const response = await fetch(url);
        if (!response.ok) throw new Error(`the image answered HTTP ${response.status}`);
        const blob = await response.blob();
        await navigator.clipboard.write([new ClipboardItem({ [mime]: blob })]);
      } else if (entry.kind === "html" && entry.html) {
        await navigator.clipboard.write([
          new ClipboardItem({
            "text/html": new Blob([entry.html], { type: "text/html" }),
            "text/plain": new Blob([entry.value ?? ""], { type: "text/plain" }),
          }),
        ]);
      } else {
        await navigator.clipboard.writeText(entry.value ?? "");
      }
      if (request === requestID) {
        copied = entry.id;
        toasts.show(copiedToast(`clipboard entry ${entry.index + 1}`));
      }
    } catch (error) {
      const reason = error instanceof Error && error.message ? ` (${error.message})` : "";
      if (request === requestID) toasts.show(copyFailedToast(`clipboard entry ${entry.index + 1}${reason}`, "Allow clipboard access, or expand the entry and select its text."));
    } finally {
      if (request === requestID) copying = null;
    }
  }

  async function remove(entry: Listed) {
    if (!/^[0-9a-f]{32}$/.test(entry.id) || removed.includes(entry.id)) return;
    removed = [...removed, entry.id];
    toasts.clear("clipboard");
    copied = null;
    try {
      await requestJSON(`/api/clipboard/${entry.id}`, { method: "DELETE" });
      void load(null);
    } catch (error) {
      removed = removed.filter((id) => id !== entry.id);
      toasts.show(failedToast("clipboard", `Could not delete clipboard entry ${entry.index + 1}. ${describeFailure(error)}.`));
    }
  }

  /** Pins or unpins one entry; the reload lists pinned entries first. */
  async function togglePin(entry: Listed) {
    if (!/^[0-9a-f]{32}$/.test(entry.id) || pinning !== null) return;
    pinning = entry.id;
    toasts.clear("clipboard");
    try {
      await requestJSON(`/api/clipboard/${entry.id}/pin`, { method: entry.pinned ? "DELETE" : "PUT" });
      await load(null);
    } catch (error) {
      toasts.show(failedToast("clipboard", `Could not ${entry.pinned ? "unpin" : "pin"} clipboard entry ${entry.index + 1}. ${describeFailure(error)}.`));
    } finally {
      pinning = null;
    }
  }

  function select(id: string | undefined, focus = true) {
    if (!id) return;
    selected = id;
    if (focus) void tick().then(() => list?.querySelector<HTMLElement>(`[data-id="${id}"]`)?.focus());
  }

  /** j/k or the arrows move, Return copies, Space opens, p pins, Delete removes. */
  function onRowKey(event: KeyboardEvent, entry: Listed) {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    // A focused button in the row answers Return and Space itself.
    if (event.target !== event.currentTarget && (event.key === "Enter" || event.key === " ")) return;
    // Navigation walks the whole filtered list, rendering up to the row it reaches.
    const ids = filtered.map((item) => item.id);
    const at = ids.indexOf(entry.id);
    const reach = (index: number) => {
      displayLimit = grownLimit(displayLimit, ids.length, index);
      select(ids[index]);
    };
    switch (event.key) {
      case "ArrowDown": case "j": event.preventDefault(); reach(Math.min(at + 1, ids.length - 1)); break;
      case "ArrowUp": case "k": event.preventDefault(); select(ids[Math.max(at - 1, 0)]); break;
      case "Home": event.preventDefault(); select(ids[0]); break;
      case "End": event.preventDefault(); reach(ids.length - 1); break;
      case "Enter": event.preventDefault(); void copy(entry); break;
      case " ": event.preventDefault(); expanded = expanded === entry.id ? null : entry.id; break;
      case "p": event.preventDefault(); void togglePin(entry); break;
      case "Delete": case "Backspace": event.preventDefault(); select(ids[at + 1] ?? ids[at - 1]); void remove(entry); break;
    }
  }
</script>

{#snippet linked(text: string)}{#each linkSegments(text) as segment}{#if segment.href}<a href={segment.href} target="_blank" rel="noopener noreferrer">{segment.text}</a>{:else}{segment.text}{/if}{/each}{/snippet}

<div class="page">
  <PageHeader id="clipboard" title="Clipboard" purpose="Text registers and the copies Flash keeps, pinned first, then newest first." manual={paths.docs("clipboard")} live>
    {#snippet help()}
      <p>Registers hold text yanked in NORMAL; history keeps recent text, images, formatted copies and files. Restore an entry to the clipboard, pin it so it stays first and is never trimmed, or delete it from history. <code>!clip</code> in the <a href={paths.docs("flashlight")}>flashlight</a> searches and pastes the same entries. Flash keeps both on this Mac and serves them only to this page on loopback; see <a href={paths.docs("privacy", "data-stored-on-your-mac")}>clipboard privacy</a>.</p>
      <p>In the history list, <kbd>j</kbd> <kbd>k</kbd> or the arrows move, <kbd>↩</kbd> copies, <kbd>space</kbd> opens an entry, <kbd>p</kbd> pins or unpins it and <kbd>⌫</kbd> deletes it.</p>
    {/snippet}
  </PageHeader>
  <ClipboardRegisters {registers} />
  <section aria-labelledby="history-heading">
    <SectionHead id="history-heading" title="History" count={`${visible.length} of ${retained} retained`}>
      {#snippet actions()}
        <div class="segmented" role="group" aria-label="Entry type">{#each kinds as item}<button type="button" class:active={kind === item.id} aria-pressed={kind === item.id} onclick={() => (kind = item.id)}>{item.label} <span>{item.id === "all" ? visible.length : kindCounts[item.id] ?? 0}</span></button>{/each}</div>
      {/snippet}
    </SectionHead>
    <div class="surface clipboard">
      <div class="toolbar"><input type="search" aria-label="Search clipboard history" placeholder="Search text, file names, types…" bind:value={query} /><span class="count">{filtered.length} shown</span><button type="button" class="refresh-button" onclick={() => load(null)} disabled={loading}><Icon name="refresh" size={13} />Refresh</button></div>
      {#if loading}<div class="history-status" role="status">{retrying || `Loading history… ${visible.length} of ${retained || "?"}`}</div>{/if}
      {#if failure}<div class="failure" role="alert"><strong>{failure}</strong>{#if unreached > 0}<span class="detail">{unreached} older {unreached === 1 ? "entry is" : "entries are"} from the previous load</span>{/if}<button type="button" onclick={() => load(resume)} disabled={loading}>{resume && resume.nextOffset ? `Resume from entry ${resume.nextOffset + 1}` : "Retry"}</button></div>{/if}
      {#if filtered.length}
        <div class="entries" role="grid" aria-label="Clipboard history" aria-rowcount={filtered.length} bind:this={list}>
          {#each displayed as entry, position (entry.id)}
            {@const src = imageURL(entry)}
            <div role="row" class="entry" class:selected={selected === entry.id} class:copied={copied === entry.id} class:open={expanded === entry.id} data-id={entry.id}
              tabindex={selected === entry.id || (selected === null && position === 0) ? 0 : -1} aria-selected={selected === entry.id} aria-rowindex={position + 1} aria-label="{entry.pinned ? "Pinned " : ""}{kindLabel(entry)} entry {entry.index + 1}: {entry.preview || entry.value}"
              onfocus={() => (selected = entry.id)} onkeydown={(event) => onRowKey(event, entry)}>
              <span role="gridcell" class="entry-number">{#if entry.pinned}<span class="pin-mark" title="Pinned"><Icon name="pin" size={12} /></span>{:else}{String(entry.index + 1).padStart(2, "0")}{/if}</span>
              <span role="gridcell" class="kind kind-{kindOf(entry)}"><Icon name={kindOf(entry)} size={13} />{kindLabel(entry)}</span>
              <div role="gridcell" class="line">
                {#if src}<button type="button" class="thumb-button" tabindex="-1" aria-label="Zoom into this image" onclick={() => (zoomed = { src, alt: entry.preview || "Copied image" })}><img class="thumb" {src} alt="" loading="lazy" onload={(event) => measure(entry, event)} /></button>{/if}
                <button type="button" class="preview" tabindex="-1" aria-expanded={expanded === entry.id} onclick={() => { select(entry.id); expanded = expanded === entry.id ? null : entry.id; }}>{entry.preview || entry.value || kindLabel(entry)}</button>
              </div>
              <span role="gridcell" class="size">{size(entry)}</span>
              <span role="gridcell" class="actions">
                <button type="button" class="icon-button copy-button" tabindex="-1" disabled={copying !== null} onclick={() => copy(entry)} aria-label={copied === entry.id ? "Entry copied" : `Copy clipboard entry ${entry.index + 1}`} title="Copy (↩)"><Icon name={copied === entry.id ? "check" : "copy"} size={14} /></button>
                <button type="button" class="icon-button pin-button" class:active={entry.pinned} tabindex="-1" disabled={pinning !== null} onclick={() => togglePin(entry)} aria-label={`${entry.pinned ? "Unpin" : "Pin"} clipboard entry ${entry.index + 1}`} aria-pressed={entry.pinned === true} title={entry.pinned ? "Unpin (p)" : "Pin (p)"}><Icon name="pin" size={14} /></button>
                <button type="button" class="icon-button delete-button" tabindex="-1" onclick={() => remove(entry)} aria-label={`Delete clipboard entry ${entry.index + 1}`} title="Delete (⌫)"><Icon name="trash" size={14} /></button>
              </span>
              {#if expanded === entry.id}
                <div role="gridcell" class="expanded">
                  {#if src}<button type="button" class="image-button" aria-label="Zoom into this image" onclick={() => (zoomed = { src, alt: entry.preview || "Copied image" })}><img class="clip-image" {src} alt={entry.preview || "Copied image"} /></button>{/if}
                  {#if entry.kind === "html" && entry.html}<iframe class="clip-html" sandbox="" srcdoc={entry.html} title="Formatted clipboard entry" referrerpolicy="no-referrer" loading="lazy"></iframe>{/if}
                  {#if entry.files?.length}<ul class="files">{#each entry.files as file (file)}<li>{file}</li>{/each}</ul>{/if}
                  {#if entry.value}<pre class="well">{@render linked(entry.value)}</pre>{/if}
                </div>
              {/if}
            </div>
          {/each}
        </div>
        {#if displayed.length < filtered.length}<div class="show-more" bind:this={sentinel} role="status">Loading more… {filtered.length - displayed.length} remaining</div>{/if}
      {:else if !loading || visible.length}
        <div class="empty"><strong>{visible.length ? "No matching entries" : "Your clipboard history is empty"}</strong><p>{visible.length ? "Try another word or type, or clear the search." : "Copy something in another app; it appears here."}</p>{#if visible.length}<button type="button" onclick={() => { query = ""; kind = "all"; }}>Clear filters</button>{/if}</div>
      {/if}
    </div>
  </section>
</div>

{#if zoomed}
  <button type="button" class="zoom" aria-label="Close the zoomed image" onclick={() => (zoomed = null)}><img src={zoomed.src} alt={zoomed.alt} /></button>
{/if}

<style>
  .clipboard { overflow: hidden; }
  .segmented button span { margin-left: 3px; color: var(--faint); font: 12px var(--mono); }
  .segmented button.active span { color: inherit; opacity: .8; }
  .history-status { padding: 7px 14px; font: 12px var(--mono); color: var(--muted); border-bottom: 1px solid var(--border-soft); background: var(--raised); }
  .refresh-button { display: inline-flex; align-items: center; gap: 6px; min-height: 32px; font-size: 12px; padding: 4px 10px; }
  .show-more { margin: 12px auto; font-size: 12px; text-align: center; color: var(--muted); }
  .entries { display: flex; flex-direction: column; }
  /* One dense line per copy; actions surface on hover, focus and selection. */
  .entry { display: grid; grid-template-columns: 34px 104px minmax(0, 1fr) minmax(90px, auto) 104px; align-items: center; gap: 0 12px; min-height: 42px; padding: 3px 10px 3px 14px; border-bottom: 1px solid var(--border-soft); outline: none; }
  .entry:last-child { border-bottom: 0; }
  .entry:hover { background: var(--hover); }
  .entry.selected { background: var(--raised); box-shadow: inset 2px 0 0 var(--accent); }
  .entry:focus-visible { box-shadow: inset 2px 0 0 var(--accent), inset 0 0 0 1px var(--accent-dim); }
  .entry.copied { box-shadow: inset 2px 0 0 var(--verdigris); }
  .entry-number { color: var(--faint); font: 12px var(--mono); }
  .kind { display: inline-flex; align-items: center; gap: 6px; font: 12px var(--mono); letter-spacing: .04em; color: var(--muted); white-space: nowrap; }
  .kind :global(svg) { flex: none; }
  .kind-image { color: var(--steel); }
  .kind-html { color: var(--copper); }
  .kind-files { color: var(--verdigris); }
  .line { display: flex; align-items: center; gap: 10px; min-width: 0; }
  .preview { flex: 1; min-width: 0; min-height: 34px; padding: 0; border: 0; background: none; text-align: left; font: 13px var(--mono); color: var(--text); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; box-shadow: none; }
  .preview:hover { background: none; color: var(--accent-strong); }
  .thumb-button, .image-button { display: block; flex: none; padding: 0; margin: 0; min-height: 0; border: 0; background: none; cursor: zoom-in; box-shadow: none; }
  .thumb { display: block; width: 52px; height: 32px; object-fit: cover; border: 1px solid var(--border-strong); border-radius: 3px; background: var(--inset); }
  .size { justify-self: end; font: 12px var(--mono); color: var(--muted); white-space: nowrap; font-variant-numeric: tabular-nums; }
  .actions { display: flex; justify-content: flex-end; gap: 4px; opacity: 0; transition: opacity .12s; }
  .entry:hover .actions, .entry:focus-within .actions, .entry.selected .actions, .entry.copied .actions { opacity: 1; }
  @media (hover: none) { .actions { opacity: 1; } }
  .copy-button:hover, .pin-button:hover, .pin-button.active { color: var(--accent); }
  .pin-mark { display: inline-flex; color: var(--accent); }
  .delete-button:hover { color: var(--danger); border-color: rgba(229, 115, 94, .45); }
  .expanded { grid-column: 3 / -1; display: flex; flex-direction: column; gap: 10px; padding: 4px 0 12px; min-width: 0; }
  .expanded pre { margin: 0; padding: 10px 12px; white-space: pre-wrap; overflow-wrap: anywhere; max-height: 340px; color: var(--text); }
  .expanded pre a { color: var(--accent); text-decoration: underline; text-underline-offset: 2px; }
  .clip-image { display: block; max-width: 100%; max-height: 280px; border: 1px solid var(--border-strong); border-radius: 4px; object-fit: contain; background: repeating-conic-gradient(#1a2028 0 25%, #141920 0 50%) 0 0 / 16px 16px; }
  .clip-html { display: block; width: 100%; height: 180px; border: 1px solid var(--border-strong); border-radius: 4px; background: #fff; }
  .files { margin: 0; padding-left: 18px; font: 12px/1.6 var(--mono); overflow-wrap: anywhere; }
  .zoom { position: fixed; inset: 0; z-index: 60; display: grid; place-items: center; padding: 32px; margin: 0; border: 0; border-radius: 0; background: rgba(4, 6, 8, .86); cursor: zoom-out; }
  .zoom img { max-width: 100%; max-height: 100%; object-fit: contain; border-radius: 4px; box-shadow: 0 18px 48px rgba(0, 0, 0, .6); }
  .empty p { max-width: 420px; margin: 0 auto; font-size: 13px; }
  .empty button { display: inline-block; margin-top: 14px; font-size: 12px; }
  @media (max-width: 760px) {
    .entry { grid-template-columns: 26px minmax(0, 1fr) 104px; padding-left: 10px; }
    .kind, .size { display: none; }
    .expanded { grid-column: 2 / -1; }
  }
  @media print {
    .actions, .thumb-button { display: none; }
    .clipboard { overflow: visible; border: 0; }
    .entry { grid-template-columns: 30px 90px minmax(0, 1fr) auto; padding: 4px 0; break-inside: avoid; }
    .preview { white-space: normal; }
    .clip-html { height: auto; min-height: 80px; }
  }
</style>
