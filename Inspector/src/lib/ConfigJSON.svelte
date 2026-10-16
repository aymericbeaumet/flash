<script lang="ts">
  import { configDocument, type ConfigSourceNode } from "./config-json";

  let { config, sources, query = "" }: { config: unknown; sources?: ConfigSourceNode; query?: string } = $props();
  const document = $derived(configDocument(config, sources, query));
</script>

{#if document.empty}
  <p class="empty">No configuration values match.</p>
{:else}
  <pre class="config-json">{#each document.tokens as token, index (index)}{#if token.where}<span class="override">{token.text}</span>{#if token.where === "config" || token.where.startsWith("config · ")}<a class="where" href="#config-editor" aria-label="Open the source configuration in the editor">{token.where}</a>{:else}<span class="where">{token.where}</span>{/if}{:else}{token.text}{/if}{/each}</pre>
{/if}

<style>
  .config-json { margin: 0; padding: 20px; background: #f5f8f0; max-height: 600px; color: var(--text); white-space: pre; }
  .override { color: #6d3b0e; font-weight: 650; background: #f8ecd9; border-radius: 3px; }
  .where { margin-left: 10px; color: var(--accent); font-size: 10px; font-weight: 700; letter-spacing: .04em; }
  a.where { text-decoration: underline; text-underline-offset: 2px; }
  .empty { padding: 28px 20px; }
  @media print {
    .config-json { padding: 12px; max-height: none; }
    .override { color: #6d3b0e; background: none; }
  }
</style>
