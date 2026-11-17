import assert from "node:assert/strict";
import test from "node:test";
import { bodyHash, freshness, hashBody, type Readable } from "./src/lib/reading.ts";

const doc = (name: string, body: string): Readable => ({ name, hash: hashBody(body) });

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

test("a guide's hash is remembered by its text", () => {
  const body = "a guide ".repeat(1000);
  assert.equal(bodyHash(body), hashBody(body));
  assert.equal(bodyHash(`${body}`), bodyHash(body));
  assert.notEqual(bodyHash(`${body}!`), bodyHash(body));
});
