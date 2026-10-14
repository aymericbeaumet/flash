<script lang="ts">
  import Icon from "./Icon.svelte";
  import KeyboardBoard from "./KeyboardBoard.svelte";
  import {
    capsAt, categories, categoryOf, keySteps, mappingModes, mappingSnippet, rowsForMode, rowsUnder, stepsToKey,
    type BoardView, type KeyStep,
  } from "./keyboard";
  import { explainMapping, scoreSearch, searchFields } from "./mapping-search";
  import SourceBadge from "./SourceBadge.svelte";
  import { sourceFromOrigin } from "./source";
  import type { CommandInfo, KeyboardState, MappingRow, MappingsState } from "./types";
  let { mappings, keyboard, commands = [], filter = "" }: { mappings: MappingsState; keyboard?: KeyboardState; commands?: CommandInfo[]; filter?: string } = $props();

  // What the page shows is picked here, never taken from the mode Flash is in.
  let mode = $state("normal");
  let layer = $state<string[]>([]);
  let path = $state<KeyStep[]>([]);
  let picked = $state<KeyStep | null>(null);
  let boardView = $state<BoardView>("bindings");
  let view = $state("effective");
  let query = $state("");
  let copied = $state<string | null>(null);
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

  const leader = $derived(mappings.normal_leader);
  const rows = $derived(view === "effective" ? mappings.effective_rows ?? mappings.rows : mappings.rows);
  const modeRows = $derived(rowsForMode(rows, mode));
  const caps = $derived(capsAt(modeRows, path, layer, leader));
  const modeInfo = $derived(mappingModes.find((item) => item.id === mode) ?? mappingModes[0]);
  const appName = $derived(mappings.localized_name ?? mappings.bundle_id ?? "the current application");
  const layers: [string[], string][] = [[[], "No modifier"], [["shift"], "⇧ Shift"], [["ctrl"], "⌃ Control"], [["alt"], "⌥ Option"], [["cmd"], "⌘ Command"]];
  const freeRule: Record<string, string> = {
    all: "Pick a mode to see which keys are free in it.",
    normal: "A free key is swallowed in NORMAL, so it is yours to map.",
    visual: "A free key falls through to NORMAL's binding, or is swallowed.",
    drag: "A free key falls through to NORMAL's binding, or is swallowed.",
    hyper: "A free key is swallowed while the hyper key is held.",
    insert: "A free key types into the app.",
    command: "Only modified chords map here; other keys type into the command line.",
    terminal: "A free key goes to the program in the terminal.",
  };

  function sameLayer(a: string[], b: string[]): boolean {
    return a.length === b.length && a.every((item) => b.includes(item));
  }
  function stepText(step: KeyStep): string {
    return [...step.modifiers, step.cap].join("+");
  }
  function pick(cap: string) {
    const step: KeyStep = { cap, modifiers: [...layer] };
    if (caps.get(cap)?.continues) {
      // A prefix opens what can follow it, as Flash waits for the next key.
      path = [...path, step];
      picked = null;
      layer = [];
      return;
    }
    picked = picked && picked.cap === cap && sameLayer(picked.modifiers, layer) ? null : step;
  }
  function back(to: number) {
    path = path.slice(0, to);
    picked = null;
  }
  function chooseMode(id: string) {
    mode = id;
    path = [];
    picked = null;
  }

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
  async function copy(text: string, id: string) {
    try {
      await navigator.clipboard.writeText(text);
      copied = id;
      setTimeout(() => { if (copied === id) copied = null; }, 1600);
    } catch {
      copied = null;
    }
  }

  // A search reads the whole mode; otherwise the keyboard's prefix and key narrow it.
  const searching = $derived(query.trim().length > 0);
  const listed = $derived.by(() => {
    const q = query.trim();
    if (!q) return rowsUnder(modeRows, path, picked, leader).map((row) => ({ row, score: 0 }));
    return modeRows
      .map((row) => ({ row, score: scoreSearch(q, searchFields(row, commands, sourceText(row.origin))) }))
      .filter((item): item is { row: MappingRow; score: number } => item.score != null)
      .sort((a, b) => b.score - a.score || compareText(a.row.action, b.row.action) || compareText(a.row.key, b.row.key));
  });
  // A search lights the first key of every match on the keyboard.
  const hits = $derived(new Set(searching ? listed.map((item) => keySteps(item.row.key, leader)?.[0]?.cap).filter((cap): cap is string => !!cap) : []));
  const groups = $derived.by(() => {
    const byCategory = new Map<string, { row: MappingRow; score: number }[]>();
    for (const item of listed) {
      const id = categoryOf(item.row.action);
      byCategory.set(id, [...(byCategory.get(id) ?? []), item]);
    }
    const order = categories.map((category) => category.id);
    const ids = [...byCategory.keys()].sort((a, b) => {
      if (searching) return (byCategory.get(b)?.[0].score ?? 0) - (byCategory.get(a)?.[0].score ?? 0) || order.indexOf(a) - order.indexOf(b);
      return order.indexOf(a) - order.indexOf(b);
    });
    return ids.map((id) => {
      const items = byCategory.get(id) ?? [];
      const sorted = searching ? items.map((item) => item.row) : items.map((item) => item.row).sort((a, b) => compareText(a.key, b.key));
      return { id, label: categories.find((category) => category.id === id)?.label ?? id, rows: sorted };
    });
  });
  const countsHere = $derived((mode === "normal" || mode === "visual" || mode === "drag") && !path.length && !layer.length);
  const pickedFree = $derived(picked !== null && !searching && !caps.get(picked.cap) && !(countsHere && /^[1-9]$/.test(picked.cap)));
  const freeSnippet = $derived(picked ? `[mode.${mode === "all" ? "normal" : mode}.mappings]\n${JSON.stringify(stepsToKey([...path, picked]))} = ["flash", "…"]` : "");
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

