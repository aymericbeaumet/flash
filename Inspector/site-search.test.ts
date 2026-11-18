import assert from "node:assert/strict";
import test from "node:test";
import type { SearchSection } from "./src/lib/docsite.ts";
import { manualEntries, search, searchSummary } from "./src/lib/search.ts";
import {
  joinSections,
  SearchLoader,
  splitSections,
  type SearchAssets,
  type SearchProgress,
} from "./src/site/assets.ts";
import { pageToPrepare, speculationRules } from "./src/site/navigation.ts";

const sections: SearchSection[] = [
  { path: "", title: "Flash", text: "Keyboard-driven hints for macOS." },
  { path: "", title: "Flash", heading: "Install", id: "install", text: "Download the app." },
  {
    path: "hints",
    title: "Hints",
    heading: "Right-click and drag",
    id: "right-click-and-drag",
    text: "Use cf for a context menu.",
  },
  { path: "hints", title: "Hints", heading: "Scope", id: "scope", text: "" },
  { path: "empty", title: "Empty", text: "" },
];
const assets: SearchAssets = { outline: "_app/outline.json", text: "_app/text.json" };

test("sections split into an outline and their text, and join back as they were", () => {
  const { outline, text } = splitSections(sections);
  assert.deepEqual(outline, [
    { path: "", title: "Flash", lead: true, headings: [["Install", "install"]] },
    {
      path: "hints",
      title: "Hints",
      lead: false,
      headings: [
        ["Right-click and drag", "right-click-and-drag"],
        ["Scope", "scope"],
      ],
    },
    { path: "empty", title: "Empty", lead: true, headings: [] },
  ]);
  assert.deepEqual(
    text,
    sections.map((section) => section.text),
  );
  assert.deepEqual(joinSections(outline, text), sections);
  assert.ok(!JSON.stringify(outline).includes("context menu"), "the outline carries no text");
});

test("an outline alone describes every section, without text", () => {
  const { outline } = splitSections(sections);
  assert.deepEqual(
    joinSections(outline),
    sections.map((section) => ({ ...section, text: "" })),
  );
});

test("a page whose lead text follows a heading cannot be split", () => {
  assert.throws(
    () =>
      splitSections([
        { path: "a", title: "A", heading: "One", id: "one", text: "x" },
        { path: "a", title: "A", text: "y" },
      ]),
    /a: a section without a heading follows the page's first/,
  );
});

/** A loader whose files are answered by hand. */
function loader() {
  const { outline, text } = splitSections(sections);
  const files: Record<string, unknown> = { [assets.outline]: outline, [assets.text]: text };
  const requests: string[] = [];
  const seen: SearchProgress[] = [];
  const pending: { file: string; settle: (fail?: boolean) => void }[] = [];
  const search = new SearchLoader(
    (file) =>
      new Promise((resolve, reject) => {
        requests.push(file);
        pending.push({
          file,
          settle: (fail) => (fail ? reject(new Error(`${file}: 503`)) : resolve(files[file])),
        });
      }),
    (progress) => seen.push(progress),
  );
  /** Answers the request in flight, then lets the loader go on. */
  const answer = async (fail = false) => {
    pending.shift()!.settle(fail);
    await new Promise((resolve) => setImmediate(resolve));
  };
  return { search, files, requests, seen, answer };
}

test("the outline answers first, by title or heading; the text completes the results", async () => {
  const { search: site, requests, seen, answer } = loader();
  site.use(assets);
  const loaded = site.load();
  assert.equal(site.load(), loaded, "one load at a time");
  assert.deepEqual(requests, [assets.outline]);
  await answer();
  assert.equal(seen.length, 1);
  assert.equal(seen[0].complete, false);
  const partial = { entries: manualEntries(seen[0].sections!) };
  assert.deepEqual(
    search(partial, "scope").map((result) => result.href),
    ["/docs/hints#scope"],
  );
  assert.deepEqual(search(partial, "context menu"), [], "text is not here yet");
  assert.deepEqual(requests, [assets.outline, assets.text]);
  await answer();
  await loaded;
  assert.deepEqual(seen[1], { sections, complete: true, failed: false });
  assert.deepEqual(
    search({ entries: manualEntries(seen[1].sections!) }, "context menu").map(
      (result) => result.href,
    ),
    ["/docs/hints#right-click-and-drag"],
  );
  await site.load();
  assert.equal(requests.length, 2, "a complete search asks for nothing");
});

