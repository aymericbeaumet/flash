import assert from "node:assert/strict";
import test from "node:test";
import {
  ansiRows,
  alphabetHeat,
  bindingsByCap,
  capsAt,
  categories,
  categoryOf,
  keycapLabel,
  keySteps,
  stepsToKey,
  topicCategories,
  layerModes,
  mappingModes,
  mappingSnippet,
  parseKey,
  phaseKeys,
  rowsForMode,
  rowsUnder,
  scopesForMode,
  zoneOf,
} from "./src/lib/keyboard.ts";
import type { KeyboardState, MappingRow } from "./src/lib/types.ts";

const row = (scope: string, key: string, action: string): MappingRow => ({
  scope,
  key,
  action,
  origin: "default",
  explanation: "",
});

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
  held_button: null,
};

test("a chord is one key with its modifiers", () => {
  assert.deepEqual(parseKey("cmd+shift+space", "space"), {
    cap: "space",
    modifiers: ["cmd", "shift"],
    rest: "",
  });
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

test("a function key is its own cap, bare in a sequence or held in a chord", () => {
  assert.deepEqual(parseKey("<f12>", ""), { cap: "f12", modifiers: [], rest: "" });
  assert.deepEqual(parseKey("<f20>g", ""), { cap: "f20", modifiers: [], rest: "g" });
  assert.deepEqual(parseKey("cmd+<f5>", ""), { cap: "f5", modifiers: ["cmd"], rest: "" });
  assert.deepEqual(parseKey("cmd+f5", ""), { cap: "f5", modifiers: ["cmd"], rest: "" });
  assert.deepEqual(keySteps("g<f1>", ""), [
    { cap: "g", modifiers: [] },
    { cap: "f1", modifiers: [] },
  ]);
  assert.equal(
    stepsToKey([{ cap: "f12", modifiers: [] }]),
    "<f12>",
    "bare, f12 is the keys f, 1, 2",
  );
  assert.equal(stepsToKey([{ cap: "f12", modifiers: ["cmd", "shift"] }]), "cmd+shift+f12");
});

test("the live mode reads its own scope and all", () => {
  assert.deepEqual(scopesForMode("normal"), ["normal", "all"]);
  assert.deepEqual(scopesForMode("hyper"), ["hyper"]);
  assert.deepEqual(scopesForMode("insert"), ["insert", "all"]);
  assert.deepEqual(scopesForMode(undefined), ["all"]);
  assert.deepEqual(scopesForMode("hold"), ["hold", "normal", "all"]);
  assert.deepEqual(scopesForMode("text"), ["text", "normal", "all"]);
  assert.deepEqual(scopesForMode("visual"), ["visual", "all"]);
  assert.deepEqual(scopesForMode("layers.resize"), ["layers.resize", "all"]);
});

test("each layer is a mode button of its own, reading its keys and all", () => {
  const rows: MappingRow[] = [
    row("layers.resize", "h", "flash window move --position=lefthalf"),
    row("layers.resize", "<escape>", "flash mode leave"),
    row("layers.media", "p", "flash key system --key=media_play"),
    row("all", "cmd+space", "flash app switch"),
    row("normal", "f", "flash mouse target"),
  ];
  assert.deepEqual(
    layerModes(rows).map((mode) => [mode.id, mode.label]),
    [
      ["layers.media", "media"],
      ["layers.resize", "resize"],
    ],
  );
  assert.deepEqual(
    rowsForMode(rows, "layers.resize").map((row) => row.key),
    ["h", "<escape>", "cmd+space"],
  );
  assert.equal(
    mappingSnippet(rows[0]),
    '[mode.layers.resize.mappings]\n"h" = ["flash", "window", "move", "--position=lefthalf"]  # change the command\n# "h" = false  # or remove the key',
  );
});

test("the mode buttons pick what the keyboard lights and the list shows", () => {
  assert.deepEqual(
    mappingModes.map((mode) => mode.id),
    ["all", "normal", "text", "visual", "hold", "hyper", "insert", "command", "terminal"],
  );
  const rows: MappingRow[] = [
    row("normal", "f", "flash mouse target"),
    row("hold", "j", "flash mouse nudge --direction=down --distance=16"),
    row("all", "cmd+space", "flash app switch"),
    row("insert", "ctrl+[", "flash mode normal"),
    row("hyper", "1", "flash key system --key=brightness_down"),
  ];
  assert.deepEqual(rowsForMode(rows, "all").length, 5);
  assert.deepEqual(
    rowsForMode(rows, "hold").map((row) => row.key),
    ["f", "j", "cmd+space"],
  );
  assert.deepEqual(
    rowsForMode(rows, "hyper").map((row) => row.key),
    ["1"],
  );
  assert.deepEqual(
    rowsForMode(rows, "insert").map((row) => row.key),
    ["cmd+space", "ctrl+["],
  );
});

test("a key is the steps you press, a capital being its shift layer", () => {
  assert.deepEqual(keySteps("f", "space"), [{ cap: "f", modifiers: [] }]);
  assert.deepEqual(keySteps("G", "space"), [{ cap: "g", modifiers: ["shift"] }]);
  assert.deepEqual(keySteps("ctrl+d", "space"), [{ cap: "d", modifiers: ["ctrl"] }]);
  assert.deepEqual(keySteps("cmd+shift+]", "space"), [{ cap: "]", modifiers: ["cmd", "shift"] }]);
  assert.deepEqual(keySteps("[t", "space"), [
    { cap: "[", modifiers: [] },
    { cap: "t", modifiers: [] },
  ]);
  assert.deepEqual(keySteps("<leader>s", "space"), [
    { cap: "space", modifiers: [] },
    { cap: "s", modifiers: [] },
  ]);
});

const drillRows: MappingRow[] = [
  row("normal", "f", "flash mouse target"),
  row("normal", "F", "flash mouse target --insert"),
  row("normal", "c", "flash noop"),
  row("normal", "cf", "flash mouse target --secondary"),
  row("normal", "ctrl+d", "flash scroll half_page_down"),
  row("normal", "g1", "flash tab select --index=1"),
  row("normal", "gg", "flash scroll top"),
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
  assert.deepEqual(
    rowsUnder(drillRows, g, null, "space").map((row) => row.key),
    ["g1", "gg"],
  );
  assert.deepEqual(
    rowsUnder(drillRows, g, { cap: "1", modifiers: [] }, "space").map((row) => row.key),
    ["g1"],
  );
  assert.deepEqual(
    rowsUnder(drillRows, [], { cap: "c", modifiers: [] }, "space").map((row) => row.key),
    ["c", "cf"],
  );
  assert.equal(rowsUnder(drillRows, [], null, "space").length, drillRows.length);
});

test("an action falls in a category by what it does", () => {
  assert.equal(categoryOf("flash mouse target --secondary"), "pointer");
  assert.equal(categoryOf("flash mouse bigram --move"), "pointer");
  assert.equal(categoryOf("flash scroll top"), "scroll");
  assert.equal(categoryOf("flash tab next"), "tabs");
  assert.equal(categoryOf("flash app previous"), "tabs");
  assert.equal(categoryOf("flash mark jump --letter=a"), "tabs");
  assert.equal(categoryOf("flash window focus --direction=left"), "windows");
  assert.equal(categoryOf("flash key system --key=mute"), "system");
  assert.equal(categoryOf("flash mode insert"), "modes");
  assert.equal(categoryOf("flash clipboard paste"), "other");
  assert.equal(categoryOf("flash screenshot window"), "plugins");
  assert.equal(categoryOf("flash tmux session main"), "plugins");
  assert.equal(categoryOf("open -a Safari"), "programs");
  // The table is the resident's; every category it names is one the page draws.
  for (const [topic, category] of Object.entries(topicCategories))
    assert.ok(
      categories.some((known) => known.id === category),
      `${topic}: ${category}`,
    );
  assert.ok(Object.keys(topicCategories).length > 50);
});

test("a keycap names its action briefly", () => {
  assert.equal(keycapLabel("flash mouse target --secondary"), "mouse target secondary");
  assert.equal(keycapLabel("flash scroll half_page_down"), "scroll half page down");
  assert.equal(keycapLabel("flash tab select --index=1"), "tab select 1");
  assert.equal(keycapLabel("open -a Safari"), "open -a Safari");
});

test("steps read back as flash.toml key syntax", () => {
  for (const key of ["f", "G", "ctrl+d", "cmd+shift+]", "[t", "gg", "<space>s"]) {
    assert.equal(stepsToKey(keySteps(key, "")!), key);
  }
  assert.equal(
    stepsToKey([
      { cap: "space", modifiers: [] },
      { cap: "x", modifiers: [] },
    ]),
    "<space>x",
  );
  assert.equal(stepsToKey([{ cap: "return", modifiers: ["ctrl"] }]), "ctrl+return");
});

test("a binding's snippet remaps or removes it in its own table", () => {
  assert.equal(
    mappingSnippet(row("normal", "f", "flash mouse target")),
    '[mode.normal.mappings]\n"f" = ["flash", "mouse", "target"]  # change the command\n# "f" = false  # or remove the key',
  );
  assert.equal(
    mappingSnippet(row("hold", "j", "flash mouse nudge --direction=down --distance=16")),
    '[mode.hold.mappings]\n"j" = ["flash", "mouse", "nudge", "--direction=down", "--distance=16"]  # change the command\n# "j" = false  # or remove the key',
  );
});

test("bindings group by the key cap they start on, sorted", () => {
  const rows: MappingRow[] = [
    row("normal", "cf", "flash mouse target --secondary"),
    row("normal", "c", "flash noop"),
    row("all", "cmd+shift+space", "flash mouse target"),
    row("insert", "x", "flash tab close"),
  ];
  const byCap = bindingsByCap(rows, ["normal", "all"], "space");
  assert.deepEqual([...byCap.keys()].sort(), ["c", "space"]);
  assert.deepEqual(
    byCap.get("c")?.map((b) => b.row.key),
    ["c", "cf"],
  );
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
  const switcher = phaseKeys("window_switcher", keyboard);
  assert.equal(switcher.keys.get("f"), "switch to that window");
  assert.match(switcher.specials.get("tab") ?? "", /next window/);
  assert.equal(switcher.heat.get("f"), 1);
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
  assert.deepEqual(
    rows[0].map((slot) => slot.cap).join(" "),
    "esc f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12",
  );
  assert.deepEqual(
    rows[1].map((slot) => slot.cap).join(" "),
    "` 1 2 3 4 5 6 7 8 9 0 - = backspace",
  );
  assert.deepEqual(rows[2].map((slot) => slot.cap).join(" "), "tab q w e r t y u i o p [ ] \\");
  assert.deepEqual(rows[3].map((slot) => slot.cap).join(" "), "caps a s d f g h j k l ; ' return");
  assert.deepEqual(rows[4].map((slot) => slot.cap).join(" "), "shift z x c v b n m , . / shift");
  assert.equal(rows[5].find((slot) => slot.cap === "space")?.units, 6.5);
  assert.deepEqual(
    rows[5].filter((slot) => slot.modifier).map((slot) => slot.modifier),
    ["ctrl", "alt", "cmd", "cmd", "alt", "ctrl"],
  );
  const dvorak = ansiRows({
    ...keyboard,
    layout: "dvorak",
    rows: ["1234567890", "',.pyfgcrl", "aoeuidhtns", ";qjkxbmwvz"],
  });
  assert.deepEqual(
    dvorak[1].slice(-3).map((slot) => slot.cap),
    ["[", "]", "backspace"],
  );
  assert.deepEqual(
    dvorak[2].slice(-4).map((slot) => slot.cap),
    ["l", "/", "=", "\\"],
  );
  assert.deepEqual(
    dvorak[3].slice(-2).map((slot) => slot.cap),
    ["-", "return"],
  );
  for (const row of dvorak.slice(1)) assert.equal(width(row), 15);
});
