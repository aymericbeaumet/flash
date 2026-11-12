// Builds the manual from `docs/` for the resident and for the published site.
//
//   node scripts/site.ts check            every link of every page, both sites
//   node scripts/site.ts bundle <dir> [--revision=<commit>]
//                                         docs.json, search.json, routes.json and files/ for the app bundle
//   node scripts/site.ts site <dir>       the published site, prerendered page by page
//
// Every command fails on a broken link or anchor, a page missing from
// docs/nav.json or a navigation entry without its file: the parity of the
// strict documentation build this replaces. `site` also renders every page
// for both sites and checks each link the HTML carries.

import { copyFile, mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { searchSections, siteLinks, type DocsBundle, type Problem, type SiteMode } from "../src/lib/docsite.ts";
import { docsDirectory, loadDocs } from "./docs-source.ts";

const inspector = join(dirname(fileURLToPath(import.meta.url)), "..");

function fail(problems: Problem[]): never {
  console.error(`The documentation has ${problems.length} ${problems.length === 1 ? "problem" : "problems"}:`);
  for (const problem of problems) console.error(`  docs/${problem.file}: ${problem.message}`);
  process.exit(1);
}

async function write(path: string, data: string | Uint8Array) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, data);
}

async function copyFiles(bundle: DocsBundle, out: string) {
  for (const file of bundle.files) {
    await mkdir(dirname(join(out, file)), { recursive: true });
    await copyFile(join(docsDirectory, file), join(out, file));
  }
}

/**
 * The resident's copy: the manual (its repository links pinned to the commit
 * it was built from), its search sections, the names it routes for `:help`
 * completion (`HelpDocs.manualNames`) and its other files.
 */
async function writeBundle(bundle: DocsBundle, out: string, revision?: string) {
  await rm(out, { recursive: true, force: true });
  await write(join(out, "docs.json"), JSON.stringify(revision ? { ...bundle, revision } : bundle));
  await write(join(out, "search.json"), JSON.stringify(searchSections(bundle)));
  await write(join(out, "routes.json"), JSON.stringify({ pages: bundle.pages.map((page) => ({ path: page.path, aliases: page.aliases })) }));
  await copyFiles(bundle, join(out, "files"));
}

/** A published alias (`/flash/config/`) is a stub that moves to its page, with or without JavaScript. */
function aliasStub(title: string, target: string, canonical: string): string {
  const url = escapeHTML(target);
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>${escapeHTML(title)}</title>
    <link rel="canonical" href="${escapeHTML(canonical)}" />
    <meta name="robots" content="noindex" />
    <meta http-equiv="refresh" content="0; url=${url}" />
    <script>location.replace(${scriptJSON(target)} + location.hash);</script>
  </head>
  <body><p><a href="${url}">${escapeHTML(title)}</a></p></body>
</html>
`;
}

const escapeHTML = (text: string) => text.replace(/[&<>"']/g, (character) => `&#${character.charCodeAt(0)};`);
/** JSON inside a script element: no `</script>` or comment opener can end it. */
const scriptJSON = (value: unknown) => JSON.stringify(value).replace(/</g, "\\u003c").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");

type Renderer = (mode: SiteMode, bundle: DocsBundle, path: string) => { head: string; body: string };

/** The published pages' links all lead somewhere on the site, and nowhere local. */
function checkPublished(pages: Map<string, string>, assets: Set<string>, root: string, siteURL: string): string[] {
  const problems: string[] = [];
  const ids = new Map<string, Set<string>>();
  const idsOf = (file: string) => {
    let found = ids.get(file);
    if (!found) {
      found = new Set([...(pages.get(file) ?? "").matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]));
      ids.set(file, found);
    }
    return found;
  };
  for (const [file, html] of pages) {
    const base = new URL(`${root}/${file.replace(/index\.html$/, "")}`, siteURL);
    for (const match of html.matchAll(/<(a|link|script|img)\b[^>]*?\s(href|src)="([^"]*)"/g)) {
      const raw = match[3].replace(/&amp;/g, "&");
      const where = `${file}: ${match[2]}="${raw}"`;
      if (/localhost|127\.0\.0\.1|\[::1\]/i.test(raw)) { problems.push(`${where} points at this Mac`); continue; }
      if (/^[a-z][a-z\d+.-]*:/i.test(raw)) {
        // The canonical link is the one absolute spelling of a page.
        if (raw.startsWith(siteURL) && !match[0].includes('rel="canonical"')) problems.push(`${where} spells an internal link as a URL`);
        continue;
      }
      const url = new URL(raw, base);
      if (!url.pathname.startsWith(`${root}/`)) { problems.push(`${where} leaves the site (${url.pathname})`); continue; }
      let target = decodeURIComponent(url.pathname.slice(root.length + 1));
      if (target === "" || target.endsWith("/")) target += "index.html";
      if (!pages.has(target) && !assets.has(target)) { problems.push(`${where} names no file`); continue; }
      const anchor = url.hash ? decodeURIComponent(url.hash.slice(1)) : "";
      if (anchor && pages.has(target) && !idsOf(target).has(anchor)) problems.push(`${where} names no heading`);
    }
  }
  return problems;
}