<div class="page">
  <div class="page-heading"><p class="eyebrow">Your Flash</p><h1>A key for every move.</h1><p>Ask what a key does, or how to do something. Pick a mode under the keyboard, then a key: a key that starts longer bindings opens what can follow it. Search by what a binding does; the keys it matches light up.</p></div>

  <div class="ask surface"><Icon name="search" size={18} /><input type="search" aria-label="Search mappings" placeholder="What do you want to do? Try brightness, window left, ctrl-f…" bind:this={searchInput} bind:value={query} />{#if mappings.normal_leader}<span class="leader">Leader <kbd>{mappings.normal_leader}</kbd></span>{/if}<div class="segmented" aria-label="Mapping source"><button class:active={view === "effective"} aria-pressed={view === "effective"} title="Resolved for {appName}, with active plugins" onclick={() => (view = "effective")}>In {appName}</button><button class:active={view === "configured"} aria-pressed={view === "configured"} title="From your configuration, before plugins and app overrides" onclick={() => (view = "configured")}>Configured</button></div></div>

  {#if keyboard}
    <div class="surface board">
      <div class="board-head">
        <nav class="trail" aria-label="Key sequence"><button class:here={!path.length} onclick={() => back(0)}>Keys</button>{#each path as step, index}<span>›</span><button class:here={index === path.length - 1} onclick={() => back(index + 1)}><kbd>{stepText(step)}</kbd></button>{/each}{#if path.length}<span class="muted">then…</span>{/if}</nav>
        <div class="controls">
          {#if boardView === "bindings"}<div class="segmented" aria-label="Modifier held">{#each layers as [mods, label]}<button class:active={sameLayer(layer, mods)} aria-pressed={sameLayer(layer, mods)} onclick={() => { layer = mods; picked = null; }}>{label}</button>{/each}</div>{/if}
          <div class="segmented" aria-label="What the keyboard shows">{#each [["bindings", "Bindings"], ["alphabet", "Hint keys"], ["grid", "Grid"], ["zones", "Zones"]] as [value, label]}<button class:active={boardView === value} aria-pressed={boardView === value} onclick={() => (boardView = value as BoardView)}>{label}</button>{/each}</div>
        </div>
      </div>
      <div class="board-keys"><KeyboardBoard {keyboard} {caps} {hits} {leader} view={boardView} selected={picked?.cap ?? null} counts={countsHere} onpick={pick} /></div>
      <div class="modes" role="radiogroup" aria-label="Mode">{#each mappingModes as item}<button role="radio" class="mode mode-{item.id}" class:active={mode === item.id} aria-checked={mode === item.id} onclick={() => chooseMode(item.id)}>{item.label}<span>{rowsForMode(rows, item.id).length}</span></button>{/each}</div>
      <p class="mode-summary"><strong>{modeInfo.label}.</strong> {modeInfo.summary} {#if boardView === "bindings"}{freeRule[mode]}{:else if boardView === "alphabet"}The hint alphabet while labels are up: warmer keys are handed out first.{:else if boardView === "grid"}The mouse grid's keys while it is up, laid out like the screen.{:else}With <code>label_order = "zones"</code>, a label's first key names the zone of the window.{/if}</p>
      {#if boardView === "bindings"}<div class="legend">{#each categories.filter((category) => [...caps.values()].some((entry) => entry.bindings.some((row) => categoryOf(row.action) === category.id))) as category}<span><i data-category={category.id}></i>{category.label}</span>{/each}<span><i class="prefix"></i>starts longer bindings</span><span><i class="free"></i>free</span></div>{/if}
    </div>
  {/if}

  {#if pickedFree && picked}
    <div class="surface free-key"><div><strong><kbd>{[...path, picked].map(stepText).join(" ")}</kbd> is free in {modeInfo.label}.</strong><p>{freeRule[mode]} Add a binding to your <a href="/docs/config">configuration</a>:</p></div><pre>{freeSnippet}</pre><button type="button" onclick={() => copy(freeSnippet, "free")}>{copied === "free" ? "Copied" : "Copy"}</button></div>
  {/if}

  <div class="surface mapping-list">
    <div class="list-head"><strong>{searching ? `Matches in ${modeInfo.label}` : picked ? `Bindings on ${[...path, picked].map(stepText).join(" ")}` : path.length ? `After ${path.map(stepText).join(" ")}` : `${modeInfo.label} bindings`}</strong>{#if picked || path.length}<button type="button" class="clear" onclick={() => back(0)}>Show every key</button>{/if}<span class="count">{listed.length} of {modeRows.length}</span></div>
    {#each groups as group (group.id)}<section class="mapping-group"><div class="group-label"><i data-category={group.id}></i><strong>{group.label}</strong><span>{group.rows.length}</span></div><div class="table-wrap"><table class="data-table"><thead><tr><th class="key-column">Key</th><th>What it does</th><th class="from-column">Source</th><th class="help-column"><span class="sr">Change it</span></th></tr></thead><tbody>{#each group.rows as row (rowId(row))}<tr><td><kbd>{row.key}</kbd>{#if mode === "all" || mode === "visual" || mode === "drag"}<span class="scope">{row.scope}</span>{/if}</td><td><span class="does">{explainMapping(row, commands)}</span><code>{row.action}</code></td><td class="from"><SourceBadge {...sourceFromOrigin(row.origin)} /></td><td class="help"><button type="button" class="change" aria-label="Copy the TOML that changes this binding" onmouseenter={(event) => showTip(event, `Copy the flash.toml lines that rebind or remove ${row.key}:\n${mappingSnippet(row)}`, rowId(row))} onmouseleave={hideTip} onfocus={(event) => showTip(event, mappingSnippet(row), rowId(row))} onblur={hideTip} onclick={() => copy(mappingSnippet(row), rowId(row))}>{copied === rowId(row) ? "✓" : "TOML"}</button></td></tr>{/each}</tbody></table></div></section>{/each}
    {#if !listed.length}<div class="empty"><strong>No mappings match</strong>{searching ? "Try what it does, a key, or a command. A close spelling still counts." : "Nothing in this mode starts here; pick another key or mode."}</div>{/if}
  </div>
  {#if tip}<div id="mapping-explanation" class="why-pop" role="tooltip" style:top="{tip.top}px" style:left="{tip.left}px">{tip.text}</div>{/if}
  {#if mappings.actions?.length && actions.length}<div class="surface mapping-list action-resolution"><div class="group-label"><strong class="resolution-title">How actions resolve in {appName}</strong><p>A source that performs the action wins; otherwise the plugin binding runs.</p><span>{actions.length} actions</span></div><div class="table-wrap"><table class="data-table"><thead><tr><th class="key-column">Action</th><th>Tried first</th><th>Binding</th><th>Declared by</th></tr></thead><tbody>{#each actions as row}<tr><td><code>{row.action}</code></td><td>{#if row.claimed_by.length}<code>{row.claimed_by.join(" → ")}</code>{:else}<span class="muted">—</span>{/if}</td><td>{#if row.binding}<kbd>{row.binding}</kbd>{:else}<span class="muted">nothing</span>{/if}</td><td>{#if row.source}<code>{row.source}</code>{:else}<span class="muted">—</span>{/if}</td></tr>{/each}</tbody></table></div></div>{/if}
  <p class="mapping-tip">Changes to your TOML file appear here after reload. <a href="/docs/mappings">Mapping syntax</a> · <a href="/docs/config">Customize your configuration</a></p>
</div>

<style>
  .ask { display: flex; align-items: center; gap: 12px; padding: 12px 18px; margin-bottom: 18px; color: #6c875c; }
  .ask input { flex: 1; max-width: none; font-size: 13px; border: 0; box-shadow: none; padding: 6px 0; }
  .ask input:focus { outline: none; }
  .leader { display: flex; align-items: center; gap: 8px; color: var(--muted); font-size: 11px; white-space: nowrap; }
  .segmented { display: inline-flex; border: 1px solid var(--border); border-radius: 7px; overflow: hidden; flex-shrink: 0; }
  .segmented button { border: 0; border-radius: 0; min-height: 30px; padding: 4px 11px; font-size: 11px; background: #fff; white-space: nowrap; }
  .segmented button + button { border-left: 1px solid var(--border); }
  .segmented button.active { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
  .board { padding: 16px 22px; margin-bottom: 18px; }
  .board-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 14px; flex-wrap: wrap; }
  .controls { display: flex; gap: 10px; flex-wrap: wrap; }
  .trail { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
  .trail button { min-height: 0; padding: 2px 8px; border-radius: 6px; font-size: 12px; background: transparent; border-color: transparent; }
  .trail button.here { font-weight: 650; color: var(--text); }
  .board-keys { overflow: auto; padding: 4px 2px; }
  .modes { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 16px; }
  .mode { display: inline-flex; align-items: center; gap: 8px; min-height: 32px; padding: 4px 12px; border-radius: 999px; font-size: 11px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; background: #fff; }
  .mode span { font-weight: 500; color: var(--muted); letter-spacing: 0; }
  .mode.active { border-color: #6c875c; background: #eef4e8; color: #244f38; }
  .mode-visual.active { border-color: #c98a4f; background: #f8eadb; color: #6a3d12; }
  .mode-drag.active { border-color: #c9a33f; background: #fbf1d6; color: #5e4710; }
  .mode-hyper.active { border-color: #9a78b8; background: #efe5f6; color: #4e2d6e; }
  .mode-insert.active { border-color: #7e9fc2; background: #e3edf7; color: #1f4a73; }
  .mode-summary { margin-top: 10px; font-size: 12px; color: var(--muted); }
  .mode-summary strong { color: var(--text); font-weight: 600; }
  .legend { display: flex; flex-wrap: wrap; gap: 6px 16px; margin-top: 12px; font-size: 11px; color: var(--muted); }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  i[data-category], .legend i { display: inline-block; width: 12px; height: 12px; border-radius: 3px; border: 1px solid #c9d8bd; background: #eef4e8; }
  i[data-category="pointer"] { background: #e6efdd; border-color: #a9c296; }
  i[data-category="scroll"] { background: #e3edf7; border-color: #9db6d8; }
  i[data-category="tabs"] { background: #f6ecdc; border-color: #d9b98a; }
  i[data-category="windows"] { background: #ece6f6; border-color: #b5a3d4; }
  i[data-category="modes"] { background: #f7e3e3; border-color: #d6a1a1; }
  i[data-category="system"] { background: #e2f1ef; border-color: #8fc3bb; }
  i[data-category="plugins"], i[data-category="programs"], i[data-category="other"] { background: #eef0ec; border-color: #bfc6bb; }
  .legend i.prefix { background: #f4f6f1; border-color: #b9c6ad; }
  .legend i.free { background: transparent; border-style: dashed; }
  .free-key { display: flex; align-items: center; gap: 16px; padding: 14px 20px; margin-bottom: 18px; flex-wrap: wrap; }
  .free-key > div { flex: 1; min-width: 240px; }
  .free-key p { font-size: 11px; color: var(--muted); margin-top: 4px; }
  .free-key pre { margin: 0; padding: 8px 12px; border-radius: 8px; background: #f4f6f1; font-size: 11px; }
  .mapping-list { overflow: hidden; }
  .list-head { display: flex; align-items: center; gap: 12px; padding: 14px 18px; border-bottom: 1px solid var(--border); }
  .list-head strong { font-size: 13px; font-weight: 600; }
  .list-head .count { margin-left: auto; font-size: 11px; color: var(--muted); }
  .clear { min-height: 0; padding: 3px 10px; border-radius: 999px; font-size: 11px; }
  .group-label { display: flex; align-items: center; gap: 10px; padding: 12px 18px; background: #f1f5ec; border-bottom: 1px solid var(--border); }
  .group-label strong { font-size: 12px; font-weight: 600; }
  .group-label p { color: var(--muted); font-size: 11px; }
  .group-label > span:last-child { margin-left: auto; font-size: 10px; color: var(--muted); }
  .key-column { width: 170px; }
  .from-column { width: 170px; }
  .help-column, .help { position: sticky; right: 0; width: 64px; background: #fff; z-index: 1; }
  .help-column { background: #fafbf8; }
  .help { text-align: right; vertical-align: middle; }
  .data-table tbody tr:hover .help { background: #fbfcf9; }
  .sr { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
  .scope { margin-left: 8px; font-size: 9px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
  .does { display: block; font-size: 12px; color: var(--text); }
  .data-table code { display: block; margin-top: 3px; color: #6b7666; font-size: 10px; white-space: pre-wrap; overflow-wrap: anywhere; }
  /* The shared button rule is a 36px field; this control stays a small mark. */
  .change { min-height: 0; height: 24px; padding: 0 8px; border-radius: 999px; font-size: 10px; font-weight: 600; background: #f7f8f4; color: #6d7868; }
  .change:hover, .change:focus-visible { color: #3f5a32; border-color: #6c875c; background: #f1f5ec; outline: none; }
  .why-pop { position: fixed; z-index: 40; width: min(300px, calc(100vw - 16px)); padding: 10px 12px; background: #fff; color: var(--text); border: 1px solid var(--border); border-radius: 10px; box-shadow: 0 10px 28px rgba(40, 48, 32, .12); font-size: 11px; line-height: 1.45; white-space: pre-wrap; font-family: var(--mono); pointer-events: none; }
  .from { white-space: nowrap; }
  .data-table td { padding-top: 10px; padding-bottom: 10px; vertical-align: top; }
  .mapping-tip { color: var(--muted); font-size: 11px; margin-top: 20px; }
  .action-resolution { margin-top: 24px; }
  .resolution-title { font-size: 12px; font-weight: 550; white-space: nowrap; }
  .muted { color: var(--muted); font-size: 11px; }
  .empty { padding: 32px; }
  @media print { .ask, .controls, .modes, .change { display: none; } .board-keys { overflow: visible; } }
</style>
