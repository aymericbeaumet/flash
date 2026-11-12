import { Marked, type Token, type Tokens, type TokenizerExtension } from "marked";
import { highlight } from "./highlight.ts";
import { htmlParts } from "./html-parts.ts";

/**
 * Markdown to a tree of plain values. One renderer serves the manual pages
 * (`docs/*.md`), the in-app guides and plugin help, in the browser help and
 * on the published site alike: `Markdown.svelte` mounts the tree, and the
 * site build renders the same tree on the server. No string is ever parsed
 * as HTML. Text stays text, raw HTML admits only the tags `htmlParts`
 * allows and never an attribute, and every link and image is resolved here
 * against the documentation, so a broken one is reported rather than shipped.
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

/** Ids the page itself owns; headings never take them. */
const reservedIds = ["main-content", "app"];

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

/** Python-Markdown's `unique`: a repeated id takes `_1`, `_2`… */
function uniqueId(id: string, ids: Set<string>): string {
  let candidate = id;
  while (!candidate || ids.has(candidate)) {
    const match = candidate.match(/^(.*)_([0-9]+)$/);
    candidate = match ? `${match[1]}_${Number(match[2]) + 1}` : `${candidate}_1`;
  }
  ids.add(candidate);
  return candidate;
}

/** `!!! note "Title"` over four-space-indented content, as Python-Markdown's admonition. */
const admonition: TokenizerExtension = {
  name: "admonition",
  level: "block",
  start(source) {
    return source.match(/^!!! /m)?.index;
  },
  tokenizer(source) {
    const match = /^!!! *([\w-]+)(?: +"([^"\n]*)")? *(?:\n|$)((?:(?: {4}|\t)[^\n]*(?:\n|$)|[ \t]*\n(?=(?: {4}|\t)))*)/.exec(source);
    if (!match) return undefined;
    const body = match[3].replace(/^(?: {4}|\t)/gm, "");
    return {
      type: "admonition",
      raw: match[0],
      kind: match[1].toLowerCase(),
      title: match[2] ?? match[1].charAt(0).toUpperCase() + match[1].slice(1),
      tokens: this.lexer.blockTokens(body, []),
    };
  },
};

const marked = new Marked({ gfm: true, extensions: [admonition] });

const entities: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ", copy: "©", reg: "®", trade: "™", mdash: "—", ndash: "–", hellip: "…", rarr: "→", larr: "←", times: "×", middot: "·", laquo: "«", raquo: "»" };

/** Character references in text, which an HTML renderer would leave to the browser. */
function decode(text: string): string {
  if (!text.includes("&")) return text;
  return text.replace(/&(#x[\da-f]+|#\d+|[a-z]+);/gi, (whole, name: string) => {
    if (name[0] === "#") {
      const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code < 0x110000 ? String.fromCodePoint(code) : whole;
    }
    return entities[name.toLowerCase()] ?? whole;
  });
}

const element = (tag: string, attrs?: Record<string, string>, children: MdNode[] = []): MdElement => (attrs ? { tag, attrs, children } : { tag, children });

/** Text of a subtree, as a heading's id and title read it. */
export function textOf(nodes: MdNode[]): string {
  return nodes.map((node) => (typeof node === "string" ? node : node.attrs?.class === "heading-anchor" ? "" : textOf(node.children ?? []))).join("");
}

function dirname(path: string) {
  const index = path.lastIndexOf("/");
  return index < 0 ? "" : path.slice(0, index);
}

/** Resolves `relative` against `base` inside `docs/`; null when it escapes. */
function joinPath(base: string, relative: string): string | null {
  const parts = base ? base.split("/") : [];
  for (const part of relative.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (!parts.length) return null;
      parts.pop();
    } else parts.push(part);
  }
  return parts.join("/");
}

/** The route path of a page file: a `README.md` is its directory's index. */
export function routeOf(file: string): string {
  const path = file.replace(/\.md$/, "");
  if (path === "README") return "";
  return path.endsWith("/README") ? path.slice(0, -"/README".length) : path;
}

function decodeFragment(fragment: string) {
  try { return decodeURIComponent(fragment); } catch { return fragment; }
}

class Builder {
  links: RenderedLink[] = [];
  /** Same-page anchors, checked once every heading has its id. */
  private anchors: { node: MdElement; link: RenderedLink; anchor: string }[] = [];
  private context: RenderContext;

  constructor(context: RenderContext) {
    this.context = context;
  }