test("text that fails keeps the outline's results, says so, and is asked for again alone", async () => {
  const { search: site, requests, seen, answer } = loader();
  site.use(assets);
  const first = site.load();
  await answer();
  await answer(true);
  await first;
  assert.equal(seen.at(-1)!.failed, true);
  assert.equal(seen.at(-1)!.complete, false);
  assert.equal(seen.at(-1)!.sections!.length, sections.length);
  const second = site.load();
  assert.deepEqual(requests, [assets.outline, assets.text, assets.text]);
  assert.equal(seen.at(-1)!.failed, false, "asking again is searching again");
  await answer();
  await second;
  assert.deepEqual(seen.at(-1), { sections, complete: true, failed: false });
});

test("an outline that fails leaves the search empty and failed", async () => {
  const { search: site, seen, answer } = loader();
  site.use(assets);
  const loaded = site.load();
  await answer(true);
  await loaded;
  assert.deepEqual(seen, [{ sections: null, complete: false, failed: true }]);
});

test("files that are not what the build wrote are refused", async () => {
  const { search: site, files, seen, answer } = loader();
  files[assets.text] = ["one text for five sections"];
  site.use(assets);
  const loaded = site.load();
  await answer();
  await answer();
  await loaded;
  assert.equal(seen.at(-1)!.failed, true);
  assert.equal(seen.at(-1)!.complete, false);
});

test("a search without its files loads nothing", async () => {
  const { search: site, requests, seen } = loader();
  await site.load();
  assert.deepEqual(requests, []);
  assert.deepEqual(seen, []);
});

test("the results line never calls a search that is still loading final", () => {
  assert.equal(searchSummary(3, "grid", "complete"), "3 results for “grid”");
  assert.equal(searchSummary(1, "grid", "complete"), "1 result for “grid”");
  assert.equal(searchSummary(0, "grid", "loading"), "Searching for “grid”…");
  assert.equal(
    searchSummary(2, "grid", "loading"),
    "2 results so far for “grid”, still searching…",
  );
  assert.equal(searchSummary(2, "grid", "failed"), "2 results for “grid”, from part of the search");
});

test("speculation rules cover the site's pages and nothing else", () => {
  const rules = speculationRules("/flash");
  const where = {
    and: [
      { href_matches: ["/flash/", "/flash/*/"] },
      { not: { selector_matches: '[href^="#"], [download], [target="_blank"]' } },
    ],
  };
  assert.deepEqual(rules, {
    prefetch: [{ where, eagerness: "moderate" }],
    prerender: [{ where, eagerness: "conservative" }],
  });
});

test("the fallback prepares another page of the site, once it is one", () => {
  const here = new URL("https://example.github.io/flash/hints/#scope");
  const prepare = (href: string) => pageToPrepare(new URL(href, here), here, "/flash");
  assert.equal(prepare("/flash/commands/#mouse"), "/flash/commands/");
  assert.equal(prepare("/flash/"), "/flash/");
  assert.equal(prepare("/flash/search/?q=grid"), "/flash/search/?q=grid");
  assert.equal(prepare("#scope"), null, "this page");
  assert.equal(prepare("/flash/hints/"), null, "this page");
  assert.equal(prepare("/flash/examples/statusbar/flash.toml"), null, "a file");
  assert.equal(prepare("/flash/_app/site.js"), null, "an asset");
  assert.equal(prepare("/elsewhere/"), null, "another site");
  assert.equal(prepare("https://github.com/aymericbeaumet/flash/"), null, "another origin");
});
