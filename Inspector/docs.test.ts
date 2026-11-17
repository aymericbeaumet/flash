import assert from "node:assert/strict";
import test from "node:test";
import { loadDocs } from "./scripts/docs-source.ts";
import { bundleDocs, checkLinks, Manual, pathOf, searchSections, siteLinks, type DocsBundle, type SiteLinks } from "./src/lib/docsite.ts";
import { commandDocs, modeDoc, topicDocs } from "./src/lib/command-docs.ts";
import { highlight } from "./src/lib/highlight.ts";
import { renderUncached, routeOf, slugify, textOf, type MdElement, type MdNode, type RenderContext } from "./src/lib/markdown.ts";
import { hashBody } from "./src/lib/reading.ts";
import { parseRoute } from "./src/lib/routes.ts";

const site = { url: "https://example.github.io/flash/" };
const local = siteLinks("local");
const published = siteLinks("public", site);

/** A small manual: nav.json and its files. */
function fixture(pages: Record<string, string>, files: string[] = [], nav?: unknown, unlisted: string[] = []) {
  const markdown = new Map(Object.entries(pages));
  const navJSON = JSON.stringify({
    site: { name: "Flash", description: "d", url: site.url, repository: "https://github.com/o/r", repository_name: "o/r", edit: "https://github.com/o/r/edit/main/docs/" },
    unlisted,
    nav: nav ?? Object.keys(pages).filter((file) => !unlisted.includes(file)).map((file) => ({ title: file, page: file })),
  });
  return bundleDocs(navJSON, markdown, files);
}

function render(bundle: DocsBundle, links: SiteLinks, file: string) {
  const manual = new Manual(bundle, links);
  const page = bundle.pages.find((candidate) => candidate.file === file)!;
  return renderUncached(page.markdown, manual.context(file));
}

/** Every `href` and `src` in a tree, in order. */
function hrefsOf(nodes: MdNode[]): string[] {
  return find(nodes, (node) => node.attrs?.href !== undefined || node.attrs?.src !== undefined).map((node) => node.attrs!.href ?? node.attrs!.src!);
}

function find(nodes: MdNode[], predicate: (node: MdElement) => boolean): MdElement[] {
  const out: MdElement[] = [];
  const walk = (list: MdNode[]) => {
    for (const node of list) {
      if (typeof node === "string") continue;
      if (predicate(node)) out.push(node);
      walk(node.children ?? []);
    }
  };
  walk(nodes);
  return out;
}

test("route paths follow the files: a README is its directory's index", () => {
  assert.equal(routeOf("README.md"), "");
  assert.equal(routeOf("normal-mode.md"), "normal-mode");
  assert.equal(routeOf("alternatives/README.md"), "alternatives");
  assert.equal(routeOf("alternatives/neru.md"), "alternatives/neru");
});

test("the resident and the published site spell the same page and file", () => {
  assert.equal(local.page(""), "/docs");
  assert.equal(local.page("alternatives/neru", "migrate-from-neru"), "/docs/alternatives/neru#migrate-from-neru");
  assert.equal(local.file("examples/statusbar/flash.toml"), "/docs/examples/statusbar/flash.toml");
  assert.equal(published.page(""), "/flash/");
  assert.equal(published.page("alternatives/neru", "migrate-from-neru"), "/flash/alternatives/neru/#migrate-from-neru");
  assert.equal(published.file("examples/statusbar/flash.toml"), "/flash/examples/statusbar/flash.toml");
  assert.equal(pathOf(published, "/flash/alternatives/neru/"), "alternatives/neru");
  assert.equal(pathOf(published, "/elsewhere/"), null);
});