  /** Resolves a destination written in the Markdown, or says why it cannot. */
  resolve(raw: string): Target | string {
    const href = raw.trim();
    if (!href) return "empty link";
    if (href.startsWith("#")) return { kind: "anchor", anchor: decodeFragment(href.slice(1)) };
    if (href.startsWith("config:")) {
      const key = href.slice("config:".length);
      return key ? { kind: "config", key } : "config: names no table or key";
    }
    const site = this.context.siteURL ? this.context.siteURL.replace(/\/?$/, "/") : undefined;
    if (site && (href.startsWith(site) || `${href}/` === site)) {
      const [path, fragment] = href.slice(site.length).split("#", 2);
      const route = path.replace(/(?:^|\/)index\.html$/, "").replace(/\/$/, "");
      const anchor = fragment ? decodeFragment(fragment) : undefined;
      if (this.pageFile(route)) return { kind: "page", path: route, anchor };
      if (this.context.hasFile(route)) return { kind: "file", path: route };
      return `no page at ${href}`;
    }
    if (/^[a-z][a-z\d+.-]*:/i.test(href)) {
      return /^(https?|mailto):/i.test(href) ? { kind: "external", url: href } : `unsupported scheme in ${href}`;
    }
    if (href.startsWith("//")) return `protocol-relative link ${href}`;
    const [beforeFragment, fragment] = href.split("#", 2);
    const anchor = fragment ? decodeFragment(fragment) : undefined;
    const pathPart = beforeFragment.split("?", 1)[0];
    if (href.startsWith("/")) {
      if (this.context.file === undefined) return { kind: "route", path: pathPart, anchor };
      const live = beforeFragment;
      if (this.context.isLive?.(live)) return { kind: "live", path: live, anchor };
      return `absolute link ${href}; link the page's file relatively, or one of the help's live pages`;
    }
    const joined = joinPath(dirname(this.context.file ?? ""), decodeFragment(pathPart));
    if (joined === null) return `${href} leaves docs/`;
    if (joined.endsWith(".md")) {
      return this.context.hasFile(joined) ? { kind: "page", path: routeOf(joined), anchor } : `missing page ${joined}`;
    }
    const index = joined ? `${joined}/README.md` : "README.md";
    if (this.context.hasFile(index)) return { kind: "page", path: routeOf(index), anchor };
    if (pathPart === "" || pathPart.endsWith("/")) return `missing page ${index}`;
    return this.context.hasFile(joined) ? { kind: "file", path: joined } : `missing file ${joined}`;
  }

  private pageFile(route: string): string | undefined {
    const files = route ? [`${route}.md`, `${route}/README.md`] : ["README.md"];
    return files.find((candidate) => this.context.hasFile(candidate));
  }

  /** Block tokens into `out`. An open raw tag (`<details>`) takes the blocks after it. */
  blocks(tokens: Token[], out: MdNode[]) {
    const stack: MdNode[][] = [out];
    const open: MdElement[] = [];
    for (const token of tokens) {
      if (token.type === "html") this.raw((token as Tokens.HTML).text, stack, open);
      else this.block(token, stack[stack.length - 1]);
    }
  }

  /** Raw HTML onto `stack`: allowed tags open and close on it, text joins whatever is open. */
  private raw(text: string, stack: MdNode[][], open: MdElement[]) {
    for (const part of htmlParts(text)) {
      const top = stack[stack.length - 1];
      if ("text" in part) {
        if (part.text.trim() || stack.length > 1) top.push(decode(part.text));
        continue;
      }
      if (part.tag === "br") {
        if (!part.close) top.push(element("br"));
        continue;
      }
      if (!part.close) {
        const node = element(part.tag);
        top.push(node);
        stack.push(node.children!);
        open.push(node);
        continue;
      }
      let index = open.length - 1;
      while (index >= 0 && open[index].tag !== part.tag) index -= 1;
      if (index >= 0) {
        open.length = index;
        stack.length = index + 1;
      }
    }
  }

