import type { KeyboardState, MappingRow } from "./types";

/** The modifier names a chord may carry, as `flash.toml` spells them. */
const modifierNames = new Set(["cmd", "ctrl", "alt", "shift", "hyper", "fn"]);

/** Named keys inside angle brackets and in chords, mapped to the key cap they sit on. */
const namedKeys: Record<string, string> = {
  space: "space", return: "return", enter: "return", tab: "tab", escape: "esc", esc: "esc",
  backspace: "backspace", delete: "backspace", plus: "+", minus: "-", lt: "<", gt: ">",
  bar: "|", bslash: "\\", left: "←", right: "→", up: "↑", down: "↓",
};

export interface ParsedKey {
  /** The key cap the binding starts on: a character, or `space`, `return`, `tab`, `esc`, `backspace`. */
  cap: string;
  /** Modifiers held with it, for a chord. */
  modifiers: string[];
  /** What follows the first key of a sequence (`f` of `cf`), empty for a chord or a single key. */
  rest: string;
}

/**
 * The key cap a mapping starts on. A chord (`cmd+shift+space`, `ctrl+d`)
 * is one key with modifiers; a sequence (`cf`, `[t`, `<leader>s`, `g1`)
 * starts on its first token, where `<leader>` is the configured leader.
 */
export function parseKey(key: string, leader: string): ParsedKey | null {
  const trimmed = key.trim();
  if (!trimmed) return null;
  const chord = parseChord(trimmed);
  if (chord) return chord;
  const tokens = tokenize(trimmed);
  if (!tokens.length) return null;
  const [first, ...rest] = tokens;
  const cap = capFor(first, leader);
  if (!cap) return null;
  return { cap, modifiers: [], rest: rest.join("") };
}

function parseChord(key: string): ParsedKey | null {
  if (!key.includes("+") || key.startsWith("<")) return null;
  const parts = key.split("+");
  // `shift+-` and `cmd+=` keep their last token; `+` alone is a key.
  const last = parts.pop() ?? "";
  const head = parts.filter(Boolean);
  if (!head.length || !head.every((part) => modifierNames.has(part.toLowerCase()))) return null;
  const cap = last === "" ? "+" : capFor(last, "");
  if (!cap) return null;
  return { cap, modifiers: head.map((part) => part.toLowerCase()), rest: "" };
}

function tokenize(key: string): string[] {
  const tokens: string[] = [];
  let index = 0;
  while (index < key.length) {
    if (key[index] === "<") {
      const close = key.indexOf(">", index + 1);
      if (close > index) {
        tokens.push(key.slice(index, close + 1));
        index = close + 1;
        continue;
      }
    }
    tokens.push(key[index]);
    index += 1;
  }
  return tokens;
}

function capFor(token: string, leader: string): string | null {
  if (token.startsWith("<") && token.endsWith(">")) {
    const name = token.slice(1, -1).toLowerCase();
    if (name === "leader") return leader ? capFor(leader.startsWith("<") ? leader : `<${leader}>`, "") : null;
    return namedKeys[name] ?? null;
  }
  const lower = token.toLowerCase();
  if (namedKeys[lower] && token.length > 1) return namedKeys[lower];
  if (token.length === 1) return token.toLowerCase();
  return null;
}

/** One key of the drawn keyboard: its cap, its width in key units, and the
 * modifier it is when it is one (pressing it shows that chord layer). */
export interface KeySlot {
  cap: string;
  label: string;
  units: number;
  modifier?: "shift" | "ctrl" | "alt" | "cmd";
  /** Drawn for the shape only (Caps Lock). */
  inert?: boolean;
}

/** The punctuation a layout puts beside its ten-key block on a US ANSI board. */
const ansiExtras: Record<string, { number: [string, string]; top: [string, string, string]; home: string }> = {
  qwerty: { number: ["-", "="], top: ["[", "]", "\\"], home: "'" },
  colemak: { number: ["-", "="], top: ["[", "]", "\\"], home: "'" },
  dvorak: { number: ["[", "]"], top: ["/", "=", "\\"], home: "-" },
};

/** A US ANSI keyboard, whatever the layout: the layout's ten-key rows from
 * the snapshot, its punctuation around them, and the standard key widths, so
 * every main row spans 15 units. */
