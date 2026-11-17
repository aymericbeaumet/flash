import test from "node:test";
import assert from "node:assert/strict";
import { backoff, classify, describeFailure, RequestError, requestJSON, withRetry } from "./src/lib/request.ts";

const noWait = (delays: number[]) => async (ms: number) => { delays.push(ms); };

test("failures are classified by whether trying again can help", () => {
  assert.equal(classify(new TypeError("Failed to fetch")).kind, "offline");
  assert.equal(classify(new TypeError("Failed to fetch")).transient, true);
  assert.equal(new RequestError("http", "Service Unavailable", 503).transient, true);
  assert.equal(new RequestError("http", "Too Many Requests", 429).transient, true);
  assert.equal(new RequestError("http", "Not Found", 404).transient, false);
  assert.equal(new RequestError("contract", "no next_offset").transient, false);
  assert.equal(classify(new DOMException("stop", "AbortError")).kind, "aborted");
  assert.equal(classify(new SyntaxError("Unexpected token")).kind, "contract");
});

test("an inline error says what failed", () => {
  assert.match(describeFailure(new TypeError("Failed to fetch")), /not answering \(offline\)/);
  assert.match(describeFailure(new RequestError("http", "Internal Server Error", 500)), /HTTP 500: Internal Server Error/);
  assert.match(describeFailure(new RequestError("contract", "clipboard page has no next_offset")), /contract error.*next_offset/);
  assert.match(describeFailure(new RequestError("timeout", "slow")), /timeout/);
});

test("backoff doubles from its base up to its cap", () => {
  assert.deepEqual([1, 2, 3, 4, 5, 6].map((attempt) => backoff(attempt, 500, 8000)), [500, 1000, 2000, 4000, 8000, 8000]);
});

test("transient failures are retried with backoff until one succeeds", async () => {
  const delays: number[] = [];
  const retries: number[] = [];
  let calls = 0;
  const value = await withRetry(async () => {
    calls += 1;
    if (calls < 3) throw new RequestError("http", "Service Unavailable", 503);
    return "page";
  }, { sleep: noWait(delays), onRetry: (_failure, attempt) => retries.push(attempt) });
  assert.equal(value, "page");
  assert.equal(calls, 3);
  assert.deepEqual(delays, [500, 1000]);
  assert.deepEqual(retries, [1, 2]);
});

test("retrying stops after a few tries with the classified failure", async () => {
  const delays: number[] = [];
  let calls = 0;
  await assert.rejects(
    withRetry(async () => { calls += 1; throw new TypeError("Failed to fetch"); }, { retries: 3, sleep: noWait(delays) }),
    (error: unknown) => error instanceof RequestError && error.kind === "offline",
  );
  assert.equal(calls, 4);
  assert.deepEqual(delays, [500, 1000, 2000]);
});

test("a refused request or an unreadable reply is not retried", async () => {
  for (const failure of [new RequestError("http", "Not Found", 404), new RequestError("contract", "bad page")]) {
    let calls = 0;
    await assert.rejects(withRetry(async () => { calls += 1; throw failure; }, { sleep: noWait([]) }), failure);
    assert.equal(calls, 1);
  }
});

test("an abort during the wait ends the retries", async () => {
  const controller = new AbortController();
  let calls = 0;
  await assert.rejects(
    withRetry(async () => { calls += 1; throw new RequestError("timeout", "slow"); }, {
      signal: controller.signal,
      sleep: async () => { controller.abort(); },
    }),
    (error: unknown) => error instanceof RequestError && error.kind === "aborted",
  );
  assert.equal(calls, 1);
});

test("requestJSON turns statuses, bodies and network errors into classified failures", async (t) => {
  const original = globalThis.fetch;
  t.after(() => { globalThis.fetch = original; });
  globalThis.fetch = async () => new Response(JSON.stringify({ error: "config is locked" }), { status: 503 });
  await assert.rejects(requestJSON("/api/config"), (error: unknown) => error instanceof RequestError && error.kind === "http" && error.status === 503 && error.message === "config is locked");
  globalThis.fetch = async () => new Response("<html>", { status: 200 });
  await assert.rejects(requestJSON("/api/state"), (error: unknown) => error instanceof RequestError && error.kind === "contract");
  globalThis.fetch = async () => { throw new TypeError("Failed to fetch"); };
  await assert.rejects(requestJSON("/api/state"), (error: unknown) => error instanceof RequestError && error.kind === "offline");
  globalThis.fetch = async () => new Response(JSON.stringify({ ok: true }), { status: 200 });
  assert.deepEqual(await requestJSON("/api/state"), { ok: true });
});

test("requestJSON tells a time limit from the caller's own abort", async (t) => {
  const original = globalThis.fetch;
  t.after(() => { globalThis.fetch = original; });
  globalThis.fetch = (_url, init) => new Promise((_resolve, reject) => {
    init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
  });
  await assert.rejects(requestJSON("/api/state", { timeoutMs: 5 }), (error: unknown) => error instanceof RequestError && error.kind === "timeout" && error.transient);
  const controller = new AbortController();
  const pending = requestJSON("/api/state", { signal: controller.signal });
  controller.abort();
  await assert.rejects(pending, (error: unknown) => error instanceof RequestError && error.kind === "aborted");
});