  private block(token: Token, out: MdNode[]) {
    switch (token.type) {
      case "space": case "def": return;
      case "heading": {
        const heading = token as Tokens.Heading;
        out.push(element(`h${Math.min(6, heading.depth)}`, undefined, this.inline(heading.tokens)));
        return;
      }
      case "paragraph": out.push(element("p", undefined, this.inline((token as Tokens.Paragraph).tokens))); return;
      case "text": {
        const text = token as Tokens.Text;
        out.push(...(text.tokens ? this.inline(text.tokens) : [decode(text.text)]));
        return;
      }
      case "code": {
        const code = token as Tokens.Code;
        const language = code.lang?.trim().split(/\s+/)[0]?.toLowerCase() || undefined;
        const runs = highlight(code.text, language).map((run): MdNode => (run.kind ? element("span", { class: `tok-${run.kind}` }, [run.text]) : run.text));
        out.push(element("pre", language ? { "data-language": language } : undefined, [element("code", language ? { class: `language-${language}` } : undefined, runs)]));
        return;
      }
      case "blockquote": {
        const quote = element("blockquote");
        this.blocks((token as Tokens.Blockquote).tokens, quote.children!);
        out.push(quote);
        return;
      }
      case "hr": out.push(element("hr")); return;
      case "list": {
        const list = token as Tokens.List;
        const attrs = list.ordered && typeof list.start === "number" && list.start !== 1 ? { start: String(list.start) } : undefined;
        const node = element(list.ordered ? "ol" : "ul", attrs);
        for (const item of list.items) {
          const li = element("li", item.task ? { class: "task" } : undefined);
          if (item.task) li.children!.push(element("input", { type: "checkbox", disabled: "disabled", ...(item.checked ? { checked: "checked" } : {}) }), " ");
          this.blocks(item.tokens.filter((child) => child.type !== "checkbox"), li.children!);
          node.children!.push(li);
        }
        out.push(node);
        return;
      }
      case "table": {
        const table = token as Tokens.Table;
        const cell = (tag: string, value: Tokens.TableCell) => element(tag, value.align ? { class: `align-${value.align}` } : undefined, this.inline(value.tokens));
        out.push(element("table", undefined, [
          element("thead", undefined, [element("tr", undefined, table.header.map((value) => cell("th", value)))]),
          element("tbody", undefined, table.rows.map((row) => element("tr", undefined, row.map((value) => cell("td", value))))),
        ]));
        return;
      }
      case "admonition": {
        const generic = token as Tokens.Generic;
        const node = element("div", { class: `admonition ${String(generic.kind).replace(/[^\w-]/g, "")}` });
        if (generic.title) node.children!.push(element("p", { class: "admonition-title" }, [decode(String(generic.title))]));
        this.blocks(generic.tokens ?? [], node.children!);
        out.push(node);
        return;
      }
      default: return;
    }
  }

  private inline(tokens: Token[] | undefined): MdNode[] {
    const out: MdNode[] = [];
    // Inline raw tags (`<kbd>f</kbd>`) nest the run's following tokens.
    const stack: MdNode[][] = [out];
    const open: MdElement[] = [];
    for (const token of tokens ?? []) {
      const parent = stack[stack.length - 1];
      switch (token.type) {
        case "text": {
          const text = token as Tokens.Text;
          parent.push(...(text.tokens ? this.inline(text.tokens) : [decode(text.text)]));
          break;
        }
        case "escape": parent.push((token as Tokens.Escape).text); break;
        case "strong": parent.push(element("strong", undefined, this.inline((token as Tokens.Strong).tokens))); break;
        case "em": parent.push(element("em", undefined, this.inline((token as Tokens.Em).tokens))); break;
        case "del": parent.push(element("del", undefined, this.inline((token as Tokens.Del).tokens))); break;
        case "codespan": parent.push(this.codespan((token as Tokens.Codespan).text)); break;
        case "br": parent.push(element("br")); break;
        case "link": parent.push(this.link(token as Tokens.Link)); break;
        case "image": parent.push(this.image(token as Tokens.Image)); break;
        case "html": this.raw((token as Tokens.HTML).text, stack, open); break;
        default: break;
      }
    }
    return out;
  }

  private codespan(text: string): MdNode {
    const code = element("code", undefined, [text]);
    const help = text.match(/^:help\s+([\w-]+)$/i);
    // The manual links `:help <page>` to that page, on either site. A
    // plugin's guide also links a topic's own name and `:command`.
    if (this.context.file !== undefined) {
      const href = help ? this.context.topic?.(help[1].toLowerCase()) : undefined;
      return href ? element("a", { href }, [code]) : code;
    }
    const href = this.context.topic?.((help?.[1] ?? text).toLowerCase())
      ?? (/^:[a-z][\w-]*(\s.*)?$/i.test(text) ? this.context.command?.(text.split(/\s/)[0]) : undefined);
    return href ? element("a", { href }, [code]) : code;
  }

