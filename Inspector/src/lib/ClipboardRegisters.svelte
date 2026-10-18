<script lang="ts">
  import Icon from "./Icon.svelte";
  import type { ClipboardRegister } from "./types";

  let { registers }: { registers: ClipboardRegister[] } = $props();
  let copied = $state<string | null>(null);
  let copyError = $state(false);

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

  function key(register: ClipboardRegister): string {
    return `"${register.name}`;
  }

  async function copy(register: ClipboardRegister) {
    copyError = false;
    copied = null;
    try {
      await navigator.clipboard.writeText(register.text);
      copied = register.name;
    } catch {
      copyError = true;
    }
  }
</script>

<section class="register-section" aria-labelledby="registers-heading">
  <div class="section-heading">
    <div><h2 id="registers-heading">Registers</h2><p>Press <kbd>"</kbd> and a register key before <kbd>y</kbd> or <kbd>p</kbd>. The unnamed register and <kbd>+</kbd> use the system clipboard; <kbd>0</kbd> holds the latest yank.</p></div>
    <a href="/docs/normal-mode">Using registers <span aria-hidden="true">→</span></a>
  </div>
  {#if copyError}<p class="register-error" role="alert">The browser could not copy this register. Expand it and select its text to copy manually.</p>{/if}
  <div class="sr-only" role="status" aria-live="polite">{copied !== null ? `Register ${copied} copied to your clipboard.` : ""}</div>
  <div class="surface register-list">
    {#if visible.length}
      {#each visible as register (`${register.kind}:${register.name}`)}
        <article class="register-row">
          <kbd class="register-key">{key(register)}</kbd>
          <div class="register-body"><strong>{label(register)}</strong><p class="register-preview">{register.text || "No plain text on the clipboard"}</p>{#if register.truncated}<p class="truncated-note">Preview truncated. <kbd>"{register.name}p</kbd> still pastes the complete value.</p>{/if}{#if register.text}<details><summary>{register.truncated ? "View preview" : "View full text"}</summary><pre>{register.text}</pre></details>{/if}</div>
          {#if register.text && !register.truncated}<button type="button" class="register-copy" onclick={() => copy(register)} aria-label={`Copy ${label(register).toLowerCase()} register`}><Icon name={copied === register.name ? "check" : "copy"} size={14} />{copied === register.name ? "Copied" : "Copy"}</button>{/if}
        </article>
      {/each}
    {:else}
      <p class="register-empty">No text registers yet. Yank a selection with <kbd>y</kbd> to fill the unnamed and latest-yank registers.</p>
    {/if}
  </div>
</section>

<style>
  .register-section { margin-bottom: 32px; }
  .section-heading { display: flex; align-items: end; justify-content: space-between; gap: 18px; margin-bottom: 14px; }
  .section-heading h2 { margin-bottom: 5px; }
  .section-heading p { max-width: 760px; color: var(--muted); font-size: 13px; }
  .section-heading a { flex-shrink: 0; font-size: 12px; }
  .register-list { overflow: hidden; }
  .register-row { display: grid; grid-template-columns: 52px minmax(0, 1fr) auto; gap: 15px; align-items: start; padding: 15px 18px; border-bottom: 1px solid var(--border-soft); }
  .register-row:last-child { border-bottom: 0; }
  .register-key { text-align: center; font-size: 14px; font-weight: 600; }
  .register-body { min-width: 0; }
  .register-body strong { font-size: 13px; }
  .register-preview { margin-top: 3px; color: var(--muted); font: 12px/1.5 var(--mono); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .truncated-note { margin-top: 5px; color: var(--muted); font-size: 11px; }
  details { margin-top: 7px; }
  summary { width: fit-content; cursor: pointer; color: var(--accent); font-size: 11px; }
  pre { max-height: 260px; margin: 9px 0 0; padding: 12px; border: 1px solid var(--border-soft); border-radius: 7px; background: var(--bg); white-space: pre-wrap; overflow-wrap: anywhere; }
  .register-copy { display: inline-flex; align-items: center; gap: 6px; min-height: 32px; padding: 5px 10px; color: var(--accent); font-size: 11px; }
  .register-empty { padding: 24px 18px; color: var(--muted); font-size: 13px; }
  .register-error { margin-bottom: 12px; color: var(--danger); font-size: 12px; }
  @media (max-width: 640px) { .section-heading { align-items: start; flex-direction: column; gap: 8px; }.register-row { grid-template-columns: 42px minmax(0, 1fr); gap: 10px; padding: 14px; }.register-copy { grid-column: 2; width: fit-content; } }
  @media print { .register-copy, .section-heading a { display: none; }.register-row { grid-template-columns: 52px minmax(0, 1fr); break-inside: avoid; }.register-list { overflow: visible; } }
</style>
