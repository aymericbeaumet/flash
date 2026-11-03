import { Manual, type DocsBundle, type SearchSection, type SiteLinks } from "./docsite";
import { bodyHash, type Readable } from "./reading";
import { describeFailure, requestJSON, withRetry } from "./request";
import { site } from "./routes";
import type { DocTopic } from "./types";

/**
 * The manual as the page holds it. The resident's help asks Flash for the
 * bundle it ships (`/api/docs`); a published page starts from the bundle it
 * was prerendered with, which carries only its own page's text, and fetches
 * the whole manual (`docs.json`) once the page is idle, so later links
 * navigate in place. Search sections load the first time a search needs them.
 */
class DocsStore {
  bundle = $state.raw<DocsBundle | null>(null);
  /** Every page's text is here, not only the prerendered one. */
  complete = $state(false);
  error = $state("");
  sections = $state.raw<SearchSection[] | null>(null);
  private built: { bundle: DocsBundle; links: SiteLinks; manual: Manual } | null = null;
  private loading: Promise<void> | null = null;
  private searching: Promise<void> | null = null;

  /** The bundle as pages and links of this site; one per bundle, so renders cache. */
  get manual(): Manual | null {
    const bundle = this.bundle;
    if (!bundle) return null;
    if (this.built?.bundle !== bundle || this.built.links !== site.links) this.built = { bundle, links: site.links, manual: new Manual(bundle, site.links) };
    return this.built.manual;
  }

  /**
   * What the resident's reader can mark new or updated: every manual page by
   * path and every plugin guide by name. Empty until the whole manual is
   * here, and on the published site, which keeps no reading state.
   */
  readable(topics: DocTopic[]): Readable[] {
    if (site.public || !this.complete || !this.bundle) return [];
    return [...this.bundle.pages.map((page) => ({ name: page.path, hash: page.hash })), ...topics.map((topic) => ({ name: topic.name, hash: bodyHash(topic.body) }))];
  }

  /** A prerendered page's bundle, before hydration. */
  prime(bundle: DocsBundle, complete: boolean) {
    this.bundle = bundle;
    this.complete = complete;
  }

  private url(name: "docs" | "search") {
    if (!site.public) return name === "docs" ? "/api/docs" : "/api/docs/search";
    return `${site.links.root}/${name}.json`;
  }

  load(): Promise<void> {
    if (this.complete) return Promise.resolve();
    this.loading ??= withRetry((signal) => requestJSON(this.url("docs"), { signal }))
      .then((value) => {
        const bundle = value as DocsBundle | null;
        if (!bundle || !Array.isArray(bundle.pages) || !Array.isArray(bundle.nav)) throw new Error("The documentation bundle is malformed");
        this.bundle = bundle;
        this.complete = true;
        this.error = "";
      })
      .catch((error) => {
        this.error = `The documentation did not load. ${describeFailure(error)}.`;
      })
      .finally(() => { this.loading = null; });
    return this.loading;
  }

  loadSections(): Promise<void> {
    if (this.sections) return Promise.resolve();
    this.searching ??= withRetry((signal) => requestJSON(this.url("search"), { signal }))
      .then((value) => {
        if (Array.isArray(value)) this.sections = value as SearchSection[];
      })
      .catch(() => { /* Search keeps the guides, commands and mappings it has. */ })
      .finally(() => { this.searching = null; });
    return this.searching;
  }
}

export const docsStore = new DocsStore();