  private link(token: Tokens.Link): MdNode {
    const children = this.inline(token.tokens);
    const record: RenderedLink = { href: token.href };
    this.links.push(record);
    const resolved = this.resolve(token.href);
    if (typeof resolved === "string") {
      record.problem = resolved;
      return element("a", undefined, children);
    }
    record.target = resolved;
    const href = this.context.href(resolved);
    // A live page the site does not have reads as its text.
    if (href === undefined && resolved.kind === "live") return element("span", { class: "live-link", title: "A live page of Flash's own help (? in NORMAL or :help)" }, children);
    if (href === undefined) {
      record.problem = resolved.kind === "config" ? `no ${resolved.key} in config.default.toml` : `${token.href} has no page on this site`;
      return element("a", undefined, children);
    }
    const attrs: Record<string, string> = { href };
    if (token.title) attrs.title = decode(token.title);
    if (resolved.kind === "external" || resolved.kind === "config") {
      attrs.target = "_blank";
      attrs.rel = "noopener noreferrer";
      try { attrs["data-external"] = new URL(href).host; } catch { attrs["data-external"] = ""; }
    }
    const node = element("a", attrs, children);
    if (resolved.kind === "anchor") this.anchors.push({ node, link: record, anchor: resolved.anchor });
    return node;
  }

  private image(token: Tokens.Image): MdNode {
    const alt = decode(token.text);
    // Only the manual's own files load; a remote or guide image is its text.
    if (this.context.file === undefined) return alt;
    const record: RenderedLink = { href: token.href };
    this.links.push(record);
    const resolved = this.resolve(token.href);
    if (typeof resolved === "string") {
      record.problem = resolved;
      return alt;
    }
    record.target = resolved;
    if (resolved.kind !== "file") {
      record.problem = `image ${token.href} is not a file under docs/`;
      return alt;
    }
    const src = this.context.href(resolved);
    if (src === undefined) {
      record.problem = `${token.href} has no file on this site`;
      return alt;
    }
    return element("img", { src, alt, loading: "lazy", ...(token.title ? { title: decode(token.title) } : {}) });
  }

  /** A same-page anchor that names no heading loses its link. */
  checkAnchors(ids: Set<string>) {
    for (const { node, link, anchor } of this.anchors) {
      if (ids.has(anchor) && !reservedIds.includes(anchor)) continue;
      delete node.attrs!.href;
      link.problem = `no heading #${anchor} on this page`;
    }
  }
}

/** Assigns heading ids and permalinks, and lifts the title out of the body. */
function finish(nodes: MdNode[], builder: Builder): Rendered {
  const ids = new Set(reservedIds);
  const headings: Heading[] = [];
  let title: string | undefined;
  let titleId: string | undefined;
  const walk = (list: MdNode[]): MdNode[] => {
    const kept: MdNode[] = [];
    for (const node of list) {
      if (typeof node === "string") { kept.push(node); continue; }
      const level = /^h([1-6])$/.exec(node.tag)?.[1];
      if (level) {
        const text = textOf(node.children ?? []).trim();
        const id = uniqueId(slugify(text), ids);
        if (level === "1" && title === undefined) {
          title = text;
          titleId = id;
          continue;
        }
        node.attrs = { ...node.attrs, id };
        node.children = [...(node.children ?? []), element("a", { class: "heading-anchor", href: `#${id}`, "aria-label": `Link to “${text}”` }, ["#"])];
        if (level === "2" || level === "3") headings.push({ id, title: text, level: Number(level) });
        kept.push(node);
        continue;
      }
      if (node.children && node.tag !== "pre") node.children = walk(node.children);
      kept.push(node);
    }
    return kept;
  };
  const body = walk(nodes);
  builder.checkAnchors(ids);
  return { nodes: body, title, titleId, headings, ids: [...ids].filter((id) => !reservedIds.includes(id)), links: builder.links };
}

/** Renders without the cache; the site build checks every page through it. */
export function renderUncached(markdown: string, context: RenderContext): Rendered {
  const builder = new Builder(context);
  const nodes: MdNode[] = [];
  builder.blocks(marked.lexer(markdown), nodes);
  return finish(nodes, builder);
}

/** A body that did not change renders once per context. */
const caches = new WeakMap<RenderContext, Map<string, Rendered>>();
const cacheLimit = 96;

export function renderMarkdown(markdown: string, context: RenderContext): Rendered {
  let cache = caches.get(context);
  if (!cache) caches.set(context, (cache = new Map()));
  const hit = cache.get(markdown);
  if (hit) return hit;
  const rendered = renderUncached(markdown, context);
  if (cache.size >= cacheLimit) cache.delete(cache.keys().next().value!);
  cache.set(markdown, rendered);
  return rendered;
}

const inlineTags = new Set(["a", "code", "strong", "em", "del", "span", "kbd", "sup", "sub", "img"]);

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
      if (typeof node === "string") { current.text += node; continue; }
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
