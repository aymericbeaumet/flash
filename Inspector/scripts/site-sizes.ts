// What a build of the published site weighs: the figures its budget holds
// (`site-budget.test.ts`) and `bench:help -- --site` prints. Node's standard
// library and erasable types only: the benchmark imports this file as it is.

import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { gzipSync } from "node:zlib";

/** Bytes as stored and as a server sends them compressed. */
export interface Weight {
  raw: number;
  gzip: number;
}

export interface NamedWeight extends Weight {
  /** The file, relative to the site's root. */
  file: string;
}

export interface SiteSizes {
  /** Documents that hold the app: every manual page, the search and the 404. */
  pages: number;
  /** Alias stubs, which only move to their page. */
  stubs: number;
  /** Every HTML file, stubs included. */
  html: Weight;
  medianPage: NamedWeight;
  largestPage: NamedWeight;
  /** The site's scripts and styles under `_app/`. */
  js: Weight;
  css: Weight;
  navigation: NamedWeight;
  searchOutline: NamedWeight;
  searchText: NamedWeight;
}

function walk(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? walk(join(directory, entry.name)) : [join(directory, entry.name)],
  );
}

const total = (weights: Weight[]): Weight =>
  weights.reduce((sum, weight) => ({ raw: sum.raw + weight.raw, gzip: sum.gzip + weight.gzip }), {
    raw: 0,
    gzip: 0,
  });

/** Weighs the site built into `root` (`node scripts/site.ts site <root>`). */
export function measureSite(root: string): SiteSizes {
  const files = walk(root).map((path) => {
    const data = readFileSync(path);
    return {
      file: relative(root, path).split("\\").join("/"),
      raw: data.length,
      gzip: gzipSync(data, { level: 9 }).length,
      app: path.endsWith(".html") && data.includes('<div id="app">'),
    };
  });
  const weigh = ({ file, raw, gzip }: NamedWeight): NamedWeight => ({ file, raw, gzip });
  const one = (pattern: RegExp): NamedWeight => {
    const found = files.filter((entry) => pattern.test(entry.file));
    if (found.length !== 1)
      throw new Error(`${root}: ${found.length} files match ${pattern}, expected one`);
    return weigh(found[0]);
  };
  const html = files.filter((entry) => entry.file.endsWith(".html"));
  const pages = html.filter((entry) => entry.app).sort((a, b) => a.raw - b.raw);
  if (!pages.length) throw new Error(`${root}: no page of the published site`);
  return {
    pages: pages.length,
    stubs: html.length - pages.length,
    html: total(html),
    medianPage: weigh(pages[pages.length >> 1]),
    largestPage: weigh(pages[pages.length - 1]),
    js: total(files.filter((entry) => /^_app\/.*\.js$/.test(entry.file))),
    css: total(files.filter((entry) => /^_app\/.*\.css$/.test(entry.file))),
    navigation: one(/^_app\/nav-[\w-]+\.json$/),
    searchOutline: one(/^_app\/search-outline-[\w-]+\.json$/),
    searchText: one(/^_app\/search-text-[\w-]+\.json$/),
  };
}

/** The most each figure may weigh; a figure without a limit is not held. */
export type SiteBudget = {
  [Figure in keyof SiteSizes]?: SiteSizes[Figure] extends Weight ? Weight : never;
};

const names: Record<string, string> = {
  html: "total HTML",
  medianPage: "the median page",
  largestPage: "the largest page",
  js: "the site's JavaScript",
  css: "the site's CSS",
  navigation: "the navigation asset",
  searchOutline: "the search outline",
  searchText: "the search text",
};

const kib = (bytes: number) => `${(bytes / 1024).toFixed(1)} KiB`;

/** One line per figure over its budget; none when the site is within it. */
export function overBudget(sizes: SiteSizes, budget: SiteBudget): string[] {
  const problems: string[] = [];
  for (const [figure, limit] of Object.entries(budget) as [keyof SiteBudget, Weight][]) {
    const weight = sizes[figure] as Weight & { file?: string };
    const name = names[figure] + (weight.file ? ` (${weight.file})` : "");
    if (weight.raw > limit.raw)
      problems.push(`${name} is ${kib(weight.raw)}, over its ${kib(limit.raw)} budget`);
    if (weight.gzip > limit.gzip)
      problems.push(`${name} is ${kib(weight.gzip)} gzipped, over its ${kib(limit.gzip)} budget`);
  }
  return problems;
}
