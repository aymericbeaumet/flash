/**
 * The tree a rendered page is, and what reads one or names its parts without
 * the lexer: `markdown.ts` builds the tree from Markdown, `Markdown.svelte`
 * mounts it, and the manual, the search and the site build walk it.
 */

export type MdElement = { tag: string; attrs?: Record<string, string>; children?: MdNode[] };
export type MdNode = string | MdElement;

export interface Heading {
  id: string;
  title: string;
  level: number;
}

/** Where a link or image leads, before a site spells it. */
export type Target =
  /** A manual page by its route path (`""`, `normal-mode`, `alternatives/neru`). */
  | { kind: "page"; path: string; anchor?: string }
  /** Another file under `docs/` (an example TOML, an image). */
  | { kind: "file"; path: string }
  /** A heading on this page. */
  | { kind: "anchor"; anchor: string }
  /** An app path written in a plugin's guide (`/mappings`, `/docs/hints`). */
  | { kind: "route"; path: string; anchor?: string }
  /** One of the help's live pages (`/mappings`) linked from the manual: a link in the resident, text on the published site. */
  | { kind: "live"; path: string; anchor?: string }
  /**
   * A table or key of the reference file, `config:mode.normal.leader`: its
   * line in `config.default.toml` on GitHub, which the strict build checks.
   */
  | { kind: "config"; key: string }
  | { kind: "external"; url: string };

export interface RenderContext {
  /**
   * The page's file under `docs/` (`alternatives/neru.md`); its relative
   * links resolve against it and an absolute path is an error, as in the
   * manual. Absent for in-app guides, whose absolute paths are app routes
   * and whose relative `.md` links name manual pages.
   */
  file?: string;
  /** Whether `docs/<path>` exists: a page (`.md`) or another file. */
  hasFile(path: string): boolean;
  /** The site's spelling of a target, or undefined when it has none there. */
  href(target: Target): string | undefined;
  /** `:help <topic>` in code; in a plugin's guide, also a topic's own name. */
  topic?(name: string): string | undefined;
  /** Whether an absolute path in a manual page is one of the help's live pages. */
  isLive?(path: string): boolean;
  /** `:command` in code, in guides only. */
  command?(name: string): string | undefined;
  /** The published site's root URL; a link into it is an internal link. Empty when unknown. */
  siteURL: string;
}

export interface RenderedLink {
  href: string;
  target?: Target;
  /** Why the link was dropped. */
  problem?: string;
}

export interface Rendered {
  nodes: MdNode[];
  /** The first level-one heading, which the page shows as its title. */
  title?: string;
  titleId?: string;
  /** Level-two and level-three headings, for the outline. */
  headings: Heading[];
  /** Every heading id: the targets of `#anchor` links. */
  ids: string[];
  links: RenderedLink[];
}

/**
 * Heading ids follow Python-Markdown's `toc` slugify, which the published
 * manual has always used: accents fold to ASCII, other non-ASCII and
 * punctuation drop, runs of spaces and hyphens become one hyphen.
 */
export function slugify(text: string): string {
  return text
    .normalize("NFKD")
    .replace(/[^\x00-\x7f]/g, "")
    .replace(/[^\w\s-]/g, "")
    .trim()
    .toLowerCase()
    .replace(/[-\s]+/g, "-");
}

/** Text of a subtree, as a heading's id and title read it. */
export function textOf(nodes: MdNode[]): string {
  return nodes
    .map((node) =>
      typeof node === "string"
        ? node
        : node.attrs?.class === "heading-anchor"
          ? ""
          : textOf(node.children ?? []),
    )
    .join("");
}

/** The route path of a page file: a `README.md` is its directory's index. */
export function routeOf(file: string): string {
  const path = file.replace(/\.md$/, "");
  if (path === "README") return "";
  return path.endsWith("/README") ? path.slice(0, -"/README".length) : path;
}

const inlineTags = new Set([
  "a",
  "code",
  "strong",
  "em",
  "del",
  "span",
  "kbd",
  "sup",
  "sub",
  "img",
]);

/** A rendered page split at its headings (levels two to four), code blocks left out, for search. */
export function sectionsOf(nodes: MdNode[]): { heading?: string; id?: string; text: string }[] {
  const out: { heading?: string; id?: string; text: string }[] = [];
  let current: { heading?: string; id?: string; text: string } = { text: "" };
  const flush = () => {
    current.text = current.text.replace(/\s+/g, " ").trim();
    if (current.text || current.heading) out.push(current);
  };
  const visit = (list: MdNode[]) => {
    for (const node of list) {
      if (typeof node === "string") {
        current.text += node;
        continue;
      }
      if (/^h[2-4]$/.test(node.tag) && node.attrs?.id) {
        flush();
        current = { heading: textOf(node.children ?? []).trim(), id: node.attrs.id, text: "" };
        continue;
      }
      if (node.tag === "pre" || node.attrs?.class === "heading-anchor") continue;
      visit(node.children ?? []);
      if (!inlineTags.has(node.tag)) current.text += " ";
    }
  };
  visit(nodes);
  flush();
  return out;
}
