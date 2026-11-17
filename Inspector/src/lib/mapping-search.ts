import type { CommandInfo, MappingRow } from "./types";

export interface SearchFields {
  key: string;
  action: string;
  explanation: string;
  scope: string;
  source: string;
}

type FieldName = keyof SearchFields;

const fieldWeight: Record<FieldName, number> = {
  key: 1.35,
  explanation: 1.25,
  action: 1,
  source: 0.5,
  scope: 0.35,
};
const fieldNames = Object.keys(fieldWeight) as FieldName[];

/** One field as the ranking reads it: normalized once, with its words and its spaceless form. */
interface PreparedField {
  text: string;
  words: string[];
  compact: string;
}

/**
 * A row's fields, normalized once. A search ranks every row of a mode on each
 * keystroke; preparing the haystack when the rows arrive keeps a keystroke to
 * the comparisons alone.
 */
export interface PreparedSearch {
  fields: Record<FieldName, PreparedField>;
}

/** The sentence the row's ? shows. A plugin command uses its own description. */
export function explainMapping(row: MappingRow, commands: CommandInfo[]): string {
  return pluginDescription(row.action, commands) || row.explanation?.trim() || row.action;
}

/** Haystack for ranking. The visible sentence and the verb sentence both count. */
export function searchFields(row: MappingRow, commands: CommandInfo[], source: string): SearchFields {
  const plugin = pluginDescription(row.action, commands);
  const base = row.explanation?.trim() ?? "";
  const visible = plugin || base || row.action;
  const explanation = unique([visible, base, plugin]).join(" ");
  return { key: row.key, action: row.action, explanation, scope: row.scope, source };
}

export function prepareSearch(fields: SearchFields): PreparedSearch {
  const prepared = {} as Record<FieldName, PreparedField>;
  for (const name of fieldNames) {
    const text = normalize(fields[name]);
    prepared[name] = { text, words: text.split(" "), compact: text.replace(/ /g, "") };
  }
  return { fields: prepared };
}

/** The words of a query, as `scorePrepared` takes them. */
export function queryTokens(query: string): string[] {
  return normalize(query).split(" ").filter(Boolean);
}

/**
 * Higher is a closer match. `null` means the query does not match.
 * An empty query matches nothing here; the caller shows the full list.
 */
export function scoreSearch(query: string, fields: SearchFields): number | null {
  return scorePrepared(queryTokens(query), prepareSearch(fields));
}

export function scorePrepared(tokens: string[], search: PreparedSearch): number | null {
  if (!tokens.length) return null;
  let total = 0;
  for (const token of tokens) {
    let best = 0;
    for (const name of fieldNames) {
      best = Math.max(best, scoreField(token, search.fields[name]) * fieldWeight[name]);
    }
    if (best <= 0) return null;
    total += best;
  }
  const phrase = tokens.join(" ");
  if (phrase.includes(" ") && search.fields.explanation.text.includes(phrase)) total += 40;
  return total;
}

/** Plugin commands by `flash <command> <subcommand>`, built once per command list. */
const commandIndexes = new WeakMap<CommandInfo[], Map<string, { first: CommandInfo; last: CommandInfo }>>();

function commandIndex(commands: CommandInfo[]) {
  let index = commandIndexes.get(commands);
  if (!index) {
    index = new Map();
    for (const command of commands) {
      if (command.source_kind !== "plugin" || !command.command || !command.subcommand) continue;
      const head = `flash ${command.command} ${command.subcommand}`;
      const found = index.get(head);
      if (found) found.last = command;
      else index.set(head, { first: command, last: command });
    }
    commandIndexes.set(commands, index);
  }
  return index;
}

/**
 * The plugin command `action` runs: its head exactly, or the head and its
 * arguments. An exact head takes the last command declaring it, arguments
 * the first.
 */
function pluginDescription(action: string, commands: CommandInfo[]): string {
  const words = action.split(" ", 3);
  if (words.length < 3) return "";
  const head = words.join(" ");
  if (action !== head && !action.startsWith(`${head} `)) return "";
  const found = commandIndex(commands).get(head);
  if (!found) return "";
  return (action === head ? found.last : found.first).description?.trim() ?? "";
}

function unique(parts: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const part of parts) {
    if (!part || seen.has(part)) continue;
    seen.add(part);
    out.push(part);
  }
  return out;
}

function normalize(text: string): string {
  return text.toLowerCase().replace(/[_+]/g, " ").replace(/-/g, " ").replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();
}

function scoreField(token: string, field: PreparedField): number {
  if (!token || !field.text) return 0;
  const wholeWord = field.words.includes(token);
  // One or two characters are keys (`f`, `gg`), not letters inside another word.
  if (token.length <= 2) return wholeWord ? (field.text === token ? 160 : 135) : 0;
  if (field.text.includes(token)) {
    return wholeWord ? (field.text === token ? 160 : 135) : 100;
  }
  if (token.length >= 6 && field.compact.includes(token)) return 90;
  let best = 0;
  for (const word of field.words) {
    if (word.length < 2) continue;
    const maxDistance = token.length <= 3 ? 0 : token.length <= 5 ? 1 : 2;
    if (maxDistance > 0 && Math.abs(word.length - token.length) <= maxDistance) {
      const distance = damerau(token, word, maxDistance);
      if (distance <= maxDistance) best = Math.max(best, 78 - distance * 18);
    }
    best = Math.max(best, subsequence(token, word) ?? 0);
  }
  return best;
}

function subsequence(needle: string, word: string): number | null {
  if (needle.length < 4 || needle.length > word.length) return null;
  let matched = 0;
  let skipped = 0;
  for (const char of word) {
    if (matched < needle.length && char === needle[matched]) matched += 1;
    else if (matched > 0 && matched < needle.length) {
      skipped += 1;
      if (skipped > 2) return null;
    }
  }
  return matched === needle.length ? 46 - skipped * 10 : null;
}

function damerau(left: string, right: string, max: number): number {
  const rows = left.length + 1;
  const cols = right.length + 1;
  const dp: number[][] = Array.from({ length: rows }, () => new Array<number>(cols).fill(0));
  for (let i = 0; i < rows; i += 1) dp[i][0] = i;
  for (let j = 0; j < cols; j += 1) dp[0][j] = j;
  for (let i = 1; i < rows; i += 1) {
    let rowMin = max + 1;
    for (let j = 1; j < cols; j += 1) {
      const cost = left[i - 1] === right[j - 1] ? 0 : 1;
      let best = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost);
      if (i > 1 && j > 1 && left[i - 1] === right[j - 2] && left[i - 2] === right[j - 1]) {
        best = Math.min(best, dp[i - 2][j - 2] + 1);
      }
      dp[i][j] = best;
      if (best < rowMin) rowMin = best;
    }
    if (rowMin > max) return max + 1;
  }
  return dp[left.length][right.length];
}
