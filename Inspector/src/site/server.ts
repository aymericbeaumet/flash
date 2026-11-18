// The build's server render of a manual page, primed with the manual and the
// page's address: the published site's app in the site's spelling, the
// resident's in its own. `scripts/site.ts` calls it for every page it
// publishes, and once more per page for the resident's spelling to check that
// its links stay local.

import { render } from "svelte/server";
import HelpApp from "../HelpApp.svelte";
import { docsStore } from "../lib/docs.svelte";
import { siteLinks, type DocsBundle, type SiteMode } from "../lib/docsite";
import { router } from "../lib/router.svelte";
import { useSite } from "../lib/routes";
import SiteApp from "../SiteApp.svelte";

export function renderPage(
  mode: SiteMode,
  bundle: DocsBundle,
  path: string,
): { head: string; body: string } {
  useSite(siteLinks(mode, bundle.site));
  docsStore.prime(bundle, mode === "local");
  router.prime(new URL(path, bundle.site.url));
  const { head, body } = render(mode === "public" ? SiteApp : HelpApp);
  return { head, body };
}
