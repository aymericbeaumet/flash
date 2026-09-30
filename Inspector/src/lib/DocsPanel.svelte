<script lang="ts">
  import Icon from "./Icon.svelte";
  import { paths } from "./routes";
  import { renderMarkdown } from "./markdown";
  import { groupTopics } from "./topics";
  import type { DocTopic } from "./types";
  let { docs, topic }: { docs: DocTopic[]; topic: string } = $props();
  let query = $state("");
  const normalize = (text: string) => text.trim().toLowerCase();
  const selected = $derived(docs.find((doc) => normalize(doc.name) === normalize(topic) || (doc.aliases ?? []).some((alias) => normalize(alias) === normalize(topic))));
  const groups = $derived(groupTopics(docs.filter((doc) => !query.trim() || normalize([doc.title, doc.name, doc.summary, doc.body, ...(doc.aliases ?? [])].join(" ")).includes(normalize(query)))));
  const rendered = $derived(selected ? renderMarkdown(selected.body, docs) : { html: "", titleId: undefined, headings: [] });
  const minutes = $derived(selected ? Math.max(1, Math.ceil(selected.body.split(/\s+/).length / 220)) : 0);
  const currentGroup = $derived(groupTopics(docs).find((group) => group.topics.some((doc) => doc.name === selected?.name))?.title);
  const index = $derived(docs.findIndex((doc) => doc.name === selected?.name));
  const next = $derived(docs[index + 1]);
</script>

