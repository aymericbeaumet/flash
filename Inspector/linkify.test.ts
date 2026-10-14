import assert from "node:assert/strict";
import test from "node:test";
import { linkSegments } from "./src/lib/linkify.ts";

test("web and mail links become segments with their target; the rest stays text", () => {
  assert.deepEqual(linkSegments("see https://example.com/a?b=1, then mail me"), [
    { text: "see " },
    { text: "https://example.com/a?b=1", href: "https://example.com/a?b=1" },
    { text: ", then mail me" },
  ]);
  assert.deepEqual(linkSegments("mailto:a@b.co"), [{ text: "mailto:a@b.co", href: "mailto:a@b.co" }]);
  assert.deepEqual(linkSegments("(http://x.io/p)."), [
    { text: "(" },
    { text: "http://x.io/p", href: "http://x.io/p" },
    { text: ")." },
  ]);
});

test("nothing else is a link", () => {
  assert.deepEqual(linkSegments("javascript:alert(1) file:///etc/hosts plain"), [
    { text: "javascript:alert(1) file:///etc/hosts plain" },
  ]);
  assert.deepEqual(linkSegments(""), []);
});
