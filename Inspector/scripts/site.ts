// Builds the manual from `docs/` for the resident and for the published site.
//
//   node scripts/site.ts check            every link of every page, both sites
//   node scripts/site.ts bundle <dir> [--revision=<commit>]
//                                         docs.json, search.json, routes.json and files/ for the app bundle
//   node scripts/site.ts site <dir>       the published site, prerendered page by page, with its
//                                         navigation and its search as hashed files under _app/
//
// Every command fails on a broken link or anchor, a page missing from
// docs/nav.json or a navigation entry without its file: the parity of the
// strict documentation build this replaces. `site` also renders every page
// for both sites and checks each link the HTML carries.

import { createHash } from "node:crypto";
import { copyFile, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  docsIndex,
  livePageNames,
  siteLinks,
  type DocsBundle,
  type SiteMode,
} from "../src/lib/docsite.ts";
import { splitSections, type SiteIndex } from "../src/site/assets.ts";
import { speculationRules } from "../src/site/navigation.ts";
import { searchSections, type Problem } from "./docs-bundle.ts";
import { docsDirectory, loadDocs } from "./docs-source.ts";

const inspector = join(dirname(fileURLToPath(import.meta.url)), "..");
/**
 * The card a shared link shows: `docs/assets/social-card.jpg`, 1280 by 640
 * (`mise run build:social-card`), published at the site's root.
 */
const socialCard = "social-card.jpg";

