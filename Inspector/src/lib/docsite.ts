import { renderUncached, routeOf, sectionsOf, type RenderContext, type Target } from "./markdown.ts";
import { hashBody } from "./reading.ts";

/**
 * The manual: `docs/*.md` ordered by `docs/nav.json`. The build bundles it
 * once (`docs.json`, `search.json` and the other files under `docs/`); the
 * resident serves that bundle at `/docs/<page>` and the published site
 * prerenders the same pages at `<site>/<page>/`. Only the spelling of a link
 * differs between the two, through `SiteLinks`.
 */

export interface SiteInfo {
  name: string;
  description: string;
  /** The published site's root URL, ending in `/`. */
  url: string;
  repository: string;
  repository_name: string;
  /** Prefix of a page's edit link: `<edit><file>`. */
  edit: string;
}

/** `docs/nav.json`: pages by file, grouped; a page may take short `aliases`. */
export type NavSource = { title: string; page: string; aliases?: string[] } | { title: string; items: NavSource[] };

/** The bundled navigation: pages by route path. */
export interface NavNode {
  title: string;
  path?: string;
  items?: NavNode[];
}

export interface ManualPage {
  /** Route path: `""`, `normal-mode`, `alternatives/neru`. */
  path: string;
  /** File under `docs/`. */
  file: string;
  /** The navigation title. */
  title: string;
  /** The page's own level-one heading. */
  heading?: string;
  /** Titles of the navigation groups above the page. */
  trail: string[];
  markdown: string;
  /**
   * `hashBody` of the page's Markdown, taken by the build: what the reader
   * compares to tell an updated page, without hashing the manual in the
   * browser.
   */
  hash: string;
  /** In the navigation, rather than `unlisted`. */
  listed: boolean;
  /**
   * Other names that route to the page (`config` for `configuration`): the
   * in-app topic names `:help <topic>` has always taken.
   */
  aliases: string[];
}

/** `docs.json`. */
export interface DocsBundle {
  site: SiteInfo;
  nav: NavNode[];
  /** Listed pages in reading order, then unlisted ones. */
  pages: ManualPage[];
  /** Other files under `docs/` that pages may link: examples, images. */
  files: string[];
  /**
   * Where each table and key of `config.default.toml` sits (`mode.normal`,
   * `mode.normal.leader`, `mode.layers.resize` from a commented example),
   * for `config:` links.
   */
  config?: { lines: Record<string, number> };
  /**
   * The commit the resident's copy was built from. Its links into the
   * repository's `main` (a source file that is not a page) pin to it, so they
   * show what this Flash runs; the published site keeps `main`.
   */
  revision?: string;
}

/** One section of a page in `search.json`. */
export interface SearchSection {
  path: string;
  title: string;
  heading?: string;
  id?: string;
  text: string;
}

export interface Problem {
  file: string;
  message: string;
}

/** Route paths a page may not take on the published site. */
const reservedPaths = new Set(["search", "404", "_app"]);
/** Files a page may link, which the resident serves as they are (`DebugServer.docsFile`). */
const servableFiles = /\.(toml|json|txt|png|jpe?g|gif|webp)$/i;
/** Generated files at the site root. */
const reservedFiles = new Set(["docs.json", "search.json", "favicon.svg", "404.html", "sitemap.xml", "robots.txt", ".nojekyll", "index.html"]);

function isNavGroup(item: NavSource): item is { title: string; items: NavSource[] } {
  return "items" in item;
}

/**
 * Bundles the manual from `nav.json` and the files under `docs/` (Markdown
 * by path with its text; other files by path). Every Markdown file is in the
 * navigation or `unlisted`, every navigation entry names a file, and no
 * page appears twice; anything else is a problem, as in a strict build.
 */
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

