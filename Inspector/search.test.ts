import assert from "node:assert/strict";
import test from "node:test";
import { buildIndex, plainText, search, sections } from "./src/lib/search.ts";
import type { DocTopic } from "./src/lib/types.ts";

const hints: DocTopic = {
  name: "hints",
  title: "Hints",
  summary: "Label controls, then type a label.",
  body: "# Hints\n\nPress the hotkey.\n\n## Right-click and drag\n\nUse `cf` for a context menu, see [the repo](https://github.com/aymericbeaumet/flash).\n\n## Scope\n\n`--scope=screen` labels every app.",
};
const grid: DocTopic = { name: "mouse-grid", title: "Mouse grid", summary: "Reach any position.", body: "# Grid\n\nThe keyboard-shaped grid. Press a key, then refine." };

test("plain text drops URLs, code marks and link targets", () => {
  assert.equal(plainText("see [the repo](https://github.com/x) and `cf` **now**"), "see the repo and cf now");
});

test("sections split at headings with GitHub-style ids", () => {
  const parts = sections(hints);
  assert.deepEqual(parts.map((part) => part.id), [undefined, "right-click-and-drag", "scope"]);
  assert.equal(parts[1].heading, "Right-click and drag");
});

test("every word must match and headings land on their anchor", () => {
  const index = buildIndex([hints, grid], [], [], []);
  const results = search(index, "context menu");
  assert.equal(results[0].href, "/docs/hints#right-click-and-drag");
  assert.equal(results[0].section, "Right-click and drag");
  assert.deepEqual(search(index, "context grid"), []);
});

test("a URL in a guide does not make it match", () => {
  const index = buildIndex([hints, grid], [], [], []);
  assert.deepEqual(search(index, "github").map((result) => result.href), []);
});

test("title matches rank before body matches", () => {
  const index = buildIndex([hints, grid], [], [], []);
  const results = search(index, "grid");
  assert.equal(results[0].href, "/docs/mouse-grid");
});
