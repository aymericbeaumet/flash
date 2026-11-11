import assert from "node:assert/strict";
import test from "node:test";
import { htmlParts } from "./src/lib/html-parts.ts";

test("raw HTML splits into allowed tags and text; everything else is text or dropped", () => {
  assert.deepEqual(htmlParts("<details><summary>S</summary>"), [
    { tag: "details", close: false },
    { tag: "summary", close: false },
    { text: "S" },
    { tag: "summary", close: true },
  ]);
  assert.deepEqual(htmlParts("press <kbd>f</kbd><br/>"), [
    { text: "press " },
    { tag: "kbd", close: false },
    { text: "f" },
    { tag: "kbd", close: true },
    { tag: "br", close: false },
  ]);
  // Attributes never survive; unknown and dangerous tags are dropped.
  assert.deepEqual(htmlParts('<span onclick="x()">a</span><script>alert(1)</script><img src=x onerror=y>'), [
    { tag: "span", close: false },
    { text: "a" },
    { tag: "span", close: true },
    { text: "alert(1)" },
  ]);
  assert.deepEqual(htmlParts("a < b"), [{ text: "a < b" }]);
  // An HTML comment is a note to the source (`<!-- modes: assumed on -->`), never text.
  assert.deepEqual(htmlParts("<!-- modes: assumed on -->"), []);
  assert.deepEqual(htmlParts("a<!-- note -->b"), [{ text: "ab" }]);
});

test("comments cannot join text fragments into raw HTML tags", () => {
  assert.deepEqual(htmlParts("<kb<!-- note -->d>key"), [{ text: "<kbd>key" }]);
  assert.deepEqual(htmlParts("<<!-- note -->!-- literal -->"), [{ text: "<!-- literal -->" }]);
  assert.deepEqual(htmlParts("a<!-- <kbd>hidden</kbd> -->b<kbd>key</kbd>"), [
    { text: "ab" },
    { tag: "kbd", close: false },
    { text: "key" },
    { tag: "kbd", close: true },
  ]);
});

test("an unterminated HTML comment hides the rest of its raw run", () => {
  assert.deepEqual(htmlParts("before<!-- <kbd>hidden"), [{ text: "before" }]);
  assert.deepEqual(htmlParts("<!-- unfinished"), []);
});

test("comment-like attribute text is discarded with its allowed tag's attributes", () => {
  assert.deepEqual(htmlParts('<kbd title="<!-- note -->">key</kbd>'), [
    { tag: "kbd", close: false },
    { text: "key" },
    { tag: "kbd", close: true },
  ]);
});
