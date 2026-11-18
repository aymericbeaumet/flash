// What the published site loads besides its pages, each a hashed file under
// `_app/`: the navigation every page hydrates from, and its search in two
// parts, read one after the other. The outline (titles, headings and their
// anchors) is small and answers a query by title or heading; the text of
// every section follows and completes the results. `scripts/site.ts` writes
// them and `search.svelte.ts` reads them.

import type { DocsIndex, SearchSection } from "../lib/docsite.ts";

/** The search's two files, as paths under the site's root. */
export interface SearchAssets {
  outline: string;
  text: string;
}

/** The navigation asset: the manual without its text, and where its search is. */
export interface SiteIndex extends DocsIndex {
  search: SearchAssets;
}

/** A page's sections without their text. */
export interface PageOutline {
  path: string;
  title: string;
  /** The page has text above its first heading: a section of its own, the first. */
  lead: boolean;
  /** Each heading with its anchor, in reading order. */
  headings: [heading: string, id: string][];
}

/** The sections split for the two files: their outline page by page, and their text in the same order. */
export function splitSections(sections: SearchSection[]): {
  outline: PageOutline[];
  text: string[];
} {
  const outline: PageOutline[] = [];
  for (const section of sections) {
    let page = outline[outline.length - 1];
    if (page?.path !== section.path) {
      page = { path: section.path, title: section.title, lead: false, headings: [] };
      outline.push(page);
    }
    if (section.heading !== undefined && section.id !== undefined)
      page.headings.push([section.heading, section.id]);
    else if (page.headings.length || page.lead)
      throw new Error(`${section.path}: a section without a heading follows the page's first`);
    else page.lead = true;
  }
  return { outline, text: sections.map((section) => section.text) };
}

/** The sections an outline describes, with their text once it is here. */
export function joinSections(outline: PageOutline[], text?: string[]): SearchSection[] {
  const sections: SearchSection[] = [];
  const next = () => text?.[sections.length] ?? "";
  for (const { path, title, lead, headings } of outline) {
    if (lead) sections.push({ path, title, text: next() });
    for (const [heading, id] of headings) sections.push({ path, title, heading, id, text: next() });
  }
  return sections;
}

/** What the search holds at a moment. */
export interface SearchProgress {
  /** The sections to search: null before the outline, without text before the text. */
  sections: SearchSection[] | null;
  /** The sections have their text: what a query finds is final. */
  complete: boolean;
  /** The last load stopped short; the next one asks for what is missing. */
  failed: boolean;
}

function list(file: string, value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${file}: not a list`);
  return value as unknown[];
}

/**
 * Loads the search's two files in turn, reporting what there is to search
 * after each. A file that arrived is never asked for again; a failed load
 * keeps what arrived and the next one resumes from there.
 */
export class SearchLoader {
  private assets: SearchAssets | null = null;
  private outline: PageOutline[] | null = null;
  private sections: SearchSection[] | null = null;
  private complete = false;
  private failed = false;
  private loading: Promise<void> | null = null;
  private readonly read: (file: string) => Promise<unknown>;
  private readonly onchange: (progress: SearchProgress) => void;

  constructor(
    read: (file: string) => Promise<unknown>,
    onchange: (progress: SearchProgress) => void,
  ) {
    this.read = read;
    this.onchange = onchange;
  }

  /** Where the navigation says the search is. */
  use(assets: SearchAssets) {
    this.assets = assets;
  }

  load(): Promise<void> {
    const assets = this.assets;
    if (this.complete || !assets) return Promise.resolve();
    if (this.loading) return this.loading;
    if (this.failed) this.report({ failed: false });
    this.loading = this.fetch(assets)
      .catch(() => this.report({ failed: true }))
      .finally(() => {
        this.loading = null;
      });
    return this.loading;
  }

  private async fetch(assets: SearchAssets) {
    if (!this.outline) {
      this.outline = list(assets.outline, await this.read(assets.outline)) as PageOutline[];
      this.report({ sections: joinSections(this.outline) });
    }
    const text = list(assets.text, await this.read(assets.text)) as string[];
    const sections = joinSections(this.outline, text);
    if (text.length !== sections.length)
      throw new Error(`${assets.text}: ${text.length} texts for ${sections.length} sections`);
    this.report({ sections, complete: true });
  }

  private report(change: Partial<SearchProgress>) {
    if (change.sections !== undefined) this.sections = change.sections;
    if (change.complete !== undefined) this.complete = change.complete;
    if (change.failed !== undefined) this.failed = change.failed;
    this.onchange({ sections: this.sections, complete: this.complete, failed: this.failed });
  }
}
