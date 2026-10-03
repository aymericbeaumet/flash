import { tick } from "svelte";
import { parseRoute, type Route } from "./routes";

type Settle = { top: number } | "anchor" | "keep";

let entries = 0;
const newKey = () => `${Date.now().toString(36)}-${++entries}`;
function currentAnchor() {
  const hash = location.hash.slice(1);
  try { return decodeURIComponent(hash); } catch { return hash; }
}

/**
 * History API routing for the single-page help. Same-origin page links
 * navigate in place; modified, middle, new-window and download clicks keep
 * the browser's behavior. Fragments are native in-page anchors. Each history
 * entry remembers its scroll position for back/forward, and an anchor whose
 * heading has not rendered yet is revealed once it appears.
 */
class Router {
  route = $state<Route>(parseRoute(location));
  private main: HTMLElement | null = null;
  private onNavigate = () => {};
  private key = "";
  private url = "";
  private anchor = "";
  private positions = new Map<string, number>();

  start(main: HTMLElement, onNavigate: () => void) {
    this.main = main;
    this.onNavigate = onNavigate;
    history.scrollRestoration = "manual";
    this.key = this.entryKey();
    this.url = location.href;
    this.anchor = currentAnchor();
    const onScroll = () => this.positions.set(this.key, main.scrollTop);
    onScroll();
    main.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("click", this.onClick);
    // A fragment navigation fires both; `sync` handles an entry once.
    window.addEventListener("popstate", this.sync);
    window.addEventListener("hashchange", this.sync);
    return () => {
      main.removeEventListener("scroll", onScroll);
      window.removeEventListener("click", this.onClick);
      window.removeEventListener("popstate", this.sync);
      window.removeEventListener("hashchange", this.sync);
      this.main = null;
    };
  }

  navigate(href: string) {
    const url = new URL(href, location.href);
    if (this.main) this.positions.set(this.key, this.main.scrollTop);
    if (url.href === location.href) {
      history.replaceState(history.state, "", url);
    } else {
      this.key = newKey();
      history.pushState({ key: this.key }, "", url);
    }
    this.url = location.href;
    this.route = parseRoute(url);
    this.onNavigate();
    this.settle(url.hash ? "anchor" : { top: 0 });
  }

  /** Scrolls to the URL's anchor once its element exists. */
  revealAnchor() {
    const target = this.anchor ? document.getElementById(this.anchor) : null;
    if (!target) return;
    this.anchor = "";
    target.scrollIntoView({ block: "start" });
  }

  private onClick = (event: MouseEvent) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const anchor = event.target instanceof Element ? event.target.closest("a[href]") : null;
    if (!(anchor instanceof HTMLAnchorElement) || (anchor.target && anchor.target !== "_self") || anchor.hasAttribute("download")) return;
    const url = new URL(anchor.href);
    if (url.origin !== location.origin) return;
    if (url.hash && url.pathname === location.pathname && url.search === location.search) return;
    if (parseRoute(url).page === "not-found") return;
    event.preventDefault();
    this.navigate(url.href);
  };

  private sync = () => {
    if (location.href === this.url && history.state?.key === this.key) return;
    const next = parseRoute(location);
    const samePage = next.page === this.route.page && next.param === this.route.param;
    this.key = this.entryKey();
    this.url = location.href;
    if (!samePage) {
      this.route = next;
      this.onNavigate();
    }
    const saved = this.positions.get(this.key);
    this.settle(saved !== undefined ? { top: saved } : location.hash ? "anchor" : samePage ? "keep" : { top: 0 });
  };

  private settle(scroll: Settle) {
    this.anchor = scroll === "anchor" ? currentAnchor() : "";
    const key = this.key;
    void tick().then(() => {
      if (typeof scroll === "object" && this.main) {
        this.main.scrollTop = scroll.top;
        this.positions.set(key, this.main.scrollTop);
      } else if (scroll === "anchor") this.revealAnchor();
    });
  }

  private entryKey() {
    const key = history.state?.key;
    if (typeof key === "string") return key;
    const fresh = newKey();
    history.replaceState({ key: fresh }, "");
    return fresh;
  }
}

export const router = new Router();