test("each site parses its own page addresses; files load as they are", () => {
  assert.deepEqual(parseRoute({ pathname: "/docs", search: "" }, local), { page: "docs", param: "" });
  assert.deepEqual(parseRoute({ pathname: "/docs/alternatives/neru", search: "" }, local), { page: "docs", param: "alternatives/neru" });
  assert.equal(parseRoute({ pathname: "/guides/hints", search: "" }, local).page, "not-found");
  assert.equal(parseRoute({ pathname: "/docs/examples/statusbar/flash.toml", search: "" }, local).page, "not-found");
  assert.deepEqual(parseRoute({ pathname: "/flash/", search: "" }, published), { page: "docs", param: "" });
  assert.deepEqual(parseRoute({ pathname: "/flash/alternatives/neru/", search: "" }, published), { page: "docs", param: "alternatives/neru" });
  assert.deepEqual(parseRoute({ pathname: "/flash/search/", search: "?q=grid" }, published), { page: "search", param: "grid" });
  assert.equal(parseRoute({ pathname: "/flash/404.html", search: "" }, published).page, "not-found");
  assert.equal(parseRoute({ pathname: "/mappings", search: "" }, published).page, "not-found");
});

test("heading ids follow the manual's slugs, repeated ones numbered, with permalinks", () => {
  assert.equal(slugify("Übersicht — the `flash.toml` keys!"), "ubersicht-the-flashtoml-keys");
  const { bundle } = fixture({ "README.md": "# Home\n\n## Setup\n\n### Setup\n\n## A  --  B\n" });
  const rendered = render(bundle, published, "README.md");
  assert.equal(rendered.title, "Home");
  assert.deepEqual(rendered.headings.map((heading) => heading.id), ["setup", "setup_1", "a-b"]);
  const anchors = find(rendered.nodes, (node) => node.attrs?.class === "heading-anchor");
  assert.deepEqual(anchors.map((node) => node.attrs?.href), ["#setup", "#setup_1", "#a-b"]);
  assert.equal(textOf(rendered.nodes).includes("Home"), false, "the title leaves the body");
});

test("relative pages, directories, anchors and files resolve to each site's routes", () => {
  const { bundle, problems } = fixture({
    "README.md": "# Home\n\n[neru](alternatives/neru.md#why) [all](alternatives/) [toml](examples/flash.toml) [here](#home-section)\n\n## Home section\n",
    "alternatives/README.md": "# Alternatives\n\n[home](../README.md) [neru](neru.md)\n",
    "alternatives/neru.md": "# Neru\n\n## Why\n",
  }, ["examples/flash.toml"]);
  assert.deepEqual(problems, []);
  // The last one is the heading's own permalink.
  assert.deepEqual(hrefsOf(render(bundle, local, "README.md").nodes), ["/docs/alternatives/neru#why", "/docs/alternatives", "/docs/examples/flash.toml", "#home-section", "#home-section"]);
  assert.deepEqual(hrefsOf(render(bundle, published, "README.md").nodes), ["/flash/alternatives/neru/#why", "/flash/alternatives/", "/flash/examples/flash.toml", "#home-section", "#home-section"]);
  assert.deepEqual(hrefsOf(render(bundle, published, "alternatives/README.md").nodes), ["/flash/", "/flash/alternatives/neru/"]);
  assert.deepEqual(checkLinks(bundle, local), []);
});

test("a link into the published site is an internal link on both sites", () => {
  const { bundle } = fixture({ "README.md": "# Home\n\n[guide](https://example.github.io/flash/guide/#start) [repo](https://github.com/o/r)\n", "guide.md": "# Guide\n\n## Start\n" });
  assert.deepEqual(hrefsOf(render(bundle, local, "README.md").nodes), ["/docs/guide#start", "https://github.com/o/r"]);
  assert.deepEqual(hrefsOf(render(bundle, published, "README.md").nodes), ["/flash/guide/#start", "https://github.com/o/r"]);
  const external = find(render(bundle, local, "README.md").nodes, (node) => node.attrs?.href === "https://github.com/o/r")[0];
  assert.equal(external.attrs?.target, "_blank");
  assert.equal(external.attrs?.["data-external"], "github.com");
});

test("only files the help can serve may sit beside the pages", () => {
  const { problems } = fixture({ "README.md": "# Home\n" }, ["examples/flash.toml", "assets/logo.svg", "assets/my image.png"]);
  assert.deepEqual(problems.map((problem) => problem.file), ["assets/logo.svg", "assets/my image.png"]);
});

