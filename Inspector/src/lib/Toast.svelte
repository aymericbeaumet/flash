<script lang="ts">
  import Icon from "./Icon.svelte";
  import type { Toast } from "./toast";
  import { toasts } from "./toasts.svelte";

  /**
   * One toast of the stack: an optional icon before the message, the
   * caller's actions and a dismiss control, all ordinary buttons. Escape on
   * any of them dismisses the toast. Pointing at it or focusing it holds its
   * timeout, if it has one.
   */
  let { toast }: { toast: Toast } = $props();
  const uid = $props.id();
  let pointed = false;
  let focused = false;

  function hold() {
    toasts.hold(toast.id, pointed || focused);
  }
  function onkeydown(event: KeyboardEvent) {
    if (event.key !== "Escape") return;
    // Escape belongs to the toast here, not to the page's shortcuts.
    event.preventDefault();
    event.stopPropagation();
    toasts.dismiss(toast.id);
  }
</script>

<div
  class="toast tone-{toast.tone}"
  role="group"
  aria-labelledby="{uid}-message"
  data-toast={toast.id}
  onpointerenter={() => { pointed = true; hold(); }}
  onpointerleave={() => { pointed = false; hold(); }}
  onfocusin={() => { focused = true; hold(); }}
  onfocusout={(event) => { if (!event.currentTarget.contains(event.relatedTarget as Node | null)) { focused = false; hold(); } }}
>
  <p class="message" id="{uid}-message">{#if toast.icon}<span class="icon" role={toast.icon.label ? "img" : undefined} aria-label={toast.icon.label} aria-hidden={toast.icon.label ? undefined : "true"} title={toast.icon.label}><Icon name={toast.icon.name} size={14} /></span>{" "}{/if}{toast.message}</p>
  {#if toast.actions.length}
    <div class="actions">
      {#each toast.actions as action, index}<button type="button" {onkeydown} onclick={() => toasts.act(toast.id, index)}>{action.label}</button>{/each}
    </div>
  {/if}
  <button type="button" class="dismiss" aria-label={toast.dismissLabel} title={toast.dismissLabel} {onkeydown} onclick={() => toasts.dismiss(toast.id)}><Icon name="close" size={14} /></button>
</div>

<style>
  .toast {
    --tone: var(--accent);
    position: relative;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 8px 12px;
    width: 100%;
    padding: 10px 44px 10px 14px;
    border: 1px solid var(--border-strong);
    border-radius: 6px;
    background: var(--raised);
    color: var(--text);
    font-size: 13px;
    line-height: 1.45;
    box-shadow: inset 2px 0 0 var(--tone), 0 14px 36px rgba(0, 0, 0, .5);
    pointer-events: auto;
  }
  .tone-fresh { --tone: var(--amber); }
  .tone-success { --tone: var(--verdigris); }
  .tone-error { --tone: var(--danger); }
  .message { flex: 1 1 200px; min-width: 0; margin: 0; overflow-wrap: anywhere; }
  .icon { display: inline-flex; vertical-align: -2px; color: var(--tone); }
  .actions { display: flex; flex-wrap: wrap; gap: 6px; }
  .actions button { min-height: 28px; padding: 3px 10px; font-size: 12px; color: var(--accent); border-color: var(--accent-dim); }
  .actions button:hover { color: var(--accent-strong); border-color: var(--accent); }
  .dismiss { position: absolute; top: 6px; right: 6px; display: grid; place-items: center; width: 30px; min-height: 30px; padding: 0; border: 0; background: none; color: var(--muted); }
  .dismiss:hover { background: var(--hover); color: var(--text); }
  @media (prefers-reduced-motion: no-preference) {
    .toast { animation: toast-in .16s ease-out; }
  }
  @keyframes toast-in {
    from { opacity: 0; transform: translateY(8px); }
  }
</style>
