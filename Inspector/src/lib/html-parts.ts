/** One piece of a raw HTML run in Markdown: an allowed tag, or text. */
export type HTMLPart = { tag: string; close: boolean } | { text: string };

/** Tags documentation may write as raw HTML. Attributes are never kept. */
export const allowedRawTags = new Set(["details", "summary", "kbd", "sup", "sub", "br", "span", "div", "del"]);

const partPattern = /<!--[\s\S]*?(?:-->|$)|<(\/?)([a-zA-Z][a-zA-Z0-9]*)\b(?:[^<>"']|"[^"]*"|'[^']*')*>/g;

/** A raw HTML run split into allowed tags (no attributes) and plain text;
 * every other tag is dropped and its text kept as text, and an HTML comment
 * (`<!-- modes: assumed on -->`, a note to the page's tests) is nothing.
 * Nothing here is ever parsed as HTML: the caller builds elements and text
 * nodes from the parts. */
export function htmlParts(raw: string): HTMLPart[] {
  const parts: HTMLPart[] = [];
  const pushText = (text: string) => {
    if (!text) return;
    const previous = parts[parts.length - 1];
    if (previous && "text" in previous) previous.text += text;
    else parts.push({ text });
  };
  // Tokenize the original input: deleting comments first could turn
  // `<kb<!-- note -->d>` into a tag that was never in the source.
  let last = 0;
  for (const match of raw.matchAll(partPattern)) {
    const start = match.index ?? 0;
    pushText(raw.slice(last, start));
    if (match[2]) {
      const tag = match[2].toLowerCase();
      if (allowedRawTags.has(tag)) parts.push({ tag, close: match[1] === "/" });
    }
    last = start + match[0].length;
  }
  pushText(raw.slice(last));
  return parts;
}
