<script lang="ts">
  import { paths } from "./routes";
  import Icon from "./Icon.svelte";
  import SectionHead from "./SectionHead.svelte";
  import { copyText } from "./toasts.svelte";
  import type { ClipboardRegister } from "./types";

  let { registers }: { registers: ClipboardRegister[] } = $props();
  /** The register copied last, marked until the next copy. */
  let copied = $state<string | null>(null);
  let expanded = $state<string | null>(null);

  const order = { unnamed: 0, yank: 1, clipboard: 2, named: 3 };
  const visible = $derived(
    [...registers]
      .filter((register) => register.kind === "clipboard" || register.text.length > 0)
      .sort((left, right) => order[left.kind] - order[right.kind] || left.name.localeCompare(right.name)),
  );

  function label(register: ClipboardRegister): string {
    switch (register.kind) {
      case "unnamed": return "Unnamed";
      case "yank": return "Latest yank";
      case "clipboard": return "System clipboard";
      case "named": return `Named ${register.name}`;
    }
  }

  function size(text: string): string {
    if (!text) return "empty";
    const lines = text.split("\n").length;
    return `${text.length.toLocaleString()} ch${lines > 1 ? ` · ${lines} lines` : ""}`;
  }

  async function copy(register: ClipboardRegister) {
    copied = null;
    if (await copyText(register.text, `register ${register.name}`, "Expand it and select its text instead.")) copied = register.name;
  }
</script>

<section class="register-section" aria-labelledby="registers-heading">
  <SectionHead id="registers-heading" title="Registers" count={visible.length}>
    {#snippet help()}Press <kbd>"</kbd> and a register key before <kbd>y</kbd> or <kbd>p</kbd>. The unnamed register and <kbd>+</kbd> use the system clipboard; <kbd>0</kbd> holds the latest yank. A truncated preview still pastes in full with <kbd>"</kbd><i>name</i><kbd>p</kbd>. <a href={paths.docs("clipboard")}>Using registers →</a>{/snippet}
  </SectionHead>
  <div class="surface register-list">
    {#if visible.length}
      <table class="data-table">
        <thead><tr><th class="key-col">Reg</th><th>Contents</th><th class="type-col">Type</th><th class="size-col">Size</th><th class="act-col"><span class="sr-only">Actions</span></th></tr></thead>
        <tbody>
          {#each visible as register (`${register.kind}:${register.name}`)}
            {@const id = `${register.kind}:${register.name}`}
            <tr class:open={expanded === id}>
              <td class="key-col"><kbd>"{register.name}</kbd></td>
              <td class="contents">{#if register.text}<button type="button" class="preview" aria-expanded={expanded === id} onclick={() => (expanded = expanded === id ? null : id)} title={register.truncated ? "Preview: Flash keeps the full value for paste" : "Show the full text"}><Icon name="chevron" size={11} /><span>{register.text.split("\n")[0]}</span></button>{:else}<span class="muted none">No plain text on the clipboard</span>{/if}</td>
              <td class="type-col">{label(register)}{#if register.truncated} <span class="badge neutral" title="The snapshot carries a preview; the resident pastes the full value">preview</span>{/if}</td>
              <td class="size-col">{size(register.text)}</td>
              <td class="act-col">{#if register.text && !register.truncated}<button type="button" class="icon-button" onclick={() => copy(register)} aria-label={`Copy ${label(register).toLowerCase()} register`} title="Copy"><Icon name={copied === register.name ? "check" : "copy"} size={14} /></button>{/if}</td>
            </tr>
            {#if expanded === id}<tr class="full"><td></td><td colspan="4"><pre class="well">{register.text}</pre></td></tr>{/if}
          {/each}
        </tbody>
      </table>
    {:else}
      <p class="register-empty">No text registers yet. Yank a selection with <kbd>y</kbd> to fill the unnamed and latest-yank registers.</p>
    {/if}
  </div>
</section>

<style>
  .register-section { margin-bottom: 20px; }
  .register-list { overflow: hidden; }
  .data-table td { padding-top: 4px; padding-bottom: 4px; vertical-align: middle; }
  .data-table tbody tr { height: 40px; }
  .key-col { width: 64px; }
  .key-col kbd { font-weight: 600; color: var(--accent); }
  .type-col { width: 210px; color: var(--muted); white-space: nowrap; }
  .size-col { width: 150px; color: var(--muted); font: 12px var(--mono); white-space: nowrap; }
  .act-col { width: 48px; text-align: right; }
  .contents { max-width: 0; }
  .preview { display: flex; align-items: center; gap: 8px; width: 100%; min-height: 32px; padding: 0 4px; border: 0; background: none; text-align: left; font: 13px var(--mono); color: var(--text); }
  .preview:hover { background: none; color: var(--accent-strong); }
  .preview span { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .preview :global(svg) { flex: none; color: var(--faint); transition: transform .12s; }
  .preview[aria-expanded="true"] :global(svg) { transform: rotate(90deg); color: var(--accent); }
  .none { font-size: 13px; }
  tr.full td { padding-top: 0; padding-bottom: 10px; }
  tr.full pre { margin: 0; padding: 10px 12px; max-height: 260px; white-space: pre-wrap; overflow-wrap: anywhere; color: var(--text); }
  .register-empty { padding: 18px 16px; color: var(--muted); font-size: 13px; }
  @media (max-width: 760px) { .type-col, .size-col { display: none; } }
  @media print { .act-col { display: none; } .register-list { overflow: visible; } .preview :global(svg) { display: none; } }
</style>
