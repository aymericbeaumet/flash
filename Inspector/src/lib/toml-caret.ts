// Which key of a TOML document the caret is on: the table it sits in and the
// key its line assigns, for the config editor's key help. A scanner, not a
// parser: it follows table headers, keys and values that stay open across
// lines, and reads no value.

/** What a value leaves open at the end of a line. */
interface Open {
  /** Unclosed `[` and `{`. */
  depth: number;
  /** The delimiter of a multi-line string still open. */
  string: '"""' | "'''" | null;
}

/** A dotted key (`a."b.c".d`) from `start`: its parts and where it ends. */
function readKey(line: string, start: number): { parts: string[]; end: number } | null {
  const parts: string[] = [];
  let index = start;
  for (;;) {
    while (line[index] === " " || line[index] === "\t") index += 1;
    const quote = line[index];
    if (quote === '"' || quote === "'") {
      let end = index + 1;
      let part = "";
      while (end < line.length && line[end] !== quote) {
        if (quote === '"' && line[end] === "\\" && end + 1 < line.length) end += 1;
        part += line[end];
        end += 1;
      }
      if (end >= line.length) return null;
      parts.push(part);
      index = end + 1;
    } else {
      const bare = /^[A-Za-z0-9_-]+/.exec(line.slice(index));
      if (!bare) return null;
      parts.push(bare[0]);
      index += bare[0].length;
    }
    while (line[index] === " " || line[index] === "\t") index += 1;
    if (line[index] !== ".") return { parts, end: index };
    index += 1;
  }
}

/** Follows a value's text from `start`, updating what it leaves open. */
function scanValue(line: string, start: number, open: Open) {
  let index = start;
  while (index < line.length) {
    if (open.string) {
      const close = line.indexOf(open.string, index);
      if (close === -1) return;
      index = close + 3;
      open.string = null;
      continue;
    }
    const character = line[index];
    if (character === "#") return;
    if (character === '"' || character === "'") {
      const triple = character.repeat(3);
      if (line.startsWith(triple, index)) {
        open.string = triple as Open["string"];
        index += 3;
        continue;
      }
      index += 1;
      while (index < line.length && line[index] !== character) {
        if (character === '"' && line[index] === "\\") index += 1;
        index += 1;
      }
      index += 1;
      continue;
    }
    if (character === "[" || character === "{") open.depth += 1;
    else if ((character === "]" || character === "}") && open.depth > 0) open.depth -= 1;
    index += 1;
  }
}

/**
 * The key path at `offset` of `text`: the caret's table, then the key its
 * line assigns (or the key whose value is still open there). A blank line or
 * a comment answers its table; text before any table answers `[]`.
 */
export function keyPathAt(text: string, offset: number): string[] {
  let table: string[] = [];
  let key: string[] | null = null;
  const open: Open = { depth: 0, string: null };
  let position = 0;
  for (const raw of text.split("\n")) {
    const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
    const continued = open.depth > 0 || open.string !== null;
    if (continued) scanValue(line, 0, open);
    else {
      key = null;
      const content = line.trimStart();
      const indent = line.length - content.length;
      if (content.startsWith("[")) {
        const brackets = content.startsWith("[[") ? 2 : 1;
        const header = readKey(line, indent + brackets);
        if (header && line.startsWith("]".repeat(brackets), header.end)) table = header.parts;
      } else if (content && !content.startsWith("#")) {
        const assigned = readKey(line, indent);
        if (assigned && line[assigned.end] === "=") {
          key = assigned.parts;
          scanValue(line, assigned.end + 1, open);
        }
      }
    }
    if (offset <= position + raw.length) break;
    position += raw.length + 1;
  }
  return key ? [...table, ...key] : table;
}
