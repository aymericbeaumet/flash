import { marked } from "marked";
import type { DocTopic } from "./types";

const allowedTags = new Set(["P", "BR", "HR", "H1", "H2", "H3", "H4", "H5", "H6", "UL", "OL", "LI", "BLOCKQUOTE", "PRE", "CODE", "STRONG", "EM", "DEL", "A", "TABLE", "THEAD", "TBODY", "TR", "TH", "TD", "DETAILS", "SUMMARY", "KBD", "SPAN", "DIV", "SUP", "SUB"]);
const discardedTags = new Set(["SCRIPT", "STYLE", "IFRAME", "OBJECT", "EMBED", "SVG", "MATH", "FORM", "INPUT", "BUTTON", "IMG", "VIDEO", "AUDIO", "LINK", "META", "BASE"]);

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
      if (href.startsWith("#")) continue;
      const file = !href.includes(":") && !href.startsWith("//")
        ? href.match(/(?:^|\/)([a-z\d-]+)\.md(?:#.*)?$/i)?.[1]?.toLowerCase()
        : undefined;
      const topic = file ? keys.get(file) ?? (file === "configuration" ? "config" : file === "commands" ? "verbs" : undefined) : undefined;
      if (topic) { element.setAttribute("href", "#docs/" + encodeURIComponent(topic)); continue; }
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
    anchor.setAttribute("href", topic ? "#docs/" + encodeURIComponent(topic) : "#commands/" + encodeURIComponent(text.split(/\s/)[0]));
    code.replaceWith(anchor); anchor.append(code);
  }
  const slug = (text: string) => text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, "").replace(/\s+/g, "-");
  const localHeadings = new Map<string, string>();
  const title = template.content.querySelector("h1");
  if (title) localHeadings.set(slug(title.textContent ?? ""), "doc-title");
  title?.remove();
  const headings = Array.from(template.content.querySelectorAll("h2, h3")).map((heading, index) => {
    const id = "doc-heading-" + index;
    heading.id = id;
    const name = slug(heading.textContent ?? "");
    let key = name;
    for (let suffix = 1; localHeadings.has(key); suffix += 1) key = `${name}-${suffix}`;
    localHeadings.set(key, id);
    return { id, title: heading.textContent ?? "", level: Number(heading.tagName[1]) };
  });
  for (const anchor of Array.from(template.content.querySelectorAll('a[href^="#"]'))) {
    const href = anchor.getAttribute("href")!;
    if (/^#(?:home|docs|mappings|commands|plugins|state|logs|clipboard)(?:\/.*)?$/.test(href)) continue;
    let key = href.slice(1);
    try { key = decodeURIComponent(key); } catch { /* Invalid fragments remain unresolved. */ }
    const id = localHeadings.get(key);
    if (id) anchor.setAttribute("href", "#" + id);
    else anchor.removeAttribute("href");
  }
  return { html: template.innerHTML, headings };
}
