import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { measureSite, overBudget, type SiteBudget, type SiteSizes } from "./scripts/site-sizes.ts";

// What a reader of the published site downloads is its weight: a page is its
// HTML, and every page shares the script, the styles and the navigation; a
// search starts from the outline. Each budget sits about 12% above what the
// site weighed when it was set (2026-11-19, 175 pages): room for the manual
// to grow, none for a second copy of an article, a navigation inlined into
// every page or a new dependency. Measure before raising one
// (`mise run bench:help -- --site`, docs/performance.md, "The published site").
// The largest page is the plugin protocol, which grows with every host RPC
// and capability: its budget was measured again the same day, at 155.9 KiB.
// The script was measured again on 2026-11-22, at 92.0 KiB (33.8 KiB gzipped):
// Svelte 5.59's runtime, with its custom renderer API, is 10.6 KiB larger.
const KiB = 1024;
const budget: SiteBudget = {
  html: { raw: 8700 * KiB, gzip: 1860 * KiB },
  medianPage: { raw: 45 * KiB, gzip: 9 * KiB },
  largestPage: { raw: 175 * KiB, gzip: 49.5 * KiB },
  js: { raw: 103 * KiB, gzip: 37.8 * KiB },
  css: { raw: 40.5 * KiB, gzip: 7.9 * KiB },
  navigation: { raw: 39.5 * KiB, gzip: 5.8 * KiB },
  searchOutline: { raw: 66 * KiB, gzip: 12.4 * KiB },
};

const weight = (raw: number, gzip: number) => ({ raw, gzip });
const sample: SiteSizes = {
  pages: 3,
  stubs: 1,
  html: weight(300 * KiB, 60 * KiB),
  medianPage: { file: "hints/index.html", ...weight(40 * KiB, 8 * KiB) },
  largestPage: { file: "commands/index.html", ...weight(130 * KiB, 30 * KiB) },
  js: weight(80 * KiB, 30 * KiB),
  css: weight(36 * KiB, 7 * KiB),
  navigation: { file: "_app/nav-a.json", ...weight(35 * KiB, 5 * KiB) },
  searchOutline: { file: "_app/search-outline-a.json", ...weight(58 * KiB, 11 * KiB) },
  searchText: { file: "_app/search-text-a.json", ...weight(1400 * KiB, 470 * KiB) },
};

test("a site within its budget has nothing to report; each figure over it is named", () => {
  assert.deepEqual(overBudget(sample, budget), []);
  assert.deepEqual(
    overBudget(
      {
        ...sample,
        largestPage: { file: "commands/index.html", ...weight(512 * KiB, 30 * KiB) },
        js: weight(80 * KiB, 54.5 * KiB),
      },
      budget,
    ),
    [
      "the largest page (commands/index.html) is 512.0 KiB, over its 175.0 KiB budget",
      "the site's JavaScript is 54.5 KiB gzipped, over its 37.8 KiB budget",
    ],
  );
  // The search text is the manual's own words: it is measured, not held.
  assert.deepEqual(
    overBudget(
      { ...sample, searchText: { file: "_app/search-text-a.json", ...weight(9e9, 9e9) } },
      budget,
    ),
    [],
  );
});

test("the published site stays within its size budget", async () => {
  const out = await mkdtemp(join(tmpdir(), "flash-site-budget-"));
  try {
    await new Promise<void>((resolve, reject) => {
      execFile(
        process.execPath,
        ["scripts/site.ts", "site", out],
        { cwd: import.meta.dirname },
        (error, _stdout, stderr) =>
          error ? reject(new Error(stderr || error.message)) : resolve(),
      );
    });
    const sizes = measureSite(out);
    assert.ok(sizes.pages > 50, "the build has the manual's pages");
    const problems = overBudget(sizes, budget);
    assert.deepEqual(problems, [], problems.join("\n"));
    // A shared link shows the card: every page names it and the build ships it.
    assert.match(
      readFileSync(join(out, "hints/index.html"), "utf8"),
      /<meta property="og:image" content="https:\/\/[^"]+\/social-card\.jpg" \/>/,
    );
    assert.ok(statSync(join(out, "social-card.jpg")).size > 10_000, "the build ships the card");
  } finally {
    await rm(out, { recursive: true, force: true });
  }
});
