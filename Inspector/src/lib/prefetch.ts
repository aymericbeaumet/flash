/**
 * Prepares a page while the pointer rests on, or the keyboard reaches, a
 * link to it, so following the link only has to mount it. A link the
 * pointer only crosses (`restMs`) prepares nothing; each link prepares once
 * per visit to it.
 */
export function prepareOnIntent(target: EventTarget, prepare: (url: URL) => void, restMs = 60): () => void {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let armed: HTMLAnchorElement | null = null;
  const anchorOf = (event: Event) => {
    const anchor = event.target instanceof Element ? event.target.closest("a[href]") : null;
    return anchor instanceof HTMLAnchorElement ? anchor : null;
  };
  const arm = (event: Event) => {
    const anchor = anchorOf(event);
    if (!anchor || anchor === armed) return;
    clearTimeout(timer);
    armed = anchor;
    timer = setTimeout(() => {
      try { prepare(new URL(anchor.href)); } catch { /* A link that is not a URL prepares nothing. */ }
    }, event.type === "focusin" ? 0 : restMs);
  };
  const disarm = (event: Event) => {
    const anchor = anchorOf(event);
    if (!anchor || anchor !== armed) return;
    const next = (event as PointerEvent | FocusEvent).relatedTarget;
    if (next instanceof Node && anchor.contains(next)) return;
    clearTimeout(timer);
    armed = null;
  };
  target.addEventListener("pointerover", arm, { passive: true });
  target.addEventListener("pointerout", disarm, { passive: true });
  target.addEventListener("focusin", arm);
  target.addEventListener("focusout", disarm);
  return () => {
    clearTimeout(timer);
    target.removeEventListener("pointerover", arm);
    target.removeEventListener("pointerout", disarm);
    target.removeEventListener("focusin", arm);
    target.removeEventListener("focusout", disarm);
  };
}
