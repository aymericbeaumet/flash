import type { SearchSection } from "../lib/docsite";
import { site } from "../lib/routes";
import type { SearchStage } from "../lib/search";
import { SearchLoader, type SearchAssets } from "./assets";

async function read(file: string): Promise<unknown> {
  const response = await fetch(`${site.links.root}/${file}`);
  if (!response.ok) throw new Error(`${file}: ${response.status}`);
  return response.json();
}

/**
 * What the published site searches: the manual's sections, fetched the first
 * time a search needs them. Their outline arrives first and finds a page by
 * its title or a heading; their text follows, and completes the results.
 */
class SiteSearch {
  sections = $state.raw<SearchSection[] | null>(null);
  /** Whether a query's results are final: only once the text is here. */
  stage = $state<SearchStage>("loading");
  private readonly loader = new SearchLoader(read, (progress) => {
    this.sections = progress.sections;
    this.stage = progress.complete ? "complete" : progress.failed ? "failed" : "loading";
  });

  /** Where the navigation says the search is. */
  use(assets: SearchAssets) {
    this.loader.use(assets);
  }

  load(): Promise<void> {
    return this.loader.load();
  }
}

export const siteSearch = new SiteSearch();
