// The published site in the browser. A page arrives whole: its article is
// HTML, and its links load other pages. This hydrates what surrounds the
// article (the navigation, the search, the shortcuts) from the navigation
// every page shares, which the page's head preloads and which names the
// search's two files.

import { hydrate } from "svelte";
import "../app.css";
import { ManualIndex, siteLinks } from "../lib/docsite";
import { router } from "../lib/router.svelte";
import { useSite } from "../lib/routes";
import SiteApp from "../SiteApp.svelte";
import type { SiteIndex } from "./assets";
import { siteSearch } from "./search.svelte";

async function start() {
  const nav = document.querySelector<HTMLLinkElement>("link#flash-nav");
  const route = document.querySelector<HTMLMetaElement>('meta[name="flash-route"]');
  if (!nav || !route) return;
  let index: SiteIndex;
  try {
    const response = await fetch(nav.href);
    if (!response.ok) return;
    index = (await response.json()) as SiteIndex;
  } catch {
    // Without its navigation the page stays as served: an article and links.
    return;
  }
  useSite(siteLinks("public", index.site));
  siteSearch.use(index.search);
  // Only a search is shown in place; every page is its own document.
  router.handles = (target) => target.page === "search";
  // The document hydrates as rendered; `router.start` then reads the address.
  router.prime(new URL(route.content, location.href));
  hydrate(SiteApp, {
    target: document.getElementById("app")!,
    props: { manual: new ManualIndex(index) },
  });
  // What `bench:help -- --site` reads: the page answers the keyboard from here.
  performance.mark("flash:hydrated");
  // The keyboard starts in the reading area, which is what scrolls; a
  // fragment keeps the browser's own starting point.
  if (!location.hash && document.activeElement === document.body)
    document.getElementById("main-content")?.focus({ preventScroll: true });
}

void start();
