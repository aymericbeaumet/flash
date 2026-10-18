import assert from "node:assert/strict";
import test from "node:test";
import { ansiRows, alphabetHeat, bindingsByCap, capsAt, categoryOf, keycapLabel, keySteps, stepsToKey, mappingModes, mappingSnippet, parseKey, phaseKeys, rowsForMode, rowsUnder, scopesForMode, zoneOf } from "./src/lib/keyboard.ts";
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
  assert.deepEqual(scopesForMode("hold"), ["hold", "normal", "all"]);
});

test("the mode buttons pick what the keyboard lights and the list shows", () => {
  assert.deepEqual(mappingModes.map((mode) => mode.id), ["all", "normal", "hold", "hyper", "insert", "command", "terminal"]);
  const rows: MappingRow[] = [
    { scope: "normal", key: "f", action: "flash mouse_target" },
    { scope: "hold", key: "j", action: "flash mouse_nudge --direction=down --distance=16" },
    { scope: "all", key: "cmd+space", action: "flash candidate_finder" },
    { scope: "insert", key: "ctrl+[", action: "flash enter_normal_mode" },
    { scope: "hyper", key: "1", action: "flash system_key --key=brightness_down" },
  ];
  assert.deepEqual(rowsForMode(rows, "all").length, 5);
  assert.deepEqual(rowsForMode(rows, "hold").map((row) => row.key), ["f", "j", "cmd+space"]);
  assert.deepEqual(rowsForMode(rows, "hyper").map((row) => row.key), ["1"]);
  assert.deepEqual(rowsForMode(rows, "insert").map((row) => row.key), ["cmd+space", "ctrl+["]);
});

test("a key is the steps you press, a capital being its shift layer", () => {
  assert.deepEqual(keySteps("f", "space"), [{ cap: "f", modifiers: [] }]);
  assert.deepEqual(keySteps("G", "space"), [{ cap: "g", modifiers: ["shift"] }]);
  assert.deepEqual(keySteps("ctrl+d", "space"), [{ cap: "d", modifiers: ["ctrl"] }]);
  assert.deepEqual(keySteps("cmd+shift+]", "space"), [{ cap: "]", modifiers: ["cmd", "shift"] }]);
  assert.deepEqual(keySteps("[t", "space"), [{ cap: "[", modifiers: [] }, { cap: "t", modifiers: [] }]);
  assert.deepEqual(keySteps("<leader>s", "space"), [{ cap: "space", modifiers: [] }, { cap: "s", modifiers: [] }]);
});

const drillRows: MappingRow[] = [
  { scope: "normal", key: "f", action: "flash mouse_target" },
  { scope: "normal", key: "F", action: "flash mouse_target --insert" },
  { scope: "normal", key: "c", action: "flash noop" },
  { scope: "normal", key: "cf", action: "flash mouse_target --secondary" },
  { scope: "normal", key: "ctrl+d", action: "flash scroll_half_page_down" },
  { scope: "normal", key: "g1", action: "flash tab_select --index=1" },
  { scope: "normal", key: "gg", action: "flash scroll_top" },
];

test("the keyboard shows what each key does at a prefix, in one modifier layer", () => {
  const top = capsAt(drillRows, [], [], "space");
  assert.equal(top.get("f")?.bindings.length, 1);
  assert.equal(top.get("c")?.bindings.length, 1);
  assert.equal(top.get("c")?.continues, 1);
  assert.equal(top.get("g")?.bindings.length, 0);
  assert.equal(top.get("g")?.continues, 2);
  assert.equal(top.has("d"), false);
  const shift = capsAt(drillRows, [], ["shift"], "space");
  assert.deepEqual([...shift.keys()], ["f"]);
  assert.equal(capsAt(drillRows, [], ["ctrl"], "space").get("d")?.bindings[0].key, "ctrl+d");
  const afterG = capsAt(drillRows, [{ cap: "g", modifiers: [] }], [], "space");
  assert.deepEqual([...afterG.keys()].sort(), ["1", "g"]);
});

test("the list keeps the bindings under a prefix and a picked key", () => {
  const g = [{ cap: "g", modifiers: [] }];
  assert.deepEqual(rowsUnder(drillRows, g, null, "space").map((row) => row.key), ["g1", "gg"]);
  assert.deepEqual(rowsUnder(drillRows, g, { cap: "1", modifiers: [] }, "space").map((row) => row.key), ["g1"]);
  assert.deepEqual(rowsUnder(drillRows, [], { cap: "c", modifiers: [] }, "space").map((row) => row.key), ["c", "cf"]);
  assert.equal(rowsUnder(drillRows, [], null, "space").length, drillRows.length);
});

