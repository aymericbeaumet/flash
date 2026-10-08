<script lang="ts">
  import Icon from "./Icon.svelte";
  import { explainMapping, scoreSearch, searchFields } from "./mapping-search";
  import SourceBadge from "./SourceBadge.svelte";
  import { sourceFromOrigin } from "./source";
  import type { CommandInfo, MappingsState } from "./types";
  let { mappings, commands = [], filter = "" }: { mappings: MappingsState; commands?: CommandInfo[]; filter?: string } = $props();
  let query = $state("");
  let scope = $state("");
  let view = $state("effective");
  let searchInput = $state<HTMLInputElement | null>(null);
  let opened = false;
  let tip = $state<{ id: string; text: string; top: number; left: number } | null>(null);
  $effect(() => { query = filter; });
  $effect(() => { query; tip = null; });
  // The field is the page's search, so opening the page lands the cursor there.
  $effect(() => {
    const node = searchInput;
    if (!node || opened) return;
    opened = true;
    queueMicrotask(() => {
      node.focus({ preventScroll: true });
      const end = node.value.length;
      node.setSelectionRange(end, end);
    });
  });
  $effect(() => {
    if (!tip) return;
    const hide = () => { tip = null; };
    window.addEventListener("scroll", hide, true);
    window.addEventListener("resize", hide);
    return () => {
      window.removeEventListener("scroll", hide, true);
      window.removeEventListener("resize", hide);
    };
  });
  const rows = $derived(view === "effective" ? mappings.effective_rows ?? mappings.rows : mappings.rows);
  const scopeOrder: Record<string, number> = { all: 0, normal: 1, hyper: 2, insert: 3, terminal: 4, command: 5 };
  const scopes = $derived([...new Set(rows.map((row) => row.scope))].sort((a, b) => (scopeOrder[a] ?? 9) - (scopeOrder[b] ?? 9)));
  function compareText(a: string, b: string): number {
    return a.localeCompare(b, undefined, { sensitivity: "base", numeric: true });
  }
  function sourceText(origin: string | undefined): string {
    const source = sourceFromOrigin(origin);
    return source.kind === "builtin" ? "built-in" : `${source.kind} ${source.label}`;
  }
  function rowId(row: { scope: string; key: string; action: string }): string {
    return `${row.scope}\0${row.key}\0${row.action}`;
  }
  function showTip(event: MouseEvent | FocusEvent, text: string, id: string) {
    const target = event.currentTarget;
    if (!(target instanceof HTMLElement)) return;
    const rect = target.getBoundingClientRect();
    const width = Math.min(300, window.innerWidth - 16);
    const left = Math.max(8, Math.min(rect.right - width, window.innerWidth - width - 8));
    let top = rect.bottom + 6;
    if (top > window.innerHeight - 96) top = Math.max(8, rect.top - 96);
    tip = { id, text, top, left };
  }
  function hideTip() { tip = null; }
  const ranked = $derived.by(() => {
    const q = query.trim();
    const pool = rows.filter((row) => !scope || row.scope === scope);
    if (!q) return pool.map((row) => ({ row, score: 0 }));
    return pool
      .map((row) => ({ row, score: scoreSearch(q, searchFields(row, commands, sourceText(row.origin))) }))
      .filter((item): item is { row: (typeof pool)[number]; score: number } => item.score != null)
      .sort((a, b) => b.score - a.score || compareText(a.row.action, b.row.action) || compareText(a.row.key, b.row.key));
  });
  const modeGroups = $derived.by(() => {
    const q = query.trim();
    const modes = [...new Set(ranked.map((item) => item.row.scope))];
    modes.sort((a, b) => {
      if (!q) return (scopeOrder[a] ?? 9) - (scopeOrder[b] ?? 9);
      const best = (mode: string) => ranked.find((item) => item.row.scope === mode)?.score ?? 0;
      return best(b) - best(a) || (scopeOrder[a] ?? 9) - (scopeOrder[b] ?? 9);
    });
    return modes.map((mode) => {
      const items = ranked.filter((item) => item.row.scope === mode).map((item) => item.row);
      const groupRows = q ? items : items.sort((a, b) => compareText(a.action, b.action) || compareText(a.key, b.key));
      return { mode, rows: groupRows };
    });
  });
  const appName = $derived(mappings.localized_name ?? mappings.bundle_id ?? "the current application");
  const actions = $derived.by(() => {
    const list = mappings.actions ?? [];
    const q = query.trim();
    if (!q) return list;
    return list
      .map((row) => ({
        row,
        score: scoreSearch(q, {
          key: row.action,
          action: `${row.binding ?? ""} ${row.source ?? ""}`,
          explanation: row.claimed_by.join(" "),
          scope: "",
          source: row.source ?? "",
        }),
      }))
      .filter((item): item is { row: (typeof list)[number]; score: number } => item.score != null)
      .sort((a, b) => b.score - a.score || compareText(a.row.action, b.row.action))
      .map((item) => item.row);
  });
