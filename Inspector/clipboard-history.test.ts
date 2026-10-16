import test from "node:test";
import assert from "node:assert/strict";
import { collectHistory, fetchHistory, type ClipboardPage } from "./src/lib/clipboard-history.ts";
import type { ClipboardEntry } from "./src/lib/types.ts";

const entry = (id: string): ClipboardEntry => ({ id, kind: "text", preview: id, value: id });

test("history pages fill the configured retention without duplicate entries", async () => {
  const pages = new Map<number, ClipboardPage>([
    [2, { entries: [entry("b"), entry("c")], next_offset: 4, total: 4 }],
    [4, { entries: [entry("d")], next_offset: null, total: 4 }],
  ]);
  const seen: string[][] = [];
  await collectHistory([entry("a"), entry("b")], 2, async (offset) => {
    const page = pages.get(offset);
    assert.ok(page);
    return page;
  }, (entries) => seen.push(entries.map((item) => item.id)));
  assert.deepEqual(seen, [["a", "b", "c"], ["a", "b", "c", "d"]]);
});

test("an aborted history load cannot apply an older page", async () => {
  const controller = new AbortController();
  const seen: string[][] = [];
  await collectHistory([entry("a")], 1, async () => {
    controller.abort();
    return { entries: [entry("b")], next_offset: null, total: 2 };
  }, (entries) => seen.push(entries.map((item) => item.id)), controller.signal);
  assert.deepEqual(seen, []);
});

test("a page must move its cursor forward", async () => {
  await assert.rejects(
    collectHistory([entry("a")], 1, async () => ({ entries: [entry("b")], next_offset: 1, total: 2 }), () => {}),
    /cursor/,
  );
});

test("opening Clipboard fetches page zero even when the state snapshot is empty", async () => {
  const offsets: number[] = [];
  const seen: string[][] = [];
  await fetchHistory(async (offset) => {
    offsets.push(offset);
    return offset === 0
      ? { entries: [entry("stored")], next_offset: 1, total: 2 }
      : { entries: [entry("older")], next_offset: null, total: 2 };
  }, (entries) => seen.push(entries.map((item) => item.id)));
  assert.deepEqual(offsets, [0, 1]);
  assert.deepEqual(seen, [["stored"], ["stored", "older"]]);
});

test("an aborted direct load cannot replace newer clipboard history", async () => {
  const controller = new AbortController();
  const seen: string[][] = [];
  await fetchHistory(async () => {
    controller.abort();
    return { entries: [entry("stale")], next_offset: null, total: 1 };
  }, (entries) => seen.push(entries.map((item) => item.id)), controller.signal);
  assert.deepEqual(seen, []);
});