test("broken links fail the check as a strict build would", () => {
  const { bundle, problems } = fixture({
    "README.md": "# Home\n\n[gone](missing.md) [anchor](guide.md#nowhere) [here](#nowhere) [abs](/docs/guide) [up](../outside.md) [file](missing.toml) [js](javascript:alert(1))\n",
    "guide.md": "# Guide\n",
    "orphan.md": "# Orphan\n",
  }, [], [{ title: "Home", page: "README.md" }, { title: "Guide", page: "guide.md" }, { title: "Gone", page: "nope.md" }]);
  assert.deepEqual(problems.map((problem) => problem.message), ["nope.md does not exist", "is neither in the navigation nor unlisted in nav.json"]);
  const messages = checkLinks(bundle, published).map((problem) => problem.message);
  for (const expected of ["missing page missing.md", "no heading #nowhere on guide", "no heading #nowhere on this page", "absolute link /docs/guide", "leaves docs/", "missing file missing.toml", "unsupported scheme"]) {
    assert.ok(messages.some((message) => message.includes(expected)), `${expected} in ${messages.join(" | ")}`);
  }
  // A dropped link keeps its text and loses its destination.
  const rendered = render(bundle, published, "README.md");
  assert.ok(find(rendered.nodes, (node) => node.tag === "a" && !node.attrs?.href).length >= 5);
});

test("tables keep their alignment; admonitions, images, task lists and raw HTML render", () => {
  const { bundle } = fixture({
    "README.md": [
      "# Home",
      "",
      "| Key | Count |",
      "|:----|------:|",
      "| `f` | 2 |",
      "",
      "!!! warning \"Mind the tap\"",
      "    Secure input stops **capture**.",
      "",
      "    A second paragraph.",
      "",
      "!!! note",
      "    Plain.",
      "",
      "![Hero](assets/hero.png) ![Remote](https://example.com/x.png)",
      "",
      "- [x] done",
      "- [ ] open",
      "",
      "<details><summary>More</summary>",
      "",
      "Inside <kbd>f</kbd> <script>alert(1)</script> &amp; &rarr;",
      "",
      "</details>",
    ].join("\n"),
  }, ["assets/hero.png"]);
  const nodes = render(bundle, published, "README.md").nodes;
  const cells = find(nodes, (node) => node.tag === "th" || node.tag === "td");
  assert.deepEqual(cells.map((cell) => cell.attrs?.class), ["align-left", "align-right", "align-left", "align-right"]);
  const admonitions = find(nodes, (node) => node.attrs?.class?.startsWith("admonition ") ?? false);
  assert.deepEqual(admonitions.map((node) => node.attrs?.class), ["admonition warning", "admonition note"]);
  assert.equal(textOf(admonitions[0].children!.slice(0, 1)), "Mind the tap");
  assert.equal(find(admonitions[0].children!, (node) => node.tag === "p").length, 3);
  assert.equal(textOf(admonitions[1].children!.slice(0, 1)), "Note");
  const images = find(nodes, (node) => node.tag === "img");
  assert.deepEqual(images.map((node) => node.attrs?.src), ["/flash/assets/hero.png"], "only the manual's own files load");
  assert.deepEqual(find(nodes, (node) => node.tag === "input").map((node) => node.attrs?.checked ?? ""), ["checked", ""]);
  assert.equal(find(nodes, (node) => node.tag === "script").length, 0);
  assert.equal(find(nodes, (node) => node.tag === "details").length, 1);
  assert.equal(find(nodes, (node) => node.tag === "kbd").length, 1);
  assert.ok(textOf(nodes).includes("& →"));
  assert.ok(find(nodes, (node) => Object.keys(node.attrs ?? {}).some((name) => name.startsWith("on"))).length === 0);
});

