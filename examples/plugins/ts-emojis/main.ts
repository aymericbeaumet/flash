// TypeScript (Bun) port of the bundled emojis plugin (Plugins/emojis),
// shrunk to a curated dataset so the example stays self-contained. The
// interesting part is the warm-catalog contract: the canonical
// `plugin:ts-emojis` catalog is published BEFORE the serve loop answers
// initialize, so the readiness gate (`published_sources`) holds, and
// `sources.snapshot` answers from memory with no I/O — same rules as the
// Rust SDK enforces.

import { Plugin, type Candidate } from "./flashplugin";

const SOURCE_ID = "plugin:ts-emojis";

// glyph, name, space-separated shortcode aliases
const EMOJIS: Array<[string, string, string]> = [
  ["😀", "grinning face", "grinning smile"],
  ["😂", "face with tears of joy", "joy lol"],
  ["🤣", "rolling on the floor laughing", "rofl"],
  ["😊", "smiling face with smiling eyes", "blush"],
  ["😍", "smiling face with heart-eyes", "heart_eyes love"],
  ["🤔", "thinking face", "thinking hmm"],
  ["😅", "grinning face with sweat", "sweat_smile"],
  ["😭", "loudly crying face", "sob cry"],
  ["🙏", "folded hands", "pray thanks please"],
  ["👍", "thumbs up", "thumbsup +1 like"],
  ["👎", "thumbs down", "thumbsdown -1"],
  ["🔥", "fire", "fire lit"],
  ["🎉", "party popper", "tada party celebrate"],
  ["❤️", "red heart", "heart love"],
  ["💀", "skull", "skull dead"],
  ["✨", "sparkles", "sparkles magic"],
  ["🚀", "rocket", "rocket ship launch"],
  ["👀", "eyes", "eyes looking"],
  ["💯", "hundred points", "100 hundred"],
  ["🐛", "bug", "bug insect"],
  ["🐞", "lady beetle", "ladybug"],
  ["⚡", "high voltage", "zap lightning flash"],
  ["🧠", "brain", "brain smart"],
  ["🤝", "handshake", "handshake deal"],
  ["🙌", "raising hands", "raised_hands praise"],
  ["😴", "sleeping face", "sleeping zzz tired"],
  ["🤯", "exploding head", "mind_blown exploding"],
  ["😱", "face screaming in fear", "scream"],
  ["🥳", "partying face", "partying celebrate"],
  ["😎", "smiling face with sunglasses", "cool sunglasses"],
  ["🍕", "pizza", "pizza food"],
  ["☕", "hot beverage", "coffee tea"],
  ["🍺", "beer mug", "beer"],
  ["🌈", "rainbow", "rainbow pride"],
  ["☀️", "sun", "sunny sun"],
  ["🌙", "crescent moon", "moon night"],
  ["⭐", "star", "star"],
  ["✅", "check mark button", "check done yes"],
  ["❌", "cross mark", "x no wrong"],
  ["⚠️", "warning", "warning caution"],
  ["❓", "red question mark", "question"],
  ["💡", "light bulb", "bulb idea"],
  ["🔒", "locked", "lock secure"],
  ["🔑", "key", "key password"],
  ["⌛", "hourglass done", "hourglass wait"],
  ["📌", "pushpin", "pin pushpin"],
  ["📝", "memo", "memo note"],
  ["📦", "package", "package box ship"],
  ["🛠️", "hammer and wrench", "tools fix"],
  ["🧪", "test tube", "test experiment"],
];

function candidates(): Candidate[] {
  return EMOJIS.map(([glyph, name, aliases]) => ({
    title: `${glyph} ${name}`,
    metadata: {
      source: "ts-emojis.glyphs",
      kind: "emoji",
      subtitle: "emoji (ts)",
      payload: glyph,
      aliases,
    },
  }));
}

const plugin = new Plugin();
// Publish before serving: initialize's published_sources must already
// contain the canonical catalog (the readiness gate).
plugin.setLocations(SOURCE_ID, candidates());
plugin.log("info", `[ts-emojis] dataset loaded count=${EMOJIS.length}`);
await plugin.serve();
