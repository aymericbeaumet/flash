import test from "node:test";
import assert from "node:assert/strict";
import { adopt, authorize, isDataEndpoint, token, withToken } from "./src/lib/access.ts";

const value = "a".repeat(64);
function memory(): { getItem(key: string): string | null; setItem(key: string, v: string): void; values: Map<string, string> } {
  const values = new Map<string, string>();
  return { values, getItem: (key) => values.get(key) ?? null, setItem: (key, v) => { values.set(key, v); } };
}

test("the token arrives once in the address, is kept, and leaves the address", () => {
  const store = memory();
  const clean = adopt(`http://localhost:4242/clipboard?token=${value}`, store);
  assert.equal(clean, "http://localhost:4242/clipboard");
  assert.equal(token(store), value);
  assert.equal(adopt("http://localhost:4242/mappings?q=gt", store), "http://localhost:4242/mappings?q=gt", "an address without one is left alone");
  assert.equal(token(store), value, "and keeps the token already kept");
});

test("a malformed token is dropped from the address but never kept", () => {
  const store = memory();
  assert.equal(adopt("http://localhost:4242/?token=not-hex", store), "http://localhost:4242/");
  assert.equal(token(store), null);
});

test("only Flash's data endpoints carry the token", () => {
  assert.equal(isDataEndpoint("/api/state"), true);
  assert.equal(isDataEndpoint("/api/clipboard/abc?offset=1"), true);
  assert.equal(isDataEndpoint("docs.json"), false);
  assert.equal(isDataEndpoint("https://example.com/api/state"), false);
  assert.equal(withToken("/api/events", value), `/api/events?token=${value}`);
  assert.equal(withToken("/api/clipboard/history?offset=2", value), `/api/clipboard/history?offset=2&token=${value}`);
  assert.equal(withToken("/docs/x.png", value), "/docs/x.png");
  assert.equal(withToken("/api/events", null), "/api/events");
  assert.equal(authorize("/api/config", { "Content-Type": "text/plain" }, value).get("Authorization"), `Bearer ${value}`);
  assert.equal(authorize("/api/config", { "Content-Type": "text/plain" }, value).get("Content-Type"), "text/plain");
  assert.equal(authorize("https://other.example/api/x", undefined, value).get("Authorization"), null);
});
