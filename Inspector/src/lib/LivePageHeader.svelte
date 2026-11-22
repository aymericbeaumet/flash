<script lang="ts">
  import type { ComponentProps } from "svelte";
  import { now } from "./clock.svelte";
  import { ago, clockTime } from "./format";
  import Icon from "./Icon.svelte";
  import PageHeader from "./PageHeader.svelte";
  import { store } from "./store.svelte";

  /**
   * The head of a page that shows resident state: it marks the page stale
   * while Flash is unreachable.
   */
  let props: Omit<ComponentProps<typeof PageHeader>, "status"> = $props();

  const snapshotAt = $derived(store.state.snapshot_at_unix_ms);
</script>

<PageHeader {...props}
  >{#snippet status()}{#if !store.connected}
      {#if snapshotAt}<span
          class="freshness stale"
          title="The connection to Flash is down: this is the last snapshot it sent"
          ><Icon name="warning" size={13} />Stale · {clockTime(snapshotAt)} · {ago(
            snapshotAt,
            now(),
          )}</span
        >
      {:else}<span class="freshness stale"><Icon name="warning" size={13} />No data yet</span>{/if}
    {/if}{/snippet}</PageHeader
>

<style>
  .freshness {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    min-height: 28px;
    padding: 0 9px;
    border-radius: 4px;
    font: 12px var(--mono);
    letter-spacing: 0.04em;
    white-space: nowrap;
  }
  .freshness.stale {
    color: var(--amber);
    background: var(--amber-soft);
    border: 1px solid rgba(227, 165, 63, 0.3);
  }
</style>
