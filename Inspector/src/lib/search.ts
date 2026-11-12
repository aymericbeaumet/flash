import type { SearchSection } from "./docsite.ts";
import { renderUncached, sectionsOf } from "./markdown.ts";
import { paths } from "./routes.ts";
import type { CommandInfo, DocTopic, MappingRow, PluginInfo } from "./types.ts";

export interface SearchResult {
  title: string;
  summary: string;
  /** The heading the match sits under, for guides and manual pages. */
  section?: string;
  kind: "Docs" | "Guide" | "Command" | "Mapping" | "Plugin";
  icon: string;
  href: string;
  score: number;
}

interface Entry {
  title: string;
  section?: string;
  /** Lower-cased text, Markdown and URLs stripped. */
  text: string;
  summary: string;
  kind: SearchResult["kind"];
  icon: string;
  href: string;
}

export interface SearchIndex {
  entries: Entry[];
}

/** A guide split at its headings, so a match can land on the section; ids are the rendered ones. */
export function sections(doc: DocTopic): { heading?: string; id?: string; text: string }[] {
  const rendered = renderUncached(doc.body, { hasFile: () => false, href: () => undefined, siteURL: "" });
  return sectionsOf(rendered.nodes);
}

/**
 * Manual sections (from `search.json`), then the plugins' guides, commands,
 * mappings and plugins. The published site has only the manual.
 */
export function buildIndex(docs: DocTopic[], commands: CommandInfo[], rows: MappingRow[], plugins: PluginInfo[], manual: SearchSection[] = []): SearchIndex {
  const entries: Entry[] = [];
  for (const section of manual) {
    const text = `${section.heading ?? section.title} ${section.text}`;
    entries.push({ title: section.title, section: section.heading, text: (section.heading ? text : `${section.title} ${text}`).toLowerCase(), summary: section.text.slice(0, 220), kind: "Docs", icon: "docs", href: paths.docs(section.path, section.id) });
  }
  for (const doc of docs) {
    const names = `${doc.title} ${doc.name}`;
    entries.push({ title: doc.title, text: `${names} ${doc.summary}`.toLowerCase(), summary: doc.summary, kind: "Guide", icon: "docs", href: paths.docs(doc.name) });
    for (const section of sections(doc)) {
      if (!section.text && !section.heading) continue;
      entries.push({
        title: doc.title,
        section: section.heading,
        text: `${section.heading ?? ""} ${section.text}`.toLowerCase(),
        summary: section.text.slice(0, 220),
        kind: "Guide",
        icon: "docs",
        href: paths.docs(doc.name) + (section.id ? `#${encodeURIComponent(section.id)}` : ""),
      });
    }
  }
  for (const command of commands) {
    entries.push({ title: command.name, text: [command.name, command.syntax, command.description, ...(command.aliases ?? [])].join(" ").toLowerCase(), summary: command.description ?? command.source, kind: "Command", icon: "commands", href: paths.commands(command.name) });
  }
  for (const row of rows) {
    entries.push({ title: row.key, text: [row.key, row.action, row.explanation, row.origin ?? ""].join(" ").toLowerCase(), summary: row.explanation || [row.action, row.origin].filter(Boolean).join(" · "), kind: "Mapping", icon: "mappings", href: paths.mappings(row.key) });
  }
  for (const plugin of plugins) {
    entries.push({ title: plugin.name || plugin.id, text: [plugin.id, plugin.name, plugin.description].join(" ").toLowerCase(), summary: plugin.description ?? plugin.state, kind: "Plugin", icon: "plugins", href: paths.plugins(plugin.id) });
  }
  return { entries };
}

/** Every word of the query must appear; title and heading matches rank first. */
export function search(index: SearchIndex, query: string, limit = 80): SearchResult[] {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return [];
  const needle = words.join(" ").replace(/^:/, "");
  const results: SearchResult[] = [];
  const seen = new Set<string>();
  for (const entry of index.entries) {
    if (!words.every((word) => entry.text.includes(word))) continue;
    const title = entry.title.toLowerCase().replace(/^:/, "");
    const heading = (entry.section ?? "").toLowerCase();
    let score = title === needle ? 0 : title.startsWith(needle) ? 1 : title.includes(needle) ? 2 : heading.includes(needle) ? 3 : words.every((word) => title.includes(word) || heading.includes(word)) ? 4 : 5;
    if (entry.kind !== "Guide" && entry.kind !== "Docs") score += 0.5;
    const key = entry.href;
    if (seen.has(key)) continue;
    seen.add(key);
    results.push({ title: entry.title, summary: snippet(entry, words), section: entry.section, kind: entry.kind, icon: entry.icon, href: entry.href, score });
  }
  return results.sort((a, b) => a.score - b.score).slice(0, limit);
}

function snippet(entry: Entry, words: string[]): string {
  if ((entry.kind !== "Guide" && entry.kind !== "Docs") || !entry.section) return entry.summary;
  const text = entry.summary;
  const lower = text.toLowerCase();
  const at = Math.min(...words.map((word) => lower.indexOf(word)).filter((index) => index >= 0));
  if (!Number.isFinite(at) || at < 60) return text.slice(0, 160);
  return "…" + text.slice(at - 40, at + 120);
}
