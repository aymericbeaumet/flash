import type { DocTopic } from "./types.ts";

/**
 * What this browser has seen of the guides, kept in localStorage so a veteran
 * can tell a guide that changed since their last visit from one they know.
 * The first visit records everything as seen; from then on a guide whose
 * body changed is "updated" and a guide that did not exist is "new", until
 * it is opened. Flash never receives the list.
 */
const seenKey = "flash.help.seen-guides";
const versionKey = "flash.help.seen-version";

export type Freshness = "new" | "updated" | undefined;

export interface SeenGuides {
  /** Topic name to a hash of the body last opened or acknowledged. */
  hashes: Record<string, string>;
}

/** FNV-1a over the body: short, stable, and enough to notice an edit. */
export function hashBody(text: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, "0");
}

function storage(): Storage | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

export function loadSeen(): SeenGuides | null {
  try {
    const raw = storage()?.getItem(seenKey);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object" || !("hashes" in parsed)) return null;
    const hashes = (parsed as { hashes: unknown }).hashes;
    if (!hashes || typeof hashes !== "object") return null;
    return { hashes: Object.fromEntries(Object.entries(hashes as Record<string, unknown>).filter(([, value]) => typeof value === "string")) as Record<string, string> };
  } catch {
    return null;
  }
}

function storeSeen(seen: SeenGuides) {
  storage()?.setItem(seenKey, JSON.stringify(seen));
}

/** Freshness of every guide against what was seen; null means first visit. */
export function freshness(docs: DocTopic[], seen: SeenGuides | null): Map<string, Freshness> {
  const map = new Map<string, Freshness>();
  if (!seen) return map;
  for (const doc of docs) {
    const known = seen.hashes[doc.name];
    if (known === undefined) map.set(doc.name, "new");
    else if (known !== hashBody(doc.body)) map.set(doc.name, "updated");
  }
  return map;
}

/** Records the current body of one guide as seen. */
export function markSeen(doc: DocTopic, seen: SeenGuides | null): SeenGuides {
  const next = { hashes: { ...(seen?.hashes ?? {}) } };
  next.hashes[doc.name] = hashBody(doc.body);
  storeSeen(next);
  return next;
}

/** Records every guide as seen: the first visit, or "mark all as read". */
export function markAllSeen(docs: DocTopic[]): SeenGuides {
  const next = { hashes: Object.fromEntries(docs.map((doc) => [doc.name, hashBody(doc.body)])) };
  storeSeen(next);
  return next;
}

/** The version this browser last saw, and whether it just changed. */
export function versionChanged(version: string | undefined): { previous: string | null; changed: boolean } {
  if (!version) return { previous: null, changed: false };
  const store = storage();
  const previous = store?.getItem(versionKey) ?? null;
  if (previous !== version) store?.setItem(versionKey, version);
  return { previous, changed: previous !== null && previous !== version };
}
