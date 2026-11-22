// How the published site moves between its pages. Every page is its own
// document, so a link is a plain navigation; what makes it quick is the
// browser having the next page before the click. Speculation rules in each
// page's head say which links to prepare; a browser that reads none gets the
// page's document fetched while its link is pointed at or focused
// (`prepareOnIntent`, wired by the shell).

import { site } from "../lib/routes.ts";

/** A page's rules: every link to another page of the site, never a file, an asset or this page. */
export function speculationRules(root: string) {
  const where = {
    and: [
      { href_matches: [`${root}/`, `${root}/*/`] },
      { not: { selector_matches: '[href^="#"], [download], [target="_blank"]' } },
    ],
  };
  return {
    // Fetched while the pointer rests on the link; rendered once it is pressed.
    prefetch: [{ where, eagerness: "moderate" }],
    prerender: [{ where, eagerness: "conservative" }],
  };
}

/** The document to fetch ahead for a link from `here`, when it leads to another page of the site. */
export function pageToPrepare(url: URL, here: URL, root: string): string | null {
  if (url.origin !== here.origin) return null;
  if (!url.pathname.startsWith(`${root}/`) || !url.pathname.endsWith("/")) return null;
  if (url.pathname === here.pathname && url.search === here.search) return null;
  return url.pathname + url.search;
}

const prepared = new Set<string>();

/** Fetches a linked page's document ahead, where the browser reads no speculation rules. */
export function preparePage(url: URL) {
  if (HTMLScriptElement.supports?.("speculationrules")) return;
  const href = pageToPrepare(url, new URL(location.href), site.links.root);
  if (!href || prepared.has(href)) return;
  prepared.add(href);
  const link = document.createElement("link");
  link.rel = "prefetch";
  link.href = href;
  if (link.relList.supports("prefetch")) document.head.append(link);
  else
    void fetch(href).catch(() => {
      prepared.delete(href);
    });
}
