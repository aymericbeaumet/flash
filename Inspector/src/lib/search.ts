import type { SearchSection } from "./docsite.ts";
import { paths } from "./routes.ts";

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

export interface SearchEntry {
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
  entries: SearchEntry[];
}

/** The manual's sections (`search.json`) as entries: all the published site searches. */
export function manualEntries(manual: SearchSection[]): SearchEntry[] {
  return manual.map((section) => {
    const text = `${section.heading ?? section.title} ${section.text}`;
    return {
      title: section.title,
      section: section.heading,
      text: (section.heading ? text : `${section.title} ${text}`).toLowerCase(),
      summary: section.text.slice(0, 220),
      kind: "Docs",
      icon: "docs",
      href: paths.docs(section.path, section.id),
    };
  });
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
    let score =
      title === needle
        ? 0
        : title.startsWith(needle)
          ? 1
          : title.includes(needle)
            ? 2
            : heading.includes(needle)
              ? 3
              : words.every((word) => title.includes(word) || heading.includes(word))
                ? 4
                : 5;
    if (entry.kind !== "Guide" && entry.kind !== "Docs") score += 0.5;
    const key = entry.href;
    if (seen.has(key)) continue;
    seen.add(key);
    results.push({
      title: entry.title,
      summary: snippet(entry, words),
      section: entry.section,
      kind: entry.kind,
      icon: entry.icon,
      href: entry.href,
      score,
    });
  }
  return results.sort((a, b) => a.score - b.score).slice(0, limit);
}

function snippet(entry: SearchEntry, words: string[]): string {
  if ((entry.kind !== "Guide" && entry.kind !== "Docs") || !entry.section) return entry.summary;
  const text = entry.summary;
  const lower = text.toLowerCase();
  const at = Math.min(...words.map((word) => lower.indexOf(word)).filter((index) => index >= 0));
  if (!Number.isFinite(at) || at < 60) return text.slice(0, 160);
  return "…" + text.slice(at - 40, at + 120);
}