<div class="docs-layout">
  <aside class="topics"><a class="all-docs" href="/docs"><Icon name="docs" size={16} /> Documentation</a><input type="search" placeholder="Find a guide…" aria-label="Filter documentation topics" bind:value={query} /><nav aria-label="Documentation topics">{#each groups as group}<section><h2 class="eyebrow">{group.title}</h2>{#each group.topics as doc}<a class:active={selected?.name === doc.name} href={paths.docs(doc.name)} aria-current={selected?.name === doc.name ? "page" : undefined}>{doc.title}</a>{/each}</section>{/each}{#if !groups.length}<p class="muted no-topics">No guides match “{query}”.</p>{/if}</nav></aside>
  <div class="reading-area">
    {#if selected}
      <article><header class="article-heading"><p class="eyebrow">{currentGroup ?? "Documentation"}</p><h1 id={rendered.titleId}>{selected.title}</h1><p class="summary">{selected.summary}</p><div class="article-meta"><span>{minutes} min read</span><span>·</span><code>:help {selected.name}</code></div></header><div class="article-body">{@html rendered.html}</div><footer class="article-footer"><a href="/docs">← All guides</a>{#if next}<a href={paths.docs(next.name)}>Next: {next.title} →</a>{/if}</footer></article>
      {#if rendered.headings.length}<aside class="toc"><p class="eyebrow">On this page</p><nav aria-label="On this page">{#each rendered.headings as heading}<a class:subheading={heading.level === 3} href={"#" + heading.id}>{heading.title}</a>{/each}</nav><a href="/mappings" class="live-link"><Icon name="mappings" size={15} /> Your live mappings</a><a href="/state" class="live-link"><Icon name="state" size={15} /> Runtime & config</a></aside>{/if}
    {:else}
      <div class="docs-index"><header class="page-heading"><p class="eyebrow">Learn, explore, build</p><h1>{topic ? "Guide not found" : "The Flash field guide"}</h1><p>{topic ? `There is no documentation topic named “${topic}”. Find a guide below, or use search to explore.` : "From your first hint to a workspace of your own. Explore the features, the configuration, and the details that make Flash work."}</p></header>
        <a href="/docs/getting-started" class="start-banner"><span class="start-icon"><Icon name="bolt" size={25} /></span><span><strong>New to Flash? Start here.</strong><small>Your first hotkey, your first hint, and where to go next.</small></span><Icon name="arrow" size={20} /></a>
        {#each groups as group}<section class="index-group"><h2>{group.title}</h2><div class="guide-grid">{#each group.topics as doc}<a class="surface guide-card" href={paths.docs(doc.name)}><h3>{doc.title}<Icon name="arrow" size={15} /></h3><p>{doc.summary}</p></a>{/each}</div></section>{/each}
        {#if !docs.length}<p class="empty">Documentation will appear when Flash sends its first snapshot.</p>{/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .docs-layout { display: grid; grid-template-columns: 214px minmax(0, 1fr); min-height: 100%; }
  .topics { border-right: 1px solid var(--border); padding: 27px 15px; background: #fafbf8; }
  .all-docs { display: flex; align-items: center; gap: 8px; font-size: 12px; font-weight: 600; padding: 0 8px; margin-bottom: 17px; color: var(--text); }
  .topics input { width: 100%; font-size: 11px; margin-bottom: 22px; }
  .topics section { margin-bottom: 24px; }
  .topics h2 { padding: 0 9px; margin-bottom: 9px; font-size: 9px; letter-spacing: .1em; }
  .topics nav a { display: block; font-size: 11px; color: #697469; padding: 7px 9px; border-radius: 5px; line-height: 1.5; }
  .topics nav a.active { background: var(--accent-soft); color: var(--accent); font-weight: 550; }
  .topics nav a:hover { background: #edf2e7; text-decoration: none; }
  .no-topics { font-size: 11px; padding: 10px; }
  .reading-area { display: flex; align-items: flex-start; justify-content: center; gap: 38px; padding: 37px 38px 64px; min-width: 0; }
  article { flex: 1; min-width: 0; max-width: 770px; }
  .article-heading { padding-bottom: 25px; margin-bottom: 28px; border-bottom: 1px solid var(--border); }
  .article-heading .eyebrow { margin-bottom: 13px; }
  .article-heading h1 { font-size: 34px; }
  .summary { font-size: 15px; color: var(--muted); margin-top: 14px; line-height: 1.7; }
  .article-meta { display: flex; align-items: center; gap: 10px; margin-top: 19px; color: #83907d; font-size: 10px; }
  .article-meta code { font-size: 10px; }
  .article-body { font-size: 13px; line-height: 1.85; color: #485347; overflow-wrap: anywhere; }
  .article-body :global(h2), .article-body :global(h3), .article-body :global(h4) { color: var(--text); scroll-margin-top: 24px; }
  .article-body :global(.heading-anchor) { margin-left: 8px; color: #9aab8c; text-decoration: none; font-weight: 400; opacity: 0; }
  .article-body :global(:is(h2, h3, h4):hover .heading-anchor), .article-body :global(.heading-anchor:focus-visible) { opacity: 1; }
  .article-body :global(h2) { margin: 35px 0 13px; font-size: 23px; }
  .article-body :global(h3) { margin: 25px 0 10px; font-size: 17px; }
  .article-body :global(h4) { margin: 20px 0 10px; font-size: 14px; }
  .article-body :global(p) { margin: 12px 0; }
  .article-body :global(ul), .article-body :global(ol) { padding-left: 24px; margin: 12px 0 18px; }
  .article-body :global(li) { margin: 6px 0; }
  .article-body :global(code) { background: #eaf0e3; padding: 2px 5px; border-radius: 4px; color: #3e5f38; font-size: .87em; overflow-wrap: anywhere; }
  .article-body :global(pre) { background: #edf2e7; border: 1px solid #dce5d1; border-radius: 9px; padding: 18px 20px; margin: 20px 0; color: #334931; max-width: 100%; }
  .article-body :global(pre code) { background: none; padding: 0; border-radius: 0; font-size: 11px; }
  .article-body :global(table) { display: block; max-width: 100%; overflow: auto; border-collapse: collapse; font-size: 11px; margin: 20px 0; }
  .article-body :global(th) { text-align: left; font-size: 10px; background: #edf2e7; font-weight: 600; color: #4d6345; }
  .article-body :global(th), .article-body :global(td) { padding: 10px 12px; border: 1px solid var(--border); min-width: 90px; }
  .article-body :global(blockquote) { margin: 20px 0; padding: 3px 20px; border-left: 3px solid #8da578; background: #edf2e6; color: #65765a; }
  .article-body :global(details) { padding: 12px 16px; border: 1px solid var(--border); border-radius: 7px; margin: 14px 0; }
  .article-body :global(summary) { cursor: pointer; color: var(--accent); font-weight: 500; }
  .article-body :global(hr) { border: 0; border-top: 1px solid var(--border); margin: 30px 0; }
  .article-body :global(a) { text-decoration: underline; text-decoration-color: #a6b99a; text-underline-offset: 3px; }
  .article-footer { display: flex; justify-content: space-between; gap: 20px; padding-top: 22px; margin-top: 35px; border-top: 1px solid var(--border); font-size: 11px; }
  .toc { width: 165px; flex-shrink: 0; position: sticky; top: 28px; font-size: 10px; padding-top: 4px; }
  .toc .eyebrow { font-size: 9px; margin-bottom: 12px; }
  .toc nav { border-left: 1px solid var(--border); padding-left: 11px; max-height: 50vh; overflow: auto; margin-bottom: 24px; }
  .toc nav a { display: flex; align-items: center; padding: 5px 0; font-size: 10px; min-height: 28px; color: var(--muted); line-height: 1.4; }
  .toc nav a:hover { color: var(--accent); text-decoration: none; }
  .toc nav a.subheading { padding-left: 10px; font-size: 9px; }
  .live-link { display: flex; align-items: center; gap: 6px; padding: 7px 0; }
  .docs-index { max-width: 980px; width: 100%; }
  .docs-index h1 { font-size: 34px; }
  .start-banner { display: flex; align-items: center; gap: 15px; padding: 22px; background: #e6eedb; border: 1px solid #d6e2c6; border-radius: 10px; margin-bottom: 32px; color: #335335; }
  .start-icon { display: flex; }
  .start-banner > span:nth-child(2) { flex: 1; }
  .start-banner strong { font-weight: 550; font-size: 14px; }
  .start-banner small { display: block; font-size: 11px; color: #78896c; margin-top: 4px; }
  .index-group { margin-top: 28px; }
  .index-group h2 { font-size: 18px; margin-bottom: 15px; }
  .guide-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
  .guide-card { padding: 20px; color: var(--text); }
  .guide-card:hover { border-color: #9eb48f; text-decoration: none; }
  .guide-card h3 { display: flex; justify-content: space-between; gap: 10px; font-size: 13px; }
  .guide-card p { color: var(--muted); font-size: 11px; margin-top: 8px; line-height: 1.7; }
  @media (max-width: 1300px) { .toc { display: none; } .reading-area { padding: 30px 28px 50px; } .docs-layout { grid-template-columns: 190px minmax(0, 1fr); } }
  @media (max-width: 1000px) { .docs-layout { grid-template-columns: minmax(0, 1fr); } .topics { border-right: 0; border-bottom: 1px solid var(--border); padding: 15px 24px; } .topics .all-docs { display: none; } .topics input { margin: 0; max-width: 250px; } .topics nav { display: flex; gap: 20px; overflow: auto; padding-top: 15px; max-height: 160px; } .topics section { min-width: 160px; margin: 0; } }
  @media (max-width: 600px) { .reading-area { padding: 25px 18px 40px; } .guide-grid { grid-template-columns: 1fr; } .article-heading h1, .docs-index h1 { font-size: 29px; } }
  @media print {
    .docs-layout, .reading-area { display: block; padding: 0; }
    .topics, .toc, .article-footer, .article-body :global(.heading-anchor) { display: none; }
    article, .docs-index { max-width: none; }
    .article-body { color: var(--text); }
    .article-body :global(table) { display: table; overflow: visible; }
    .article-body :global(tr), .article-body :global(blockquote), .guide-card, .start-banner { break-inside: avoid; }
    .article-body :global(pre) { padding: 12px 14px; }
    .guide-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  }
</style>
