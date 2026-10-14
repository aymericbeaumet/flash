/** One run of text: plain, or a link with the target it opens. */
export interface TextSegment {
  text: string;
  href?: string;
}

// Web and mail links only: nothing that runs script or reads local files.
const linkPattern = /\b(?:https?:\/\/|mailto:)[^\s<>"'`]+/gi;
// Punctuation that ends a sentence around a link rather than belonging to it.
const trailing = /[.,;:!?)\]}]+$/;

/** `text` split into plain runs and the web or mail links inside it. */
export function linkSegments(text: string): TextSegment[] {
  const segments: TextSegment[] = [];
  let last = 0;
  for (const match of text.matchAll(linkPattern)) {
    const start = match.index ?? 0;
    const raw = match[0];
    const href = raw.replace(trailing, "");
    if (start > last) segments.push({ text: text.slice(last, start) });
    segments.push({ text: href, href });
    last = start + href.length;
  }
  if (last < text.length) segments.push({ text: text.slice(last) });
  return segments;
}
