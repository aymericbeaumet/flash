import table from "./help-routes.json" with { type: "json" };
import type { RenderContext, Target } from "./markdown-tree.ts";

/**
 * The manual: `docs/*.md` ordered by `docs/nav.json`. The build bundles it
 * once (`docs.json`, `search.json` and the other files under `docs/`); the
 * resident serves that bundle at `/docs/<page>` and the published site
 * prerenders the same pages at `<site>/<page>/`, where a page carries its
 * article as HTML and reads the navigation (`DocsIndex`) from one asset every
 * page shares, with the search sections in two more (`src/site/assets.ts`).
 * Only the spelling of a link differs between the two, through `SiteLinks`.
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

/** The bundled navigation: pages by route path. */
export interface NavNode {
  title: string;
  path?: string;
  items?: NavNode[];
}

/** What the navigation knows of a page: where it is, what it is called and what leads to it. */
export interface PageEntry {
  /** Route path: `""`, `normal-mode`, `alternatives/neru`. */
  path: string;
  /** The navigation title. */
  title: string;
  /** The page's own level-one heading. */
  heading?: string;
  /** Titles of the navigation groups above the page. */
  trail: string[];
  /** In the navigation, rather than `unlisted`. */
  listed: boolean;
  /**
   * Other names that route to the page (`config` for `configuration`): the
   * in-app topic names `:help <topic>` has always taken.
   */
  aliases: string[];
}

export interface ManualPage extends PageEntry {
  /** File under `docs/`. */
  file: string;
  markdown: string;
  /**
   * `hashBody` of the page's Markdown, taken by the build: what the reader
   * compares to tell an updated page, without hashing the manual in the
   * browser.
   */
  hash: string;
}

/** The manual without its text: the published site's navigation asset. */
export interface DocsIndex {
  site: SiteInfo;
  nav: NavNode[];
  /** Listed pages in reading order, then unlisted ones. */
  pages: PageEntry[];
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

export function docsIndex(bundle: DocsBundle): DocsIndex {
  return {
    site: bundle.site,
    nav: bundle.nav,
    pages: bundle.pages.map(({ path, title, heading, trail, listed, aliases }) => ({
      path,
      title,
      heading,
      trail,
      listed,
      aliases,
    })),
  };
}

/** One section of a page, as search reads it: the resident's `search.json`, the published site's two files. */
export interface SearchSection {
  path: string;
  title: string;
  heading?: string;
  id?: string;
  text: string;
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
export const livePageNames: readonly string[] = table.pages.filter((name) => name !== "docs");
const livePages = new RegExp(`^/(${livePageNames.join("|")})?(?:[?#]|$)`);

export function isLivePath(path: string): boolean {
  return livePages.test(path);
}

/** The manual's pages by path and alias, in reading order: all a sidebar, a path or a title needs. */
export class ManualIndex<Page extends PageEntry = PageEntry> {
  readonly site: SiteInfo;
  readonly nav: NavNode[];
  readonly pages: Page[];
  protected byPath = new Map<string, Page>();
  private byAlias = new Map<string, Page>();

  constructor(index: { site: SiteInfo; nav: NavNode[]; pages: Page[] }) {
    this.site = index.site;
    this.nav = index.nav;
    this.pages = index.pages;
    for (const page of index.pages) {
      this.byPath.set(page.path, page);
      for (const alias of page.aliases ?? []) this.byAlias.set(alias, page);
    }
  }

  /** A page by its path, or by one of its aliases. */
  page(path: string): Page | undefined {
    const name = path.replace(/^\/+|\/+$/g, "");
    return this.byPath.get(name) ?? this.byAlias.get(name.toLowerCase());
  }

  /** Listed pages in reading order. */
  get listed(): Page[] {
    return this.pages.filter((page) => page.listed);
  }

  neighbours(path: string): { previous?: Page; next?: Page } {
    const listed = this.listed;
    const index = listed.findIndex((page) => page.path === path);
    if (index < 0) return {};
    return { previous: listed[index - 1], next: listed[index + 1] };
  }
}

/** The whole manual: every page's text, and how this site spells a link. */
export class Manual extends ManualIndex<ManualPage> {
  readonly bundle: DocsBundle;
  readonly links: SiteLinks;
  private known: Set<string>;
  private contexts = new Map<string, RenderContext>();

  constructor(bundle: DocsBundle, links: SiteLinks) {
    super(bundle);
    this.bundle = bundle;
    this.links = links;
    this.known = new Set([...bundle.pages.map((page) => page.file), ...bundle.files]);
  }

  hasFile(path: string): boolean {
    return this.known.has(path);
  }

  /** A target spelled for this site; undefined when it names nothing here. */
  href(target: Target): string | undefined {
    switch (target.kind) {
      case "page":
        return this.byPath.has(target.path)
          ? this.links.page(target.path, target.anchor)
          : undefined;
      case "file":
        return this.bundle.files.includes(target.path) ? this.links.file(target.path) : undefined;
      case "anchor":
        return `#${encodeURIComponent(target.anchor)}`;
      case "external":
        return this.pin(target.url);
      // Live pages exist only in the resident's help.
      case "live":
        return this.links.mode === "local"
          ? target.path + (target.anchor ? `#${encodeURIComponent(target.anchor)}` : "")
          : undefined;
      case "config": {
        const line = this.bundle.config?.lines[target.key];
        if (line === undefined) return undefined;
        const repository = this.bundle.site.repository.replace(/\/$/, "");
        return `${repository}/blob/${this.bundle.revision ?? "main"}/config.default.toml#L${line}`;
      }
      case "route":
        return undefined;
    }
  }

  /** A link into the repository's `main` pinned to the bundle's revision, when it has one. */
  private pin(url: string): string {
    const revision = this.bundle.revision;
    if (!revision) return url;
    const repository = this.bundle.site.repository.replace(/\/$/, "");
    for (const kind of ["blob", "tree"]) {
      const prefix = `${repository}/${kind}/main/`;
      if (url.startsWith(prefix))
        return `${repository}/${kind}/${revision}/${url.slice(prefix.length)}`;
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
