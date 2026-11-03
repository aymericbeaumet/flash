<script lang="ts">
  import { commandDoc, commandOfAction, modeDoc } from "./command-docs";
  import { paths } from "./routes";
  import Icon from "./Icon.svelte";
  import PageHeader from "./PageHeader.svelte";
  import KeyboardBoard from "./KeyboardBoard.svelte";
  import {
    capsAt, categories, categoryOf, keySteps, layerModes, mappingModes, mappingSnippet, rowsForMode, rowsUnder, stepsToKey,
    type BoardView, type KeyStep,
  } from "./keyboard";
  import { explainMapping, prepareSearch, queryTokens, scorePrepared, scoreSearch, searchFields } from "./mapping-search";
  import SourceBadge from "./SourceBadge.svelte";
  import { sourceFromOrigin } from "./source";
  import { copyText } from "./toasts.svelte";
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
  const modes = $derived([...mappingModes, ...layerModes(rows)]);
  const modeInfo = $derived(modes.find((item) => item.id === mode) ?? mappingModes[0]);
  const appName = $derived(mappings.localized_name ?? mappings.bundle_id ?? "the current application");
  // Zones exist only with `label_order = "zones"`: the first key of a label
  // names a keyboard-shaped region of the window.
  const boardViews = $derived<[string, string][]>([["bindings", "Bindings"], ["alphabet", "Hint keys"], ["grid", "Grid"], ...(keyboard?.label_order === "zones" ? [["zones", "Zones"] as [string, string]] : [])]);
  const freeRule: Record<string, string> = {
    all: "Pick a mode to see which keys are free in it.",
    normal: "A free key is swallowed in NORMAL, so it is yours to map.",
    hold: "A free key falls through to NORMAL's binding, or is swallowed.",
    text: "A free key falls through to NORMAL's binding, or is swallowed.",
    visual: "The Text and Normal motions (h j k l, w b e, gg G, …) also move the selection; any other free key is swallowed.",
    hyper: "A free key is swallowed while the hyper key is held.",
    insert: "A free key types into the app.",
    command: "Only modified chords map here; other keys type into the command line.",
    terminal: "A free key goes to the program in the terminal.",
  };
  const freeText = $derived(freeRule[mode] ?? "A free key is swallowed in the layer, so it is yours to map.");
  const modePage = $derived(modeDoc(mode));
  /** The documentation of the command a binding runs; nothing for a program. */
  function actionDoc(action: string): { href: string; name: string } | undefined {
    const name = commandOfAction(action);
    if (!name) return undefined;
    const target = commandDoc(name);
    return { href: paths.docs(target.page, target.anchor), name };
  }

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
  /** A modifier key on the board toggles it in the chord layer. */
  function toggleModifier(modifier: string) {
    layer = layer.includes(modifier) ? layer.filter((item) => item !== modifier) : [...layer, modifier];
    picked = null;
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

  const collator = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });
  const compareText = collator.compare;
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
  function copy(text: string, subject: string) {
    void copyText(text, subject);
  }

  // A search reads the whole mode; otherwise the keyboard's prefix and key narrow it.
  const searching = $derived(query.trim().length > 0);
  // The mode's haystack, prepared once per set of rows rather than per keystroke.
  const prepared = $derived(modeRows.map((row) => ({ row, search: prepareSearch(searchFields(row, commands, sourceText(row.origin))) })));
  const listed = $derived.by(() => {
    const q = query.trim();
    if (!q) return rowsUnder(modeRows, path, picked, leader).map((row) => ({ row, score: 0 }));
    const tokens = queryTokens(q);
    return prepared
      .map(({ row, search }) => ({ row, score: scorePrepared(tokens, search) }))
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
  const countsHere = $derived((mode === "normal" || mode === "hold" || mode === "text") && !path.length && !layer.length);
  const pickedFree = $derived(picked !== null && !searching && !caps.get(picked.cap) && !(countsHere && /^[1-9]$/.test(picked.cap)));
  const freeKeys = $derived(picked ? [...path, picked].map(stepText).join(" ") : "");
  const freeSnippet = $derived(picked ? `[mode.${mode === "all" ? "normal" : mode}.mappings]\n${JSON.stringify(stepsToKey([...path, picked]))} = ["flash", "…"]` : "");
  const resolutions = $derived.by(() => {
    const list = mappings.commands ?? [];
    const q = query.trim();
    if (!q) return list;
    return list
      .map((row) => ({
        row,
        score: scoreSearch(q, {
          key: row.command,
          action: `${row.binding ?? ""} ${row.source ?? ""}`,
          explanation: row.claimed_by.join(" "),
          scope: "",
          source: row.source ?? "",
        }),
      }))
      .filter((item): item is { row: (typeof list)[number]; score: number } => item.score != null)
      .sort((a, b) => b.score - a.score || compareText(a.row.command, b.row.command))
      .map((item) => item.row);
  });
</script>

<div class="page">
  <PageHeader id="mappings" title="Key mappings" purpose="What each key does in each mode, as Flash resolves it now." manual={paths.docs("mappings")}>
    {#snippet help()}
      <p>Ask what a key does, or how to do something. Pick a mode under the keyboard, then a key: a key that starts longer bindings opens what can follow it, and Shift, Control, Option or Command shows the chords held with it. Search by what a binding does; the keys it matches light up.</p>
      <p>Each row's copy control gives the TOML that rebinds or removes it; a free key offers the lines that map it. Changes to your file appear here after reload. See the <a href={paths.docs("mappings")}>mapping syntax</a> and how to <a href={paths.docs("configuration")}>customize your configuration</a>.</p>
    {/snippet}
  </PageHeader>

  <div class="ask surface"><Icon name="search" size={18} /><input type="search" aria-label="Search mappings" placeholder="What do you want to do? Try brightness, window left, ctrl-f…" bind:this={searchInput} bind:value={query} />{#if mappings.normal_leader}<span class="leader">Leader <kbd>{mappings.normal_leader}</kbd></span>{/if}<div class="segmented" aria-label="Mapping source"><button class:active={view === "effective"} aria-pressed={view === "effective"} title="Resolved for {appName}, with active plugins" onclick={() => (view = "effective")}>In {appName}</button><button class:active={view === "configured"} aria-pressed={view === "configured"} title="From your configuration, before plugins and app overrides" onclick={() => (view = "configured")}>Configured</button></div></div>

  {#if keyboard}
    <div class="surface board">
      <div class="board-head">
        <nav class="trail" aria-label="Key sequence"><button class:here={!path.length} onclick={() => back(0)}>Keys</button>{#each path as step, index}<span>›</span><button class:here={index === path.length - 1} onclick={() => back(index + 1)}><kbd>{stepText(step)}</kbd></button>{/each}{#if path.length}<span class="muted">then…</span>{/if}</nav>
        <div class="controls">
          <div class="segmented" aria-label="What the keyboard shows">{#each boardViews as [value, label]}<button class:active={boardView === value} aria-pressed={boardView === value} onclick={() => (boardView = value as BoardView)}>{label}</button>{/each}</div>
        </div>
      </div>
      <div class="board-keys"><KeyboardBoard {keyboard} {caps} {hits} {leader} view={boardView} selected={picked?.cap ?? null} counts={countsHere} {layer} onpick={pick} onmodifier={toggleModifier} /></div>
      <div class="modes" role="radiogroup" aria-label="Mode">{#each modes as item}<button role="radio" class="mode mode-{item.id}" class:active={mode === item.id} aria-checked={mode === item.id} onclick={() => chooseMode(item.id)}>{item.label}<span>{rowsForMode(rows, item.id).length}</span></button>{/each}</div>
      <p class="mode-summary"><strong>{modeInfo.label}.</strong> {modeInfo.summary} {#if boardView === "bindings"}{freeText}{:else if boardView === "alphabet"}The hint alphabet while labels are up: warmer keys are handed out first.{:else if boardView === "grid"}The mouse grid's keys while it is up, laid out like the screen.{:else}With <code>label_order = "zones"</code>, a label's first key names the zone of the window.{/if} <a class="mode-doc" href={paths.docs(modePage.page, modePage.anchor)}>{mode === "all" ? "Which keys a mode reads" : `${modeInfo.label} documentation`} <span aria-hidden="true">→</span></a></p>
      {#if boardView === "bindings"}<div class="legend">{#each categories.filter((category) => [...caps.values()].some((entry) => entry.bindings.some((row) => categoryOf(row.action) === category.id))) as category}<span><i data-category={category.id}></i>{category.label}</span>{/each}<span><i class="prefix"></i>starts longer bindings</span><span><i class="free"></i>free</span></div>{/if}
    </div>
  {/if}

  {#if pickedFree && picked}
    <div class="surface free-key"><div><strong><kbd>{[...path, picked].map(stepText).join(" ")}</kbd> is free in {modeInfo.label}.</strong><p>{freeText} Add a binding to your <a href={paths.docs("configuration")}>configuration</a>:</p></div><pre>{freeSnippet}</pre><button type="button" onclick={() => copy(freeSnippet, `the TOML that maps ${freeKeys}`)}>Copy</button></div>
  {/if}

  <div class="surface mapping-list">
    <div class="list-head"><strong>{searching ? `Matches in ${modeInfo.label}` : picked ? `Bindings on ${[...path, picked].map(stepText).join(" ")}` : path.length ? `After ${path.map(stepText).join(" ")}` : `${modeInfo.label} bindings`}</strong>{#if picked || path.length}<button type="button" class="clear" onclick={() => back(0)}>Show every key</button>{/if}<span class="count">{listed.length} of {modeRows.length}</span></div>
    {#each groups as group (group.id)}<section class="mapping-group"><div class="group-label"><i data-category={group.id}></i><strong>{group.label}</strong><span>{group.rows.length}</span></div><div class="table-wrap"><table class="data-table"><thead><tr><th class="key-column">Key</th><th>What it does</th><th class="from-column">Source</th><th class="help-column"><span class="sr">Copy configuration</span></th></tr></thead><tbody>{#each group.rows as row (rowId(row))}<tr><td><kbd>{row.key}</kbd>{#if mode === "all" || mode === "hold" || mode === "text" || mode.startsWith("layers.")}<span class="scope">{row.scope}</span>{/if}</td><td><span class="does">{explainMapping(row, commands)}</span>{#if actionDoc(row.action)}{@const doc = actionDoc(row.action)!}<a class="action-doc" href={doc.href} title="Documentation for {doc.name}"><code>{row.action}</code></a>{:else}<code>{row.action}</code>{/if}</td><td class="from"><SourceBadge {...sourceFromOrigin(row.origin)} /></td><td class="help"><button type="button" class="change" aria-label="Copy the TOML that changes this binding" onmouseenter={(event) => showTip(event, `Copy the flash.toml lines that rebind or remove ${row.key}:\n${mappingSnippet(row)}`, rowId(row))} onmouseleave={hideTip} onfocus={(event) => showTip(event, mappingSnippet(row), rowId(row))} onblur={hideTip} onclick={() => copy(mappingSnippet(row), `the TOML that rebinds ${row.key}`)}><Icon name="copy" size={15} /></button></td></tr>{/each}</tbody></table></div></section>{/each}
    {#if !listed.length}<div class="empty"><strong>No mappings match</strong>{searching ? "Try what it does, a key, or a command. A close spelling still counts." : "Nothing in this mode starts here; pick another key or mode."}</div>{/if}
  </div>
  {#if tip}<div id="mapping-explanation" class="why-pop" role="tooltip" style:top="{tip.top}px" style:left="{tip.left}px">{tip.text}</div>{/if}
  {#if mappings.commands?.length && resolutions.length}<div class="surface mapping-list command-resolution"><div class="group-label"><strong class="resolution-title">How commands resolve in {appName}</strong><p>A source that performs the command wins; otherwise the plugin binding runs.</p><span>{resolutions.length} commands</span></div><div class="table-wrap"><table class="data-table"><thead><tr><th class="key-column">Command</th><th>Tried first</th><th>Binding</th><th>Declared by</th></tr></thead><tbody>{#each resolutions as row}<tr><td><code>{row.command}</code></td><td>{#if row.claimed_by.length}<code>{row.claimed_by.join(" → ")}</code>{:else}<span class="muted">—</span>{/if}</td><td>{#if row.binding}<kbd>{row.binding}</kbd>{:else}<span class="muted">nothing</span>{/if}</td><td>{#if row.source}<code>{row.source}</code>{:else}<span class="muted">—</span>{/if}</td></tr>{/each}</tbody></table></div></div>{/if}
</div>

<style>
  .mode-doc { white-space: nowrap; }
  .action-doc { text-decoration: none; }
  .action-doc:hover code { text-decoration: underline; }
  .ask { display: flex; align-items: center; flex-wrap: wrap; gap: 10px 12px; padding: 6px 8px 6px 14px; margin-bottom: 12px; color: var(--accent); }
  .ask input { flex: 1; min-width: 200px; max-width: none; font-size: 14px; border: 0; background: none; box-shadow: none; padding: 6px 0; }
  .ask input:focus { outline: none; }
  .leader { display: flex; align-items: center; gap: 8px; color: var(--muted); font-size: 12px; white-space: nowrap; }
  .board { padding: 12px 16px 14px; margin-bottom: 12px; }
  .board-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 10px; flex-wrap: wrap; }
  .controls { display: flex; gap: 10px; flex-wrap: wrap; }
  .trail { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
  .trail button { min-height: 28px; padding: 2px 8px; border-radius: 4px; font: 12px var(--mono); letter-spacing: .1em; text-transform: uppercase; background: transparent; border-color: transparent; color: var(--muted); }
  .trail button.here { color: var(--text); }
  .board-keys { overflow: auto; padding: 4px 2px; }
  .modes { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 12px; }
  .mode { --mode: var(--accent); display: inline-flex; align-items: center; gap: 8px; min-height: 30px; padding: 3px 11px; border-radius: 4px; font: 500 12px var(--mono); letter-spacing: .08em; text-transform: uppercase; color: var(--muted); }
  .mode span { color: var(--faint); letter-spacing: 0; }
  .mode.active { border-color: color-mix(in oklab, var(--mode) 60%, transparent); background: color-mix(in oklab, var(--mode) 14%, var(--panel)); color: var(--mode); }
  .mode.active span { color: inherit; opacity: .8; }
  .mode-hold { --mode: var(--amber); }
  .mode-hyper { --mode: #b39ad3; }
  .mode-insert { --mode: var(--steel); }
  .mode-command { --mode: var(--verdigris); }
  .mode-terminal { --mode: var(--copper); }
  .mode-summary { margin-top: 10px; font-size: 13px; color: var(--muted); }
  .mode-summary strong { color: var(--text); font-weight: 600; }
  .legend { display: flex; flex-wrap: wrap; gap: 6px 16px; margin-top: 10px; font-size: 12px; color: var(--muted); }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  i[data-category], .legend i { display: inline-block; width: 12px; height: 12px; border-radius: 3px; border: 1px solid color-mix(in oklab, var(--cat, var(--muted)) 60%, transparent); background: color-mix(in oklab, var(--cat, var(--muted)) 22%, var(--panel)); }
  .legend i.prefix { --cat: var(--accent); background: var(--raised); }
  .legend i.free { background: transparent; border: 1px dashed var(--border-strong); }
  .free-key { display: flex; align-items: center; gap: 16px; padding: 12px 16px; margin-bottom: 12px; flex-wrap: wrap; border-left: 2px solid var(--accent); }
  .free-key > div { flex: 1; min-width: 240px; }
  .free-key p { font-size: 13px; color: var(--muted); margin-top: 4px; }
  .free-key pre { margin: 0; padding: 8px 12px; border-radius: 5px; background: var(--inset); box-shadow: var(--well); font-size: 12px; color: var(--code); }
  .mapping-list { overflow: hidden; }
  .list-head { display: flex; align-items: center; gap: 12px; padding: 10px 14px; border-bottom: 1px solid var(--border); }
  .list-head strong { font-size: 13px; font-weight: 600; }
  .list-head .count { margin-left: auto; }
  .clear { min-height: 28px; padding: 2px 10px; font-size: 12px; }
  .group-label { display: flex; align-items: center; flex-wrap: wrap; gap: 6px 10px; padding: 8px 14px; background: var(--raised); border-bottom: 1px solid var(--border); }
  .group-label strong { font: 500 12px var(--mono); letter-spacing: .1em; text-transform: uppercase; }
  .group-label p { color: var(--muted); font-size: 12px; }
  .group-label > span:last-child { margin-left: auto; font: 12px var(--mono); color: var(--muted); }
  .key-column { width: 170px; }
  .from-column { width: 170px; }
  .help-column, .help { position: sticky; right: 0; width: 48px; background: var(--panel); z-index: 1; }
  .help-column { background: var(--raised); }
  .help { text-align: right; vertical-align: middle; }
  .data-table tbody tr:hover .help { background: var(--hover); }
  .sr { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
  .scope { margin-left: 8px; font: 12px var(--mono); letter-spacing: .06em; text-transform: uppercase; color: var(--muted); }
  .does { display: block; font-size: 13px; color: var(--text); }
  .data-table code { display: block; margin-top: 2px; color: var(--muted); font-size: 12px; white-space: pre-wrap; overflow-wrap: anywhere; }
  /* The shared button rule is a field; this control stays a small mark. */
  .change { display: inline-grid; place-items: center; min-height: 0; width: 30px; height: 30px; padding: 0; border-radius: 5px; color: var(--muted); }
  .change:hover, .change:focus-visible { color: var(--accent); border-color: var(--accent-dim); outline: none; }
  .why-pop { position: fixed; z-index: 40; width: min(300px, calc(100vw - 16px)); padding: 10px 12px; background: var(--raised); color: var(--text); border: 1px solid var(--border-strong); border-radius: 6px; box-shadow: 0 12px 32px rgba(0, 0, 0, .55); font-size: 12px; line-height: 1.5; white-space: pre-wrap; font-family: var(--mono); pointer-events: none; }
  .from { white-space: nowrap; }
  .data-table td { padding-top: 8px; padding-bottom: 8px; vertical-align: top; }
  .command-resolution { margin-top: 16px; }
  .resolution-title { font-size: 12px; white-space: nowrap; }
  .muted { color: var(--muted); font-size: 12px; }
  .empty { padding: 32px; }
  @media print { .ask, .controls, .modes, .change { display: none; } .board-keys { overflow: visible; } }
</style>
