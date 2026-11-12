import assert from "node:assert/strict";
import test from "node:test";
import { explainMapping, scoreSearch, searchFields } from "./src/lib/mapping-search.ts";
import type { CommandInfo, MappingRow } from "./src/lib/types.ts";

function row(partial: Partial<MappingRow> & Pick<MappingRow, "key" | "action" | "explanation">): MappingRow {
  return { scope: "hyper", origin: "default", ...partial };
}

const brightness = row({
  key: "2",
  action: "flash key system --key=brightness_up",
  explanation: "Raises the display brightness.",
});
const volume = row({
  key: "=",
  action: "flash key system --key=volume_up",
  explanation: "Raises the volume.",
});
const arrow = row({
  key: "h",
  action: "flash key arrow --direction=left",
  explanation: "Posts the Left arrow.",
});
const shiftArrow = row({
  key: "shift+h",
  action: "flash key arrow --direction=left --shift",
  explanation: "Posts Shift+Left.",
});
const quit = row({ key: "q", action: "flash resident quit", explanation: "Quits Flash." });

function score(query: string, item: MappingRow, source = ""): number | null {
  return scoreSearch(query, searchFields(item, [], source));
}

test("a typo for what a mapping does still finds it", () => {
  assert.ok((score("brigtness", brightness) ?? 0) > 0);
  assert.equal(score("brigtness", quit), null);
  assert.ok((score("brigtness", brightness) ?? 0) > (score("brigtness", volume) ?? 0));
});

test("the explanation outranks a source-only hit and a key still wins when it is the query", () => {
  const sourceOnly = row({ key: "x", action: "flash resident quit", explanation: "Quits Flash." });
  const byEffect = row({
    key: "mf",
    action: "flash mouse target --move",
    explanation: "Labels targets in the focused window and moves the pointer onto the one you pick.",
  });
  const byKey = row({ key: "pointer", action: "flash resident quit", explanation: "Quits Flash." });
  assert.ok((score("pointer", byEffect) ?? 0) > (score("pointer", sourceOnly, "pointer plugin") ?? 0));
  assert.ok((score("pointer", byKey) ?? 0) > (score("pointer", byEffect) ?? 0));
});

test("shift and direction stay distinct", () => {
  assert.ok((score("shift left", shiftArrow) ?? 0) > (score("shift left", arrow) ?? 0));
  assert.equal(score("shift left", arrow), null);
});

test("an empty query is not a match", () => {
  assert.equal(score("   ", brightness), null);
});

test("a one-letter search matches that key, not every word containing the letter", () => {
  const jump = row({
    key: "f",
    action: "flash mouse target",
    explanation: "Labels targets in the focused window and left-clicks the one you pick.",
  });
  const nextApp = row({ key: "a", action: "flash app next", explanation: "Focuses the next app." });
  assert.ok((score("f", jump) ?? 0) > 0);
  assert.equal(score("f", quit), null);
  assert.equal(score("up", nextApp), null);
  assert.ok((score("volume", volume) ?? 0) > 0);
});

test("a plugin description is the hover text and counts in the ranking", () => {
  const mapping = row({
    scope: "normal",
    key: "<leader>c",
    action: "flash screenshot window",
    explanation: "Runs the screenshot window command.",
  });
  const commands: CommandInfo[] = [{
    name: ":screenshot window",
    command: "screenshot",
    subcommand: "window",
    description: "Copy a capture of the focused window to the clipboard",
    source: "screenshot",
    source_kind: "plugin",
  }];
  assert.equal(explainMapping(mapping, commands), "Copy a capture of the focused window to the clipboard");
  const fields = searchFields(mapping, commands, "plugin screenshot");
  assert.match(fields.explanation, /Copy a capture of the focused window/);
  assert.match(fields.explanation, /Runs the screenshot window command/);
  assert.ok((scoreSearch("capture", fields) ?? 0) > 0);
  assert.equal(scoreSearch("capture", searchFields(quit, commands, "")), null);
});
