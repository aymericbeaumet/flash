<script lang="ts">
  import Icon from "./Icon.svelte";
  import { alphabetHeat, bindingsByCap, phaseKeys, scopesForMode, zoneOf, type KeyBinding } from "./keyboard";
  import { explainMapping } from "./mapping-search";
  import type { CommandInfo, InspectorState } from "./types";

  let { state: snapshot, commands = [], connected }: { state: InspectorState; commands?: CommandInfo[]; connected: boolean } = $props();

  type View = "auto" | "bindings" | "alphabet" | "grid" | "zones";
  let follow = $state(true);
  let chosenMode = $state("normal");
  let view = $state<View>("auto");
  let selected = $state<string | null>(null);

  const keyboard = $derived(snapshot.keyboard);
  const liveMode = $derived(snapshot.mode ?? "insert");
  const phase = $derived(snapshot.hint_session ?? "idle");
  const mode = $derived(follow ? liveMode : chosenMode);
  const mappings = $derived(snapshot.mappings ?? { normal_leader: "", rows: [] });
  const rows = $derived(mappings.effective_rows ?? mappings.rows);
  const scopes = $derived(scopesForMode(mode));
  const byCap = $derived(bindingsByCap(rows, scopes, mappings.normal_leader));
  const phaseModel = $derived(phaseKeys(phase, keyboard));
  const sessionActive = $derived(phase !== "idle");
  const effectiveView = $derived.by<View>(() => {
    if (view !== "auto") return view;
    if (phase === "grid") return "grid";
    if (phase === "labels" || phase === "bigram" || phase === "search") return keyboard?.label_order === "zones" ? "zones" : "alphabet";
    return "bindings";
  });
  const heat = $derived(keyboard ? alphabetHeat(keyboard) : new Map<string, number>());
  const gridKeys = $derived(new Set((keyboard?.grid_keys ?? []).flatMap((row) => [...row])));
  const appName = $derived(mappings.localized_name ?? mappings.bundle_id ?? "the current application");
  const modeOptions = ["normal", "hyper", "insert", "command", "terminal"];
  const specials = [
    { cap: "esc", label: "esc" },
    { cap: "tab", label: "tab" },
    { cap: "backspace", label: "⌫" },
    { cap: "return", label: "return" },
    { cap: "space", label: "space" },
  ];
  const phaseTitle: Record<string, string> = {
    idle: "No hint session",
    discovering: "Finding targets…",
    labels: "Hint labels are up",
    grid: "The mouse grid is up",
    search: "Seek & click",
    adjusting: "Adjusting the click point",
    pointer: "Pointer mode",
    bigram: "Waiting for a letter",
    confirming: "A question is up",
  };

  function bindingsFor(cap: string): KeyBinding[] {
    return byCap.get(cap) ?? [];
  }
  function roleFor(cap: string): string | undefined {
    return phaseModel.keys.get(cap) ?? phaseModel.specials.get(cap);
  }
  function heatStyle(cap: string): string {
    const value = heat.get(cap);
    return value === undefined ? "" : `--heat:${value.toFixed(2)}`;
  }
  function zoneStyle(cap: string): string {
    const zone = zoneOf(keyboard, cap);
    if (!zone) return "";
    const hue = 110 + (zone.column / Math.max(1, zone.columns - 1)) * 170;
    const light = 88 - zone.row * 10;
    return `--zone:hsl(${hue.toFixed(0)} 45% ${light}%)`;
  }
  function isLit(cap: string): boolean {
    switch (effectiveView) {
      case "bindings": return bindingsFor(cap).length > 0 || phaseModel.keys.has(cap);
      case "alphabet": return heat.has(cap);
      case "grid": return gridKeys.has(cap) || phaseModel.keys.has(cap);
      case "zones": return zoneOf(keyboard, cap) !== null;
      default: return false;
    }
  }
  function pick(cap: string) {
    selected = selected === cap ? null : cap;
  }
  const detail = $derived.by(() => {
    if (!selected) return null;
    return { cap: selected, role: roleFor(selected), bindings: bindingsFor(selected), zone: zoneOf(keyboard, selected), heat: heat.get(selected) };
  });
</script>

