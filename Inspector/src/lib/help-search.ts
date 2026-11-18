import type { SearchSection } from "./docsite.ts";
import { renderUncached } from "./markdown.ts";
import { sectionsOf } from "./markdown-tree.ts";
import { paths } from "./routes.ts";
import { manualEntries, type SearchIndex } from "./search.ts";
import type { CommandInfo, DocTopic, MappingRow, PluginInfo } from "./types.ts";

/** A guide split at its headings, so a match can land on the section; ids are the rendered ones. */
export function sections(doc: DocTopic): { heading?: string; id?: string; text: string }[] {
  const rendered = renderUncached(doc.body, {
    hasFile: () => false,
    href: () => undefined,
    siteURL: "",
  });
  return sectionsOf(rendered.nodes);
}

/**
 * What the resident's help searches: the manual's sections (from
 * `search.json`), then the plugins' guides, commands, mappings and plugins.
 */
export function buildIndex(
  docs: DocTopic[],
  commands: CommandInfo[],
  rows: MappingRow[],
  plugins: PluginInfo[],
  manual: SearchSection[] = [],
): SearchIndex {
  const entries = manualEntries(manual);
  for (const doc of docs) {
    const names = `${doc.title} ${doc.name}`;
    entries.push({
      title: doc.title,
      text: `${names} ${doc.summary}`.toLowerCase(),
      summary: doc.summary,
      kind: "Guide",
      icon: "docs",
      href: paths.docs(doc.name),
    });
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
    entries.push({
      title: command.name,
      text: [command.name, command.syntax, command.description, ...(command.aliases ?? [])]
        .join(" ")
        .toLowerCase(),
      summary: command.description ?? command.source,
      kind: "Command",
      icon: "commands",
      href: paths.commands(command.name),
    });
  }
  for (const row of rows) {
    entries.push({
      title: row.key,
      text: [row.key, row.action, row.explanation, row.origin ?? ""].join(" ").toLowerCase(),
      summary: row.explanation || [row.action, row.origin].filter(Boolean).join(" · "),
      kind: "Mapping",
      icon: "mappings",
      href: paths.mappings(row.key),
    });
  }
  for (const plugin of plugins) {
    entries.push({
      title: plugin.name || plugin.id,
      text: [plugin.id, plugin.name, plugin.description].join(" ").toLowerCase(),
      summary: plugin.description ?? plugin.state,
      kind: "Plugin",
      icon: "plugins",
      href: paths.plugins(plugin.id),
    });
  }
  return { entries };
}
