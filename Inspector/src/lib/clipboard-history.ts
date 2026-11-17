import { contractError, classify, type RequestError } from "./request.ts";
import type { ClipboardEntry } from "./types.ts";

export interface ClipboardPage {
  entries: ClipboardEntry[];
  next_offset: number | null;
  total: number;
}

/** How far a history load got: the entries so far and the next page to ask for. */
export interface HistoryCursor {
  entries: ClipboardEntry[];
  /** The offset of the next page, or null once the history is complete. */
  nextOffset: number | null;
  total: number;
}

/** A load that stopped: everything it loaded is kept, and `cursor.nextOffset`
 * is the page that failed, so a retry resumes there rather than at the top. */
export class HistoryLoadError extends Error {
  readonly cursor: HistoryCursor;
  readonly failure: RequestError;

  constructor(cursor: HistoryCursor, failure: RequestError) {
    super(failure.message);
    this.name = "HistoryLoadError";
    this.cursor = cursor;
    this.failure = failure;
  }
}

const isOffset = (value: unknown) => Number.isSafeInteger(value) && Number(value) >= 0;

/** Reads one `/api/clipboard/history` reply, naming the field that breaks the contract. */
export function parseClipboardPage(value: unknown): ClipboardPage {
  if (typeof value !== "object" || value === null) throw contractError("clipboard page is not an object");
  const page = value as Record<string, unknown>;
  if (!Array.isArray(page.entries)) throw contractError("clipboard page has no entries array");
  if (!("next_offset" in page)) throw contractError("clipboard page has no next_offset");
  if (page.next_offset !== null && !isOffset(page.next_offset)) throw contractError("clipboard page next_offset is not an offset or null");
  if (!isOffset(page.total)) throw contractError("clipboard page total is not a count");
  for (const entry of page.entries) {
    if (typeof entry !== "object" || entry === null || typeof (entry as ClipboardEntry).id !== "string" || typeof (entry as ClipboardEntry).kind !== "string") {
      throw contractError("clipboard entry without an id and kind");
    }
    if ("pinned" in entry && (entry as ClipboardEntry).pinned !== true) throw contractError("clipboard entry pinned is not true");
  }
  return page as unknown as ClipboardPage;
}

export async function fetchHistory(
  fetchPage: (offset: number) => Promise<ClipboardPage>,
  onPage: (entries: ClipboardEntry[], nextOffset: number | null, total: number) => void,
  signal?: AbortSignal,
): Promise<void> {
  let first: ClipboardPage;
  try {
    first = await fetchPage(0);
  } catch (error) {
    throw new HistoryLoadError({ entries: [], nextOffset: 0, total: 0 }, classify(error));
  }
  if (signal?.aborted) return;
  onPage(first.entries, first.next_offset, first.total);
  await collectHistory(first.entries, first.next_offset, fetchPage, onPage, signal, first.total);
}

/** Loads the pages from `nextOffset` on after `first`. A failed page rejects
 * with a `HistoryLoadError` whose cursor keeps every entry loaded so far. */
export async function collectHistory(
  first: ClipboardEntry[],
  nextOffset: number | null,
  fetchPage: (offset: number) => Promise<ClipboardPage>,
  onPage: (entries: ClipboardEntry[], nextOffset: number | null, total: number) => void,
  signal?: AbortSignal,
  total = first.length,
): Promise<void> {
  const entries = [...first];
  const ids = new Set(first.map((entry) => entry.id));
  let offset = nextOffset;
  let known = total;
  while (offset !== null && !signal?.aborted) {
    let page: ClipboardPage;
    try {
      page = await fetchPage(offset);
      if (page.next_offset !== null && (!Number.isSafeInteger(page.next_offset) || page.next_offset <= offset)) {
        throw contractError("clipboard history cursor did not advance");
      }
    } catch (error) {
      throw new HistoryLoadError({ entries: [...entries], nextOffset: offset, total: known }, classify(error));
    }
    if (signal?.aborted) return;
    for (const entry of page.entries) {
      if (ids.has(entry.id)) continue;
      ids.add(entry.id);
      entries.push(entry);
    }
    known = page.total;
    onPage([...entries], page.next_offset, page.total);
    offset = page.next_offset;
  }
}

/** While a reload is still under way, or after it stopped early, the older
 * entries it has not reached stay listed after the ones it reloaded. */
export function withUnreached(loaded: ClipboardEntry[], previous: ClipboardEntry[], complete: boolean): ClipboardEntry[] {
  if (complete) return loaded;
  const ids = new Set(loaded.map((entry) => entry.id));
  return [...loaded, ...previous.filter((entry) => !ids.has(entry.id))];
}

/** Rows rendered at first, and added each time the list's end comes near:
 * more than a tall window shows, so opening the page builds no more rows
 * than it can display. */
export const renderStep = 50;

/** The render limit after the list's end came near, or a row past it was
 * reached (`reach`, a 0-based index): one more step, or up to that row,
 * never past what is `available`. */
export function grownLimit(limit: number, available: number, reach = limit, step = renderStep): number {
  if (limit >= available) return limit;
  return Math.min(Math.max(limit + step, reach + 1), available);
}
