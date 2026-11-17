// The browser help's page table. `DebugServer.Page` mirrors it so the server
// hands the app to a direct load or reload of any page, and a 404 to the rest.
// Data endpoints live under `/api/`; fragments are in-page heading anchors.
//
// The published site serves the same docs view from its own path: there the
// manual is the whole site (`/flash/`, `/flash/<page>/`, `/flash/search/`)
// and the live pages do not exist. `useSite` picks the spelling once, before
// the app renders; every link the app writes goes through `paths`.

import { pathOf, siteLinks, type SiteLinks } from "./docsite.ts";

export type PageName = "home" | "docs" | "mappings" | "commands" | "plugins" | "state" | "monitors" | "telemetry" | "logs" | "clipboard" | "search";

/**
 * `param` is the manual page's route path or alias (`alternatives/neru`,
 * `config`) or a plugin's guide, the plugin id, or the `?q=` query of
 * mappings, commands and search.
 */
export type Route = { page: PageName | "not-found"; param: string };

let current: SiteLinks = siteLinks("local");

/** Chooses the site the app renders for; the resident's help is the default. */
export function useSite(links: SiteLinks) {
  current = links;
}

export const site = {
  get links(): SiteLinks { return current; },
  get public(): boolean { return current.mode === "public"; },
};

const pages = new Set(["mappings", "commands", "plugins", "state", "monitors", "telemetry", "logs", "clipboard", "search"]);
/** Pages that accept one detail segment. */
const detailPages = new Set(["plugins"]);
/** Pages whose list starts filtered by `?q=`. */
const filterPages = new Set(["mappings", "commands", "search"]);
const notFound: Route = { page: "not-found", param: "" };

/** A manual path from URL segments; a last segment with a dot is a file the server sends as it is. */
function manualRoute(segments: string[]): Route {
  if (segments.length && segments[segments.length - 1].includes(".")) return notFound;
  try {
    return { page: "docs", param: segments.map(decodeURIComponent).join("/") };
  } catch {
    return notFound;
  }
}

export function parseRoute(url: { pathname: string; search: string }, links: SiteLinks = current): Route {
  if (links.mode === "public") {
    const path = pathOf(links, url.pathname);
    if (path === null) return notFound;
    if (path === "search") return { page: "search", param: new URLSearchParams(url.search).get("q") ?? "" };
    return manualRoute(url.pathname.slice(links.root.length).split("/").filter(Boolean));
  }
  const [head, ...rest] = url.pathname.split("/").filter(Boolean);
  if (head === undefined) return { page: "home", param: "" };
  if (head === "docs") return manualRoute(rest);
  if (!pages.has(head) || rest.length > (detailPages.has(head) ? 1 : 0)) return notFound;
  if (filterPages.has(head)) return { page: head as PageName, param: new URLSearchParams(url.search).get("q") ?? "" };
  try {
    return { page: head as PageName, param: rest.length ? decodeURIComponent(rest[0]) : "" };
  } catch {
    return notFound;
  }
}

const filtered = (path: string, query?: string) => (query ? `${path}?${new URLSearchParams({ q: query })}` : path);

export const paths = {
  /** A manual page by route path (`""` is the manual's home), or a plugin's guide by name. */
  docs: (page = "", anchor?: string) => current.page(page, anchor),
  mappings: (query?: string) => filtered("/mappings", query),
  commands: (query?: string) => filtered("/commands", query),
  plugins: (id?: string) => (id ? `/plugins/${encodeURIComponent(id)}` : "/plugins"),
  search: (query?: string) => filtered(current.mode === "public" ? `${current.root}/search/` : "/search", query),
};