test("fenced code is highlighted without changing its text", () => {
  const toml = '[statusbar]\nenabled = true # on\ntemplate = "#{flash.mode}"\nlines = 3\n';
  const runs = highlight(toml, "toml");
  assert.equal(runs.map((run) => run.text).join(""), toml);
  assert.deepEqual(runs.filter((run) => run.kind).map((run) => [run.kind, run.text]), [
    ["section", "[statusbar]"], ["key", "enabled"], ["keyword", "true"], ["comment", "# on"],
    ["key", "template"], ["string", '"#{flash.mode}"'], ["key", "lines"], ["number", "3"],
  ]);
  const shell = "flash mouse grid --bisect # go\necho \"$HOME\"";
  assert.equal(highlight(shell, "sh").map((run) => run.text).join(""), shell);
  assert.deepEqual(highlight("plain <b>", "text"), [{ text: "plain <b>" }]);
  const { bundle } = fixture({ "README.md": "# Home\n\n```toml\na = 1\n```\n" });
  const pre = find(render(bundle, local, "README.md").nodes, (node) => node.tag === "pre")[0];
  assert.equal(pre.attrs?.["data-language"], "toml");
  assert.equal(textOf(pre.children!), "a = 1");
});

test("a plugin's guide links app routes, other guides and manual pages", () => {
  const context: RenderContext = {
    hasFile: (path) => path === "configuration.md",
    href: (target) => (target.kind === "route" ? target.path : target.kind === "page" ? local.page(target.path, target.anchor) : undefined),
    topic: (name) => (name === "hints" ? "/docs/hints" : undefined),
    command: (name) => `/commands?q=${name}`,
    siteURL: site.url,
  };
  const guide = renderUncached("# G\n\n[map](/mappings) [ref](configuration.md#keys) `:help hints` `:quit` `hints`\n", context);
  assert.deepEqual(hrefsOf(guide.nodes), ["/mappings", "/docs/configuration#keys", "/docs/hints", "/commands?q=:quit", "/docs/hints"]);
});

test("the manual links `:help <page>` and the help's live pages, which the published site names as text", () => {
  const { bundle, problems } = fixture({
    "README.md": "# Home\n\nSee [your mappings](/mappings?q=gg), the [homepage](/) and `:help config`; `:quit` and `config` stay code.\n",
    "configuration.md": "# Configuration\n",
  }, [], [{ title: "Home", page: "README.md" }, { title: "Configuration", page: "configuration.md", aliases: ["config"] }]);
  assert.deepEqual(problems, []);
  assert.deepEqual(hrefsOf(render(bundle, local, "README.md").nodes), ["/mappings?q=gg", "/", "/docs/configuration"]);
  const published_ = render(bundle, published, "README.md").nodes;
  assert.deepEqual(hrefsOf(published_), ["/flash/configuration/"]);
  assert.deepEqual(find(published_, (node) => node.attrs?.class === "live-link").map((node) => textOf(node.children!)), ["your mappings", "homepage"]);
  // Any other absolute path is still an error.
  const broken = fixture({ "README.md": "# Home\n\n[x](/docs/configuration) [y](/guides/hints)\n" }).bundle;
  assert.equal(checkLinks(broken, local).length, 2);
});

test("aliases route to their page on both sites, and name nothing else", () => {
  const { bundle, problems } = fixture({ "README.md": "# Home\n", "configuration.md": "# Configuration\n" }, [], [
    { title: "Home", page: "README.md", aliases: ["overview"] },
    { title: "Configuration", page: "configuration.md", aliases: ["config"] },
  ]);
  assert.deepEqual(problems, []);
  for (const links of [local, published]) {
    const manual = new Manual(bundle, links);
    assert.equal(manual.page("config")?.path, "configuration");
    assert.equal(manual.page("overview")?.path, "");
  }
  const clashes = fixture({ "README.md": "# Home\n", "configuration.md": "# Configuration\n", "config.md": "# C\n" }, [], [
    { title: "Home", page: "README.md", aliases: ["config", "search", "Two Words"] },
    { title: "Configuration", page: "configuration.md", aliases: ["home-again", "home-again"] },
    { title: "Config", page: "config.md" },
  ]).problems.map((problem) => problem.message);
  assert.ok(clashes.some((message) => message.includes("alias config names another page")), clashes.join(" | "));
  assert.ok(clashes.some((message) => message.includes("alias search names another page")), clashes.join(" | "));
  assert.ok(clashes.some((message) => message.includes("Two Words is not one lowercase word")), clashes.join(" | "));
  assert.ok(clashes.some((message) => message.includes("alias home-again also names")), clashes.join(" | "));
});

