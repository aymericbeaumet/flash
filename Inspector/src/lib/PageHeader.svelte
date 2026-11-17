<script lang="ts">
  import type { Snippet } from "svelte";
  import { now } from "./clock.svelte";
  import { ago, clockTime } from "./format";
  import Icon from "./Icon.svelte";
  import { store } from "./store.svelte";

  /**
   * The compact head of every page: a title and one line of purpose, the
   * page's own controls, whether its data is live, and the help for it folded
   * behind one toggle with a link to its page of the manual.
   */
  let {
    title,
    purpose = "",
    id,
    manual,
    live = false,
    help,
    actions,
  }: {
    title: string;
    purpose?: string;
    /** Names the page: the help toggle remembers its state under it. */
    id: string;
    /** The manual page (`/docs/<page>`). */
    manual?: string;
    /** The page shows resident state: mark it stale while Flash is unreachable. */
    live?: boolean;
    help?: Snippet;
    actions?: Snippet;
  } = $props();

  const key = $derived(`flash.help.page-help.${id}`);
  let open = $state(false);
  $effect.pre(() => {
    try { open = localStorage.getItem(key) === "open"; } catch { open = false; }
  });
  function toggle() {
    open = !open;
    try { if (open) localStorage.setItem(key, "open"); else localStorage.removeItem(key); } catch { /* Private browsing keeps it for this page only. */ }
  }
  const snapshotAt = $derived(store.state.snapshot_at_unix_ms);
</script>

<header class="page-header">
  <div class="title-row">
    <h1><span class="rivet" aria-hidden="true"></span>{title}</h1>
    {#if purpose}<p class="purpose">{purpose}</p>{/if}
    <div class="tools">
      {@render actions?.()}
      {#if live && !store.connected}
        {#if snapshotAt}<span class="freshness stale" title="The connection to Flash is down: this is the last snapshot it sent"><Icon name="warning" size={13} />Stale · {clockTime(snapshotAt)} · {ago(snapshotAt, now())}</span>
        {:else}<span class="freshness stale"><Icon name="warning" size={13} />No data yet</span>{/if}
      {/if}
      {#if help}<button type="button" class="help-toggle" class:open aria-expanded={open} aria-controls="help-{id}" onclick={toggle}><span aria-hidden="true">?</span> About this page</button>{/if}
      {#if manual}<a class="docs-link" href={manual}>Documentation <span aria-hidden="true">→</span></a>{/if}
    </div>
  </div>
  {#if help && open}
    <div class="help" id="help-{id}">
      <div class="help-body">{@render help()}</div>
      {#if manual}<p class="help-links"><a href={manual}>Read the documentation <span aria-hidden="true">→</span></a></p>{/if}
    </div>
  {/if}
  <div class="rule" aria-hidden="true"></div>
</header>

<style>
  .page-header { margin-bottom: 18px; }
  .title-row { display: flex; align-items: center; flex-wrap: wrap; gap: 6px 14px; min-height: 40px; }
  h1 { display: flex; align-items: center; gap: 12px; font-size: 22px; white-space: nowrap; }
  .purpose { color: var(--muted); font-size: 13px; min-width: 0; flex: 1 1 260px; }
  .tools { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; margin-left: auto; }
  .freshness { display: inline-flex; align-items: center; gap: 6px; min-height: 28px; padding: 0 9px; border-radius: 4px; font: 12px var(--mono); letter-spacing: .04em; white-space: nowrap; }
  .freshness.stale { color: var(--amber); background: var(--amber-soft); border: 1px solid rgba(227, 165, 63, .3); }
  .help-toggle { display: inline-flex; align-items: center; gap: 6px; min-height: 30px; padding: 2px 10px; font-size: 12px; color: var(--muted); }
  .help-toggle span { display: inline-grid; place-items: center; width: 16px; height: 16px; border: 1px solid currentColor; border-radius: 50%; font: 600 12px/1 var(--mono); }
  .help-toggle.open { color: var(--accent); border-color: var(--accent-dim); background: var(--accent-soft); }
  .docs-link { display: inline-flex; align-items: center; gap: 4px; min-height: 30px; padding: 2px 4px; font-size: 12px; }
  .help { margin-top: 12px; padding: 12px 16px; border: 1px solid var(--border-soft); border-left: 2px solid var(--accent-dim); border-radius: 0 5px 5px 0; background: var(--inset); color: var(--muted); font-size: 13px; line-height: 1.6; max-width: 900px; }
  .help-body :global(p + p) { margin-top: 6px; }
  .help-body :global(strong) { color: var(--text); font-weight: 600; }
  .help-links { display: flex; flex-wrap: wrap; gap: 6px 20px; margin-top: 8px; font-size: 12px; }
  /* A ruler under the title: a hairline with a short run of gauge ticks,
     a major one every fifth. */
  .rule { position: relative; height: 7px; margin-top: 12px; border-bottom: 1px solid var(--border); }
  .rule::before { content: ""; position: absolute; left: 0; bottom: 0; width: 121px; height: 7px; background:
    linear-gradient(90deg, var(--accent) 1px, transparent 1px) 0 0 / 40px 7px repeat-x,
    linear-gradient(90deg, var(--accent-dim) 1px, transparent 1px) 0 100% / 8px 3px repeat-x; }
  @media (max-width: 700px) { h1 { font-size: 20px; } .tools { margin-left: 0; } }
  @media print { .tools, .help-toggle { display: none; } .help { border: 0; padding: 0; background: none; } .rule::before { display: none; } }
</style>
