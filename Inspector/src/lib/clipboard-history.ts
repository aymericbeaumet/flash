import type { ClipboardEntry } from "./types";

export interface ClipboardPage {
  entries: ClipboardEntry[];
  next_offset: number | null;
  total: number;
}

export async function fetchHistory(
  fetchPage: (offset: number) => Promise<ClipboardPage>,
  onPage: (entries: ClipboardEntry[], nextOffset: number | null, total: number) => void,
  signal?: AbortSignal,
): Promise<void> {
  const first = await fetchPage(0);
  if (signal?.aborted) return;
  onPage(first.entries, first.next_offset, first.total);
  await collectHistory(first.entries, first.next_offset, fetchPage, onPage, signal);
}

export async function collectHistory(
  first: ClipboardEntry[],
  nextOffset: number | null,
  fetchPage: (offset: number) => Promise<ClipboardPage>,
  onPage: (entries: ClipboardEntry[], nextOffset: number | null, total: number) => void,
  signal?: AbortSignal,
): Promise<void> {
  const entries = [...first];
  const ids = new Set(first.map((entry) => entry.id));
  let offset = nextOffset;
  while (offset !== null && !signal?.aborted) {
    const page = await fetchPage(offset);
    if (signal?.aborted) return;
    if (page.next_offset !== null && (!Number.isSafeInteger(page.next_offset) || page.next_offset <= offset)) {
      throw new Error("Clipboard history cursor did not advance");
    }
    for (const entry of page.entries) {
      if (ids.has(entry.id)) continue;
      ids.add(entry.id);
      entries.push(entry);
    }
    onPage([...entries], page.next_offset, page.total);
    offset = page.next_offset;
  }
}