/** Every link of a page the resident serves leads to its own routes. */
function checkLocal(file: string, html: string, bundle: DocsBundle): string[] {
  const problems: string[] = [];
  const local = siteLinks("local");
  const pages = new Set(bundle.pages.map((page) => page.path));
  for (const match of html.matchAll(/<a\b[^>]*?\shref="([^"]*)"/g)) {
    const raw = match[1].replace(/&amp;/g, "&");
    const where = `${file} (local): href="${raw}"`;
    if (raw.startsWith(bundle.site.url) || raw.includes("aymericbeaumet.github.io/flash")) { problems.push(`${where} leaves for the published site`); continue; }
    if (/^[a-z][a-z\d+.-]*:/i.test(raw) || raw.startsWith("#")) continue;
    const url = new URL(raw, "http://127.0.0.1:4242");
    if (url.pathname === local.root || url.pathname.startsWith(`${local.root}/`)) {
      const path = decodeURIComponent(url.pathname.slice(local.root.length + 1));
      if (!pages.has(path) && !bundle.files.includes(path)) problems.push(`${where} names no page`);
      continue;
    }
    if (!/^\/(guides|mappings|commands|plugins|state|monitors|telemetry|logs|clipboard|search)?(\/|$|\?)/.test(url.pathname)) problems.push(`${where} is not a page of the help`);
  }
  return problems;
}

