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
});
