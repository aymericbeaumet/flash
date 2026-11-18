<script lang="ts">
  import Icon from "./Icon.svelte";
  import PageHeader from "./PageHeader.svelte";
  import { paths } from "./routes";

  /**
   * What the reading area says in place of a page: the documentation did not
   * load, it is on its way, or nothing lives at the address.
   */
  let {
    param,
    waiting = false,
    error = "",
    onretry,
  }: {
    /** The address asked for. */
    param: string;
    waiting?: boolean;
    /** Why the documentation did not load. */
    error?: string;
    onretry?: () => void;
  } = $props();
</script>

<div class="docs-index">
  {#if error}<PageHeader id="docs" title="Documentation" purpose={error} /><p
      class="not-found-links"
      ><button type="button" onclick={onretry}><Icon name="refresh" size={14} /> Retry</button></p
    >
  {:else if waiting}<PageHeader id="docs" title="Loading…" purpose="Fetching the documentation." />
  {:else}<PageHeader
      id="docs"
      title="Page not found"
      purpose={`There is no documentation page at “${param}”. Pick one from the list, or search.`}
    /><p class="not-found-links"
      ><a href={paths.docs()}>Documentation home <span aria-hidden="true">→</span></a><a
        href={paths.search()}>Search <span aria-hidden="true">→</span></a
      ></p
    >{/if}
</div>

<style>
  .docs-index {
    max-width: 1000px;
    width: 100%;
  }
  .not-found-links {
    display: flex;
    gap: 24px;
    font-size: 14px;
  }
  .not-found-links button {
    display: inline-flex;
    align-items: center;
    gap: 6px;
  }
  @media (max-width: 600px) {
    .docs-index :global(h1) {
      font-size: 26px;
    }
  }
  @media print {
    .docs-index {
      max-width: none;
    }
  }
</style>
