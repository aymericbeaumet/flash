// The browser help's page table. `DebugServer.Page` mirrors it so the server
// hands the app to a direct load or reload of any page, and a 404 to the rest.
// Data endpoints live under `/api/`; fragments are in-page heading anchors.

export type PageName = "home" | "docs" | "mappings" | "commands" | "plugins" | "state" | "logs" | "clipboard";

/** `param` is the docs topic, the plugin id, or the `?q=` filter of mappings and commands. */
export type Route = { page: PageName | "not-found"; param: string };

const pages = new Set(["docs", "mappings", "commands", "plugins", "state", "logs", "clipboard"]);
/** Pages that accept one detail segment. */
const detailPages = new Set(["docs", "plugins"]);
/** Pages whose list starts filtered by `?q=`. */
const filterPages = new Set(["mappings", "commands"]);
const notFound: Route = { page: "not-found", param: "" };

export function parseRoute(url: { pathname: string; search: string }): Route {
  const [head, ...rest] = url.pathname.split("/").filter(Boolean);
  if (head === undefined) return { page: "home", param: "" };
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
  docs: (topic?: string) => (topic ? `/docs/${encodeURIComponent(topic)}` : "/docs"),
  mappings: (query?: string) => filtered("/mappings", query),
  commands: (query?: string) => filtered("/commands", query),
  plugins: (id?: string) => (id ? `/plugins/${encodeURIComponent(id)}` : "/plugins"),
};
