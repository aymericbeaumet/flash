<script lang="ts">
  import { tick } from "svelte";
  import Toast from "./Toast.svelte";
  import { toastList } from "./toasts.svelte";

  /**
   * The bottom-right corner where the page's toasts stack, oldest first and
   * the newest nearest the corner; full width along the bottom on a narrow
   * screen. The live region is always in the page, so a toast added to it is
   * announced politely, and it is a "Notifications" landmark while it holds
   * one. A toast never takes focus. When one closes with focus inside, focus
   * moves to the toast now in its place, else back where it came from, else
   * to `fallback`. `space` is the height the stack covers at the bottom of
   * the window while a toast that stays is up, so the page can leave that
   * much room under its content; a passing toast leaves by itself and moves
   * nothing.
   */
  let { fallback, space = $bindable(0) }: { fallback?: () => HTMLElement | null | undefined; space?: number } = $props();

  const list = $derived(toastList.current);
  let stack = $state<HTMLElement>();
  let height = $state(0);
  let returnTo: HTMLElement | null = null;

  const lasting = $derived(list.some((toast) => toast.timeout === undefined));
  // The corner's offset is 16 px (12 px narrow); the extra keeps a gap above the stack.
  $effect(() => { space = lasting && height ? height + 24 : 0; });

  // Runs before the DOM drops a closed toast, while its focused control is still there.
  $effect.pre(() => {
    const open = new Set(list.map((toast) => toast.id));
    const container = stack;
    const active = document.activeElement;
    if (!container || !(active instanceof HTMLElement) || !container.contains(active)) return;
    const host = active.closest<HTMLElement>("[data-toast]");
    if (!host || open.has(host.dataset.toast ?? "")) return;
    const position = Array.from(container.querySelectorAll("[data-toast]")).indexOf(host);
    void tick().then(() => {
      const hosts = Array.from(container.querySelectorAll<HTMLElement>("[data-toast]"));
      const neighbour = hosts[Math.min(position, hosts.length - 1)]?.querySelector<HTMLElement>("button");
      (neighbour ?? (returnTo?.isConnected ? returnTo : null) ?? fallback?.())?.focus();
    });
  });

  function onfocusin(event: FocusEvent) {
    const from = event.relatedTarget;
    if (from instanceof HTMLElement && !stack?.contains(from)) returnTo = from;
  }
</script>

<section class="toaster" aria-label={list.length ? "Notifications" : undefined}>
  <div class="stack" role="status" aria-live="polite" aria-atomic="false" aria-relevant="additions text" bind:this={stack} bind:offsetHeight={height} {onfocusin}>
    {#each list as toast (toast.id)}<Toast {toast} />{/each}
  </div>
</section>

<style>
  /* Above the page, below every scrim, drawer and dialog. */
  .toaster { position: fixed; right: 16px; bottom: 16px; z-index: 15; width: min(380px, calc(100vw - 32px)); pointer-events: none; }
  .stack { display: flex; flex-direction: column; gap: 8px; }
  @media (max-width: 600px) { .toaster { left: 12px; right: 12px; bottom: 12px; width: auto; } }
  @media print { .toaster { display: none; } }
</style>
