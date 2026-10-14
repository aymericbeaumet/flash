import assert from "node:assert/strict";
import test from "node:test";
import { alphabetHeat, bindingsByCap, parseKey, phaseKeys, scopesForMode, zoneOf } from "./src/lib/keyboard.ts";
import type { KeyboardState, MappingRow } from "./src/lib/types.ts";

const keyboard: KeyboardState = {
  layout: "qwerty",
  rows: ["1234567890", "qwertyuiop", "asdfghjkl;", "zxcvbnm,./"],
  alphabet: "fjdksla;gh",
  key_scores: { f: 331, j: 330, d: 321, k: 320, s: 311, l: 310, a: 301, ";": 300, g: 316, h: 315 },
  grid_keys: ["12345", "qwert", "asdfg", "zxcvb"],
  label_order: "zones",
  zone_rows: ["qwertyuiop", "asdfghjkl"],
  navigation: { left: "h", down: "j", up: "k", right: "l", quadrants: ["yu", "bn"] },
  adjust_digits: "width",
};

test("a chord is one key with its modifiers", () => {
  assert.deepEqual(parseKey("cmd+shift+space", "space"), { cap: "space", modifiers: ["cmd", "shift"], rest: "" });
  assert.deepEqual(parseKey("ctrl+d", ""), { cap: "d", modifiers: ["ctrl"], rest: "" });
  assert.deepEqual(parseKey("shift+-", ""), { cap: "-", modifiers: ["shift"], rest: "" });
  assert.deepEqual(parseKey("+", ""), { cap: "+", modifiers: [], rest: "" });
});

test("a sequence starts on its first token", () => {
  assert.deepEqual(parseKey("cf", ""), { cap: "c", modifiers: [], rest: "f" });
  assert.deepEqual(parseKey("[t", ""), { cap: "[", modifiers: [], rest: "t" });
  assert.deepEqual(parseKey("g1", ""), { cap: "g", modifiers: [], rest: "1" });
  assert.deepEqual(parseKey("<leader>s", "space"), { cap: "space", modifiers: [], rest: "s" });
  assert.deepEqual(parseKey("<leader>s", "<space>"), { cap: "space", modifiers: [], rest: "s" });
  assert.deepEqual(parseKey("<plus>", ""), { cap: "+", modifiers: [], rest: "" });
  assert.equal(parseKey("<leader>s", ""), null, "no leader, no key to draw on");
  assert.equal(parseKey("", ""), null);
});

test("the live mode reads its own scope and all", () => {
  assert.deepEqual(scopesForMode("normal"), ["normal", "all"]);
  assert.deepEqual(scopesForMode("hyper"), ["hyper"]);
  assert.deepEqual(scopesForMode("insert"), ["insert", "all"]);
  assert.deepEqual(scopesForMode(undefined), ["all"]);
});

test("bindings group by the key cap they start on, sorted", () => {
  const rows: MappingRow[] = [
    { scope: "normal", key: "cf", action: "flash mouse_target --secondary" },
    { scope: "normal", key: "c", action: "flash noop" },
    { scope: "all", key: "cmd+shift+space", action: "flash mouse_target" },
    { scope: "insert", key: "x", action: "flash tab_close" },
  ];
  const byCap = bindingsByCap(rows, ["normal", "all"], "space");
  assert.deepEqual([...byCap.keys()].sort(), ["c", "space"]);
  assert.deepEqual(byCap.get("c")?.map((b) => b.row.key), ["c", "cf"]);
  assert.equal(byCap.get("x"), undefined, "insert is not read in NORMAL");
});

test("phase keys name what every key does", () => {
  const labels = phaseKeys("labels", keyboard);
  assert.equal(labels.keys.get("f"), "hint label");
  assert.match(labels.specials.get("tab") ?? "", /grid/);
  assert.equal(labels.heat.get("f"), 1);
  assert.equal(labels.heat.get(";"), 0);
  const grid = phaseKeys("grid", keyboard);
  assert.equal(grid.keys.get("q"), "zoom into that cell");
  assert.equal(grid.keys.get("y"), "bisect: keep that quarter");
  assert.equal(grid.heat.size, 0);
  const pointer = phaseKeys("pointer", keyboard);
  assert.equal(pointer.keys.get("h"), "move left");
  assert.equal(pointer.keys.get("v"), "hold or release the button (drag)");
  assert.equal(phaseKeys("idle", keyboard).keys.size, 0);
  assert.equal(phaseKeys("labels", undefined).keys.size, 0);
});

test("heat spans the alphabet and zones follow the zone rows", () => {
  const heat = alphabetHeat(keyboard);
  assert.equal(heat.get("f"), 1);
  assert.equal(heat.get(";"), 0);
  assert.deepEqual(zoneOf(keyboard, "p"), { row: 0, column: 9, rows: 2, columns: 10 });
  assert.deepEqual(zoneOf(keyboard, "a"), { row: 1, column: 0, rows: 2, columns: 9 });
  assert.equal(zoneOf(keyboard, "z"), null);
  assert.equal(zoneOf({ ...keyboard, label_order: "reading" }, "a"), null);
});
