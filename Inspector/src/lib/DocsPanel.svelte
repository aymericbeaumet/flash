<script lang="ts">
  import { pageArticle, readingMinutes, type ArticleInfo } from "./article";
  import Article from "./Article.svelte";
  import { docsStore } from "./docs.svelte";
  import DocsLayout from "./DocsLayout.svelte";
  import DocsNotice from "./DocsNotice.svelte";
  import { renderMarkdown } from "./markdown";
  import type { RenderContext, Rendered } from "./markdown-tree";
  import {
    bodyHash,
    freshNotice,
    freshness,
    loadSeen,
    markAllSeen,
    markSeen,
    readingKey,
    type SeenGuides,
  } from "./reading";
  import { router } from "./router.svelte";
  import { parseRoute, paths } from "./routes";
  import { toasts } from "./toasts.svelte";
  import type { DocTopic } from "./types";

  /**
   * The resident's documentation view: a page of the manual (`docs/`), which
   * `/docs/<page>` renders as the published site's build does, or a plugin's
   * own guide. A page's alias (`config`) shows the page and settles on its
   * path.
   */
  let { param, docs = [] }: { param: string; docs?: DocTopic[] } = $props();

  let seen = $state<SeenGuides | null>(loadSeen());

  const normalize = (text: string) => text.trim().toLowerCase();
  const matches = (doc: DocTopic, name: string) => normalize(doc.name) === normalize(name);
  const manual = $derived(docsStore.manual);
  const page = $derived(manual?.page(param));
  /** A plugin's guide takes a name only the manual leaves free. */
  const topic = $derived(manual && !page ? docs.find((doc) => matches(doc, param)) : undefined);

  /** A plugin's guide links app paths, manual pages and other plugin guides. */
  const guideContext = $derived.by((): RenderContext => {
    const known = manual;
    const route = (path: string, anchor?: string) => {
      const target = parseRoute(new URL(path, "http://flash.invalid"));
      if (target.page === "not-found") return undefined;
      if (target.page === "docs") {
        const found = known?.page(target.param);
        if (found) return paths.docs(found.path, anchor);
        return docs.some((doc) => matches(doc, target.param))
          ? paths.docs(target.param, anchor)
          : undefined;
      }
      return path + (anchor ? `#${encodeURIComponent(anchor)}` : "");
    };
    return {
      hasFile: (path) => known?.hasFile(path) ?? false,
      href: (target) => {
        if (target.kind === "route") return route(target.path, target.anchor);
        if (known) return known.href(target);
        if (target.kind === "anchor") return `#${encodeURIComponent(target.anchor)}`;
        return target.kind === "external" ? target.url : undefined;
      },
      topic: (name) => {
        const found = known?.page(name);
        if (found) return paths.docs(found.path);
        const doc = docs.find((candidate) => matches(candidate, name));
        return doc ? paths.docs(doc.name) : undefined;
      },
      command: (name) => paths.commands(name),
      siteURL: known?.bundle.site.url ?? "",
    };
  });

  const rendered = $derived.by((): Rendered | undefined => {
    if (page && manual) return renderMarkdown(page.markdown, manual.context(page.file));
    return topic ? renderMarkdown(topic.body, guideContext) : undefined;
  });
  const markdown = $derived(page?.markdown ?? topic?.body ?? "");
  const minutes = $derived(readingMinutes(markdown));
  /** Pages new or changed since this browser last read them; the resident's help only. */
  const reading = $derived(docsStore.readable(docs));
  const fresh = $derived(freshness(reading, seen));
  const helpCommand = $derived(
    topic ? `flash help show --topic='${topic.name.replaceAll("'", "'\\''")}'` : "",
  );

  const article = $derived.by((): ArticleInfo | undefined => {
    if (page && manual && rendered) return pageArticle(manual, page, rendered);
    if (!topic || !rendered) return undefined;
    return {
      crumbs: [{ label: "Documentation", href: paths.docs() }, { label: "Plugin guides" }],
      title: topic.title,
      summary: topic.summary,
      up: { href: paths.docs(), title: "Documentation" },
    };
  });
  const current = $derived(
    page
      ? { name: page.path, hash: page.hash }
      : topic
        ? { name: topic.name, hash: bodyHash(topic.body) }
        : undefined,
  );

  const currentLabel = $derived(
    article
      ? `${article.crumbs[article.crumbs.length - 1].label} · ${article.title}`
      : "Documentation",
  );

  // The first visit records every page as seen: badges mark what changes
  // from here on. Opening a page acknowledges its current text.
  $effect(() => {
    if (!reading.length) return;
    if (!seen) {
      seen = markAllSeen(reading);
      return;
    }
    if (current && fresh.get(current.name)) seen = markSeen(current, seen);
  });
  // While anything is new or updated, a toast says what the ✨ marks. It
  // closes when the last fresh page is opened, on Mark all as read, and with
  // this view; a dismissal holds until the documentation changes again.
  const noticeKey = $derived(fresh.size ? readingKey(reading) : "");
  $effect(() => {
    if (!noticeKey) return;
    const id = toasts.show(
      freshNotice(noticeKey, () => {
        seen = markAllSeen(reading);
      }),
    );
    return () => toasts.close(id);
  });
  // An alias settles on its page's path, keeping the anchor.
  $effect(() => {
    if (!page || page.path === param.replace(/^\/+|\/+$/g, "")) return;
    router.replace(paths.docs(page.path) + location.hash);
  });
</script>

<DocsLayout
  index={manual}
  guides={docs}
  active={page?.path ?? topic?.name}
  {fresh}
  label={currentLabel}
>
  {#if article && rendered}<Article
      {article}
      {rendered}
      {minutes}
      fresh={current && fresh.get(current.name)}
      help={topic ? helpCommand : undefined}
    />
  {:else}<DocsNotice
      {param}
      waiting={!manual}
      error={manual ? "" : docsStore.error}
      onretry={() => void docsStore.load()}
    />{/if}
</DocsLayout>
