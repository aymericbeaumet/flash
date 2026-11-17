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
  .config-json { margin: 0; padding: 16px; background: var(--inset); max-height: 600px; color: var(--muted); white-space: pre; font-size: 12px; }
  .override { color: var(--copper); font-weight: 650; background: rgba(208, 138, 92, .12); border-radius: 3px; }
  .where { margin-left: 10px; color: var(--accent); font-size: 12px; font-weight: 600; letter-spacing: .04em; }
  a.where { text-decoration: underline; text-underline-offset: 2px; }
  .empty { padding: 28px 20px; }
  @media print {
    .config-json { padding: 12px; max-height: none; color: inherit; }
    .override { color: #6d3b0e; background: none; }
  }
</style>
