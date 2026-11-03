<script lang="ts">
  import { alphabetHeat, ansiRows, categoryOf, keycapLabel, phaseKeys, zoneOf, type BoardView, type CapBindings, type KeySlot } from "./keyboard";
  import type { KeyboardState } from "./types";

  let {
    keyboard,
    caps,
    hits,
    leader,
    view,
    selected,
    counts,
    layer,
    onpick,
    onmodifier,
  }: {
    keyboard: KeyboardState;
    /** What each key does at the current prefix and modifier layer. */
    caps: Map<string, CapBindings>;
    /** Keys a search matched, lit while it runs. */
    hits: Set<string>;
    leader: string;
    view: BoardView;
    selected: string | null;
    /** Unbound digits 1–9 are repeat counts here (NORMAL, HOLD), not free keys. */
    counts: boolean;
    /** The modifiers the chord layer holds; their keys are drawn pressed. */
    layer: string[];
    onpick: (cap: string) => void;
    onmodifier: (modifier: string) => void;
  } = $props();

  const rows = $derived(ansiRows(keyboard));
  const unit = 62;
  const gap = 6;
  const widthOf = (units: number) => `${units * unit + (units - 1) * gap}px`;

  // What a key does on a hint surface, independent of what Flash is doing now.
  const surface = $derived(phaseKeys(view === "grid" ? "grid" : view === "alphabet" ? "labels" : "idle", keyboard));
  const heat = $derived(alphabetHeat(keyboard));
  const gridKeys = $derived(new Set(keyboard.grid_keys.flatMap((row) => [...row])));

  function noteFor(cap: string): string | undefined {
    if (view !== "bindings") return surface.keys.get(cap) ?? surface.specials.get(cap);
    const entry = caps.get(cap);
    if (!entry?.bindings.length) return isCount(cap) ? "count" : undefined;
    const label = keycapLabel(entry.bindings[0].action);
    return entry.bindings.length > 1 ? `${label} +${entry.bindings.length - 1}` : label;
  }
  function isCount(cap: string): boolean {
    return counts && view === "bindings" && /^[1-9]$/.test(cap) && !caps.has(cap);
  }
  function category(cap: string): string | undefined {
    const binding = caps.get(cap)?.bindings[0];
    return binding ? categoryOf(binding.action) : undefined;
  }
  function style(cap: string): string {
    if (view === "alphabet") {
      const value = heat.get(cap);
      return value === undefined ? "" : `--heat:${value.toFixed(2)}`;
    }
    if (view === "zones") {
      const zone = zoneOf(keyboard, cap);
      if (!zone) return "";
      const hue = 110 + (zone.column / Math.max(1, zone.columns - 1)) * 170;
      return `--zone:hsl(${hue.toFixed(0)} 45% ${62 - zone.row * 8}%)`;
    }
    return "";
  }
  function state(cap: string): string {
    switch (view) {
      case "bindings": {
        const entry = caps.get(cap);
        if (!entry) return isCount(cap) ? "prefix" : "free";
        return entry.bindings.length ? "bound" : "prefix";
      }
      case "alphabet": return heat.has(cap) ? "alpha" : surface.specials.has(cap) ? "bound" : "";
      case "grid": return gridKeys.has(cap) ? "grid-key" : surface.keys.has(cap) || surface.specials.has(cap) ? "bound" : "";
      case "zones": return zoneOf(keyboard, cap) ? "zone" : "";
    }
  }
</script>