function fail(problems: Problem[]): never {
  console.error(
    `The documentation has ${problems.length} ${problems.length === 1 ? "problem" : "problems"}:`,
  );
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
  await write(
    join(out, "routes.json"),
    JSON.stringify({
      pages: bundle.pages.map((page) => ({ path: page.path, aliases: page.aliases })),
    }),
  );
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

const escapeHTML = (text: string) =>
  text.replace(/[&<>"']/g, (character) => `&#${character.charCodeAt(0)};`);
/** JSON inside a script element: no `</script>` or comment opener can end it. */
const scriptJSON = (value: unknown) =>
  JSON.stringify(value)
    .replace(/</g, "\\u003c")
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");

type Renderer = (
  mode: SiteMode,
  bundle: DocsBundle,
  path: string,
) => { head: string; body: string; article?: string };

/** A name that changes with the content, so the file caches for good. */
const hashed = (name: string, extension: string, content: string) =>
  `${name}-${createHash("sha256").update(content).digest("base64url").slice(0, 8)}.${extension}`;

/** The reading area the site's app renders empty, for the page's article. */
const readingArea = /(<div class="reading-area[^"]*">)(<\/div>)/g;
/** What a server render leaves for a hydration to find its place by. */
const hydrationMarkers = /<!--[^>]*-->/g;

/**
 * The HTML without them. Taking one marker out can join the halves of
 * another (`<!-<!--[-->-->`), so this repeats until none is left.
 */
function withoutHydrationMarkers(html: string): string {
  let previous: string;
  do {
    previous = html;
    html = html.replace(hydrationMarkers, "");
  } while (html !== previous);
  return html;
}

/** The published pages' links all lead somewhere on the site, and nowhere local. */
function checkPublished(
  pages: Map<string, string>,
  assets: Set<string>,
  root: string,
  siteURL: string,
): string[] {
  const problems: string[] = [];
  const ids = new Map<string, Set<string>>();
  const idsOf = (file: string) => {
    let found = ids.get(file);
    if (!found) {
      found = new Set(
        [...(pages.get(file) ?? "").matchAll(/\sid="([^"]+)"/g)].map((match) => match[1]),
      );
      ids.set(file, found);
    }
    return found;
  };
  for (const [file, html] of pages) {
    const base = new URL(`${root}/${file.replace(/index\.html$/, "")}`, siteURL);
    for (const match of html.matchAll(/<(a|link|script|img)\b[^>]*?\s(href|src)="([^"]*)"/g)) {
      const raw = match[3].replace(/&amp;/g, "&");
      const where = `${file}: ${match[2]}="${raw}"`;
      if (/localhost|127\.0\.0\.1|\[::1\]/i.test(raw)) {
        problems.push(`${where} points at this Mac`);
        continue;
      }
      if (/^[a-z][a-z\d+.-]*:/i.test(raw)) {
        // The canonical link is the one absolute spelling of a page.
        if (raw.startsWith(siteURL) && !match[0].includes('rel="canonical"'))
          problems.push(`${where} spells an internal link as a URL`);
        continue;
      }
      const url = new URL(raw, base);
      if (!url.pathname.startsWith(`${root}/`)) {
        problems.push(`${where} leaves the site (${url.pathname})`);
        continue;
      }
      let target = decodeURIComponent(url.pathname.slice(root.length + 1));
      if (target === "" || target.endsWith("/")) target += "index.html";
      if (!pages.has(target) && !assets.has(target)) {
        problems.push(`${where} names no file`);
        continue;
      }
      const anchor = url.hash ? decodeURIComponent(url.hash.slice(1)) : "";
      if (anchor && pages.has(target) && !idsOf(target).has(anchor))
        problems.push(`${where} names no heading`);
    }
  }
  return problems;
}

/** A page of the help besides the manual, with its detail. */
const livePage = new RegExp(`^/(${livePageNames.join("|")})?(/|$)`);

/** Every link of a page the resident serves leads to its own routes. */
function checkLocal(file: string, html: string, bundle: DocsBundle): string[] {
  const problems: string[] = [];
  const local = siteLinks("local");
  const pages = new Set(bundle.pages.map((page) => page.path));
  for (const match of html.matchAll(/<a\b[^>]*?\shref="([^"]*)"/g)) {
    const raw = match[1].replace(/&amp;/g, "&");
    const where = `${file} (local): href="${raw}"`;
    if (raw.startsWith(bundle.site.url) || raw.includes("aymericbeaumet.github.io/flash")) {
      problems.push(`${where} leaves for the published site`);
      continue;
    }
    if (/^[a-z][a-z\d+.-]*:/i.test(raw) || raw.startsWith("#")) continue;
    const url = new URL(raw, "http://127.0.0.1:4242");
    if (url.pathname === local.root || url.pathname.startsWith(`${local.root}/`)) {
      const path = decodeURIComponent(url.pathname.slice(local.root.length + 1));
      if (!pages.has(path) && !bundle.files.includes(path)) problems.push(`${where} names no page`);
      continue;
    }
    if (!livePage.test(url.pathname)) problems.push(`${where} is not a page of the help`);
  }
  return problems;
}

function favicon() {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect width="24" height="24" rx="5" fill="#0e1115"/><path d="m13 2-9 12h7l-1 8 10-13h-7z" fill="none" stroke="#d4ab5f" stroke-width="1.6" stroke-linejoin="round"/></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

/**
 * The published site: one prerendered page per manual page, readable without
 * JavaScript. A page is the site's app around its article: the app hydrates
 * from the navigation asset all pages share, and the article is HTML alone,
 * with nothing left for a hydration, set into the app's empty reading area.
 * The navigation names the search's two files (`src/site/assets.ts`); the
 * manual's Markdown is not published.
 *
 * Each run builds in its own directory under `dist-site/` (inside the package,
 * so the server render resolves its dependencies) and removes it afterwards:
 * two builds of one checkout, such as the unit tests and `build:site`, never
 * share intermediate files.
 */
async function writeSite(bundle: DocsBundle, out: string) {
  await mkdir(join(inspector, "dist-site"), { recursive: true });
  const work = await mkdtemp(join(inspector, "dist-site", "build-"));
  let built: { pages: number; aliases: number; problems: string[] };
  try {
    built = await renderSite(bundle, out, work);
  } finally {
    await rm(work, { recursive: true, force: true });
  }
  if (built.problems.length) {
    console.error(
      `The published site has ${built.problems.length} broken ${built.problems.length === 1 ? "link" : "links"}:`,
    );
    for (const problem of built.problems) console.error(`  ${problem}`);
    process.exit(1);
  }
  console.log(`Built ${built.pages} pages and ${built.aliases} aliases into ${out}`);
}

async function renderSite(bundle: DocsBundle, out: string, work: string) {
  const { build } = await import("vite");
  await build({
    root: inspector,
    mode: "site",
    logLevel: "warn",
    build: { outDir: join(work, "client"), emptyOutDir: true },
  });
  await build({
    root: inspector,
    mode: "site",
    logLevel: "warn",
    build: { ssr: "src/site/server.ts", outDir: join(work, "server"), emptyOutDir: true },
  });
  const { renderPage } = (await import(pathToFileURL(join(work, "server", "server.js")).href)) as {
    renderPage: Renderer;
  };
  const template = await readFile(join(work, "client", "site.html"), "utf8");
  for (const marker of ["<!--site-head-->", "<!--site-body-->"]) {
    if (!template.includes(marker)) throw new Error(`site.html lost its ${marker} marker`);
  }

  const links = siteLinks("public", bundle.site);
  const root = links.root;
  await rm(out, { recursive: true, force: true });
  await mkdir(out, { recursive: true });
  const html = new Map<string, string>();
  const problems: string[] = [];
  const assets = new Set<string>();
  /** A file every page shares, named by its content so it caches for good. */
  const asset = async (name: string, value: unknown) => {
    const text = JSON.stringify(value);
    const file = `_app/${hashed(name, "json", text)}`;
    await write(join(out, file), text);
    assets.add(file);
    return file;
  };
  // The search in two files, read one after the other: the outline answers
  // by title or heading while the text of every section is on its way.
  const search = splitSections(searchSections(bundle));
  const index: SiteIndex = {
    ...docsIndex(bundle),
    search: {
      outline: await asset("search-outline", search.outline),
      text: await asset("search-text", search.text),
    },
  };
  const navigationFile = await asset("nav", index);
  const speculation = `<script type="speculationrules">${scriptJSON(speculationRules(root))}</script>`;
  const description = escapeHTML(bundle.site.description);
  const card = escapeHTML(new URL(socialCard, bundle.site.url).href);
  const page = (route: string) => {
    const rendered = renderPage("public", bundle, route);
    const head = [
      `<meta name="description" content="${description}" />`,
      `<link rel="icon" href="${favicon()}" />`,
      `<meta property="og:type" content="website" />`,
      `<meta property="og:site_name" content="${escapeHTML(bundle.site.name)}" />`,
      `<meta property="og:description" content="${description}" />`,
      `<meta property="og:image" content="${card}" />`,
      `<meta property="og:image:width" content="1280" />`,
      `<meta property="og:image:height" content="640" />`,
      `<meta name="twitter:card" content="summary_large_image" />`,
      // What the page hydrates from: the address it was rendered for, and
      // the navigation, fetched while the script loads.
      `<meta name="flash-route" content="${escapeHTML(route)}" />`,
      `<link rel="preload" as="fetch" crossorigin="anonymous" id="flash-nav" href="${escapeHTML(`${root}/${navigationFile}`)}" />`,
      // Which links the browser may fetch or render ahead of the click.
      speculation,
      rendered.head,
    ].join("\n    ");
    let body = rendered.body;
    if (rendered.article !== undefined) {
      const article = withoutHydrationMarkers(rendered.article);
      if (body.match(readingArea)?.length !== 1)
        throw new Error(`${route}: the page has no single reading area for its article`);
      body = body.replace(readingArea, (_, open: string, close: string) => open + article + close);
    }
    return template.replace("<!--site-head-->", () => head).replace("<!--site-body-->", () => body);
  };
  for (const entry of bundle.pages) {
    const file = entry.path ? `${entry.path}/index.html` : "index.html";
    html.set(file, page(links.page(entry.path)));
    const local = renderPage("local", bundle, siteLinks("local").page(entry.path));
    problems.push(...checkLocal(file, local.body, bundle));
  }
  html.set("search/index.html", page(`${root}/search/`));
  html.set("404.html", page(`${root}/404.html`));
  for (const [file, text] of html) await write(join(out, file), text);
  // `:help config` names a page by alias; the published URL does too.
  const stubs = new Map<string, string>();
  for (const entry of bundle.pages) {
    for (const alias of entry.aliases) {
      stubs.set(
        `${alias}/index.html`,
        aliasStub(
          `${entry.heading ?? entry.title} - ${bundle.site.name}`,
          links.page(entry.path),
          new URL(links.page(entry.path), bundle.site.url).href,
        ),
      );
    }
  }
  for (const [file, text] of stubs) await write(join(out, file), text);

  await mkdir(join(out, "_app"), { recursive: true });
  for (const file of await readdir(join(work, "client", "_app"))) {
    await copyFile(join(work, "client", "_app", file), join(out, "_app", file));
    assets.add(`_app/${file}`);
  }
  await copyFiles(bundle, out);
  for (const file of bundle.files) assets.add(file);
  const urls = bundle.pages
    .filter((entry) => entry.listed)
    .map(
      (entry) =>
        `  <url><loc>${escapeHTML(new URL(links.page(entry.path), bundle.site.url).href)}</loc></url>`,
    );
  await write(
    join(out, "sitemap.xml"),
    `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls.join("\n")}\n</urlset>\n`,
  );
  await write(
    join(out, "robots.txt"),
    `User-agent: *\nAllow: /\n\nSitemap: ${new URL("sitemap.xml", bundle.site.url).href}\n`,
  );
  await write(join(out, ".nojekyll"), "");
  await copyFile(join(docsDirectory, "assets", socialCard), join(out, socialCard));
  for (const file of ["sitemap.xml", "robots.txt", socialCard]) assets.add(file);

  problems.push(...checkPublished(new Map([...html, ...stubs]), assets, root, bundle.site.url));
  for (const [file, text] of html) {
    if (file !== "search/index.html" && file !== "404.html" && !text.includes("<article"))
      problems.push(`${file}: the page rendered no article`);
  }
  return { pages: html.size, aliases: stubs.size, problems };
}

const [command, target, ...options] = process.argv.slice(2);
const revision = options
  .find((option) => option.startsWith("--revision="))
  ?.slice("--revision=".length);
if (revision !== undefined && !/^[0-9a-f]{40}$/.test(revision))
  throw new Error(`--revision takes a full commit hash, not ${revision}`);
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
