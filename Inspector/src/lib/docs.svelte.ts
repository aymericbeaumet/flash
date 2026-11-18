import { Manual, type DocsBundle, type SearchSection, type SiteLinks } from "./docsite";
import { bodyHash, type Readable } from "./reading";
import { describeFailure, requestJSON, withRetry } from "./request";
import { site } from "./routes";
import type { DocTopic } from "./types";

/**
 * The manual as the resident's help holds it: the bundle Flash ships
 * (`/api/docs`), every page's text included, so links navigate in place.
 * Search sections (`/api/docs/search`) load the first time a search needs
 * them.
 */
class DocsStore {
  bundle = $state.raw<DocsBundle | null>(null);
  error = $state("");
  sections = $state.raw<SearchSection[] | null>(null);
  private built: { bundle: DocsBundle; links: SiteLinks; manual: Manual } | null = null;
  private loading: Promise<void> | null = null;
  private searching: Promise<void> | null = null;

  /** The bundle as pages and links of this site; one per bundle, so renders cache. */
  get manual(): Manual | null {
    const bundle = this.bundle;
    if (!bundle) return null;
    if (this.built?.bundle !== bundle || this.built.links !== site.links)
      this.built = { bundle, links: site.links, manual: new Manual(bundle, site.links) };
    return this.built.manual;
  }

  /**
   * What the reader can mark new or updated: every manual page by path and
   * every plugin guide by name. Empty until the manual is here.
   */
  readable(topics: DocTopic[]): Readable[] {
    if (!this.bundle) return [];
    return [
      ...this.bundle.pages.map((page) => ({ name: page.path, hash: page.hash })),
      ...topics.map((topic) => ({ name: topic.name, hash: bodyHash(topic.body) })),
    ];
  }

  /** The bundle the build's server render draws from. */
  prime(bundle: DocsBundle) {
    this.bundle = bundle;
  }

  load(): Promise<void> {
    if (this.bundle) return Promise.resolve();
    this.loading ??= withRetry((signal) => requestJSON("/api/docs", { signal }))
      .then((value) => {
        const bundle = value as DocsBundle | null;
        if (!bundle || !Array.isArray(bundle.pages) || !Array.isArray(bundle.nav))
          throw new Error("The documentation bundle is malformed");
        this.bundle = bundle;
        this.error = "";
      })
      .catch((error) => {
        this.error = `The documentation did not load. ${describeFailure(error)}.`;
      })
      .finally(() => {
        this.loading = null;
      });
    return this.loading;
  }

  /** Loads once the page is idle, for a page that shows without the manual. */
  loadWhenIdle() {
    const load = () => void this.load();
    if ("requestIdleCallback" in window) requestIdleCallback(load, { timeout: 2000 });
    else setTimeout(load, 200);
  }

  loadSections(): Promise<void> {
    if (this.sections) return Promise.resolve();
    this.searching ??= withRetry((signal) => requestJSON("/api/docs/search", { signal }))
      .then((value) => {
        if (Array.isArray(value)) this.sections = value as SearchSection[];
      })
      .catch(() => {
        /* Search keeps the guides, commands and mappings it has. */
      })
      .finally(() => {
        this.searching = null;
      });
    return this.searching;
  }
}

export const docsStore = new DocsStore();
