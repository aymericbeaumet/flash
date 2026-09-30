<script lang="ts">
  import Icon from "./Icon.svelte";
  import type { MappingsState } from "./types";
  let { mappings, filter = "" }: { mappings: MappingsState; filter?: string } = $props();
  let query = $state("");
  let scope = $state("");
  let view = $state("effective");
  $effect(() => { query = filter; });
  const rows = $derived(view === "effective" ? mappings.effective_rows ?? mappings.rows : mappings.rows);
  const scopes = $derived([...new Set(rows.map((row) => row.scope))]);
  const scopeOrder: Record<string, number> = { all: 0, normal: 1, insert: 2 };
  const filtered = $derived(rows.filter((row) => (!scope || row.scope === scope) && `${row.key} ${row.action} ${row.scope}`.toLowerCase().includes(query.trim().toLowerCase())).sort((a, b) => (scopeOrder[a.scope] ?? 9) - (scopeOrder[b.scope] ?? 9) || a.key.localeCompare(b.key)));
  const categories = $derived([...new Set(filtered.map((row) => row.scope))]);
</script>

<div class="page"><div class="page-heading"><p class="eyebrow">Your Flash</p><h1>A key for every move.</h1><p>Explore your live mappings. Find the key you need, see exactly what it does, and make it your own.</p></div>
  <div class="mapping-context surface"><span class="context-icon"><Icon name="mappings" size={22} /></span><div><strong>{view === "effective" ? "Effective mappings" : "Configured mappings"}</strong><p>{view === "effective" ? `Resolved for ${mappings.localized_name ?? mappings.bundle_id ?? "the current application"}, including active plugin contributions.` : "Mappings from your resolved Flash configuration, before active plugin contributions."}</p></div>{#if mappings.normal_leader}<span class="leader">Leader <kbd>{mappings.normal_leader}</kbd></span>{/if}<a href="#docs/mappings">Mapping syntax <Icon name="arrow" size={15} /></a></div>
  <div class="surface mapping-list"><div class="toolbar"><input type="search" aria-label="Search mappings by key, action or scope" placeholder="Find a key, action, or scope…" bind:value={query} /><select bind:value={scope} aria-label="Filter mappings by mode"><option value="">All modes</option>{#each scopes as item}<option value={item}>{item}</option>{/each}</select><div class="segmented" aria-label="Mapping source"><button class:active={view === "effective"} aria-pressed={view === "effective"} onclick={() => { view = "effective"; scope = ""; }}>Effective</button><button class:active={view === "configured"} aria-pressed={view === "configured"} onclick={() => { view = "configured"; scope = ""; }}>Configured</button></div><span class="count">{filtered.length} of {rows.length}</span></div>
    {#each categories as category}<section class="mapping-group"><div class="group-label"><span class="badge" class:neutral={category !== "normal"}>{category}</span><p>{category === "all" ? "Available across modes" : category === "normal" ? "Navigate and act while NORMAL is active" : category === "insert" ? "Available while typing in INSERT" : "Mappings for this context"}</p><span>{filtered.filter((row) => row.scope === category).length} bindings</span></div><div class="table-wrap"><table class="data-table"><thead><tr><th class="key-column">Key sequence</th><th>Action</th></tr></thead><tbody>{#each filtered.filter((row) => row.scope === category) as row}<tr><td><kbd>{row.key}</kbd></td><td><code>{row.action}</code></td></tr>{/each}</tbody></table></div></section>{/each}
    {#if !filtered.length}<div class="empty"><strong>No mappings match</strong>Try a different key or action, or select all modes.</div>{/if}
  </div><p class="mapping-tip">Changes to your TOML file appear here after reload. <a href="#docs/config">Learn how to customize mappings →</a></p>
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
  .data-table td { padding-top: 11px; padding-bottom: 11px; }
  .data-table code { color: #6b7666; font-size: 11px; white-space: pre-wrap; overflow-wrap: anywhere; }
  .mapping-tip { color: var(--muted); font-size: 11px; margin-top: 20px; }
  @media (max-width: 1100px) { .mapping-context { flex-wrap: wrap; } .mapping-context > div { min-width: 230px; } .leader { margin-left: 37px; } .key-column { width: 150px; } }
  @media (max-width: 600px) { .group-label p { display: none; } .mapping-context { padding: 17px; } .key-column { width: 110px; } .toolbar input { flex-basis: 100%; } .mapping-context > div { min-width: 160px; } }
</style>
