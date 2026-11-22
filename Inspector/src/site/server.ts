// The build's server render of a manual page, primed with the manual and the
// page's address. The published site's page is its app around an empty
// reading area, and the article apart: `scripts/site.ts` sets the article
// into the reading area as HTML no browser hydrates. The resident's spelling
// renders once more per page, to check that its links stay local.

import { render } from "svelte/server";
import HelpApp from "../HelpApp.svelte";
import { pageArticle, readingMinutes } from "../lib/article";
import Article from "../lib/Article.svelte";
import { docsStore } from "../lib/docs.svelte";
import {
  docsIndex,
  Manual,
  ManualIndex,
  siteLinks,
  type DocsBundle,
  type SiteMode,
} from "../lib/docsite";
import { renderMarkdown } from "../lib/markdown";
import { router } from "../lib/router.svelte";
import { useSite } from "../lib/routes";
import SiteApp from "../SiteApp.svelte";

export interface RenderedPage {
  head: string;
  body: string;
  /** The page's article, for the published site's reading area. */
  article?: string;
}

const manuals = new WeakMap<DocsBundle, { manual: Manual; index: ManualIndex }>();

function publicManual(bundle: DocsBundle) {
  let known = manuals.get(bundle);
  if (!known) {
    known = {
      manual: new Manual(bundle, siteLinks("public", bundle.site)),
      index: new ManualIndex(docsIndex(bundle)),
    };
    manuals.set(bundle, known);
  }
  return known;
}

export function renderPage(mode: SiteMode, bundle: DocsBundle, path: string): RenderedPage {
  useSite(siteLinks(mode, bundle.site));
  router.prime(new URL(path, bundle.site.url));
  if (mode === "local") {
    docsStore.prime(bundle);
    const { head, body } = render(HelpApp);
    return { head, body };
  }
  const { manual, index } = publicManual(bundle);
  const { head, body } = render(SiteApp, { props: { manual: index } });
  const route = router.route;
  const page = route.page === "docs" ? manual.page(route.param) : undefined;
  if (!page) return { head, body };
  const rendered = renderMarkdown(page.markdown, manual.context(page.file));
  const article = render(Article, {
    props: {
      article: pageArticle(manual, page, rendered),
      rendered,
      minutes: readingMinutes(page.markdown),
    },
  });
  return { head, body, article: article.body };
}
