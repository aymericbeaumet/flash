import { paths } from "./routes.ts";
import type { CommandInfo, DocTopic, MappingRow, PluginInfo } from "./types.ts";

export interface SearchResult {
  title: string;
  summary: string;
  /** The heading the match sits under, for guides. */
  section?: string;
  kind: "Guide" | "Command" | "Mapping" | "Plugin";
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

const slug = (text: string) => text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s+/g, "-") || "section";

/** Plain words from Markdown: no links' URLs, code fences, emphasis or table pipes. */
export function plainText(markdown: string): string {
  return markdown
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/!\[[^\]]*\]\([^)]*\)/g, " ")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/https?:\/\/\S+/g, " ")
    .replace(/[`*_>|#]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Splits a guide at its headings, so a match can land on the section. */
export function sections(doc: DocTopic): { heading?: string; id?: string; text: string }[] {
  const out: { heading?: string; id?: string; text: string }[] = [];
  const ids = new Set<string>();
  let heading: string | undefined;
  let id: string | undefined;
  let buffer: string[] = [];
  const flush = () => {
    const text = plainText(buffer.join("\n"));
    if (text || heading) out.push({ heading, id, text });
    buffer = [];
  };
  for (const line of doc.body.split("\n")) {
    const match = line.match(/^(#{2,4})\s+(.*)$/);
    if (match) {
      flush();
      heading = plainText(match[2]);
      let candidate = slug(heading);
      for (let suffix = 1; ids.has(candidate); suffix += 1) candidate = `${slug(heading)}-${suffix}`;
      ids.add(candidate);
      id = candidate;
      continue;
    }
    if (/^#\s/.test(line)) continue;
    buffer.push(line);
  }
  flush();
  return out;
}

export function buildIndex(docs: DocTopic[], commands: CommandInfo[], rows: MappingRow[], plugins: PluginInfo[]): SearchIndex {
  const entries: Entry[] = [];
  for (const doc of docs) {
    const names = [doc.title, doc.name, ...(doc.aliases ?? [])].join(" ");
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
        href: paths.docs(doc.name) + (section.id ? `#${section.id}` : ""),
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
    if (entry.kind !== "Guide") score += 0.5;
    const key = entry.href;
    if (seen.has(key)) continue;
    seen.add(key);
    results.push({ title: entry.title, summary: snippet(entry, words), section: entry.section, kind: entry.kind, icon: entry.icon, href: entry.href, score });
  }
  return results.sort((a, b) => a.score - b.score).slice(0, limit);
}

function snippet(entry: Entry, words: string[]): string {
  if (entry.kind !== "Guide" || !entry.section) return entry.summary;
  const text = entry.summary;
  const lower = text.toLowerCase();
  const at = Math.min(...words.map((word) => lower.indexOf(word)).filter((index) => index >= 0));
  if (!Number.isFinite(at) || at < 60) return text.slice(0, 160);
  return "…" + text.slice(at - 40, at + 120);
}