export function bundleDocs(navJSON: string, markdown: Map<string, string>, otherFiles: string[], configText?: string): { bundle: DocsBundle; problems: Problem[] } {
  const problems: Problem[] = [];
  const config = JSON.parse(navJSON) as { site: SiteInfo; nav: NavSource[]; unlisted?: (string | { page: string; aliases?: string[] })[] };
  const site = config.site;
  if (!site?.url?.endsWith("/")) problems.push({ file: "nav.json", message: "site.url must end with /" });
  const pages: ManualPage[] = [];
  const seen = new Set<string>();
  const add = (title: string, file: string, trail: string[], listed: boolean, aliases: string[] = []): string | undefined => {
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
    if (reservedPaths.has(path.split("/")[0])) problems.push({ file, message: `the route ${path} is reserved` });
    pages.push({ path, file, title, trail, markdown: text, hash: hashBody(text), listed, aliases });
    return path;
  };
  const walk = (items: NavSource[], trail: string[]): NavNode[] =>
    items.flatMap((item): NavNode[] => {
      if (isNavGroup(item)) return [{ title: item.title, items: walk(item.items, [...trail, item.title]) }];
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
      if (!/^[a-z0-9][a-z0-9_-]*$/.test(alias)) problems.push({ file: page.file, message: `the alias ${alias} is not one lowercase word` });
      else if (paths.has(alias) || reservedPaths.has(alias) || otherFiles.some((file) => file.split("/")[0] === alias)) problems.push({ file: page.file, message: `the alias ${alias} names another page or file` });
      else if (claimed.has(alias)) problems.push({ file: page.file, message: `the alias ${alias} also names ${claimed.get(alias)}` });
      else claimed.set(alias, page.file);
    }
  }
  for (const file of markdown.keys()) {
    if (!seen.has(file)) problems.push({ file, message: "is neither in the navigation nor unlisted in nav.json" });
  }
  for (const file of otherFiles) {
    if (reservedFiles.has(file) || reservedPaths.has(file.split("/")[0])) problems.push({ file, message: "takes a name the site reserves" });
    if (!servableFiles.test(file) || file.split("/").some((segment) => !/^[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(segment))) {
      problems.push({ file, message: "is not a file the help can serve (a plain name ending in .toml, .json, .txt, .png, .jpg, .gif or .webp)" });
    }
  }
  for (const page of pages) page.heading = renderUncached(page.markdown, neutralContext(markdown, otherFiles, page.file, site)).title;
  const bundle: DocsBundle = { site, nav, pages, files: [...otherFiles].sort() };
  if (configText !== undefined) bundle.config = { lines: configIndex(configText) };
  return { bundle, problems };
}

function neutralContext(markdown: Map<string, string>, files: string[], file: string, site: SiteInfo): RenderContext {
  const known = new Set([...markdown.keys(), ...files]);
  return { file, hasFile: (path) => known.has(path), href: () => "#", siteURL: site.url };
}

export type SiteMode = "local" | "public";

/** How a site spells the manual's pages and files. */
export interface SiteLinks {
  mode: SiteMode;
  /** The site's root path for pages: `/docs` or `/flash`. */
  root: string;
  page(path: string, anchor?: string): string;
  file(path: string): string;
}

const encodePath = (path: string) => path.split("/").map(encodeURIComponent).join("/");
const fragment = (anchor?: string) => (anchor ? `#${encodeURIComponent(anchor)}` : "");

/**
 * The resident serves the manual under `/docs` (`/docs`, `/docs/normal-mode`,
 * `/docs/examples/statusbar/flash.toml`); the published site lives at its
 * URL's path (`/flash/`, `/flash/normal-mode/`, with the same files).
 */
export function siteLinks(mode: SiteMode, site?: Pick<SiteInfo, "url">): SiteLinks {
  if (mode === "local") {
    return {
      mode,
      root: "/docs",
      page: (path, anchor) => (path ? `/docs/${encodePath(path)}` : "/docs") + fragment(anchor),
      file: (path) => `/docs/${encodePath(path)}`,
    };
  }
  const root = new URL(site?.url ?? "https://example.invalid/").pathname.replace(/\/$/, "");
  return {
    mode,
    root,
    page: (path, anchor) => `${root}/${path ? `${encodePath(path)}/` : ""}${fragment(anchor)}`,
    file: (path) => `${root}/${encodePath(path)}`,
  };
}

/** The route path a site URL path names, or null when it is outside the manual. */
export function pathOf(links: SiteLinks, pathname: string): string | null {
  const root = links.root;
  if (pathname !== root && !pathname.startsWith(`${root}/`)) return null;
  const segments = pathname.slice(root.length).split("/").filter(Boolean);
  try {
    return segments.map(decodeURIComponent).join("/");
  } catch {
    return null;
  }
}

/** The help's own pages, which only the resident has: a manual page links them as live companions. */
const livePages = /^\/(mappings|commands|plugins|state|monitors|logs|clipboard|search)?(?:[?#]|$)/;

export function isLivePath(path: string): boolean {
  return livePages.test(path);
}

export class Manual {
  readonly bundle: DocsBundle;
  readonly links: SiteLinks;
  private byPath = new Map<string, ManualPage>();
  private byAlias = new Map<string, ManualPage>();
  private known: Set<string>;
  private contexts = new Map<string, RenderContext>();

  constructor(bundle: DocsBundle, links: SiteLinks) {
    this.bundle = bundle;
    this.links = links;
    for (const page of bundle.pages) {
      this.byPath.set(page.path, page);
      for (const alias of page.aliases ?? []) this.byAlias.set(alias, page);
    }
    this.known = new Set([...bundle.pages.map((page) => page.file), ...bundle.files]);
  }

  /** A page by its path, or by one of its aliases. */
  page(path: string): ManualPage | undefined {
    const name = path.replace(/^\/+|\/+$/g, "");
    return this.byPath.get(name) ?? this.byAlias.get(name.toLowerCase());
  }

  /** Listed pages in reading order. */
  get listed(): ManualPage[] {
    return this.bundle.pages.filter((page) => page.listed);
  }

  neighbours(path: string): { previous?: ManualPage; next?: ManualPage } {
    const listed = this.listed;
    const index = listed.findIndex((page) => page.path === path);
    if (index < 0) return {};
    return { previous: listed[index - 1], next: listed[index + 1] };
  }

  hasFile(path: string): boolean {
    return this.known.has(path);
  }

  /** A target spelled for this site; undefined when it names nothing here. */
  href(target: Target): string | undefined {
    switch (target.kind) {
      case "page": return this.byPath.has(target.path) ? this.links.page(target.path, target.anchor) : undefined;
      case "file": return this.bundle.files.includes(target.path) ? this.links.file(target.path) : undefined;
      case "anchor": return `#${encodeURIComponent(target.anchor)}`;
      case "external": return this.pin(target.url);
      // Live pages exist only in the resident's help.
      case "live": return this.links.mode === "local" ? target.path + (target.anchor ? `#${encodeURIComponent(target.anchor)}` : "") : undefined;
      case "config": {
        const line = this.bundle.config?.lines[target.key];
        if (line === undefined) return undefined;
        const repository = this.bundle.site.repository.replace(/\/$/, "");
        return `${repository}/blob/${this.bundle.revision ?? "main"}/config.default.toml#L${line}`;
      }
      case "route": return undefined;
    }
  }

  /** A link into the repository's `main` pinned to the bundle's revision, when it has one. */
  private pin(url: string): string {
    const revision = this.bundle.revision;
    if (!revision) return url;
    const repository = this.bundle.site.repository.replace(/\/$/, "");
    for (const kind of ["blob", "tree"]) {
      const prefix = `${repository}/${kind}/main/`;
      if (url.startsWith(prefix)) return `${repository}/${kind}/${revision}/${url.slice(prefix.length)}`;
    }
    return url;
  }

  /** The render context of a page, stable so its renders cache. */
  context(file: string): RenderContext {
    let context = this.contexts.get(file);
    if (!context) {
      context = {
        file,
        hasFile: (path) => this.hasFile(path),
        href: (target) => this.href(target),
        // `:help <page>` in a page's code names another page, on either site.
        topic: (name) => {
          const page = this.page(name);
          return page ? this.links.page(page.path) : undefined;
        },
        isLive: isLivePath,
        siteURL: this.bundle.site.url,
      };
      this.contexts.set(file, context);
    }
    return context;
  }

  editURL(page: ManualPage): string {
    return `${this.bundle.site.edit}${page.file}`;
  }
}

/** Searchable sections of every page: text between headings, code blocks left out. */
export function searchSections(bundle: DocsBundle): SearchSection[] {
  const manual = new Manual(bundle, siteLinks("public", bundle.site));
  return bundle.pages.flatMap((page) => {
    const title = page.heading ?? page.title;
    return sectionsOf(renderUncached(page.markdown, manual.context(page.file)).nodes).map((section) => ({ path: page.path, title, ...section }));
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
        problems.push({ file: page.file, message: `${link.href}: no heading #${target.anchor} on ${target.path || "the home page"}` });
      }
    }
  }
  return problems;
}
