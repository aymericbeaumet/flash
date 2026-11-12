// Reads `docs/` from the repository: the manual and every problem a strict
// build refuses, checked for the resident's site and the published one.

import { readdir, readFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { bundleDocs, checkLinks, siteLinks, type DocsBundle, type Problem, type SiteMode } from "../src/lib/docsite.ts";

export const docsDirectory = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "docs");

async function walk(directory: string): Promise<string[]> {
  const out: string[] = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name.startsWith(".")) continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) out.push(...(await walk(path)));
    else if (entry.isFile()) out.push(relative(docsDirectory, path).split("\\").join("/"));
  }
  return out.sort();
}

export async function loadDocs(): Promise<{ bundle: DocsBundle; problems: Problem[] }> {
  const files = await walk(docsDirectory);
  const markdown = new Map<string, string>();
  for (const file of files.filter((name) => name.endsWith(".md"))) markdown.set(file, await readFile(join(docsDirectory, file), "utf8"));
  const others = files.filter((name) => !name.endsWith(".md") && name !== "nav.json");
  const config = await readFile(join(docsDirectory, "..", "config.default.toml"), "utf8");
  const { bundle, problems } = bundleDocs(await readFile(join(docsDirectory, "nav.json"), "utf8"), markdown, others, config);
  for (const mode of ["local", "public"] as SiteMode[]) problems.push(...checkLinks(bundle, siteLinks(mode, bundle.site)));
  const seen = new Set<string>();
  return {
    bundle,
    problems: problems.filter((problem) => {
      const key = `${problem.file}\u0000${problem.message}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    }),
  };
}
