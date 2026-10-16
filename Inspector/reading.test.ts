import assert from "node:assert/strict";
import test from "node:test";
import { freshness, hashBody } from "./src/lib/reading.ts";
import type { DocTopic } from "./src/lib/types.ts";

const doc = (name: string, body: string): DocTopic => ({ name, title: name, summary: "", body });

test("the first visit marks nothing", () => {
  assert.equal(freshness([doc("a", "x")], null).size, 0);
});

test("a changed body is updated and an unknown guide is new", () => {
  const seen = { hashes: { a: hashBody("x"), b: hashBody("old") } };
  const fresh = freshness([doc("a", "x"), doc("b", "new"), doc("c", "z")], seen);
  assert.equal(fresh.get("a"), undefined);
  assert.equal(fresh.get("b"), "updated");
  assert.equal(fresh.get("c"), "new");
});

test("hashes are stable and short", () => {
  assert.equal(hashBody("flash"), hashBody("flash"));
  assert.equal(hashBody("flash").length, 8);
  assert.notEqual(hashBody("flash"), hashBody("flesh"));
});