test("the resident's copy pins repository links to its commit; the published site keeps main", () => {
  const { bundle } = fixture({ "README.md": "# Home\n\n[guide](https://github.com/o/r/blob/main/AGENTS.md) [tree](https://github.com/o/r/tree/main/Plugins) [edit](https://github.com/o/r/edit/main/docs/README.md)\n" });
  assert.deepEqual(hrefsOf(render(bundle, published, "README.md").nodes), ["https://github.com/o/r/blob/main/AGENTS.md", "https://github.com/o/r/tree/main/Plugins", "https://github.com/o/r/edit/main/docs/README.md"]);
  const pinned = { ...bundle, revision: "a".repeat(40) };
  assert.deepEqual(hrefsOf(render(pinned, local, "README.md").nodes), [`https://github.com/o/r/blob/${"a".repeat(40)}/AGENTS.md`, `https://github.com/o/r/tree/${"a".repeat(40)}/Plugins`, "https://github.com/o/r/edit/main/docs/README.md"]);
});

test("a config: link lands on the reference file's line, and an unknown table fails the build", () => {
  const config = "[mode]\nsequence_timeout_ms = 1000\n\n[mode.normal]\n# leader = false\nleader = \"\\\\\"\n\n# [mode.layers.resize]\n# label = \"RESIZE\"\n";
  const markdown = new Map(Object.entries({ "README.md": "# Home\n\n[leader](config:mode.normal.leader) [layer](config:mode.layers.resize) [label](config:mode.layers.resize.label) [gone](config:mode.nothing)\n" }));
  const navJSON = JSON.stringify({ site: { name: "Flash", description: "d", url: site.url, repository: "https://github.com/o/r", repository_name: "o/r", edit: "https://github.com/o/r/edit/main/docs/" }, nav: [{ title: "Home", page: "README.md" }] });
  const { bundle } = bundleDocs(navJSON, markdown, [], config);
  assert.equal(bundle.config?.lines["mode.normal.leader"], 6, "the real key wins over its commented example");
  assert.deepEqual(hrefsOf(render(bundle, published, "README.md").nodes), ["https://github.com/o/r/blob/main/config.default.toml#L6", "https://github.com/o/r/blob/main/config.default.toml#L8", "https://github.com/o/r/blob/main/config.default.toml#L9"]);
  const pinned = { ...bundle, revision: "b".repeat(40) };
  assert.ok(hrefsOf(render(pinned, local, "README.md").nodes)[0].includes(`/blob/${"b".repeat(40)}/config.default.toml#L6`));
  assert.deepEqual(checkLinks(bundle, published).map((problem) => problem.message), ["config:mode.nothing: no mode.nothing in config.default.toml"]);
});

/** The live pages link commands and modes to these pages and headings. */
test("every command and mode documentation target is a real page and heading", async () => {
  const { bundle } = await loadDocs();
  const manual = new Manual(bundle, local);
  const targets = [...Object.entries(commandDocs), ...Object.entries(topicDocs), ...["all", "normal", "text", "visual", "insert", "command", "terminal", "hyper", "hold", "layers.resize"].map((mode) => [`mode ${mode}`, modeDoc(mode)] as const)];
  for (const [name, target] of targets) {
    const page = manual.page(target.page);
    assert.ok(page, `${name}: no page ${target.page}`);
    if (!target.anchor) continue;
    const ids = new Set(renderUncached(page!.markdown, manual.context(page!.file)).ids);
    assert.ok(ids.has(target.anchor), `${name}: no heading #${target.anchor} on ${target.page}`);
  }
});

/** Every in-app topic name and alias `:help` took still opens a page. */
test("every former help topic name routes to a manual page", async () => {
  const { bundle } = await loadDocs();
  const manual = new Manual(bundle, local);
  for (const name of ["overview", "help", "getting-started", "start", "hints", "hint", "mouse", "mouse-grid", "grid", "pointer", "mappings", "flashlight", "normal-mode", "commands", "config", "configuration", "clipboard", "statusbar", "status-bar", "status-format", "formats", "widgets", "widget", "monitors", "monitor", "popups", "popup", "terminal", "plugins", "privacy", "permissions", "troubleshooting", "doctor", "diagnostics", "development", "architecture", "manual", "docs", "reference", "alternatives"]) {
    assert.ok(manual.page(name), `:help ${name}`);
  }
});

