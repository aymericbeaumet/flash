// Emoji finder, in TypeScript on Bun (one of the six deliberately
// non-Rust official plugins exercising the language-agnostic wire protocol;
// see docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
//
// Reads the Unicode-derived dataset (emoji.txt: `<glyph>\t<name>` rows) and
// the curated Slack-style shortcodes (aliases.txt: `<glyph>\t<tokens>`)
// from the plugin root at startup, publishes the whole set as the
// canonical `plugin:emojis` warm catalog BEFORE answering initialize (the
// readiness gate), and serves `sources.snapshot` from memory — the same
// contract the Rust SDK enforces. The dataset never changes at runtime, so
// there is nothing to refresh on events.

import { Plugin, type Candidate } from "./flashplugin";

const SOURCE_ID = "plugin:emojis";

async function loadCandidates(): Promise<Candidate[]> {
  const [emojiData, aliasData] = await Promise.all([
    Bun.file("emoji.txt").text(),
    Bun.file("aliases.txt").text(),
  ]);
  const aliases = new Map<string, string>();
  for (const line of aliasData.split("\n")) {
    const tab = line.indexOf("\t");
    if (tab < 0) continue;
    const glyph = line.slice(0, tab).trim();
    const tokens = line.slice(tab + 1).trim();
    if (glyph && tokens) aliases.set(glyph, tokens);
  }
  const candidates: Candidate[] = [];
  for (const line of emojiData.split("\n")) {
    const tab = line.indexOf("\t");
    if (tab < 0) continue;
    const glyph = line.slice(0, tab).trim();
    const name = line.slice(tab + 1).trim();
    if (!glyph || !name) continue;
    const metadata: { [key: string]: string } = {
      source: "emojis.glyphs",
      kind: "emoji",
      subtitle: "emoji",
      payload: glyph,
    };
    const shortcodes = aliases.get(glyph);
    if (shortcodes) metadata.aliases = shortcodes;
    candidates.push({ title: `${glyph} ${name}`, metadata });
  }
  return candidates;
}

const plugin = new Plugin();
const candidates = await loadCandidates();
// Publish before serving: initialize's published_sources must already
// carry the canonical catalog (the readiness gate).
plugin.setLocations(SOURCE_ID, candidates);
plugin.log("info", `[emoji] dataset loaded count=${candidates.length}`);
await plugin.serve();