<div class="page">
  <div class="page-heading"><p class="eyebrow">Your Flash</p><h1>Every key, where it sits.</h1><p>Your layout with what each key does right now: the bindings of the mode Flash is in, the hint alphabet while labels are up, the grid while it is up. Nothing you type is shown; only what Flash is ready for.</p></div>

  {#if !keyboard}
    <div class="surface empty"><strong>Waiting for Flash</strong>{connected ? "The keyboard arrives with the next snapshot." : "Start Flash to see your keyboard."}</div>
  {:else}
    <div class="surface live" class:active={sessionActive}>
      <div class="live-state">
        {#key liveMode}<span class="mode-badge mode-{liveMode}">{liveMode}</span>{/key}
        {#key phase}<span class="phase" class:on={sessionActive}><i></i>{phaseTitle[phase] ?? phase}</span>{/key}
        <span class="muted">in {appName}</span>
        {#if keyboard.held_button}<span class="badge held">{keyboard.held_button} button held</span>{/if}
      </div>
      <div class="live-controls">
        <label class="follow"><input type="checkbox" bind:checked={follow} /> Follow Flash</label>
        {#if !follow}<select bind:value={chosenMode} aria-label="Mode to draw">{#each modeOptions as option}<option value={option}>{option}</option>{/each}</select>{/if}
        <div class="segmented" aria-label="What to draw">
          {#each [["auto", "Auto"], ["bindings", "Bindings"], ["alphabet", "Hint keys"], ["grid", "Grid"], ["zones", "Zones"]] as [value, label]}
            <button class:active={view === value} aria-pressed={view === value} onclick={() => (view = value as View)}>{label}</button>
          {/each}
        </div>
      </div>
    </div>

    <div class="surface board" data-view={effectiveView}>
      <div class="rows">
        {#each keyboard.rows as row, rowIndex}
          <div class="row" style:--offset={rowIndex}>
            {#if rowIndex === 1}<button class="key special" class:lit={phaseModel.specials.has("tab")} class:selected={selected === "tab"} onclick={() => pick("tab")}><span class="cap">tab</span>{#if phaseModel.specials.has("tab")}<span class="note">{phaseModel.specials.get("tab")}</span>{/if}</button>{/if}
            {#if rowIndex === 0}<button class="key special" class:lit={phaseModel.specials.has("esc")} class:selected={selected === "esc"} onclick={() => pick("esc")}><span class="cap">esc</span>{#if phaseModel.specials.has("esc")}<span class="note">{phaseModel.specials.get("esc")}</span>{/if}</button>{/if}
            {#each [...row] as cap}
              {@const bindings = bindingsFor(cap)}
              {@const role = phaseModel.keys.get(cap)}
              <button
                class="key"
                class:lit={isLit(cap)}
                class:grid-key={effectiveView === "grid" && gridKeys.has(cap)}
                class:alpha={effectiveView === "alphabet" && heat.has(cap)}
                class:zone={effectiveView === "zones" && zoneOf(keyboard, cap) !== null}
                class:phase={role !== undefined}
                class:selected={selected === cap}
                style={[heatStyle(cap), zoneStyle(cap)].filter(Boolean).join(";")}
                aria-label={`${cap}: ${role ?? (bindings.length ? `${bindings.length} bindings` : "nothing")}`}
                onclick={() => pick(cap)}>
                <span class="cap">{cap}</span>
                {#if bindings.length && effectiveView === "bindings"}<span class="count">{bindings.length}</span>{/if}
                {#if role}<span class="note">{role}</span>{:else if bindings.length === 1 && effectiveView === "bindings"}<span class="note">{bindings[0].row.key}{bindings[0].parsed.rest ? "" : ""} · {bindings[0].row.action.replace(/^flash /, "")}</span>{/if}
              </button>
            {/each}
            {#if rowIndex === 0}<button class="key special wide" class:lit={phaseModel.specials.has("backspace")} class:selected={selected === "backspace"} onclick={() => pick("backspace")}><span class="cap">⌫</span>{#if phaseModel.specials.has("backspace")}<span class="note">{phaseModel.specials.get("backspace")}</span>{/if}</button>{/if}
            {#if rowIndex === 2}<button class="key special wide" class:lit={phaseModel.specials.has("return")} class:selected={selected === "return"} onclick={() => pick("return")}><span class="cap">return</span>{#if phaseModel.specials.has("return")}<span class="note">{phaseModel.specials.get("return")}</span>{/if}</button>{/if}
          </div>
        {/each}
        <div class="row space-row">
          <button class="key special space" class:lit={phaseModel.specials.has("space") || bindingsFor("space").length > 0} class:selected={selected === "space"} onclick={() => pick("space")}><span class="cap">space{#if mappings.normal_leader}<span class="leader-mark"> · leader</span>{/if}</span>{#if phaseModel.specials.has("space")}<span class="note">{phaseModel.specials.get("space")}</span>{:else if bindingsFor("space").length}<span class="count">{bindingsFor("space").length}</span>{/if}</button>
        </div>
      </div>
      <div class="legend">
        {#if effectiveView === "bindings"}<span><i class="swatch lit"></i>has a binding in <strong>{scopes.join(" + ")}</strong></span><span>Select a key to read its bindings.</span>
        {:else if effectiveView === "alphabet"}<span><i class="swatch heat"></i>hint alphabet, warmer is handed out first</span><span>{keyboard.alphabet.length} keys · order <strong>{keyboard.label_order}</strong></span>
        {:else if effectiveView === "grid"}<span><i class="swatch grid"></i>grid cells, laid out like the screen</span><span>bisect on {keyboard.navigation.left}{keyboard.navigation.down}{keyboard.navigation.up}{keyboard.navigation.right}</span>
        {:else}<span><i class="swatch zone"></i>the first key of a label names the zone of the window</span><span>{keyboard.zone_rows.length} bands × up to {Math.max(...keyboard.zone_rows.map((row) => row.length))} columns</span>{/if}
      </div>
    </div>

    {#if detail}
      <div class="surface detail">
        <div class="detail-head"><kbd>{detail.cap}</kbd>{#if detail.role}<span class="badge">{detail.role}</span>{/if}{#if detail.heat !== undefined}<span class="badge neutral">hint key · ease {(detail.heat * 100).toFixed(0)}%</span>{/if}{#if detail.zone}<span class="badge neutral">zone row {detail.zone.row + 1}, column {detail.zone.column + 1}</span>{/if}<button class="close" aria-label="Close" onclick={() => (selected = null)}><Icon name="close" size={14} /></button></div>
        {#if detail.bindings.length}
          <table class="data-table"><thead><tr><th>Key sequence</th><th>Command</th><th>What it does</th></tr></thead><tbody>
            {#each detail.bindings as binding}<tr><td><kbd>{binding.row.key}</kbd></td><td><code>{binding.row.action}</code></td><td>{explainMapping(binding.row, commands)}</td></tr>{/each}
          </tbody></table>
        {:else}
          <p class="muted">No binding starts on this key in {scopes.join(" or ")}.{#if !detail.role} It is swallowed in NORMAL and typed everywhere else.{/if}</p>
        {/if}
      </div>
    {/if}
    <p class="tip">The map reads the bindings of the focused app, so an app-scoped mapping shows up when that app is in front. <a href="/mappings">Full mapping list →</a></p>
  {/if}
</div>

<style>
  .live { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 14px 20px; margin-bottom: 18px; transition: box-shadow .3s, border-color .3s; }
  .live.active { border-color: #9fbf8a; box-shadow: 0 0 0 4px #e7f1df; }
  .live-state { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; font-size: 12px; }
  .live-controls { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .mode-badge { display: inline-block; padding: 4px 10px; border-radius: 6px; font-size: 11px; font-weight: 700; letter-spacing: .12em; text-transform: uppercase; animation: pop .35s ease-out; }
  .mode-normal { background: #dcebd2; color: #244f38; }
  .mode-insert { background: #dbe8f5; color: #1f4a73; }
  .mode-command { background: #e9dcf3; color: #4e2d6e; }
  .mode-terminal { background: #f3e6d6; color: #6a4418; }
  .mode-hyper { background: #f8e4e4; color: #7a2d2d; }
  .phase { display: inline-flex; align-items: center; gap: 7px; color: var(--muted); animation: pop .35s ease-out; }
  .phase i { width: 7px; height: 7px; border-radius: 50%; background: #c9cfc6; transition: background .3s; }
  .phase.on { color: var(--text); font-weight: 550; }
  .phase.on i { background: #5c9662; box-shadow: 0 0 0 3px #e9f1e4; animation: pulse 1.6s ease-in-out infinite; }
  .badge.held { background: #e5efdf; color: #2e5b43; }
  .follow { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); }
  .follow input { min-height: 0; width: 14px; height: 14px; padding: 0; margin: 0; }
  .segmented { display: inline-flex; border: 1px solid var(--border); border-radius: 7px; overflow: hidden; }
  .segmented button { border: 0; border-radius: 0; min-height: 32px; padding: 4px 11px; font-size: 11px; background: #fff; }
  .segmented button + button { border-left: 1px solid var(--border); }
  .segmented button.active { background: var(--accent-soft); color: var(--accent); font-weight: 600; }
  .board { padding: 22px 24px 16px; overflow: auto; }
  .rows { display: flex; flex-direction: column; gap: 7px; min-width: 760px; }
  .row { display: flex; gap: 7px; padding-left: calc(var(--offset, 0) * 18px); }
  .space-row { padding-left: 190px; }
  .key { position: relative; display: flex; flex-direction: column; align-items: flex-start; justify-content: space-between; width: 62px; height: 58px; min-height: 0; padding: 6px 7px; border: 1px solid var(--border); border-bottom-width: 3px; border-radius: 8px; background: #fbfcf9; color: #8a948a; text-align: left; transition: background .25s, color .25s, border-color .25s, transform .15s, box-shadow .25s; }
  .key:hover { transform: translateY(-1px); }
  .key.lit { background: #eef4e8; color: var(--text); border-color: #c9d8bd; }
  .key.phase { background: #e1ecd8; border-color: #9fbf8a; color: #1f4a2e; }
  .key.alpha { background: color-mix(in oklab, #fff785 calc(var(--heat, 0) * 100%), #f6f8f3); border-color: color-mix(in oklab, #e3be23 calc(var(--heat, 0) * 100%), var(--border)); color: #302505; }
  .key.grid-key { background: #dfe9f6; border-color: #9db6d8; color: #1f3f66; }
  .key.zone { background: var(--zone, #f6f8f3); border-color: color-mix(in oklab, var(--zone, #ccc), #000 20%); color: #233; }
  .key.selected { box-shadow: 0 0 0 3px #d7e7c9; border-color: #6c875c; }
  .key.special { width: 86px; }
  .key.special.wide { width: 110px; }
  .key.space { width: 360px; }
  .cap { font-family: var(--mono); font-size: 14px; font-weight: 600; }
  .leader-mark { font-size: 10px; font-weight: 500; color: var(--muted); }
  .count { position: absolute; top: 5px; right: 6px; min-width: 16px; padding: 0 5px; border-radius: 999px; background: #2e5b43; color: #eff6e7; font-size: 10px; font-weight: 700; text-align: center; }
  .note { font-size: 9px; line-height: 1.15; color: inherit; opacity: .8; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  .legend { display: flex; justify-content: space-between; gap: 16px; margin-top: 18px; font-size: 11px; color: var(--muted); flex-wrap: wrap; }
  .legend span { display: inline-flex; align-items: center; gap: 7px; }
  .swatch { width: 12px; height: 12px; border-radius: 3px; border: 1px solid var(--border); }
  .swatch.lit { background: #eef4e8; }
  .swatch.heat { background: linear-gradient(90deg, #f6f8f3, #fff785); }
  .swatch.grid { background: #dfe9f6; }
  .swatch.zone { background: linear-gradient(90deg, hsl(110 45% 88%), hsl(280 45% 78%)); }
  .detail { margin-top: 18px; padding: 16px 20px; }
  .detail-head { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 12px; }
  .detail-head kbd { font-size: 14px; padding: 4px 10px; }
  .close { margin-left: auto; min-height: 0; width: 28px; height: 28px; padding: 0; display: grid; place-items: center; border-radius: 999px; }
  .detail .data-table td { padding: 10px 12px; }
  .detail code { font-size: 11px; color: #6b7666; }
  .tip { margin-top: 18px; font-size: 11px; color: var(--muted); }
  .empty { padding: 48px; }
  @keyframes pop { from { transform: scale(.92); opacity: .4; } to { transform: scale(1); opacity: 1; } }
  @keyframes pulse { 0%, 100% { box-shadow: 0 0 0 3px #e9f1e4; } 50% { box-shadow: 0 0 0 6px #d7e7c9; } }
  @media (prefers-reduced-motion: reduce) { .mode-badge, .phase, .phase.on i { animation: none; } .key { transition: none; } }
  @media print { .live-controls, .close, .tip { display: none; } .board { overflow: visible; } }
</style>
