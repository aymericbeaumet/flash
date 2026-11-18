import type { SearchSection } from "../lib/docsite";
import { site } from "../lib/routes";

/**
 * What the published site searches: the manual's sections (`search.json`),
 * fetched the first time a search needs them.
 */
class SiteSearch {
  sections = $state.raw<SearchSection[] | null>(null);
  private loading: Promise<void> | null = null;

  load(): Promise<void> {
    if (this.sections) return Promise.resolve();
    this.loading ??= fetch(`${site.links.root}/search.json`)
      .then((response) => (response.ok ? response.json() : null))
      .then((value: unknown) => {
        if (Array.isArray(value)) this.sections = value as SearchSection[];
      })
      .catch(() => {
        /* Search stays empty; the next use asks again. */
      })
      .finally(() => {
        this.loading = null;
      });
    return this.loading;
  }
}

export const siteSearch = new SiteSearch();
