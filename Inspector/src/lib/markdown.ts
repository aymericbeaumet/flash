import { marked, type Token, type Tokens } from "marked";
import { htmlParts } from "./html-parts";
import { parseRoute, paths } from "./routes";
import type { DocTopic } from "./types";

/** Ids the page itself owns; headings never take them. */
const reservedIds = ["main-content"];

const slug = (text: string) => text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s+/g, "-") || "section";

export interface Rendered {
  /** The guide as nodes; a consumer mounts a clone of it. */
  fragment: DocumentFragment;
  titleId: string | undefined;
  headings: { id: string; title: string; level: number }[];
}

/** Every snapshot carries every guide; a body that did not change renders once. */
const cache = new Map<string, Rendered>();
const cacheLimit = 64;

export function renderMarkdown(markdown: string, docs: DocTopic[]): Rendered {
  const key = `${docs.length}\u0000${markdown}`;
  const hit = cache.get(key);
  if (hit) return hit;
  const rendered = renderUncached(markdown, docs);
  if (cache.size >= cacheLimit) cache.delete(cache.keys().next().value!);
  cache.set(key, rendered);
  return rendered;
}

/** Builds DOM nodes from Marked's tokens. No string is ever parsed as HTML:
 * text enters as text nodes, and raw HTML in a guide (authored outside the
 * host, for plugin help) admits only the tags `htmlParts` allows, without
 * attributes. Open raw tags span blocks (`<details>` around paragraphs). */
class Builder {
  private stack: Node[];

  constructor(root: DocumentFragment) {
    this.stack = [root];
  }

  private get parent(): Node {
    return this.stack[this.stack.length - 1];
  }

  private element<K extends keyof HTMLElementTagNameMap>(tag: K, parent: Node = this.parent): HTMLElementTagNameMap[K] {
    const node = document.createElement(tag);
    parent.appendChild(node);
    return node;
  }

  private text(text: string, parent: Node = this.parent) {
    parent.appendChild(document.createTextNode(text));
  }

  /** Raw HTML into `stack`: allowed tags open and close on it, text joins
   * whatever is open. Block-level raw HTML uses the builder's own stack, so
   * `<details>` can wrap paragraphs; inline raw HTML uses its run's stack. */
  private raw(text: string, stack: Node[]) {
    for (const part of htmlParts(text)) {
      const top = stack[stack.length - 1];
      if ("text" in part) { this.text(part.text, top); continue; }
      if (part.tag === "br") { if (!part.close) top.appendChild(document.createElement("br")); continue; }
      if (!part.close) {
        const node = document.createElement(part.tag);
        top.appendChild(node);
        stack.push(node);
        continue;
      }
      let index = stack.length - 1;
      while (index > 0 && !(stack[index] instanceof Element && (stack[index] as Element).tagName.toLowerCase() === part.tag)) index -= 1;
      if (index > 0) stack.length = index;
    }
  }

  blocks(tokens: Token[]) {
    for (const token of tokens) this.block(token);
  }

  private block(token: Token) {
    switch (token.type) {
      case "space": return;
      case "heading": {
        const heading = token as Tokens.Heading;
        this.inline(heading.tokens, this.element(`h${Math.min(6, heading.depth)}` as "h1"));
        return;
      }
      case "paragraph": this.inline((token as Tokens.Paragraph).tokens, this.element("p")); return;
      case "text": {
        const text = token as Tokens.Text;
        if (text.tokens) this.inline(text.tokens, this.parent);
        else this.text(text.text);
        return;
      }
      case "code": {
        const pre = this.element("pre");
        this.element("code", pre).textContent = (token as Tokens.Code).text;
        return;
      }
      case "blockquote": {
        const quote = this.element("blockquote");
        this.stack.push(quote);
        this.blocks((token as Tokens.Blockquote).tokens);
        this.stack.pop();
        return;
      }
      case "hr": this.element("hr"); return;
      case "list": {
        const list = token as Tokens.List;
        const node = this.element(list.ordered ? "ol" : "ul");
        if (list.ordered && typeof list.start === "number" && list.start !== 1) node.setAttribute("start", String(list.start));
        for (const item of list.items) {
          const li = this.element("li", node);
          this.stack.push(li);
          this.blocks(item.tokens);
          this.stack.pop();
        }
        return;
      }
      case "table": {
        const table = token as Tokens.Table;
        const node = this.element("table");
        const head = this.element("tr", this.element("thead", node));
        for (const cell of table.header) this.inline(cell.tokens, this.element("th", head));
        const body = this.element("tbody", node);
        for (const row of table.rows) {
          const tr = this.element("tr", body);
          for (const cell of row) this.inline(cell.tokens, this.element("td", tr));
        }
        return;
      }
      case "html": this.raw((token as Tokens.HTML).text, this.stack); return;
      default: return;
    }
  }

