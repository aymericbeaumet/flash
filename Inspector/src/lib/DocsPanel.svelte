<script lang="ts">
  import { onMount, tick } from "svelte";
  import { docsStore } from "./docs.svelte";
  import type { NavNode } from "./docsite";
  import FreshMark from "./FreshMark.svelte";
  import Icon from "./Icon.svelte";
  import Markdown from "./Markdown.svelte";
  import { renderMarkdown, type RenderContext, type Rendered } from "./markdown";
  import { markGuideRead } from "./onboarding";
  import PageHeader from "./PageHeader.svelte";
  import { bodyHash, freshNotice, freshness, loadSeen, markAllSeen, markSeen, readingKey, type Freshness, type SeenGuides } from "./reading";
  import { router } from "./router.svelte";
  import { parseRoute, paths } from "./routes";
  import { copyText, toasts } from "./toasts.svelte";
  import type { DocTopic } from "./types";

  /**
   * The documentation view: a page of the manual (`docs/`), which the
   * resident's `/docs/<page>` and the published site render identically, or
   * a plugin's own guide, which only the resident has. A page's alias
   * (`config`) shows the page and settles on its path.
   */
  let { param, docs = [] }: { param: string; docs?: DocTopic[] } = $props();

  type Entry = { title: string; href: string; depth: number; active: boolean; badge?: Freshness } | { title: string; depth: number; heading: true };
  type Section = { title?: string; entries: Entry[] };

  let query = $state("");
  let topicsOpen = $state(false);
  let seen = $state<SeenGuides | null>(loadSeen());
  let activeHeading = $state("");
  let body = $state<HTMLElement>();
  let mounted = $state(false);
  onMount(() => { mounted = true; });

  const normalize = (text: string) => text.trim().toLowerCase();
  const matches = (doc: DocTopic, name: string) => normalize(doc.name) === normalize(name);
  const manual = $derived(docsStore.manual);
  const page = $derived(manual?.page(param));
  /** A plugin's guide takes a name only the manual leaves free. */
  const topic = $derived(manual && !page ? docs.find((doc) => matches(doc, param)) : undefined);
  /** A prerendered page holds only its own text until the whole manual arrives. */
  const waiting = $derived(!manual || (!!page && !page.markdown && !docsStore.complete));

  /** A plugin's guide links app paths, manual pages and other plugin guides. */
  const guideContext = $derived.by((): RenderContext => {
    const known = manual;
    const route = (path: string, anchor?: string) => {
      const target = parseRoute(new URL(path, "http://flash.invalid"));
      if (target.page === "not-found") return undefined;
      if (target.page === "docs") {
        const found = known?.page(target.param);
        if (found) return paths.docs(found.path, anchor);
        return docs.some((doc) => matches(doc, target.param)) ? paths.docs(target.param, anchor) : undefined;
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
    if (page && manual && !waiting) return renderMarkdown(page.markdown, manual.context(page.file));
    return topic ? renderMarkdown(topic.body, guideContext) : undefined;
  });
  const markdown = $derived(page?.markdown ?? topic?.body ?? "");
  const minutes = $derived(Math.max(1, Math.ceil(markdown.split(/\s+/).length / 220)));
  /** Pages new or changed since this browser last read them; the resident's help only. */
  const reading = $derived(docsStore.readable(docs));
  const fresh = $derived(freshness(reading, seen));
  const helpCommand = $derived(topic ? `flash help show --topic='${topic.name.replaceAll("'", "'\\''")}'` : "");
  const pluginGroup = "Plugin guides";

  const article = $derived.by(() => {
    if (page && manual && rendered) {
      const { previous, next } = manual.neighbours(page.path);
      return {
        key: `page:${page.path}`,
        crumbs: [{ label: "Documentation", href: paths.docs() as string | undefined }, ...page.trail.map((label) => ({ label, href: undefined }))],
        title: rendered.title ?? page.title,
        summary: undefined as string | undefined,
        edit: manual.editURL(page) as string | undefined,
        previous: previous && { href: paths.docs(previous.path), title: previous.title },
        next: next && { href: paths.docs(next.path), title: next.title },
        up: undefined as { href: string; title: string } | undefined,
      };
    }
    if (!topic || !rendered) return undefined;
    return {
      key: `topic:${topic.name}`,
      crumbs: [{ label: "Documentation", href: paths.docs() as string | undefined }, { label: pluginGroup, href: undefined }],
      title: topic.title,
      summary: topic.summary as string | undefined,
      edit: undefined as string | undefined,
      previous: undefined as { href: string; title: string } | undefined,
      next: undefined as { href: string; title: string } | undefined,
      up: { href: paths.docs(), title: "Documentation" },
    };
  });
  const current = $derived(page ? { name: page.path, hash: page.hash } : topic ? { name: topic.name, hash: bodyHash(topic.body) } : undefined);

  /** The sidebar: the manual's navigation, then the plugins' guides in the resident's help. */
  const sections = $derived.by((): Section[] => {
    if (!manual) return [];
    const filter = normalize(query);
    const known = manual;
    const walk = (nodes: NavNode[], depth: number, trail: string[]): Entry[] => nodes.flatMap((node): Entry[] => {
      if (node.items) {
        const inner = walk(node.items, depth + 1, [...trail, node.title]);
        return inner.length ? [{ title: node.title, depth, heading: true }, ...inner] : [];
      }
      const path = node.path ?? "";
      const target = known.page(path);
      if (filter && !normalize([node.title, target?.heading ?? "", ...(target?.aliases ?? []), ...trail].join(" ")).includes(filter)) return [];
      return [{ title: node.title, href: paths.docs(path), depth, active: page?.path === path, badge: fresh.get(path) }];
    });
    const out: Section[] = [];
    for (const node of known.bundle.nav) {
      if (!node.items) {
        const entries = walk([node], 0, []);
        if (!entries.length) continue;
        const last = out[out.length - 1];
        if (last && last.title === undefined) last.entries.push(...entries);
        else out.push({ entries });
        continue;
      }
      const entries = walk(node.items, 1, [node.title]);
      if (entries.length) out.push({ title: node.title, entries });
    }
    const guides = docs.filter((doc) => !known.page(doc.name) && (!filter || normalize([doc.title, doc.name, doc.summary].join(" ")).includes(filter)));
    if (guides.length) out.push({ title: pluginGroup, entries: guides.map((doc) => ({ title: doc.title, href: paths.docs(doc.name), depth: 1, active: topic?.name === doc.name, badge: fresh.get(doc.name) })) });
    return out;
  });
  const currentLabel = $derived(article ? `${article.crumbs[article.crumbs.length - 1].label} · ${article.title}` : "Documentation");

  // The first visit records every page as seen: badges mark what changes
  // from here on. Opening a page acknowledges its current text.
  $effect(() => {
    if (!reading.length) return;
    if (!seen) { seen = markAllSeen(reading); return; }
    if (current && fresh.get(current.name)) seen = markSeen(current, seen);
  });
  // While anything is new or updated, a toast says what the ✨ marks. It
  // closes when the last fresh page is opened, on Mark all as read, and with
  // this view; a dismissal holds until the documentation changes again.
  const noticeKey = $derived(fresh.size ? readingKey(reading) : "");
  $effect(() => {
    if (!noticeKey) return;
    const id = toasts.show(freshNotice(noticeKey, () => { seen = markAllSeen(reading); }));
    return () => toasts.close(id);
  });
  $effect(() => { if (page) markGuideRead(page.path); });
  // An alias settles on its page's path, keeping the anchor.
  $effect(() => {
    if (!page || page.path === param.replace(/^\/+|\/+$/g, "")) return;
    router.replace(paths.docs(page.path) + location.hash);
  });
  $effect(() => { void article?.key; topicsOpen = false; });
  $effect(() => { if (page && !page.markdown && !docsStore.complete) void docsStore.load(); });

  // The outline follows the section at the top of the reading area.
  $effect(() => {
    const container = body;
    void rendered;
    if (!container) return;
    let observer: IntersectionObserver | undefined;
    void tick().then(() => {
      const headings = Array.from(container.querySelectorAll("h2, h3"));
      if (!headings.length || typeof IntersectionObserver === "undefined") return;
      observer = new IntersectionObserver((entries) => {
        const visible = entries.filter((entry) => entry.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
        if (visible[0]) activeHeading = visible[0].target.id;
      }, { root: container.closest("main"), rootMargin: "0px 0px -70% 0px", threshold: 0 });
      for (const heading of headings) observer.observe(heading);
    });
    return () => observer?.disconnect();
  });

  function copyHelp() {
    if (topic) void copyText(helpCommand, "the help command");
  }
</script>

<div class="docs-layout">
  <aside class="topics" aria-label="Documentation">
    <a class="all-docs" href={paths.docs()}><Icon name="docs" size={16} /> Documentation <FreshMark state={fresh.size ? "new" : undefined} label="New or updated pages since your last visit" /></a>
    <button type="button" class="topics-toggle" aria-expanded={topicsOpen} aria-controls="guide-list" onclick={() => topicsOpen = !topicsOpen}><Icon name="docs" size={16} /><span>{currentLabel}</span><Icon name="chevron" size={12} /></button>
    <div class="topics-body" class:open={topicsOpen} id="guide-list">
      <input type="search" placeholder="Find a page…" aria-label="Filter documentation pages" bind:value={query} />
      <nav aria-label="Documentation pages">{#each sections as section}<section>{#if section.title}<h2 class="eyebrow">{section.title}</h2>{/if}{#each section.entries as entry}{#if "heading" in entry}<h3 class="subgroup">{entry.title}</h3>{:else}<a class:active={entry.active} class:nested={entry.depth > 1} href={entry.href} aria-current={entry.active ? "page" : undefined}><span>{entry.title}</span><FreshMark state={entry.badge} /></a>{/if}{/each}</section>{/each}{#if !sections.length && query}<p class="muted no-topics">Nothing matches “{query}”.</p>{/if}</nav>
    </div>
  </aside>
  <div class="reading-area">
    {#if article && rendered}
      <article>
        <header class="article-heading">
          <p class="eyebrow">{#each article.crumbs as crumb, position}{#if position}{" › "}{/if}{#if crumb.href}<a href={crumb.href}>{crumb.label}</a>{:else}{crumb.label}{/if}{/each}</p>
          <h1 id={rendered.titleId}>{article.title}{#if current}<FreshMark state={fresh.get(current.name)} />{/if}</h1>
          {#if article.summary}<p class="summary">{article.summary}</p>{/if}
          <div class="article-meta">
            <span>{minutes} min read</span>
            {#if topic}<span aria-hidden="true">·</span><button type="button" class="help-copy" onclick={copyHelp} aria-label="Copy the flash help command for this guide"><code>{helpCommand}</code> <span>copy</span></button>{/if}
            {#if article.edit}<span aria-hidden="true">·</span><a href={article.edit} target="_blank" rel="noopener noreferrer">Edit on GitHub <span aria-hidden="true">↗</span></a>{/if}
          </div>
        </header>
        {#if rendered.headings.length}
          <details class="toc-inline"><summary>On this page</summary><nav aria-label="On this page">{#each rendered.headings as heading}<a class:subheading={heading.level === 3} href={"#" + heading.id}>{heading.title}</a>{/each}</nav></details>
        {/if}
        <div class="article-body" bind:this={body}><Markdown nodes={rendered.nodes} interactive={mounted} /></div>
        <footer class="article-footer">
          {#if article.previous}<a class="prev" href={article.previous.href}><span class="eyebrow">Previous</span>{article.previous.title}</a>{:else if article.up}<a class="prev" href={article.up.href}><span class="eyebrow">Up</span>{article.up.title}</a>{/if}
          {#if article.next}<a class="next" href={article.next.href}><span class="eyebrow">Next</span>{article.next.title}</a>{/if}
        </footer>
      </article>
      {#if rendered.headings.length}<aside class="toc"><p class="eyebrow">On this page</p><nav aria-label="On this page">{#each rendered.headings as heading}<a class:subheading={heading.level === 3} class:current={activeHeading === heading.id} href={"#" + heading.id} aria-current={activeHeading === heading.id ? "location" : undefined}>{heading.title}</a>{/each}</nav></aside>{/if}
    {:else}
      <div class="docs-index">
        {#if docsStore.error && !manual}<PageHeader id="docs" title="Documentation" purpose={docsStore.error} /><p class="not-found-links"><button type="button" onclick={() => docsStore.load()}><Icon name="refresh" size={14} /> Retry</button></p>
        {:else if waiting}<PageHeader id="docs" title="Loading…" purpose="Fetching the documentation." />
        {:else}<PageHeader id="docs" title="Page not found" purpose={`There is no documentation page at “${param}”. Pick one from the list, or search.`} /><p class="not-found-links"><a href={paths.docs()}>Documentation home <span aria-hidden="true">→</span></a><a href={paths.search()}>Search <span aria-hidden="true">→</span></a></p>{/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .docs-layout { display: grid; grid-template-columns: 228px minmax(0, 1fr); min-height: 100%; }
  .topics { border-right: 1px solid var(--border); padding: 20px 12px; background: var(--sidebar); }
  .all-docs { display: flex; align-items: center; gap: 8px; font: 600 12px var(--mono); letter-spacing: .1em; text-transform: uppercase; padding: 0 8px; margin-bottom: 14px; color: var(--text); }
  .all-docs:hover { color: var(--accent); text-decoration: none; }
  .topics-toggle { display: none; width: 100%; align-items: center; gap: 10px; text-align: left; font-size: 13px; }
  .topics-toggle span:nth-child(2) { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .topics input { width: 100%; font-size: 13px; margin-bottom: 18px; }
  .topics section { margin-bottom: 18px; }
  .topics h2 { padding: 0 9px; margin-bottom: 4px; font-size: 12px; letter-spacing: .14em; color: var(--faint); }
  .topics .subgroup { padding: 0 9px; margin: 10px 0 2px; font-size: 12px; font-weight: 500; color: var(--muted); }
  .topics nav a { display: flex; align-items: center; justify-content: space-between; gap: 8px; font-size: 13px; color: var(--muted); padding: 6px 9px; min-height: 34px; border-radius: 5px; line-height: 1.35; }
  .topics nav a.nested { padding-left: 19px; }
  .topics nav a.active { background: var(--raised); color: var(--text); font-weight: 550; box-shadow: inset 2px 0 0 var(--accent); }
  .topics nav a:hover { background: var(--raised); color: var(--text); text-decoration: none; }
  .no-topics { font-size: 13px; padding: 10px; }
  .reading-area { display: flex; align-items: flex-start; justify-content: center; gap: 38px; padding: 30px 36px 64px; min-width: 0; }
  article { flex: 1; min-width: 0; max-width: 760px; }
  .article-heading { position: relative; padding-bottom: 20px; margin-bottom: 26px; border-bottom: 1px solid var(--border); }
  .article-heading::after { content: ""; position: absolute; left: 0; bottom: -1px; width: 48px; height: 1px; background: var(--accent); }
  .article-heading .eyebrow { margin-bottom: 12px; }
  .article-heading .eyebrow a { color: inherit; }
  .article-heading h1 { font-size: 32px; letter-spacing: -.02em; display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .summary { font-size: 16px; color: var(--muted); margin-top: 12px; line-height: 1.65; }
  .article-meta { display: flex; align-items: center; flex-wrap: wrap; gap: 10px; margin-top: 14px; color: var(--muted); font-size: 12px; min-height: 36px; }
  .help-copy { border: 0; background: none; padding: 0; min-height: 36px; max-width: 100%; display: inline-flex; align-items: center; gap: 6px; color: var(--muted); font-size: 12px; text-align: left; box-shadow: none; }
  .help-copy:hover { background: none; color: var(--accent); }
  .article-meta code { font-size: 12px; overflow-wrap: anywhere; }
  .toc-inline { display: none; margin-bottom: 22px; border: 1px solid var(--border); border-radius: 6px; padding: 8px 14px; background: var(--panel); }
  .toc-inline summary { cursor: pointer; font-weight: 600; font-size: 13px; min-height: 32px; display: flex; align-items: center; }
  .toc-inline nav { display: flex; flex-direction: column; padding-top: 6px; }
  .toc-inline nav a { padding: 6px 0; min-height: 36px; display: flex; align-items: center; font-size: 14px; }
  .toc-inline nav a.subheading { padding-left: 14px; }
  .article-body { font-size: 15px; line-height: 1.75; color: #d9d1c0; overflow-wrap: anywhere; }
  .article-body :global(h2), .article-body :global(h3), .article-body :global(h4) { color: var(--text); scroll-margin-top: 24px; }
  .article-body :global(.heading-anchor) { margin-left: 8px; color: var(--accent-dim); text-decoration: none; font-weight: 400; opacity: 0; }
  .article-body :global(:is(h2, h3, h4):hover .heading-anchor), .article-body :global(.heading-anchor:focus-visible) { opacity: 1; }
  @media (hover: none) { .article-body :global(.heading-anchor) { opacity: .7; } }
  .article-body :global(h2) { margin: 36px 0 12px; font-size: 22px; padding-bottom: 6px; border-bottom: 1px solid var(--border-soft); }
  .article-body :global(h3) { margin: 26px 0 8px; font-size: 17px; }
  .article-body :global(h4) { margin: 20px 0 8px; font-size: 15px; }
  .article-body :global(p) { margin: 12px 0; }
  .article-body :global(strong) { color: var(--text); }
  .article-body :global(ul), .article-body :global(ol) { padding-left: 24px; margin: 12px 0 18px; }
  .article-body :global(li) { margin: 5px 0; }
  .article-body :global(li::marker) { color: var(--accent-dim); }
  .article-body :global(li.task) { list-style: none; margin-left: -20px; }
  .article-body :global(code) { background: var(--raised); border: 1px solid var(--border-soft); padding: 1px 5px; border-radius: 4px; color: var(--code); font-size: .86em; overflow-wrap: anywhere; }
  .article-body :global(pre) { position: relative; background: var(--inset); border: 1px solid var(--border-soft); border-left: 2px solid var(--accent-dim); box-shadow: var(--well); border-radius: 5px; padding: 16px 18px; margin: 18px 0; color: var(--code); max-width: 100%; }
  .article-body :global(pre code) { background: none; border: 0; padding: 0; border-radius: 0; font-size: 13px; overflow-wrap: normal; }
  /* Code: comments recede, strings take verdigris, keys and tables brass. */
  .article-body :global(.tok-comment) { color: var(--faint); font-style: italic; }
  .article-body :global(.tok-string) { color: var(--verdigris); }
  .article-body :global(.tok-number) { color: var(--copper); }
  .article-body :global(.tok-keyword) { color: var(--steel); }
  .article-body :global(.tok-key) { color: var(--accent); }
  .article-body :global(.tok-section) { color: var(--accent-strong); font-weight: 600; }
  .article-body :global(.tok-variable) { color: var(--amber); }
  .article-body :global(.tok-flag) { color: var(--steel); }
  .article-body :global(.tok-function) { color: var(--accent); }
  .article-body :global(.tok-type) { color: var(--steel); }
  .article-body :global(.copy-code) { position: absolute; top: 8px; right: 8px; min-height: 28px; padding: 2px 10px; font: 12px var(--sans); opacity: .85; }
  .article-body :global(.copy-code:hover), .article-body :global(.copy-code:focus-visible) { opacity: 1; }
  .article-body :global(table) { display: block; max-width: 100%; overflow: auto; border-collapse: collapse; font-size: 13px; margin: 18px 0; }
  .article-body :global(th) { text-align: left; font: 500 12px var(--mono); letter-spacing: .06em; text-transform: uppercase; background: var(--raised); color: var(--muted); }
  .article-body :global(th), .article-body :global(td) { padding: 8px 12px; border: 1px solid var(--border); min-width: 90px; overflow-wrap: break-word; }
  .article-body :global(.align-center) { text-align: center; }
  .article-body :global(.align-right) { text-align: right; }
  .article-body :global(blockquote) { margin: 18px 0; padding: 4px 18px; border-left: 2px solid var(--verdigris); background: var(--verdigris-soft); color: var(--text); border-radius: 0 5px 5px 0; }
  /* Admonitions: a hairline panel with a brass rule, amber or oxide for caution. */
  .article-body :global(.admonition) { margin: 18px 0; padding: 4px 18px; border: 1px solid var(--border-soft); border-left: 2px solid var(--accent); background: var(--panel); border-radius: 0 5px 5px 0; }
  .article-body :global(.admonition-title) { margin: 10px 0 4px; font: 600 12px var(--mono); letter-spacing: .1em; text-transform: uppercase; color: var(--accent); }
  .article-body :global(:is(.admonition.tip, .admonition.success, .admonition.info)) { border-left-color: var(--verdigris); }
  .article-body :global(:is(.admonition.tip, .admonition.success, .admonition.info) .admonition-title) { color: var(--verdigris); }
  .article-body :global(:is(.admonition.warning, .admonition.caution, .admonition.attention)) { border-left-color: var(--amber); }
  .article-body :global(:is(.admonition.warning, .admonition.caution, .admonition.attention) .admonition-title) { color: var(--amber); }
  .article-body :global(:is(.admonition.danger, .admonition.error, .admonition.failure, .admonition.bug)) { border-left-color: var(--danger); }
  .article-body :global(:is(.admonition.danger, .admonition.error, .admonition.failure, .admonition.bug) .admonition-title) { color: var(--danger); }
  .article-body :global(img) { max-width: 100%; height: auto; border: 1px solid var(--border-soft); border-radius: 5px; }
  .article-body :global(details) { padding: 10px 14px; border: 1px solid var(--border); border-radius: 5px; margin: 14px 0; background: var(--panel); }
  .article-body :global(summary) { cursor: pointer; color: var(--accent); font-weight: 500; }
  .article-body :global(hr) { border: 0; border-top: 1px solid var(--border); margin: 30px 0; }
  .article-body :global(a) { text-decoration: underline; text-decoration-color: var(--accent-dim); text-underline-offset: 3px; }
  .article-body :global(a[data-external])::after { content: " ↗"; font-size: .8em; color: var(--muted); }
  /* A live page of the resident's help, named on the published site. */
  .article-body :global(.live-link) { color: var(--text); border-bottom: 1px dotted var(--accent-dim); cursor: help; }
  .article-body :global(kbd) { font-size: 12px; }
  .article-footer { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; padding-top: 20px; margin-top: 34px; border-top: 1px solid var(--border); }
  .article-footer a { display: flex; flex-direction: column; gap: 3px; padding: 12px 14px; border: 1px solid var(--border); border-radius: 6px; background: var(--panel); box-shadow: var(--engrave); color: var(--text); font-size: 14px; font-weight: 500; min-height: 44px; }
  .article-footer a:hover { border-color: var(--accent-dim); text-decoration: none; color: var(--text); }
  .article-footer .next { text-align: right; align-items: flex-end; grid-column: 2; }
  .toc { width: 190px; flex-shrink: 0; position: sticky; top: 24px; font-size: 12px; padding-top: 4px; }
  .toc .eyebrow { margin-bottom: 10px; }
  .toc nav { border-left: 1px solid var(--border); padding-left: 11px; max-height: 55vh; overflow: auto; margin-bottom: 20px; }
  .toc nav a { display: flex; align-items: center; padding: 4px 0; font-size: 12px; min-height: 30px; color: var(--muted); line-height: 1.4; margin-left: -12px; padding-left: 11px; border-left: 2px solid transparent; }
  .toc nav a:hover { color: var(--accent); text-decoration: none; }
  .toc nav a.current { color: var(--accent); border-left-color: var(--accent); }
  .toc nav a.subheading { padding-left: 22px; }
  .docs-index { max-width: 1000px; width: 100%; }
  .not-found-links { display: flex; gap: 24px; font-size: 14px; }
  .not-found-links button { display: inline-flex; align-items: center; gap: 6px; }
  @media (max-width: 1300px) { .toc { display: none; } .toc-inline { display: block; } .reading-area { padding: 26px 26px 50px; } .docs-layout { grid-template-columns: 204px minmax(0, 1fr); } }
  @media (max-width: 1000px) {
    .docs-layout { grid-template-columns: minmax(0, 1fr); }
    .topics { border-right: 0; border-bottom: 1px solid var(--border); padding: 10px 22px; }
    .topics .all-docs { display: none; }
    .topics-toggle { display: flex; }
    .topics-body { display: none; padding-top: 12px; }
    .topics-body.open { display: block; }
    .topics input { margin: 0 0 12px; max-width: 320px; }
    .topics nav { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 0 24px; }
    .topics section { margin: 0 0 12px; }
  }
  @media (max-width: 600px) { .reading-area { padding: 20px 14px 40px; } .article-heading h1, .docs-index :global(h1) { font-size: 26px; } .article-footer { grid-template-columns: 1fr; } .article-footer .next { grid-column: 1; } .topics { padding: 10px 14px; } }
  @media print {
    .docs-layout, .reading-area { display: block; padding: 0; }
    .topics, .toc, .toc-inline, .article-footer, .article-body :global(.heading-anchor), .article-body :global(.copy-code), .help-copy span { display: none; }
    article, .docs-index { max-width: none; }
    .article-body { color: var(--text); }
    .article-body :global(a[data-external])::after { content: " (" attr(href) ")"; }
    .article-body :global(table) { display: table; overflow: visible; }
    .article-body :global(tr), .article-body :global(blockquote), .article-body :global(.admonition) { break-inside: avoid; }
    .article-body :global(pre) { padding: 12px 14px; box-shadow: none; }
  }
</style>
