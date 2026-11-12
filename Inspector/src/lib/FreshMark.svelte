<script lang="ts">
  import Icon from "./Icon.svelte";
  import type { Freshness } from "./reading";

  /**
   * Content new or changed since this browser last read it, as one small
   * sparkle rather than a word or a count. Whether it is new or updated stays
   * in its accessible name and tooltip; `label` names a group instead.
   */
  let { state, label }: { state: Freshness; label?: string } = $props();
  const name = $derived(label ?? (state === "new" ? "New since your last visit" : "Updated since your last visit"));
</script>

{#if state}<span class="fresh-mark" role="img" aria-label={name} title={name}><Icon name="sparkle" size={12} /></span>{/if}

<style>
  .fresh-mark { display: inline-flex; align-items: center; flex: none; margin-left: 6px; color: var(--amber); vertical-align: -1px; }
</style>
