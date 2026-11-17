// The published site's server render: the same App, primed with the manual
// and the page's address, in the site's spelling. `scripts/site.ts` calls it
// for every page, and once more per page for the resident's spelling to check
// that its links stay local.

import { render } from "svelte/server";
import App from "../App.svelte";
import { docsStore } from "../lib/docs.svelte";
import { siteLinks, type DocsBundle, type SiteMode } from "../lib/docsite";
import { router } from "../lib/router.svelte";
import { useSite } from "../lib/routes";

export function renderPage(mode: SiteMode, bundle: DocsBundle, path: string): { head: string; body: string } {
  useSite(siteLinks(mode, bundle.site));
  docsStore.prime(bundle, mode === "local");
  router.prime(new URL(path, bundle.site.url));
  const { head, body } = render(App);
  return { head, body };
}
