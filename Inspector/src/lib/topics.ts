import type { DocTopic } from "./types.ts";

export const pluginGroup = "Plugin guides";

/**
 * Guides grouped as Flash sent them: the snapshot lists built-in topics in
 * reading order with their group, and plugin topics last under one group.
 * Groups keep the order of their first topic, so the sidebar, the index and
 * previous/next links agree.
 */
export function groupTopics(docs: DocTopic[]) {
  const groups: { title: string; topics: DocTopic[] }[] = [];
  for (const doc of docs) {
    const title = doc.group || pluginGroup;
    let group = groups.find((candidate) => candidate.title === title);
    if (!group) {
      group = { title, topics: [] };
      groups.push(group);
    }
    group.topics.push(doc);
  }
  return groups;
}

/** The guide before and after `name` in reading order. */
export function neighbours(docs: DocTopic[], name: string | undefined) {
  const index = docs.findIndex((doc) => doc.name === name);
  if (index < 0) return { previous: undefined, next: undefined };
  return { previous: docs[index - 1], next: docs[index + 1] };
}