export function ansiRows(keyboard: KeyboardState): KeySlot[][] {
  const extras = ansiExtras[keyboard.layout] ?? ansiExtras.qwerty;
  const key = (cap: string, units = 1): KeySlot => ({ cap, label: cap, units });
  const block = (row: number) => [...(keyboard.rows[row] ?? "")].map((cap) => key(cap));
  const modifier = (name: KeySlot["modifier"] & string, label: string, units: number): KeySlot => ({ cap: name, label, units, modifier: name });
  return [
    [key("esc")],
    [key("`"), ...block(0), key(extras.number[0]), key(extras.number[1]), { cap: "backspace", label: "⌫", units: 2 }],
    [{ cap: "tab", label: "tab", units: 1.5 }, ...block(1), key(extras.top[0]), key(extras.top[1]), key(extras.top[2], 1.5)],
    [{ cap: "caps", label: "caps", units: 1.75, inert: true }, ...block(2), key(extras.home), { cap: "return", label: "return", units: 2.25 }],
    [modifier("shift", "⇧ shift", 2.25), ...block(3), modifier("shift", "⇧ shift", 2.75)],
    [
      modifier("ctrl", "⌃ control", 1.5), modifier("alt", "⌥ option", 1.25), modifier("cmd", "⌘ command", 1.5),
      { cap: "space", label: "space", units: 6.5 },
      modifier("cmd", "⌘ command", 1.5), modifier("alt", "⌥ option", 1.25), modifier("ctrl", "⌃ control", 1.5),
    ],
  ];
}

/** What the key-mappings keyboard draws: bindings, or a hint surface's keys. */
export type BoardView = "bindings" | "alphabet" | "grid" | "zones";

/** The modes the key-mappings page can show, in the order of its buttons. */
export const mappingModes: { id: string; label: string; summary: string }[] = [
  { id: "all", label: "All", summary: "Every mapping, in every mode." },
  { id: "normal", label: "Normal", summary: "Navigate and act; unmapped keys are swallowed." },
  { id: "visual", label: "Visual", summary: "A visual selection: motions extend it, as in Vim; its own keys come first, then NORMAL's." },
  { id: "drag", label: "Drag", summary: "Dragging with a mouse button held: nudge, pick where it goes, drop or put it back." },
  { id: "hyper", label: "Hyper", summary: "While the hyper key is held." },
  { id: "insert", label: "Insert", summary: "Typing in an app; only these keys are Flash's." },
  { id: "command", label: "Command", summary: "The command line is open." },
  { id: "terminal", label: "Terminal", summary: "A terminal popup has the keyboard." },
];

/** The mapping scopes a mode reads: its own and `all`. VISUAL and DRAG read
 * their own table first, then NORMAL's. */
export function scopesForMode(mode: string | undefined): string[] {
  switch (mode) {
    case "normal": return ["normal", "all"];
    case "visual": return ["visual", "normal", "all"];
    case "drag": return ["drag", "normal", "all"];
    case "hyper": return ["hyper"];
    case "insert": return ["insert", "all"];
    case "command": return ["command", "all"];
    case "terminal": return ["terminal", "all"];
    default: return ["all"];
  }
}

export interface KeyBinding {
  row: MappingRow;
  parsed: ParsedKey;
}

/** The bindings of `scopes`, grouped by the key cap they start on. */
export function bindingsByCap(rows: MappingRow[], scopes: string[], leader: string): Map<string, KeyBinding[]> {
  const byCap = new Map<string, KeyBinding[]>();
  const wanted = new Set(scopes);
  for (const row of rows) {
    if (!wanted.has(row.scope)) continue;
    const parsed = parseKey(row.key, leader);
    if (!parsed) continue;
    const list = byCap.get(parsed.cap) ?? [];
    list.push({ row, parsed });
    byCap.set(parsed.cap, list);
  }
  for (const list of byCap.values()) list.sort((a, b) => a.row.key.localeCompare(b.row.key));
  return byCap;
}

/** The rows `mode` reads, every row for `all`, in their given order. */
export function rowsForMode(rows: MappingRow[], mode: string): MappingRow[] {
  if (mode === "all") return rows;
  const wanted = new Set(scopesForMode(mode));
  return rows.filter((row) => wanted.has(row.scope));
}

/** One key you press: its cap and the modifiers held with it. */
export interface KeyStep {
  cap: string;
  /** In `cmd ctrl alt shift hyper fn` order; a capital letter is its cap with `shift`. */
  modifiers: string[];
}

const modifierOrder = ["cmd", "ctrl", "alt", "shift", "hyper", "fn"];

/** The steps a mapping key is pressed as: one for a chord, one per key of a sequence. */
export function keySteps(key: string, leader: string): KeyStep[] | null {
  const trimmed = key.trim();
  if (!trimmed) return null;
  const chord = parseChord(trimmed);
  if (chord) {
    return [{ cap: chord.cap, modifiers: [...chord.modifiers].sort((a, b) => modifierOrder.indexOf(a) - modifierOrder.indexOf(b)) }];
  }
  const steps: KeyStep[] = [];
  for (const token of tokenize(trimmed)) {
    const cap = capFor(token, leader);
    if (!cap) return null;
    const capital = token.length === 1 && token !== token.toLowerCase();
    steps.push({ cap, modifiers: capital ? ["shift"] : [] });
  }
  return steps.length ? steps : null;
}

