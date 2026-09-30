import type { DocTopic } from "./types";

const groups = [
  { title: "Start here", names: ["getting-started", "overview", "normal-mode", "mappings"] },
  { title: "Move & discover", names: ["hints", "mouse-grid", "flashlight", "verbs"] },
  { title: "Make it yours", names: ["config", "statusbar", "status-format", "widgets", "popups"] },
  { title: "Extend & understand", names: ["plugins", "privacy", "troubleshooting", "development"] },
];

export function groupTopics(docs: DocTopic[]) {
  const known = new Set(groups.flatMap((group) => group.names));
  return [
    ...groups.map((group) => ({ title: group.title, topics: group.names.flatMap((name) => docs.filter((doc) => doc.name === name)) })),
    { title: "Plugin guides", topics: docs.filter((doc) => !known.has(doc.name)).sort((a, b) => a.title.localeCompare(b.title)) },
  ].filter((group) => group.topics.length > 0);
}
