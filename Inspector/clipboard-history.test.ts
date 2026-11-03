import test from "node:test";
import assert from "node:assert/strict";
import { collectHistory, fetchHistory, grownLimit, HistoryLoadError, parseClipboardPage, renderStep, withUnreached, type ClipboardPage } from "./src/lib/clipboard-history.ts";
import { RequestError, withRetry } from "./src/lib/request.ts";
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

const pagesOf = (pages: Map<number, ClipboardPage>, failing: Map<number, unknown[]> = new Map()) => {
  const offsets: number[] = [];
  const fetchPage = async (offset: number) => {
    offsets.push(offset);
    const failures = failing.get(offset);
    if (failures?.length) throw failures.shift();
    const page = pages.get(offset);
    assert.ok(page, `unexpected offset ${offset}`);
    return page;
  };
  return { offsets, fetchPage };
};
const history = new Map<number, ClipboardPage>([
  [0, { entries: [entry("a"), entry("b")], next_offset: 2, total: 4 }],
  [2, { entries: [entry("c")], next_offset: 3, total: 4 }],
  [3, { entries: [entry("d")], next_offset: null, total: 4 }],
]);

test("a failed page keeps what loaded and names the offset to resume from", async () => {
  const { fetchPage } = pagesOf(history, new Map([[2, [new RequestError("http", "Internal Server Error", 500)]]]));
  const seen: string[][] = [];
  const error = await fetchHistory(fetchPage, (entries) => seen.push(entries.map((item) => item.id))).then(() => null, (caught: unknown) => caught);
  assert.ok(error instanceof HistoryLoadError);
  assert.deepEqual(error.cursor.entries.map((item) => item.id), ["a", "b"]);
  assert.equal(error.cursor.nextOffset, 2);
  assert.equal(error.cursor.total, 4);
  assert.equal(error.failure.kind, "http");
  assert.equal(error.failure.status, 500);
  assert.deepEqual(seen, [["a", "b"]]);
});

test("a retry resumes at the failing offset instead of reloading from the top", async () => {
  const failing = new Map<number, unknown[]>([[2, [new TypeError("Failed to fetch")]]]);
  const { offsets, fetchPage } = pagesOf(history, failing);
  const error = await fetchHistory(fetchPage, () => {}).then(() => null, (caught: unknown) => caught);
  assert.ok(error instanceof HistoryLoadError);
  assert.equal(error.failure.kind, "offline");
  const seen: string[][] = [];
  await collectHistory(error.cursor.entries, error.cursor.nextOffset, fetchPage, (entries) => seen.push(entries.map((item) => item.id)), undefined, error.cursor.total);
  assert.deepEqual(offsets, [0, 2, 2, 3]);
  assert.deepEqual(seen, [["a", "b", "c"], ["a", "b", "c", "d"]]);
});

test("a transient page failure is retried in place before the load gives up", async () => {
  const failing = new Map<number, unknown[]>([[2, [new RequestError("http", "Service Unavailable", 503), new RequestError("timeout", "slow")]]]);
  const { offsets, fetchPage } = pagesOf(history, failing);
  const delays: number[] = [];
  const retrying = (offset: number) => withRetry(() => fetchPage(offset), { sleep: async (ms) => { delays.push(ms); } });
  const seen: string[][] = [];
  await fetchHistory(retrying, (entries) => seen.push(entries.map((item) => item.id)));
  assert.deepEqual(offsets, [0, 2, 2, 2, 3]);
  assert.deepEqual(delays, [500, 1000]);
  assert.deepEqual(seen.at(-1), ["a", "b", "c", "d"]);
});

test("a failed first page stops at offset zero with nothing loaded", async () => {
  const { fetchPage } = pagesOf(history, new Map([[0, [new RequestError("http", "Not Found", 404)]]]));
  const error = await fetchHistory(fetchPage, () => {}).then(() => null, (caught: unknown) => caught);
  assert.ok(error instanceof HistoryLoadError);
  assert.deepEqual(error.cursor, { entries: [], nextOffset: 0, total: 0 });
});

test("a clipboard page must carry next_offset, an entries array and a total", () => {
  assert.deepEqual(parseClipboardPage({ entries: [entry("a")], next_offset: null, total: 1 }).entries.map((item) => item.id), ["a"]);
  assert.throws(() => parseClipboardPage({ entries: [entry("a")], total: 1 }), (error: unknown) => error instanceof RequestError && error.kind === "contract" && /next_offset/.test(error.message));
  assert.throws(() => parseClipboardPage({ entries: {}, next_offset: null, total: 1 }), /entries/);
  assert.throws(() => parseClipboardPage({ entries: [], next_offset: -1, total: 1 }), /next_offset/);
  assert.throws(() => parseClipboardPage({ entries: [], next_offset: null, total: 1.5 }), /total/);
  assert.throws(() => parseClipboardPage({ entries: [{ kind: "text" }], next_offset: null, total: 1 }), /id/);
  assert.equal(parseClipboardPage({ entries: [{ ...entry("a"), pinned: true }], next_offset: null, total: 1 }).entries[0].pinned, true);
  assert.throws(() => parseClipboardPage({ entries: [{ ...entry("a"), pinned: false }], next_offset: null, total: 1 }), /pinned/);
});

test("entries a reload has not reached yet stay listed after it", () => {
  const previous = [entry("a"), entry("b"), entry("c")];
  assert.deepEqual(withUnreached([entry("new"), entry("a")], previous, false).map((item) => item.id), ["new", "a", "b", "c"]);
  assert.deepEqual(withUnreached([entry("new"), entry("a")], previous, true).map((item) => item.id), ["new", "a"]);
});

test("the list renders one step more as its end nears, up to a row navigation reaches", () => {
  assert.equal(grownLimit(renderStep, 1000), 2 * renderStep);
  assert.equal(grownLimit(1000 - renderStep / 2, 1000), 1000, "never past what is available");
  assert.equal(grownLimit(1000, 1000), 1000, "complete: unchanged");
  assert.equal(grownLimit(renderStep, 1000, 640), 641, "End reaches the row it selects");
  assert.equal(grownLimit(renderStep, 1000, renderStep), 2 * renderStep, "j past the last row renders one more step");
  assert.equal(grownLimit(renderStep, renderStep / 2), renderStep, "a filter shorter than the limit stays as it is");
  assert.ok(renderStep <= 60, "the first rows fill a tall window, not the whole history: each row is dozens of elements");
});

