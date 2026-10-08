<script lang="ts">
  import Icon from "./Icon.svelte";
  import { paths } from "./routes";
  import type { SourceKind } from "./source";

  let { kind, label = "" }: { kind: SourceKind; label?: string } = $props();
  const text = $derived.by(() => {
    if (kind === "builtin") return "Built-in";
    if (kind === "plugin") return label;
    if (!label || label === kind) return kind;
    return `${kind} · ${label}`;
  });
</script>

{#if kind === "plugin"}
  <a class="badge neutral" href={paths.plugins(label)}>{text} <Icon name="chevron" size={11} /></a>
{:else if kind === "builtin"}
  <span class="badge">{text}</span>
{:else}
  <span class="badge neutral">{text}</span>
{/if}
