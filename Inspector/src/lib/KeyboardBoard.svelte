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
    /** Unbound digits 1–9 are repeat counts here (NORMAL, VISUAL), not free keys. */
    counts: boolean;
    /** The modifiers the chord layer holds; their keys are drawn pressed. */
    layer: string[];
    onpick: (cap: string) => void;
    onmodifier: (modifier: string) => void;
  } = $props();

  const rows = $derived(ansiRows(keyboard));
  const unit = 58;
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
      return `--zone:hsl(${hue.toFixed(0)} 45% ${88 - zone.row * 10}%)`;
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
  .key { --tint: #eef4e8; --edge: #c9d8bd; position: relative; display: flex; flex-direction: column; align-items: flex-start; justify-content: space-between; height: 60px; min-height: 0; flex: none; padding: 6px 7px; border: 1px solid var(--border); border-bottom-width: 3px; border-radius: 8px; background: #fbfcf9; color: #8a948a; text-align: left; transition: background .2s, color .2s, border-color .2s, transform .15s, box-shadow .2s; }
  .key:hover { transform: translateY(-1px); }
  .key.free { border-style: dashed; background: transparent; color: #a8b0a6; }
  .key.bound { background: var(--tint); color: var(--text); border-color: var(--edge); }
  .key.prefix { background: #f4f6f1; color: var(--text); border-color: #b9c6ad; }
  .key[data-category="pointer"] { --tint: #e6efdd; --edge: #a9c296; }
  .key[data-category="scroll"] { --tint: #e3edf7; --edge: #9db6d8; }
  .key[data-category="tabs"] { --tint: #f6ecdc; --edge: #d9b98a; }
  .key[data-category="windows"] { --tint: #ece6f6; --edge: #b5a3d4; }
  .key[data-category="modes"] { --tint: #f7e3e3; --edge: #d6a1a1; }
  .key[data-category="system"] { --tint: #e2f1ef; --edge: #8fc3bb; }
  .key[data-category="plugins"], .key[data-category="programs"], .key[data-category="other"] { --tint: #eef0ec; --edge: #bfc6bb; }
  .key.alpha { background: color-mix(in oklab, #fff785 calc(var(--heat, 0) * 100%), #f6f8f3); border-color: color-mix(in oklab, #e3be23 calc(var(--heat, 0) * 100%), var(--border)); color: #302505; }
  .key.grid-key { background: #dfe9f6; border-color: #9db6d8; color: #1f3f66; }
  .key.zone { background: var(--zone, #f6f8f3); border-color: color-mix(in oklab, var(--zone, #ccc), #000 20%); color: #233; }
  .key.hit { box-shadow: 0 0 0 2px #e3be23; }
  .key.selected { box-shadow: 0 0 0 3px #6c875c; border-color: #6c875c; }
  .key.modifier { justify-content: center; background: #f3f4f0; color: #6d7868; font-size: 12px; }
  .key.modifier .cap { font-family: inherit; font-size: 12px; font-weight: 600; }
  .key.modifier.held { background: #e4ecdb; border-color: #6c875c; color: #244f38; box-shadow: inset 0 2px 0 rgba(0, 0, 0, .06); }
  .key.inert { border-style: dotted; background: transparent; color: #b4bbb2; cursor: default; }
  .key.inert .cap { font-family: inherit; font-size: 12px; }
  .cap { font-family: var(--mono); font-size: 14px; font-weight: 600; }
  .leader-mark { font-size: 10px; font-weight: 500; color: var(--muted); }
  .more { position: absolute; top: 5px; right: 6px; padding: 0 5px; border-radius: 999px; background: #2e5b43; color: #eff6e7; font-size: 10px; font-weight: 700; }
  .note { font-size: 9px; line-height: 1.15; color: inherit; opacity: .85; overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2; -webkit-box-orient: vertical; }
  @media (prefers-reduced-motion: reduce) { .key { transition: none; } }
</style>