function favicon() {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect width="24" height="24" rx="5" fill="#0e1115"/><path d="m13 2-9 12h7l-1 8 10-13h-7z" fill="none" stroke="#d4ab5f" stroke-width="1.6" stroke-linejoin="round"/></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

/** The published site: one prerendered page per manual page, readable without JavaScript. */
async function writeSite(bundle: DocsBundle, out: string) {
  const { build } = await import("vite");
  const work = join(inspector, "dist-site");
  await rm(work, { recursive: true, force: true });
  await build({ root: inspector, mode: "site", logLevel: "warn" });
  await build({ root: inspector, mode: "site", logLevel: "warn", build: { ssr: "src/site/server.ts", outDir: join(work, "server"), emptyOutDir: true } });
  const { renderPage } = (await import(pathToFileURL(join(work, "server", "server.js")).href)) as { renderPage: Renderer };
  const template = await readFile(join(work, "client", "site.html"), "utf8");
  for (const marker of ["<!--site-head-->", "<!--site-boot-->", "<!--site-body-->"]) {
    if (!template.includes(marker)) throw new Error(`site.html lost its ${marker} marker`);
  }

  const links = siteLinks("public", bundle.site);
  const root = links.root;
  await rm(out, { recursive: true, force: true });
  await mkdir(out, { recursive: true });
  const html = new Map<string, string>();
  const problems: string[] = [];
  const page = (path: string | null, route: string) => {
    const current = bundle.pages.find((candidate) => candidate.path === path);
    // Each page carries its own text (search and 404 none); the rest of the
    // manual loads when idle.
    const boot = { ...bundle, pages: bundle.pages.map((candidate) => (candidate === current ? candidate : { ...candidate, markdown: "" })) };
    const rendered = renderPage("public", boot, route);
    const description = escapeHTML(bundle.site.description);
    const head = [
      `<meta name="description" content="${description}" />`,
      `<link rel="icon" href="${favicon()}" />`,
      `<meta property="og:type" content="website" />`,
      `<meta property="og:site_name" content="${escapeHTML(bundle.site.name)}" />`,
      `<meta property="og:description" content="${description}" />`,
      `<meta name="twitter:card" content="summary" />`,
      rendered.head,
    ].join("\n    ");
    return template
      .replace("<!--site-head-->", () => head)
      .replace("<!--site-boot-->", () => `<script id="flash-docs" type="application/json">${scriptJSON({ bundle: boot, route })}</script>`)
      .replace("<!--site-body-->", () => rendered.body);
  };
  for (const entry of bundle.pages) {
    const file = entry.path ? `${entry.path}/index.html` : "index.html";
    html.set(file, page(entry.path, links.page(entry.path)));
    const local = renderPage("local", bundle, siteLinks("local").page(entry.path));
    problems.push(...checkLocal(file, local.body, bundle));
  }
  html.set("search/index.html", page(null, `${root}/search/`));
  html.set("404.html", page(null, `${root}/404.html`));
  for (const [file, text] of html) await write(join(out, file), text);
  // `:help config` names a page by alias; the published URL does too.
  const stubs = new Map<string, string>();
  for (const entry of bundle.pages) {
    for (const alias of entry.aliases) {
      stubs.set(`${alias}/index.html`, aliasStub(`${entry.heading ?? entry.title} - ${bundle.site.name}`, links.page(entry.path), new URL(links.page(entry.path), bundle.site.url).href));
    }
  }
  for (const [file, text] of stubs) await write(join(out, file), text);

  const assets = new Set<string>();
  await mkdir(join(out, "_app"), { recursive: true });
  for (const file of await readdir(join(work, "client", "_app"))) {
    await copyFile(join(work, "client", "_app", file), join(out, "_app", file));
    assets.add(`_app/${file}`);
  }
  await copyFiles(bundle, out);
  for (const file of bundle.files) assets.add(file);
  await write(join(out, "docs.json"), JSON.stringify(bundle));
  await write(join(out, "search.json"), JSON.stringify(searchSections(bundle)));
  const urls = bundle.pages.filter((entry) => entry.listed).map((entry) => `  <url><loc>${escapeHTML(new URL(links.page(entry.path), bundle.site.url).href)}</loc></url>`);
  await write(join(out, "sitemap.xml"), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join("\n")}\n</urlset>\n`);
  await write(join(out, ".nojekyll"), "");
  for (const file of ["docs.json", "search.json", "sitemap.xml"]) assets.add(file);

  problems.push(...checkPublished(new Map([...html, ...stubs]), assets, root, bundle.site.url));
  for (const [file, text] of html) {
    if (file !== "search/index.html" && file !== "404.html" && !text.includes("<article")) problems.push(`${file}: the page rendered no article`);
  }
  if (problems.length) {
    console.error(`The published site has ${problems.length} broken ${problems.length === 1 ? "link" : "links"}:`);
    for (const problem of problems) console.error(`  ${problem}`);
    process.exit(1);
  }
  console.log(`Built ${html.size} pages and ${stubs.size} aliases into ${out}`);
}

const [command, target, ...options] = process.argv.slice(2);
const revision = options.find((option) => option.startsWith("--revision="))?.slice("--revision=".length);
if (revision !== undefined && !/^[0-9a-f]{40}$/.test(revision)) throw new Error(`--revision takes a full commit hash, not ${revision}`);
const { bundle, problems } = await loadDocs();
if (problems.length) fail(problems);
switch (command) {
  case "check":
    console.log(`Checked ${bundle.pages.length} pages: every link and anchor resolves`);
    break;
  case "bundle":
    if (!target) throw new Error("usage: site.ts bundle <directory>");
    await writeBundle(bundle, target, revision);
    console.log(`Bundled ${bundle.pages.length} pages into ${target}`);
    break;
  case "site":
    if (!target) throw new Error("usage: site.ts site <directory>");
    await writeSite(bundle, target);
    break;
  default:
    throw new Error("usage: site.ts check | bundle <directory> | site <directory>");
}
