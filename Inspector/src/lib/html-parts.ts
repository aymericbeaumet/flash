/** One piece of a raw HTML run in Markdown: an allowed tag, or text. */
export type HTMLPart = { tag: string; close: boolean } | { text: string };

/** Tags documentation may write as raw HTML. Attributes are never kept. */
export const allowedRawTags = new Set(["details", "summary", "kbd", "sup", "sub", "br", "span", "div", "del"]);

const tagPattern = /<(\/?)([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>/g;

/** A raw HTML run split into allowed tags (no attributes) and plain text;
 * every other tag is dropped and its text kept as text. Nothing here is ever
 * parsed as HTML: the caller builds elements and text nodes from the parts. */
export function htmlParts(raw: string): HTMLPart[] {
  const parts: HTMLPart[] = [];
  let last = 0;
  const pushText = (text: string) => {
    if (!text) return;
    const previous = parts[parts.length - 1];
    if (previous && "text" in previous) previous.text += text;
    else parts.push({ text });
  };
  for (const match of raw.matchAll(tagPattern)) {
    const start = match.index ?? 0;
    pushText(raw.slice(last, start));
    const tag = match[2].toLowerCase();
    if (allowedRawTags.has(tag)) parts.push({ tag, close: match[1] === "/" });
    last = start + match[0].length;
  }
  pushText(raw.slice(last));
  return parts;
}
