import type { ToastOptions } from "./toast.ts";

/**
 * What this browser has seen of the documentation (the manual's pages and
 * the plugins' guides), kept in localStorage so a veteran can tell a page
 * that changed since their last visit from one they know. The first visit
 * records everything as seen; from then on a page whose text changed is
 * "updated" and one that did not exist is "new", until it is opened. Flash
 * never receives the list.
 */
const seenKey = "flash.help.seen-guides";
const versionKey = "flash.help.seen-version";

export type Freshness = "new" | "updated" | undefined;

export interface SeenGuides {
  /** Page path or topic name to a hash of the text last opened or acknowledged. */
  hashes: Record<string, string>;
}

/**
 * Something to read: a manual page by path, or a plugin's guide by name,
 * with the `hashBody` of its text. The build hashes every manual page
 * (`ManualPage.hash`) and `bodyHash` remembers a guide's, so a snapshot or a
 * navigation never rehashes the whole manual.
 */
export interface Readable {
  name: string;
  hash: string;
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

const bodyHashes = new Map<string, string>();
const bodyHashLimit = 256;

/** `hashBody`, remembered by text: a plugin's guide arrives anew with every snapshot that carries it. */
export function bodyHash(text: string): string {
  let hash = bodyHashes.get(text);
  if (hash === undefined) {
    if (bodyHashes.size >= bodyHashLimit) bodyHashes.clear();
    hash = hashBody(text);
    bodyHashes.set(text, hash);
  }
  return hash;
}

function storage(): Storage | undefined {
  try {
    // A server render has no browser storage (and Node warns on a look).
    return typeof window === "undefined" || typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

let parsedSeen: { raw: string; seen: SeenGuides | null } | null = null;

/** What this browser has seen; the stored text is parsed again only once it changed. */
export function loadSeen(): SeenGuides | null {
  try {
    const raw = storage()?.getItem(seenKey);
    if (!raw) return null;
    if (parsedSeen?.raw !== raw) parsedSeen = { raw, seen: parseSeen(raw) };
    // A copy: the caller may keep it as reactive state.
    return parsedSeen.seen && { hashes: { ...parsedSeen.seen.hashes } };
  } catch {
    return null;
  }
}

function parseSeen(raw: string): SeenGuides | null {
  try {
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
export function freshness(docs: Readable[], seen: SeenGuides | null): Map<string, Freshness> {
  const map = new Map<string, Freshness>();
  if (!seen) return map;
  for (const doc of docs) {
    const known = seen.hashes[doc.name];
    if (known === undefined) map.set(doc.name, "new");
    else if (known !== doc.hash) map.set(doc.name, "updated");
  }
  return map;
}

/** Records the current body of one guide as seen. */
export function markSeen(doc: Readable, seen: SeenGuides | null): SeenGuides {
  const next = { hashes: { ...(seen?.hashes ?? {}) } };
  next.hashes[doc.name] = doc.hash;
  storeSeen(next);
  return next;
}

/** Records every guide as seen: the first visit, or "mark all as read". */
export function markAllSeen(docs: Readable[]): SeenGuides {
  const next = { hashes: Object.fromEntries(docs.map((doc) => [doc.name, doc.hash])) };
  storeSeen(next);
  return next;
}

/**
 * Names everything there is to read as it is now: it changes when a page or
 * guide is added, removed or edited, not as the reader opens pages. A
 * dismissed notice sticks under it until the documentation changes again.
 */
export function readingKey(docs: Readable[]): string {
  return hashBody(docs.map((doc) => `${doc.name}\u0000${doc.hash}`).sort().join("\n"));
}

/**
 * The toast that explains the ✨ marks while anything is new or updated,
 * with "Mark all as read". Dismissing it holds until the documentation
 * changes again (`key`, from `readingKey`).
 */
export function freshNotice(key: string, markAllRead: () => void): ToastOptions {
  return {
    id: "docs-fresh",
    icon: { name: "sparkle", label: "New or updated" },
    tone: "fresh",
    message: "marks what is new or updated since your last visit.",
    actions: [{ label: "Mark all as read", run: markAllRead }],
    dismissLabel: "Dismiss the new pages notice",
    persist: `docs-fresh:${key}`,
  };
}

/** The version this browser last saw, and whether it just changed. */
export function versionChanged(version: string | undefined): { previous: string | null; changed: boolean } {
  if (!version) return { previous: null, changed: false };
  const store = storage();
  const previous = store?.getItem(versionKey) ?? null;
  if (previous !== version) store?.setItem(versionKey, version);
  return { previous, changed: previous !== null && previous !== version };
}
