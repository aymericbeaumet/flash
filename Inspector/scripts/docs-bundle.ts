// The manual's build: `docs/` into the bundle the resident and the published
// site load (`docs.json`), its search sections (`search.json`) and the link
// check of a strict build. Only the build scripts and the tests import it;
// the page reads the bundle through `src/lib/docsite.ts`.

import {
  Manual,
  siteLinks,
  type DocsBundle,
  type ManualPage,
  type NavNode,
  type SearchSection,
  type SiteInfo,
  type SiteLinks,
} from "../src/lib/docsite.ts";
import { routeOf, sectionsOf, type RenderContext } from "../src/lib/markdown-tree.ts";
import { renderUncached } from "../src/lib/markdown.ts";
import { hashBody } from "../src/lib/reading.ts";

/** `docs/nav.json`: pages by file, grouped; a page may take short `aliases`. */
export type NavSource =
  { title: string; page: string; aliases?: string[] } | { title: string; items: NavSource[] };

export interface Problem {
  file: string;
  message: string;
}

/** Route paths a page may not take on the published site. */
const reservedPaths = new Set(["search", "404", "_app"]);
/** Files a page may link, which the resident serves as they are (`DebugServer.docsFile`). */
const servableFiles = /\.(toml|json|txt|png|jpe?g|gif|webp)$/i;
/** Generated files at the site root. */
const reservedFiles = new Set([
  "docs.json",
  "search.json",
  "favicon.svg",
  "404.html",
  "sitemap.xml",
  "robots.txt",
  ".nojekyll",
  "index.html",
]);

function isNavGroup(item: NavSource): item is { title: string; items: NavSource[] } {
  return "items" in item;
}

/**
 * The line of every table header and key in the reference file. A real
 * header or key wins over a commented example of the same name; within a
 * table, the first assignment of a key is its line.
 */