function sameStep(a: KeyStep, b: KeyStep): boolean {
  return a.cap === b.cap && a.modifiers.length === b.modifiers.length && a.modifiers.every((m, i) => m === b.modifiers[i]);
}

function startsWith(steps: KeyStep[], path: KeyStep[]): boolean {
  return steps.length >= path.length && path.every((step, index) => sameStep(step, steps[index]));
}

const bracketed: Record<string, string> = { space: "<space>", return: "<return>", tab: "<tab>", esc: "<esc>", backspace: "<backspace>" };

/** `steps` in `flash.toml` key syntax: `G` for a shifted letter, `<space>` in a sequence. */
export function stepsToKey(steps: KeyStep[]): string {
  return steps
    .map((step) => {
      const letter = /^[a-z]$/.test(step.cap);
      if (letter && step.modifiers.length === 1 && step.modifiers[0] === "shift") return step.cap.toUpperCase();
      if (step.modifiers.length) return [...step.modifiers, step.cap].join("+");
      return bracketed[step.cap] ?? step.cap;
    })
    .join("");
}

/** What one key does after `path`, in one modifier layer. */
export interface CapBindings {
  /** The bindings that end on this key. */
  bindings: MappingRow[];
  /** How many longer bindings continue past it (it is a prefix). */
  continues: number;
}

/** Every key that acts after the prefix `path` while `layer` is held. */
export function capsAt(rows: MappingRow[], path: KeyStep[], layer: string[], leader: string): Map<string, CapBindings> {
  const wanted = [...layer].sort((a, b) => modifierOrder.indexOf(a) - modifierOrder.indexOf(b));
  const caps = new Map<string, CapBindings>();
  for (const row of rows) {
    const steps = keySteps(row.key, leader);
    if (!steps || steps.length <= path.length || !startsWith(steps, path)) continue;
    const next = steps[path.length];
    if (!sameStep(next, { cap: next.cap, modifiers: wanted })) continue;
    const entry = caps.get(next.cap) ?? { bindings: [], continues: 0 };
    if (steps.length === path.length + 1) entry.bindings.push(row);
    else entry.continues += 1;
    caps.set(next.cap, entry);
  }
  return caps;
}

/** The rows under the prefix `path`, and past `picked` when a key is picked. */
export function rowsUnder(rows: MappingRow[], path: KeyStep[], picked: KeyStep | null, leader: string): MappingRow[] {
  const prefix = picked ? [...path, picked] : path;
  if (!prefix.length) return rows;
  return rows.filter((row) => {
    const steps = keySteps(row.key, leader);
    return steps !== null && startsWith(steps, prefix);
  });
}

/** What an action is for, so bindings group by purpose. */
export const categories: { id: string; label: string }[] = [
  { id: "pointer", label: "Click and point" },
  { id: "scroll", label: "Scroll" },
  { id: "tabs", label: "Tabs, pages and apps" },
  { id: "windows", label: "Windows" },
  { id: "modes", label: "Modes and the command line" },
  { id: "system", label: "Keys and system" },
  { id: "plugins", label: "Plugins" },
  { id: "programs", label: "Programs" },
  { id: "other", label: "Everything else" },
];

export function categoryOf(action: string): string {
  const words = action.trim().split(/\s+/);
  if (words[0] !== "flash" || words.length < 2) return "programs";
  const verb = words[1];
  if (words.length >= 3 && !words[2].startsWith("--") && !verb.includes("_")) return "plugins";
  if (/^(mouse_|hints_)/.test(verb)) return "pointer";
  if (verb.startsWith("scroll_")) return "scroll";
  if (/^(tab_|app_|history_|pane_|resource_|page_)/.test(verb) || ["reload", "find", "undo", "redo"].includes(verb)) return "tabs";
  if (verb.startsWith("window_")) return "windows";
  if (/^(enter_|leave_|popup_|terminal_|command|candidate_finder|help)/.test(verb)) return "modes";
  if (/^(system_key|function_key|arrow|send_key|volume|brightness|media)/.test(verb)) return "system";
  return "other";
}

/** A keycap's few words: the verb, then the values of its flags. */
export function keycapLabel(action: string): string {
  const words = action.trim().split(/\s+/);
  if (words[0] !== "flash" || words.length < 2) return action;
  return words
    .slice(1)
    .map((word) => (word.startsWith("--") ? (word.includes("=") ? word.slice(word.indexOf("=") + 1) : word.slice(2)) : word))
    .join(" ")
    .replace(/_/g, " ");
}

