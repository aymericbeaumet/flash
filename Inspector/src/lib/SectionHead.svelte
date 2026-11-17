<script lang="ts">
  import type { Snippet } from "svelte";

  /**
   * A section's head inside a page: a rivet, the title, a count, the
   * section's controls, and its help folded behind a small "?" toggle.
   */
  let {
    title,
    id,
    count,
    help,
    actions,
    level = 2,
  }: {
    title: string;
    /** Labels the section and names its help region. */
    id: string;
    count?: string | number;
    help?: Snippet;
    actions?: Snippet;
    level?: 2 | 3;
  } = $props();
  let open = $state(false);
</script>

<div class="section-head">
  <span class="rivet" aria-hidden="true"></span>
  <svelte:element this={`h${level}`} id={id}>{title}</svelte:element>
  {#if count !== undefined}<span class="section-count">{count}</span>{/if}
  {#if help}<button type="button" class="tip" class:open aria-expanded={open} aria-controls="{id}-help" aria-label="About {title}" title="About {title}" onclick={() => (open = !open)}>?</button>{/if}
  {#if actions}<div class="section-actions">{@render actions()}</div>{/if}
</div>
{#if help && open}<div class="section-help" id="{id}-help">{@render help()}</div>{/if}

<style>
  .section-head { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 10px; min-height: 36px; margin-bottom: 8px; }
  .section-head :global(h2), .section-head :global(h3) { font: 600 12px var(--mono); letter-spacing: .12em; text-transform: uppercase; color: var(--text); }
  .section-count { font: 12px var(--mono); color: var(--muted); font-variant-numeric: tabular-nums; }
  .tip { display: inline-grid; place-items: center; width: 26px; height: 26px; min-height: 0; padding: 0; border-radius: 50%; font: 600 12px/1 var(--mono); color: var(--muted); background: transparent; }
  .tip.open { color: var(--accent); border-color: var(--accent-dim); background: var(--accent-soft); }
  .section-actions { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; margin-left: auto; }
  .section-help { margin: 0 0 10px; padding: 9px 14px; border-left: 2px solid var(--accent-dim); background: var(--inset); color: var(--muted); font-size: 13px; line-height: 1.6; max-width: 900px; border-radius: 0 5px 5px 0; }
  .section-help :global(strong) { color: var(--text); }
  @media print { .tip, .section-actions { display: none; } }
</style>