export function configIndex(text: string): Record<string, number> {
  const real: Record<string, number> = {};
  const example: Record<string, number> = {};
  let table = "";
  text.split("\n").forEach((raw, index) => {
    const line = index + 1;
    const header = /^(#\s?)?\[([A-Za-z0-9_.\-"<>+ ]+)\]\s*(?:#.*)?$/.exec(raw);
    if (header) {
      table = header[2].replace(/\s+/g, "");
      const into = header[1] ? example : real;
      into[table] ??= line;
      return;
    }
    const assignment = /^(#\s?)?([A-Za-z0-9_-]+|"[^"]+")\s*=/.exec(raw);
    if (!assignment || !table) return;
    const into = assignment[1] ? example : real;
    into[`${table}.${assignment[2]}`] ??= line;
  });
  return { ...example, ...real };
}

/**
 * Bundles the manual from `nav.json` and the files under `docs/` (Markdown
 * by path with its text; other files by path). Every Markdown file is in the
 * navigation or `unlisted`, every navigation entry names a file, and no
 * page appears twice; anything else is a problem, as in a strict build.
 */
export function bundleDocs(
  navJSON: string,
  markdown: Map<string, string>,
  otherFiles: string[],
  configText?: string,
): { bundle: DocsBundle; problems: Problem[] } {
  const problems: Problem[] = [];
  const config = JSON.parse(navJSON) as {
    site: SiteInfo;
    nav: NavSource[];
    unlisted?: (string | { page: string; aliases?: string[] })[];
  };
  const site = config.site;
  if (!site?.url?.endsWith("/"))
    problems.push({ file: "nav.json", message: "site.url must end with /" });
  const pages: ManualPage[] = [];
  const seen = new Set<string>();
  const add = (
    title: string,
    file: string,
    trail: string[],
    listed: boolean,
    aliases: string[] = [],
  ): string | undefined => {
    if (seen.has(file)) {
      problems.push({ file: "nav.json", message: `${file} appears twice` });
      return undefined;
    }
    seen.add(file);
    const text = markdown.get(file);
    if (text === undefined) {
      problems.push({ file: "nav.json", message: `${file} does not exist` });
      return undefined;
    }
    const path = routeOf(file);
    if (reservedPaths.has(path.split("/")[0]))
      problems.push({ file, message: `the route ${path} is reserved` });
    pages.push({ path, file, title, trail, markdown: text, hash: hashBody(text), listed, aliases });
    return path;
  };
  const walk = (items: NavSource[], trail: string[]): NavNode[] =>
    items.flatMap((item): NavNode[] => {
      if (isNavGroup(item))
        return [{ title: item.title, items: walk(item.items, [...trail, item.title]) }];
      const path = add(item.title, item.page, trail, true, item.aliases ?? []);
      return path === undefined ? [] : [{ title: item.title, path }];
    });
  const nav = walk(config.nav ?? [], []);
  for (const entry of config.unlisted ?? []) {
    const { page, aliases = [] } = typeof entry === "string" ? { page: entry } : entry;
    add(routeOf(page) || "Home", page, [], false, aliases);
  }
  // An alias is one plain word that names nothing else on the site.
  const paths = new Set(pages.map((page) => page.path));
  const claimed = new Map<string, string>();
  for (const page of pages) {
    for (const alias of page.aliases) {
      if (!/^[a-z0-9][a-z0-9_-]*$/.test(alias))
        problems.push({ file: page.file, message: `the alias ${alias} is not one lowercase word` });
      else if (
        paths.has(alias) ||
        reservedPaths.has(alias) ||
        otherFiles.some((file) => file.split("/")[0] === alias)
      )
        problems.push({
          file: page.file,
          message: `the alias ${alias} names another page or file`,
        });
      else if (claimed.has(alias))
        problems.push({
          file: page.file,
          message: `the alias ${alias} also names ${claimed.get(alias)}`,
        });
      else claimed.set(alias, page.file);
    }
  }
  for (const file of markdown.keys()) {
    if (!seen.has(file))
      problems.push({ file, message: "is neither in the navigation nor unlisted in nav.json" });
  }
  for (const file of otherFiles) {
    if (reservedFiles.has(file) || reservedPaths.has(file.split("/")[0]))
      problems.push({ file, message: "takes a name the site reserves" });
    if (
      !servableFiles.test(file) ||
      file.split("/").some((segment) => !/^[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(segment))
    ) {
      problems.push({
        file,
        message:
          "is not a file the help can serve (a plain name ending in .toml, .json, .txt, .png, .jpg, .gif or .webp)",
      });
    }
  }
  for (const page of pages)
    page.heading = renderUncached(
      page.markdown,
      neutralContext(markdown, otherFiles, page.file, site),
    ).title;
  const bundle: DocsBundle = { site, nav, pages, files: [...otherFiles].sort() };
  if (configText !== undefined) bundle.config = { lines: configIndex(configText) };
  return { bundle, problems };
}

function neutralContext(
  markdown: Map<string, string>,
  files: string[],
  file: string,
  site: SiteInfo,
): RenderContext {
  const known = new Set([...markdown.keys(), ...files]);
  return { file, hasFile: (path) => known.has(path), href: () => "#", siteURL: site.url };
}

/** Searchable sections of every page: text between headings, code blocks left out. */
export function searchSections(bundle: DocsBundle): SearchSection[] {
  const manual = new Manual(bundle, siteLinks("public", bundle.site));
  return bundle.pages.flatMap((page) => {
    const title = page.heading ?? page.title;
    return sectionsOf(renderUncached(page.markdown, manual.context(page.file)).nodes).map(
      (section) => ({ path: page.path, title, ...section }),
    );
  });
}

/**
 * Every link of every page resolves on `links`' site: relative pages and
 * files exist, anchors name a heading of their page, and the manual never
 * links an absolute path. The parity of a strict documentation build.
 */
export function checkLinks(bundle: DocsBundle, links: SiteLinks): Problem[] {
  const manual = new Manual(bundle, links);
  const problems: Problem[] = [];
  const ids = new Map<string, Set<string>>();
  const rendered = bundle.pages.map((page) => {
    const result = renderUncached(page.markdown, manual.context(page.file));
    ids.set(page.path, new Set(result.ids));
    return { page, result };
  });
  for (const { page, result } of rendered) {
    if (!result.title) problems.push({ file: page.file, message: "has no level-one heading" });
    for (const link of result.links) {
      if (link.problem) {
        problems.push({ file: page.file, message: `${link.href}: ${link.problem}` });
        continue;
      }
      const target = link.target;
      if (target?.kind === "page" && target.anchor && !ids.get(target.path)?.has(target.anchor)) {
        problems.push({
          file: page.file,
          message: `${link.href}: no heading #${target.anchor} on ${target.path || "the home page"}`,
        });
      }
    }
  }
  return problems;
}