/** The `flash.toml` lines that rebind or remove `row`'s key, in its own table. */
export function mappingSnippet(row: MappingRow): string {
  const key = JSON.stringify(row.key);
  const argv = row.action.trim().split(/\s+/).map((word) => JSON.stringify(word)).join(", ");
  return `[mode.${row.scope}.mappings]\n${key} = [${argv}]  # change the command\n# ${key} = false  # or remove the key`;
}

/** One hint session phase, as the keys see it. */
export interface PhaseKeys {
  /** The keys that act in this phase, with what they do. */
  keys: Map<string, string>;
  /** The special keys and what they do: `esc`, `tab`, `backspace`, `return`, `space`. */
  specials: Map<string, string>;
  /** A heat per key, 0 to 1, for the hint alphabet's ease. Empty when the phase types no label. */
  heat: Map<string, number>;
}

/** What every key does while Flash is in `phase`. */
export function phaseKeys(phase: string | undefined, keyboard: KeyboardState | undefined): PhaseKeys {
  const keys = new Map<string, string>();
  const specials = new Map<string, string>();
  const heat = new Map<string, number>();
  if (!keyboard) return { keys, specials, heat };
  const nav = keyboard.navigation;
  switch (phase) {
    case "labels":
    case "bigram":
    case "search": {
      for (const [cap, value] of alphabetHeat(keyboard)) heat.set(cap, value);
      for (const cap of keyboard.alphabet) keys.set(cap, phase === "search" ? "type to filter" : "hint label");
      specials.set("esc", "cancel");
      specials.set("backspace", phase === "search" ? "erase" : "undo a key, or back to the surface before");
      if (phase === "labels") {
        specials.set("tab", "same click on the grid; with Shift, across the screen");
      }
      if (phase === "search") {
        specials.set("tab", "next match");
        specials.set("return", "click the match");
      }
      break;
    }
    case "grid": {
      for (const row of keyboard.grid_keys) for (const cap of row) keys.set(cap, "zoom into that cell");
      keys.set(nav.left, "bisect: keep the left half");
      keys.set(nav.down, "bisect: keep the bottom half");
      keys.set(nav.up, "bisect: keep the top half");
      keys.set(nav.right, "bisect: keep the right half");
      for (const quadrant of keyboard.navigation.quadrants) for (const cap of quadrant) keys.set(cap, "bisect: keep that quarter");
      keys.set("`", "toggle cursor-follow");
      specials.set("space", "zoom into the centre");
      specials.set("return", "click the centre now");
      specials.set("backspace", "undo a step, or back to the labels");
      specials.set("tab", "next display");
      specials.set("esc", "cancel");
      break;
    }
    case "adjusting": {
      keys.set(nav.left, "snap to the left edge");
      keys.set(nav.right, "snap to the right edge");
      keys.set(nav.up, "snap to the top edge");
      keys.set(nav.down, "snap to the bottom edge");
      for (const digit of "123456789") keys.set(digit, keyboard.adjust_digits === "grid" ? "keypad cell" : "tenths of the width");
      keys.set("0", "back to the centre");
      specials.set("return", "click here");
      specials.set("space", "click here");
      specials.set("esc", "cancel");
      break;
    }
    case "pointer": {
      keys.set(nav.left, "move left");
      keys.set(nav.right, "move right");
      keys.set(nav.up, "move up");
      keys.set(nav.down, "move down");
      keys.set("m", "left click");
      keys.set(",", "middle click");
      keys.set(".", "right click");
      keys.set("v", "hold or release the button (drag)");
      keys.set("q", "leave");
      specials.set("return", "click and leave");
      specials.set("space", "click and leave");
      specials.set("esc", "leave");
      break;
    }
    case "confirming": {
      keys.set("y", "yes");
      specials.set("esc", "no");
      break;
    }
    default:
      break;
  }
  return { keys, specials, heat };
}

/** Each alphabet key's ease, 0 to 1, from its score. */
export function alphabetHeat(keyboard: KeyboardState): Map<string, number> {
  const scores = [...keyboard.alphabet].map((cap) => keyboard.key_scores[cap] ?? 0);
  const min = Math.min(...scores);
  const max = Math.max(...scores);
  const heat = new Map<string, number>();
  for (const cap of keyboard.alphabet) {
    const score = keyboard.key_scores[cap] ?? 0;
    heat.set(cap, max > min ? (score - min) / (max - min) : 1);
  }
  return heat;
}

/** The zone key of `label_order = "zones"` for a key cap, when the cap is one. */
export function zoneOf(keyboard: KeyboardState | undefined, cap: string): { row: number; column: number; rows: number; columns: number } | null {
  if (!keyboard || keyboard.label_order !== "zones") return null;
  for (const [row, keys] of keyboard.zone_rows.entries()) {
    const column = [...keys].indexOf(cap);
    if (column >= 0) return { row, column, rows: keyboard.zone_rows.length, columns: keys.length };
  }
  return null;
}