  private inline(tokens: Token[] | undefined, root: Node) {
    // Inline raw tags (`<kbd>f</kbd>`) nest the run's following tokens.
    const stack: Node[] = [root];
    for (const token of tokens ?? []) {
      const parent = stack[stack.length - 1];
      switch (token.type) {
        case "text": {
          const text = token as Tokens.Text;
          if (text.tokens) this.inline(text.tokens, parent);
          else this.text(text.text, parent);
          break;
        }
        case "escape": this.text((token as Tokens.Escape).text, parent); break;
        case "strong": this.inline((token as Tokens.Strong).tokens, this.element("strong", parent)); break;
        case "em": this.inline((token as Tokens.Em).tokens, this.element("em", parent)); break;
        case "del": this.inline((token as Tokens.Del).tokens, this.element("del", parent)); break;
        case "codespan": this.element("code", parent).textContent = (token as Tokens.Codespan).text; break;
        case "br": this.element("br", parent); break;
        case "link": {
          const link = token as Tokens.Link;
          const anchor = this.element("a", parent);
          anchor.setAttribute("href", link.href);
          this.inline(link.tokens, anchor);
          break;
        }
        case "image": this.text((token as Tokens.Image).text, parent); break;
        case "html": this.raw((token as Tokens.HTML).text, stack); break;
        default: break;
      }
    }
  }
}

function renderUncached(markdown: string, docs: DocTopic[]): Rendered {
  const fragment = document.createDocumentFragment();
  new Builder(fragment).blocks(marked.lexer(markdown, { gfm: true }));
  const keys = new Map(docs.flatMap((doc) => [doc.name, ...(doc.aliases ?? [])].map((name) => [name.toLowerCase(), doc.name])));
  for (const element of Array.from(fragment.querySelectorAll("a"))) {
    const href = element.getAttribute("href") ?? "";
    // In-page anchors resolve against the headings below.
    if (href.startsWith("#")) continue;
    // Other help pages, by path.
    if (href.startsWith("/") && !href.startsWith("//")) {
      const url = new URL(href, location.origin);
      if (parseRoute(url).page === "not-found") element.removeAttribute("href");
      continue;
    }
    // A repository guide (`normal-mode.md#section`) opens its browser topic.
    const file = !href.includes(":") && !href.startsWith("//")
      ? href.match(/(?:^|\/)([a-z\d-]+)\.md(#.*)?$/i)
      : null;
    const topic = file ? keys.get(file[1].toLowerCase()) ?? (file[1].toLowerCase() === "configuration" ? "config" : file[1].toLowerCase() === "commands" ? "verbs" : undefined) : undefined;
    if (topic) { element.setAttribute("href", paths.docs(topic) + (file?.[2] ?? "")); continue; }
    try {
      const url = new URL(href);
      if (!["http:", "https:", "mailto:"].includes(url.protocol)) throw new Error("Unsupported link");
      element.setAttribute("target", "_blank");
      element.setAttribute("rel", "noopener noreferrer");
      element.setAttribute("data-external", url.host);
    } catch { element.removeAttribute("href"); }
  }
  for (const code of Array.from(fragment.querySelectorAll("code"))) {
    if (code.closest("pre, a")) continue;
    const text = code.textContent ?? "";
    const help = text.match(/^:help\s+([\w-]+)$/i);
    const topic = keys.get((help?.[1] ?? text).toLowerCase());
    const command = /^:[a-z][\w-]*(\s.*)?$/i.test(text);
    if (!topic && !command) continue;
    const anchor = document.createElement("a");
    anchor.setAttribute("href", topic ? paths.docs(topic) : paths.commands(text.split(/\s/)[0]));
    code.replaceWith(anchor); anchor.append(code);
  }
  // Headings take GitHub-style slugs, so `/docs/<topic>#<heading>` links and
  // the Markdown's own `#heading` references land on them.
  const ids = new Set(reservedIds);
  const unique = (name: string) => {
    let id = name;
    for (let suffix = 1; ids.has(id); suffix += 1) id = `${name}-${suffix}`;
    ids.add(id);
    return id;
  };
  const title = fragment.querySelector("h1");
  const titleId = title ? unique(slug(title.textContent ?? "")) : undefined;
  title?.remove();
  const headings = Array.from(fragment.querySelectorAll("h2, h3, h4")).map((heading) => {
    const text = heading.textContent ?? "";
    heading.id = unique(slug(text));
    const link = document.createElement("a");
    link.className = "heading-anchor";
    link.setAttribute("href", "#" + heading.id);
    link.setAttribute("aria-label", `Link to “${text}”`);
    link.textContent = "#";
    heading.append(link);
    return { id: heading.id, title: text, level: Number(heading.tagName[1]) };
  });
  for (const anchor of Array.from(fragment.querySelectorAll('a[href^="#"]'))) {
    if (anchor.classList.contains("heading-anchor")) continue;
    let id = anchor.getAttribute("href")!.slice(1);
    try { id = decodeURIComponent(id); } catch { /* Invalid fragments remain unresolved. */ }
    if (!ids.has(id) || reservedIds.includes(id)) anchor.removeAttribute("href");
  }
  return { fragment, titleId, headings: headings.filter((heading) => heading.level < 4) };
}
