import { marked } from "marked";
import { parseRoute, paths } from "./routes";
import type { DocTopic } from "./types";

const allowedTags = new Set(["P", "BR", "HR", "H1", "H2", "H3", "H4", "H5", "H6", "UL", "OL", "LI", "BLOCKQUOTE", "PRE", "CODE", "STRONG", "EM", "DEL", "A", "TABLE", "THEAD", "TBODY", "TR", "TH", "TD", "DETAILS", "SUMMARY", "KBD", "SPAN", "DIV", "SUP", "SUB"]);
const discardedTags = new Set(["SCRIPT", "STYLE", "IFRAME", "OBJECT", "EMBED", "SVG", "MATH", "FORM", "INPUT", "BUTTON", "IMG", "VIDEO", "AUDIO", "LINK", "META", "BASE"]);
/** Ids the page itself owns; headings never take them. */
const reservedIds = ["main-content"];

const slug = (text: string) => text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s+/g, "-") || "section";

export function renderMarkdown(markdown: string, docs: DocTopic[]) {
  // Plugin help is authored outside the host. Parse in an inert template and
  // admit only documentation markup, with no executable or fetching elements.
  const template = document.createElement("template");
  template.innerHTML = marked.parse(markdown, { async: false, gfm: true }) as string;
  const keys = new Map(docs.flatMap((doc) => [doc.name, ...(doc.aliases ?? [])].map((name) => [name.toLowerCase(), doc.name])));
  for (const element of Array.from(template.content.querySelectorAll("*"))) {
    if (discardedTags.has(element.tagName)) { element.remove(); continue; }
    if (!allowedTags.has(element.tagName)) { element.replaceWith(...element.childNodes); continue; }
    for (const attribute of Array.from(element.attributes)) {
      const allowed = (element.tagName === "A" && attribute.name === "href") || (["TH", "TD"].includes(element.tagName) && ["colspan", "rowspan"].includes(attribute.name));
      if (!allowed) element.removeAttribute(attribute.name);
    }
    if (element.tagName === "A") {
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
      } catch { element.removeAttribute("href"); }
    }
  }
  for (const code of Array.from(template.content.querySelectorAll("code"))) {
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
  const title = template.content.querySelector("h1");
  const titleId = title ? unique(slug(title.textContent ?? "")) : undefined;
  title?.remove();
  const headings = Array.from(template.content.querySelectorAll("h2, h3, h4")).map((heading) => {
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
  for (const anchor of Array.from(template.content.querySelectorAll('a[href^="#"]'))) {
    if (anchor.classList.contains("heading-anchor")) continue;
    let id = anchor.getAttribute("href")!.slice(1);
    try { id = decodeURIComponent(id); } catch { /* Invalid fragments remain unresolved. */ }
    if (!ids.has(id) || reservedIds.includes(id)) anchor.removeAttribute("href");
  }
  return { html: template.innerHTML, titleId, headings: headings.filter((heading) => heading.level < 4) };
}
