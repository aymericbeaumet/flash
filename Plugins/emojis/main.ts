// Emoji finder, in TypeScript on Bun (one of the six deliberately
// non-Rust official plugins exercising the language-agnostic wire protocol;
// see docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
//
// Reads the Unicode-derived dataset (emoji.txt: `<glyph>\t<name>` rows) and
// the curated Slack-style shortcodes (aliases.txt: `<glyph>\t<tokens>`)
// from the plugin root, then pushes the whole set with publish() from the
// on_start hook — the catalog is host-owned and push-based, so initialize
// is answered immediately and the first paint never waits on this process.
// The dataset never changes at runtime, so there is nothing to refresh.

import { Plugin, type Row } from "flashplugin"; // resolved via host-injected NODE_PATH

const SOURCE = "emojis.glyphs"; // must name the manifest sources[].name

async function loadRows(): Promise<Row[]> {
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
  const rows: Row[] = [];
  for (const line of emojiData.split("\n")) {
    const tab = line.indexOf("\t");
    if (tab < 0) continue;
    const glyph = line.slice(0, tab).trim();
    const name = line.slice(tab + 1).trim();
    if (!glyph || !name) continue;
    const metadata: { [key: string]: string } = {
      kind: "emoji",
      subtitle: "emoji",
      payload: glyph,
    };
    const shortcodes = aliases.get(glyph);
    if (shortcodes) metadata.aliases = shortcodes;
    rows.push({ source: SOURCE, title: `${glyph} ${name}`, metadata });
  }
  return rows;
}

const plugin = new Plugin({
  onStart: async () => {
    const rows = await loadRows();
    plugin.publish(rows);
    plugin.log("info", "[emoji] dataset published", { count: rows.length });
  },
});
await plugin.serve();
