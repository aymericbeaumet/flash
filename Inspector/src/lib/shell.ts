import type { PageEntry } from "./docsite.ts";
import { paths, type Route } from "./routes.ts";
import type { DocTopic } from "./types.ts";

/** A page of the sidebar, which `g <key>` goes to. */
export interface Section {
  /** The page's route name, and its icon's. */
  id: string;
  href: string;
  label: string;
  group: string;
  key: string;
}

/** A step of the path in the top bar: every crumb but the last is a link. */
export interface Crumb {
  label: string;
  href?: string;
}

/**
 * The path to a page the help and the published site both have: search, a
 * missing address, and the manual, where a plugin's `guide` sits at a path
 * the manual leaves free. Undefined on a page of the help alone.
 */
export function sharedCrumbs(
  route: Route,
  page: PageEntry | undefined,
  guide?: DocTopic,
): Crumb[] | undefined {
  if (route.page === "search")
    return [{ label: "Search" }, ...(route.param ? [{ label: `“${route.param}”` }] : [])];
  if (route.page === "not-found") return [{ label: "Page not found" }];
  if (route.page !== "docs") return undefined;
  const list: Crumb[] = [{ label: "Documentation", href: paths.docs() }];
  if (page?.path)
    list.push(...page.trail.map((label) => ({ label })), { label: page.heading ?? page.title });
  else if (guide) list.push({ label: "Plugin guides" }, { label: guide.title });
  else if (route.param && !page) list.push({ label: route.param });
  return list;
}