{#snippet key(slot: KeySlot)}
  {#if slot.modifier}
    <button
      class="key modifier"
      class:held={layer.includes(slot.modifier)}
      style:width={widthOf(slot.units)}
      aria-pressed={layer.includes(slot.modifier)}
      aria-label={`${slot.label}: show the bindings held with it`}
      onclick={() => onmodifier(slot.modifier ?? "")}><span class="cap">{slot.label}</span></button>
  {:else if slot.inert}
    <span class="key inert" style:width={widthOf(slot.units)}><span class="cap">{slot.label}</span></span>
  {:else}
    {@const cap = slot.cap}
    {@const entry = caps.get(cap)}
    {@const note = noteFor(cap)}
    <button
      class="key {state(cap)}"
      class:hit={hits.has(cap)}
      class:selected={selected === cap}
      data-category={view === "bindings" ? category(cap) : undefined}
      style={`${style(cap)};width:${widthOf(slot.units)}`}
      aria-pressed={selected === cap}
      aria-label={`${cap}: ${note ?? (entry?.continues ? "starts longer bindings" : "free")}`}
      onclick={() => onpick(cap)}>
      <span class="cap">{slot.label}{#if cap === "space" && leader}<span class="leader-mark"> · leader</span>{/if}</span>
      {#if view === "bindings" && entry?.continues}<span class="more" title="Starts {entry.continues} longer bindings">›{entry.continues}</span>{/if}
      {#if note}<span class="note">{note}</span>{/if}
    </button>
  {/if}
{/snippet}

<div class="rows" style:--unit="{unit}px" style:--gap="{gap}px">
  {#each rows as row, index}
    <div class="row" class:escape-row={index === 0}>{#each row as slot}{@render key(slot)}{/each}</div>
  {/each}
</div>

<style>
  .rows { display: flex; flex-direction: column; gap: var(--gap); width: max-content; }
  .row { display: flex; gap: var(--gap); }
  .escape-row { margin-bottom: 8px; }
  /* Keycaps: a raised face over a darker skirt. */
  .key { position: relative; display: flex; flex-direction: column; align-items: flex-start; justify-content: space-between; height: 66px; min-height: 0; flex: none; padding: 5px 7px 6px; border: 1px solid var(--border); border-bottom: 3px solid var(--inset); border-radius: 6px; background: var(--raised); color: var(--faint); text-align: left; box-shadow: var(--engrave); transition: background-color .15s, color .15s, border-color .15s, box-shadow .15s; }
  .key:hover { border-color: var(--border-strong); background: var(--hover); }
  .key.free { border-style: dashed; border-bottom-width: 1px; background: transparent; box-shadow: none; color: var(--faint); }
  .key.bound { background: color-mix(in oklab, var(--cat, var(--muted)) 20%, var(--raised)); color: var(--text); border-color: color-mix(in oklab, var(--cat, var(--muted)) 55%, var(--border)); border-bottom-color: color-mix(in oklab, var(--cat, var(--muted)) 30%, var(--inset)); }
  .key.bound .note { color: color-mix(in oklab, var(--cat, var(--muted)) 55%, var(--text)); }
  .key.prefix { background: var(--raised); color: var(--text); border-color: var(--accent-dim); }
  .key.alpha { background: color-mix(in oklab, var(--accent) calc(var(--heat, 0) * 42%), var(--raised)); border-color: color-mix(in oklab, var(--accent) calc(var(--heat, 0) * 80%), var(--border)); color: var(--text); }
  .key.grid-key { background: color-mix(in oklab, var(--steel) 20%, var(--raised)); border-color: color-mix(in oklab, var(--steel) 55%, var(--border)); color: var(--text); }
  .key.zone { background: color-mix(in oklab, var(--zone, var(--raised)) 26%, var(--raised)); border-color: color-mix(in oklab, var(--zone, var(--border)) 60%, var(--border)); color: var(--text); }
  .key.hit { box-shadow: 0 0 0 2px var(--amber); }
  .key.selected { box-shadow: 0 0 0 2px var(--accent); border-color: var(--accent); }
  .key.modifier { justify-content: center; background: var(--panel); color: var(--muted); font-size: 12px; }
  .key.modifier .cap { font-family: inherit; font-size: 12px; font-weight: 600; }
  .key.modifier.held { background: var(--accent-soft); border-color: var(--accent); color: var(--accent); box-shadow: inset 0 2px 0 rgba(0, 0, 0, .35); }
  .key.inert { border-style: dotted; border-bottom-width: 1px; background: transparent; box-shadow: none; color: var(--faint); cursor: default; }
  .key.inert .cap { font-family: inherit; font-size: 12px; }
  .cap { font-family: var(--mono); font-size: 14px; font-weight: 600; line-height: 1.25; }
  .leader-mark { font-size: 12px; font-weight: 500; color: var(--accent); }
  .more { position: absolute; top: 5px; right: 6px; padding: 0 5px; border-radius: 3px; border: 1px solid var(--accent-dim); background: var(--accent-soft); color: var(--accent); font: 600 12px/1.3 var(--mono); }
  .note { font-size: 11px; line-height: 1.15; color: var(--muted); overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; letter-spacing: -.01em; }
  @media (prefers-reduced-motion: reduce) { .key { transition: none; } }
  @media print { .key { box-shadow: none; } }
</style>