test("an action falls in a category by what it does", () => {
  assert.equal(categoryOf("flash mouse_target --secondary"), "pointer");
  assert.equal(categoryOf("flash mouse_bigram --move"), "pointer");
  assert.equal(categoryOf("flash scroll_top"), "scroll");
  assert.equal(categoryOf("flash tab_next"), "tabs");
  assert.equal(categoryOf("flash app_previous"), "tabs");
  assert.equal(categoryOf("flash window_focus --direction=left"), "windows");
  assert.equal(categoryOf("flash system_key --key=mute"), "system");
  assert.equal(categoryOf("flash enter_insert_mode"), "modes");
  assert.equal(categoryOf("flash caffeinate toggle"), "plugins");
  assert.equal(categoryOf("open -a Safari"), "programs");
});

test("a keycap names its action briefly", () => {
  assert.equal(keycapLabel("flash mouse_target --secondary"), "mouse target secondary");
  assert.equal(keycapLabel("flash scroll_half_page_down"), "scroll half page down");
  assert.equal(keycapLabel("flash tab_select --index=1"), "tab select 1");
  assert.equal(keycapLabel("open -a Safari"), "open -a Safari");
});

test("steps read back as flash.toml key syntax", () => {
  for (const key of ["f", "G", "ctrl+d", "cmd+shift+]", "[t", "gg", "<space>s"]) {
    assert.equal(stepsToKey(keySteps(key, "")!), key);
  }
  assert.equal(stepsToKey([{ cap: "space", modifiers: [] }, { cap: "x", modifiers: [] }]), "<space>x");
  assert.equal(stepsToKey([{ cap: "return", modifiers: ["ctrl"] }]), "ctrl+return");
});

test("a binding's snippet remaps or removes it in its own table", () => {
  assert.equal(
    mappingSnippet({ scope: "normal", key: "f", action: "flash mouse_target" }),
    '[mode.normal.mappings]\n"f" = ["flash", "mouse_target"]  # change the command\n# "f" = false  # or remove the key',
  );
  assert.equal(
    mappingSnippet({ scope: "hold", key: "j", action: "flash mouse_nudge --direction=down --distance=16" }),
    '[mode.hold.mappings]\n"j" = ["flash", "mouse_nudge", "--direction=down", "--distance=16"]  # change the command\n# "j" = false  # or remove the key',
  );
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

test("the board is a US ANSI keyboard whatever the layout", () => {
  const width = (row: { units: number }[]) => row.reduce((sum, slot) => sum + slot.units, 0);
  const rows = ansiRows(keyboard);
  assert.equal(rows.length, 6, "escape, numbers, top, home, bottom, modifiers");
  for (const row of rows.slice(1)) assert.equal(width(row), 15);
  assert.deepEqual(rows[1].map((slot) => slot.cap).join(" "), "` 1 2 3 4 5 6 7 8 9 0 - = backspace");
  assert.deepEqual(rows[2].map((slot) => slot.cap).join(" "), "tab q w e r t y u i o p [ ] \\");
  assert.deepEqual(rows[3].map((slot) => slot.cap).join(" "), "caps a s d f g h j k l ; ' return");
  assert.deepEqual(rows[4].map((slot) => slot.cap).join(" "), "shift z x c v b n m , . / shift");
  assert.equal(rows[5].find((slot) => slot.cap === "space")?.units, 6.5);
  assert.deepEqual(rows[5].filter((slot) => slot.modifier).map((slot) => slot.modifier), ["ctrl", "alt", "cmd", "cmd", "alt", "ctrl"]);
  const dvorak = ansiRows({ ...keyboard, layout: "dvorak", rows: ["1234567890", "',.pyfgcrl", "aoeuidhtns", ";qjkxbmwvz"] });
  assert.deepEqual(dvorak[1].slice(-3).map((slot) => slot.cap), ["[", "]", "backspace"]);
  assert.deepEqual(dvorak[2].slice(-4).map((slot) => slot.cap), ["l", "/", "=", "\\"]);
  assert.deepEqual(dvorak[3].slice(-2).map((slot) => slot.cap), ["-", "return"]);
  for (const row of dvorak.slice(1)) assert.equal(width(row), 15);
});
