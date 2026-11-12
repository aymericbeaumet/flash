import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { gzipSync } from "node:zlib";

// The help is one HTML document every page load parses and runs whole
// (`DebugServer` serves it at every page path), so its size is load time.
// The budget leaves room for ordinary growth and stops a new dependency or a
// duplicated table from slipping in: measure what it costs to load
// (docs/performance.md, "Browser help") before raising it.
const budget = { bytes: 460 * 1024, gzipBytes: 135 * 1024 };

test("the committed help page stays within its size budget", () => {
  const page = readFileSync(new URL("../Sources/flash/Resources/inspector.html", import.meta.url));
  const gzip = gzipSync(page, { level: 9 }).length;
  const kib = (bytes: number) => `${(bytes / 1024).toFixed(1)} KiB`;
  assert.ok(page.length <= budget.bytes, `inspector.html is ${kib(page.length)}, over its ${kib(budget.bytes)} budget`);
  assert.ok(gzip <= budget.gzipBytes, `inspector.html is ${kib(gzip)} gzipped, over its ${kib(budget.gzipBytes)} budget`);
});