/** Every internal link of every real page, in both spellings. */
test("the manual's links stay on their own site", async () => {
  const { bundle, problems } = await loadDocs();
  assert.deepEqual(problems, [], problems.map((problem) => `docs/${problem.file}: ${problem.message}`).join("\n"));
  assert.ok(bundle.pages.length > 50);
  for (const [links, own, foreign] of [[local, /^\/(docs(\/|$|#)|(mappings|commands|plugins|state|monitors|logs|clipboard|search)?([?#]|$))/, /aymericbeaumet\.github\.io\/flash|^\/flash\//], [published, /^\/flash\//, /localhost|127\.0\.0\.1|^\/docs(\/|$)|^\/(guides|mappings|commands|plugins|state|monitors|logs|clipboard)(\/|$)/]] as const) {
    const manual = new Manual(bundle, links);
    for (const page of bundle.pages) {
      for (const href of hrefsOf(renderUncached(page.markdown, manual.context(page.file)).nodes)) {
        assert.doesNotMatch(href, foreign, `${links.mode} docs/${page.file} links ${href}`);
        if (/^[a-z][a-z\d+.-]*:/i.test(href) || href.startsWith("#")) continue;
        assert.match(href, own, `${links.mode} docs/${page.file} links ${href}`);
      }
    }
  }
});

test("search sections land on the rendered heading ids", async () => {
  const { bundle } = await loadDocs();
  const sections = searchSections(bundle);
  const manual = new Manual(bundle, published);
  for (const page of bundle.pages) {
    const ids = new Set(renderUncached(page.markdown, manual.context(page.file)).ids);
    for (const section of sections.filter((candidate) => candidate.path === page.path && candidate.id)) assert.ok(ids.has(section.id!), `${page.file}#${section.id}`);
  }
  assert.ok(sections.some((section) => section.path === "normal-mode" && section.heading));
});

/**
 * The whole published site: every page prerendered through the App, the
 * build's own checks of each page for both sites (it renders the help's
 * spelling too and fails on a link to the published site), then every href
 * of the published HTML read back here.
 */
test("the published site builds, and its pages link only within it", async () => {
  const { execFile } = await import("node:child_process");
  const { mkdtemp, readdir, readFile, rm } = await import("node:fs/promises");
  const { join } = await import("node:path");
  const { tmpdir } = await import("node:os");
  const out = await mkdtemp(join(tmpdir(), "flash-site-"));
  try {
    await new Promise<void>((resolve, reject) => {
      execFile(process.execPath, ["scripts/site.ts", "site", out], { cwd: import.meta.dirname }, (error, _stdout, stderr) => (error ? reject(new Error(stderr || error.message)) : resolve()));
    });
    const pages: string[] = [];
    const walk = async (directory: string) => {
      for (const entry of await readdir(directory, { withFileTypes: true })) {
        if (entry.isDirectory()) await walk(join(directory, entry.name));
        else if (entry.name.endsWith(".html")) pages.push(join(directory, entry.name));
      }
    };
    await walk(out);
    assert.ok(pages.length > 50);
    for (const page of pages) {
      const html = await readFile(page, "utf8");
      for (const [, href] of html.matchAll(/<a\b[^>]*?\shref="([^"]*)"/g)) {
        assert.doesNotMatch(href, /localhost|127\.0\.0\.1|^\/docs(\/|$)|^\/(guides|mappings|state|logs)(\/|$)/, `${page} links ${href}`);
        if (!/^[a-z][a-z\d+.-]*:/i.test(href) && !href.startsWith("#")) assert.match(href, /^\/flash\//, `${page} links ${href}`);
      }
    }
  } finally {
    await rm(out, { recursive: true, force: true });
  }
});

test("each bundled page carries the hash the reader compares, so the browser never hashes the manual", () => {
  const { bundle } = fixture({ "README.md": "# Home\n", "guide.md": "# Guide\n\nText.\n" });
  for (const page of bundle.pages) assert.equal(page.hash, hashBody(page.markdown), page.file);
  assert.notEqual(bundle.pages[0].hash, bundle.pages[1].hash);
});
