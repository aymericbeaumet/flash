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

/** The mapping scopes the live mode reads: its own and `all`. */
export function scopesForMode(mode: string | undefined): string[] {
  switch (mode) {
    case "normal": return ["normal", "all"];
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