</script>

<div class="page"><div class="page-heading"><p class="eyebrow">Your Flash</p><h1>A key for every move.</h1><p>Search by what a binding does, its key, or its command. A typo still finds it. Hover ? to read the exact effect.</p></div>
  <div class="mapping-context surface"><span class="context-icon"><Icon name="mappings" size={22} /></span><div><strong>{view === "effective" ? "Effective mappings" : "Configured mappings"}</strong><p>{view === "effective" ? `Resolved for ${mappings.localized_name ?? mappings.bundle_id ?? "the current application"}, including active plugin contributions.` : "Mappings from your resolved Flash configuration, before active plugin contributions."}</p></div>{#if mappings.normal_leader}<span class="leader">Leader <kbd>{mappings.normal_leader}</kbd></span>{/if}<a href="/docs/mappings">Mapping syntax <Icon name="arrow" size={15} /></a></div>
  <div class="surface mapping-list"><div class="toolbar"><input type="search" aria-label="Search mappings" placeholder="Try brightness, window left, ctrl-f…" bind:this={searchInput} bind:value={query} /><select bind:value={scope} aria-label="Filter mappings by mode"><option value="">All modes</option>{#each scopes as item}<option value={item}>{item}</option>{/each}</select><div class="segmented" aria-label="Mapping source"><button class:active={view === "effective"} aria-pressed={view === "effective"} onclick={() => { view = "effective"; scope = ""; }}>Effective</button><button class:active={view === "configured"} aria-pressed={view === "configured"} onclick={() => { view = "configured"; scope = ""; }}>Configured</button></div><span class="count">{ranked.length} of {rows.length}</span></div>
    {#each modeGroups as modeGroup (modeGroup.mode)}<section class="mapping-group"><div class="group-label"><span class="badge" class:neutral={modeGroup.mode !== "normal"}>{modeGroup.mode}</span><p>{modeGroup.mode === "all" ? "Available across modes" : modeGroup.mode === "normal" ? "Navigate and act while NORMAL is active" : modeGroup.mode === "hyper" ? "Active while the leader is held" : modeGroup.mode === "insert" ? "Available while typing in INSERT" : "Mappings for this context"}</p><span>{modeGroup.rows.length} bindings</span></div><div class="table-wrap"><table class="data-table"><thead><tr><th class="key-column">Key sequence</th><th>Command</th><th class="from-column">Source</th><th class="help-column"><span class="sr">What it does</span></th></tr></thead><tbody>{#each modeGroup.rows as row (rowId(row))}<tr><td><kbd>{row.key}</kbd></td><td><code>{row.action}</code></td><td class="from"><SourceBadge {...sourceFromOrigin(row.origin)} /></td><td class="help"><button type="button" class="why" aria-label="What this binding does" aria-describedby={tip?.id === rowId(row) ? "mapping-explanation" : undefined} onmouseenter={(event) => showTip(event, explainMapping(row, commands), rowId(row))} onmouseleave={hideTip} onfocus={(event) => showTip(event, explainMapping(row, commands), rowId(row))} onblur={hideTip}>?</button></td></tr>{/each}</tbody></table></div></section>{/each}
    {#if !ranked.length}<div class="empty"><strong>No mappings match</strong>Try what it does, a key, or a command. A close spelling still counts.</div>{/if}
  </div>
  {#if tip}<div id="mapping-explanation" class="why-pop" role="tooltip" style:top="{tip.top}px" style:left="{tip.left}px">{tip.text}</div>{/if}
  {#if mappings.actions?.length && actions.length}<div class="surface mapping-list action-resolution"><div class="group-label"><span class="badge neutral">actions</span><strong class="resolution-title">How actions resolve in {appName}</strong><p>A source that performs the action wins; otherwise the plugin binding runs.</p><span>{actions.length} actions</span></div><div class="table-wrap"><table class="data-table"><thead><tr><th class="key-column">Action</th><th>Tried first</th><th>Binding</th><th>Declared by</th></tr></thead><tbody>{#each actions as row}<tr><td><code>{row.action}</code></td><td>{#if row.claimed_by.length}<code>{row.claimed_by.join(" → ")}</code>{:else}<span class="muted">—</span>{/if}</td><td>{#if row.binding}<kbd>{row.binding}</kbd>{:else}<span class="muted">nothing</span>{/if}</td><td>{#if row.source}<code>{row.source}</code>{:else}<span class="muted">—</span>{/if}</td></tr>{/each}</tbody></table></div></div>{/if}
  <p class="mapping-tip">Changes to your TOML file appear here after reload. <a href="/docs/config">Learn how to customize mappings →</a></p>
</div>

<style>
  .mapping-context { display: flex; align-items: center; gap: 15px; padding: 20px 23px; margin-bottom: 24px; }
  .context-icon { display: flex; color: #6c875c; }
  .mapping-context > div { flex: 1; }
  .mapping-context strong { font-size: 13px; font-weight: 550; }
  .mapping-context p { font-size: 11px; color: var(--muted); margin-top: 4px; }
  .mapping-context a { display: flex; align-items: center; gap: 7px; font-size: 11px; white-space: nowrap; }
  .leader { display: flex; align-items: center; gap: 8px; color: var(--muted); font-size: 11px; margin: 0 10px; }
  .mapping-list { overflow: hidden; }
  .toolbar { gap: 12px; }
  .toolbar input { max-width: none; font-size: 12px; }
  .toolbar select { font-size: 11px; }
  .group-label { display: flex; align-items: center; gap: 14px; padding: 17px 18px; background: #f1f5ec; border-bottom: 1px solid var(--border); }
  .group-label .badge { text-transform: uppercase; font-size: 9px; letter-spacing: .08em; }
  .group-label p { color: var(--muted); font-size: 11px; }
  .group-label > span:last-child { margin-left: auto; font-size: 10px; color: var(--muted); }
  .key-column { width: 200px; }
  .from-column { width: 180px; }
  .help-column, .help { position: sticky; right: 0; width: 52px; background: #fff; z-index: 1; }
  .help-column { background: #fafbf8; }
  .help { text-align: right; line-height: 0; vertical-align: middle; }
  .data-table tbody tr:hover .help { background: #fbfcf9; }
  .sr { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
  /* The shared button rule is a 36px field. This control has to stay a 22px mark or it becomes the row's height. */
  .why { display: inline-flex; align-items: center; justify-content: center; width: 22px; height: 22px; min-height: 0; padding: 0; border-radius: 999px; border: 1px solid var(--border); background: #f7f8f4; color: #6d7868; font-size: 12px; font-weight: 600; line-height: 1; cursor: help; }
  .why:hover, .why:focus-visible { color: #3f5a32; border-color: #6c875c; background: #f1f5ec; outline: none; }
  .why-pop { position: fixed; z-index: 40; width: min(300px, calc(100vw - 16px)); padding: 10px 12px; background: #fff; color: var(--text); border: 1px solid var(--border); border-radius: 10px; box-shadow: 0 10px 28px rgba(40, 48, 32, .12); font-size: 12px; line-height: 1.45; pointer-events: none; }
  .from { white-space: nowrap; }
  .data-table td { padding-top: 11px; padding-bottom: 11px; }
  .data-table code { color: #6b7666; font-size: 11px; white-space: pre-wrap; overflow-wrap: anywhere; }
  .mapping-tip { color: var(--muted); font-size: 11px; margin-top: 20px; }
  .action-resolution { margin-top: 24px; }
  .resolution-title { font-size: 12px; font-weight: 550; white-space: nowrap; }
  .muted { color: var(--muted); font-size: 11px; }
  @media (max-width: 1100px) { .mapping-context { flex-wrap: wrap; } .mapping-context > div { min-width: 230px; } .leader { margin-left: 37px; } .key-column { width: 150px; } .from-column { width: 130px; } }
  @media (max-width: 600px) { .group-label p { display: none; } .mapping-context { padding: 17px; } .key-column { width: 110px; } .from-column { width: 90px; } .from { white-space: normal; } .toolbar input { flex-basis: 100%; } .mapping-context > div { min-width: 160px; } }
  @media print {
    .mapping-context { padding: 0 0 14px; border: 0; }
    .mapping-context a, .context-icon, .mapping-tip, .help-column, .help, .why-pop { display: none; }
    .mapping-list { overflow: visible; border: 0; }
    .group-label { padding: 14px 0 6px; background: none; break-after: avoid; }
    .group-label p { display: block; }
    .key-column { width: 170px; }
    .data-table td { padding-top: 4px; padding-bottom: 4px; }
    .data-table kbd { padding: 0 6px; font-size: 11px; border-bottom-width: 1px; }
    .data-table code { color: var(--text); }
  }
</style>
