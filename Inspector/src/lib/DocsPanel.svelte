<script lang="ts">
  import { tick } from "svelte";
  import Icon from "./Icon.svelte";
  import { paths } from "./routes";
  import { renderMarkdown } from "./markdown";
  import { freshness, loadSeen, markAllSeen, markSeen, type Freshness, type SeenGuides } from "./reading";
  import { groupTopics, neighbours } from "./topics";
  import type { DocTopic } from "./types";
  let { docs, topic, loading = false, version }: { docs: DocTopic[]; topic: string; loading?: boolean; version?: string } = $props();
  let query = $state("");
  let topicsOpen = $state(false);
  let seen = $state<SeenGuides | null>(loadSeen());
  let activeHeading = $state("");
  let copiedHelp = $state(false);
  let body = $state<HTMLElement>();
  const normalize = (text: string) => text.trim().toLowerCase();
  const selected = $derived(docs.find((doc) => normalize(doc.name) === normalize(topic) || (doc.aliases ?? []).some((alias) => normalize(alias) === normalize(topic))));
  const groups = $derived(groupTopics(docs.filter((doc) => !query.trim() || normalize([doc.title, doc.name, doc.summary, doc.body, ...(doc.aliases ?? [])].join(" ")).includes(normalize(query)))));
  const rendered = $derived(selected ? renderMarkdown(selected.body, docs) : { fragment: document.createDocumentFragment(), titleId: undefined, headings: [] });
  const minutes = $derived(selected ? Math.max(1, Math.ceil(selected.body.split(/\s+/).length / 220)) : 0);
  const currentGroup = $derived(selected?.group ?? "Documentation");
  const { previous, next } = $derived(neighbours(docs, selected?.name));
  const fresh = $derived(freshness(docs, seen));
  const freshTopics = $derived(docs.filter((doc) => fresh.get(doc.name)));
  const releaseURL = $derived(version ? `https://github.com/aymericbeaumet/flash/releases` : undefined);

  // The first visit records every guide as seen: badges mark what changes
  // from here on. Opening a guide acknowledges its current body.
  $effect(() => {
    if (!docs.length) return;
    if (!seen) { seen = markAllSeen(docs); return; }
    if (selected && fresh.get(selected.name)) seen = markSeen(selected, seen);
  });
  $effect(() => { void selected; topicsOpen = false; });

  // The guide's nodes (built, never parsed from HTML), then copy buttons on
  // code blocks and the outline's current section.
  $effect(() => {
    const container = body;
    if (!container) return;
    container.replaceChildren(rendered.fragment.cloneNode(true));
    let observer: IntersectionObserver | undefined;
    void tick().then(() => {
      for (const pre of Array.from(container.querySelectorAll("pre"))) {
        if (pre.querySelector(".copy-code")) continue;
        const button = document.createElement("button");
        button.type = "button";
        button.className = "copy-code";
        button.textContent = "Copy";
        button.setAttribute("aria-label", "Copy code");
        button.addEventListener("click", async () => {
          try { await navigator.clipboard.writeText(pre.querySelector("code")?.textContent ?? pre.textContent ?? ""); button.textContent = "Copied"; } catch { button.textContent = "Select and copy"; }
          setTimeout(() => { button.textContent = "Copy"; }, 1600);
        });
        pre.append(button);
      }
      const headings = Array.from(container.querySelectorAll("h2, h3"));
      if (!headings.length || typeof IntersectionObserver === "undefined") return;
      const root = container.closest("main");
      observer = new IntersectionObserver((entries) => {
        const visible = entries.filter((entry) => entry.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
        if (visible[0]) activeHeading = visible[0].target.id;
      }, { root, rootMargin: "0px 0px -70% 0px", threshold: 0 });
      for (const heading of headings) observer.observe(heading);
    });
    return () => observer?.disconnect();
  });

  async function copyHelp() {
    if (!selected) return;
    try { await navigator.clipboard.writeText(`:help ${selected.name}`); copiedHelp = true; setTimeout(() => { copiedHelp = false; }, 1600); } catch { copiedHelp = false; }
  }
  function badge(name: string): Freshness { return fresh.get(name); }
</script>

<div class="docs-layout">
  <aside class="topics" aria-label="Guides">
    <a class="all-docs" href="/docs"><Icon name="docs" size={16} /> Documentation {#if freshTopics.length}<span class="badge fresh">{freshTopics.length}</span>{/if}</a>
    <button type="button" class="topics-toggle" aria-expanded={topicsOpen} aria-controls="guide-list" onclick={() => topicsOpen = !topicsOpen}><Icon name="docs" size={16} /><span>{selected ? `${currentGroup} · ${selected.title}` : "All guides"}</span><Icon name="chevron" size={12} /></button>
    <div class="topics-body" class:open={topicsOpen} id="guide-list">
      <input type="search" placeholder="Find a guide…" aria-label="Filter documentation topics" bind:value={query} />
      <nav aria-label="Documentation topics">{#each groups as group}<section><h2 class="eyebrow">{group.title}</h2>{#each group.topics as doc}<a class:active={selected?.name === doc.name} href={paths.docs(doc.name)} aria-current={selected?.name === doc.name ? "page" : undefined}><span>{doc.title}</span>{#if badge(doc.name)}<span class="badge fresh">{badge(doc.name)}</span>{/if}</a>{/each}</section>{/each}{#if !groups.length}<p class="muted no-topics">No guides match “{query}”.</p>{/if}</nav>
    </div>
  </aside>
  <div class="reading-area">
    {#if selected}
      <article>
        <header class="article-heading">
          <p class="eyebrow"><a href="/docs">Documentation</a> › {currentGroup}</p>
          <h1 id={rendered.titleId}>{selected.title}{#if badge(selected.name)}<span class="badge fresh title-badge">{badge(selected.name)}</span>{/if}</h1>
          <p class="summary">{selected.summary}</p>
          <div class="article-meta">
            <span>{minutes} min read</span><span aria-hidden="true">·</span>
            <button type="button" class="help-copy" onclick={copyHelp} aria-label="Copy the :help command for this guide"><code>:help {selected.name}</code> <span>{copiedHelp ? "copied" : "copy"}</span></button>
            {#if selected.manual}<span aria-hidden="true">·</span><a href={selected.manual} target="_blank" rel="noopener noreferrer">Full reference in the manual <span aria-hidden="true">↗</span></a>{/if}
          </div>
        </header>
        {#if rendered.headings.length}
          <details class="toc-inline"><summary>On this page</summary><nav aria-label="On this page">{#each rendered.headings as heading}<a class:subheading={heading.level === 3} href={"#" + heading.id}>{heading.title}</a>{/each}</nav></details>
        {/if}
        <div class="article-body" bind:this={body}></div>
        <footer class="article-footer">
          {#if previous}<a class="prev" href={paths.docs(previous.name)}><span class="eyebrow">Previous</span>{previous.title}</a>{:else}<a class="prev" href="/docs"><span class="eyebrow">Up</span>All guides</a>{/if}
          {#if next}<a class="next" href={paths.docs(next.name)}><span class="eyebrow">Next</span>{next.title}</a>{/if}
        </footer>
      </article>
      {#if rendered.headings.length}<aside class="toc"><p class="eyebrow">On this page</p><nav aria-label="On this page">{#each rendered.headings as heading}<a class:subheading={heading.level === 3} class:current={activeHeading === heading.id} href={"#" + heading.id} aria-current={activeHeading === heading.id ? "location" : undefined}>{heading.title}</a>{/each}</nav><a href="/mappings" class="live-link"><Icon name="mappings" size={15} /> Your live mappings</a><a href="/state" class="live-link"><Icon name="state" size={15} /> Runtime & config</a></aside>{/if}
    {:else if loading}
      <div class="docs-index"><header class="page-heading"><p class="eyebrow">Documentation</p><h1>Loading…</h1><p>Waiting for Flash's first snapshot. Guides appear as soon as the resident answers.</p></header></div>
    {:else}
      <div class="docs-index"><header class="page-heading"><p class="eyebrow">Learn, explore, build</p><h1>{topic ? "Guide not found" : "The Flash field guide"}</h1><p>{topic ? `There is no documentation topic named “${topic}”. Find a guide below, or use search to explore.` : "From your first hint to a workspace of your own. Explore the features, the configuration, and the details that make Flash work."}</p></header>
        <a href="/docs/getting-started" class="start-banner"><span class="start-icon"><Icon name="bolt" size={25} /></span><span><strong>New to Flash? Start here.</strong><small>Your first hotkey, your first hint, and where to go next.</small></span><Icon name="arrow" size={20} /></a>
        {#if freshTopics.length}
          <section class="whats-new surface" aria-labelledby="whats-new">
            <div class="whats-new-head"><h2 id="whats-new">What changed since your last visit</h2><button type="button" onclick={() => seen = markAllSeen(docs)}>Mark all as read</button></div>
            <p class="muted">{freshTopics.length} {freshTopics.length === 1 ? "guide" : "guides"} {version ? `in Flash ${version}` : ""}. {#if releaseURL}<a href={releaseURL} target="_blank" rel="noopener noreferrer">Release notes <span aria-hidden="true">↗</span></a>{/if}</p>
            <ul>{#each freshTopics as doc}<li><a href={paths.docs(doc.name)}><strong>{doc.title}</strong><span class="badge fresh">{badge(doc.name)}</span><span class="muted">{doc.summary}</span></a></li>{/each}</ul>
          </section>
        {/if}
        {#each groups as group}<section class="index-group"><h2>{group.title}</h2><div class="guide-grid">{#each group.topics as doc}<a class="surface guide-card" href={paths.docs(doc.name)}><h3><span>{doc.title}{#if badge(doc.name)} <span class="badge fresh">{badge(doc.name)}</span>{/if}</span><Icon name="arrow" size={15} /></h3><p>{doc.summary}</p></a>{/each}</div></section>{/each}
        {#if !docs.length}<p class="empty">Documentation will appear when Flash sends its first snapshot.</p>{/if}
      </div>
    {/if}
  </div>
</div>

<style>
  .docs-layout { display: grid; grid-template-columns: 224px minmax(0, 1fr); min-height: 100%; }
  .topics { border-right: 1px solid var(--border); padding: 27px 15px; background: #fafbf8; }
  .all-docs { display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600; padding: 0 8px; margin-bottom: 17px; color: var(--text); }
  .topics-toggle { display: none; width: 100%; align-items: center; gap: 10px; text-align: left; font-size: 14px; }
  .topics-toggle span:nth-child(2) { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .topics input { width: 100%; font-size: 13px; margin-bottom: 22px; }
  .topics section { margin-bottom: 24px; }
  .topics h2 { padding: 0 9px; margin-bottom: 9px; font-size: 10px; letter-spacing: .1em; }
  .topics nav a { display: flex; align-items: center; justify-content: space-between; gap: 8px; font-size: 13px; color: #55615a; padding: 9px 9px; min-height: 40px; border-radius: 6px; line-height: 1.4; }
  .topics nav a.active { background: var(--accent-soft); color: var(--accent); font-weight: 550; }
  .topics nav a:hover { background: #edf2e7; text-decoration: none; }
  .no-topics { font-size: 13px; padding: 10px; }
  .reading-area { display: flex; align-items: flex-start; justify-content: center; gap: 38px; padding: 37px 38px 64px; min-width: 0; }
  article { flex: 1; min-width: 0; max-width: 770px; }
  .article-heading { padding-bottom: 25px; margin-bottom: 28px; border-bottom: 1px solid var(--border); }
  .article-heading .eyebrow { margin-bottom: 13px; }
  .article-heading .eyebrow a { color: inherit; }
  .article-heading h1 { font-size: 34px; display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  .title-badge { font-size: 11px; }
  .summary { font-size: 16px; color: var(--muted); margin-top: 14px; line-height: 1.7; }
  .article-meta { display: flex; align-items: center; flex-wrap: wrap; gap: 10px; margin-top: 19px; color: var(--muted); font-size: 12px; }
  .help-copy { border: 0; background: none; padding: 0; min-height: 0; display: inline-flex; align-items: center; gap: 6px; color: var(--muted); font-size: 12px; }
  .help-copy:hover { background: none; color: var(--accent); }
  .article-meta code { font-size: 12px; }
  .toc-inline { display: none; margin-bottom: 24px; border: 1px solid var(--border); border-radius: 8px; padding: 10px 14px; }
  .toc-inline summary { cursor: pointer; font-weight: 600; font-size: 13px; }
  .toc-inline nav { display: flex; flex-direction: column; padding-top: 8px; }
  .toc-inline nav a { padding: 8px 0; min-height: 40px; display: flex; align-items: center; font-size: 14px; }
  .toc-inline nav a.subheading { padding-left: 14px; }
  .article-body { font-size: 15px; line-height: 1.8; color: #3f4a40; overflow-wrap: anywhere; }
  .article-body :global(h2), .article-body :global(h3), .article-body :global(h4) { color: var(--text); scroll-margin-top: 24px; }
  .article-body :global(.heading-anchor) { margin-left: 8px; color: #6c7f62; text-decoration: none; font-weight: 400; opacity: 0; }
  .article-body :global(:is(h2, h3, h4):hover .heading-anchor), .article-body :global(.heading-anchor:focus-visible) { opacity: 1; }
  @media (hover: none) { .article-body :global(.heading-anchor) { opacity: .7; } }
  .article-body :global(h2) { margin: 38px 0 14px; font-size: 24px; }
  .article-body :global(h3) { margin: 28px 0 10px; font-size: 18px; }
  .article-body :global(h4) { margin: 22px 0 10px; font-size: 15px; }
  .article-body :global(p) { margin: 12px 0; }
  .article-body :global(ul), .article-body :global(ol) { padding-left: 24px; margin: 12px 0 18px; }
  .article-body :global(li) { margin: 6px 0; }
  .article-body :global(code) { background: #eaf0e3; padding: 2px 5px; border-radius: 4px; color: #345630; font-size: .88em; overflow-wrap: anywhere; }
  .article-body :global(pre) { position: relative; background: #edf2e7; border: 1px solid #dce5d1; border-radius: 9px; padding: 18px 20px; margin: 20px 0; color: #2f432d; max-width: 100%; }
  .article-body :global(pre code) { background: none; padding: 0; border-radius: 0; font-size: 13px; }
  .article-body :global(.copy-code) { position: absolute; top: 8px; right: 8px; min-height: 30px; padding: 3px 10px; font-size: 12px; background: #fff; opacity: .85; }
  .article-body :global(.copy-code:hover), .article-body :global(.copy-code:focus-visible) { opacity: 1; }
  .article-body :global(table) { display: block; max-width: 100%; overflow: auto; border-collapse: collapse; font-size: 13px; margin: 20px 0; }
  .article-body :global(th) { text-align: left; font-size: 12px; background: #edf2e7; font-weight: 600; color: #3f5338; }
  .article-body :global(th), .article-body :global(td) { padding: 10px 12px; border: 1px solid var(--border); min-width: 90px; }
  .article-body :global(blockquote) { margin: 20px 0; padding: 3px 20px; border-left: 3px solid #8da578; background: #edf2e6; color: #55644b; }
  .article-body :global(details) { padding: 12px 16px; border: 1px solid var(--border); border-radius: 7px; margin: 14px 0; }
  .article-body :global(summary) { cursor: pointer; color: var(--accent); font-weight: 500; }
  .article-body :global(hr) { border: 0; border-top: 1px solid var(--border); margin: 30px 0; }
  .article-body :global(a) { text-decoration: underline; text-decoration-color: #a6b99a; text-underline-offset: 3px; }
  .article-body :global(a[data-external])::after { content: " ↗"; font-size: .8em; color: var(--muted); }
  .article-footer { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; padding-top: 22px; margin-top: 35px; border-top: 1px solid var(--border); }
  .article-footer a { display: flex; flex-direction: column; gap: 4px; padding: 14px 16px; border: 1px solid var(--border); border-radius: 9px; color: var(--text); font-size: 14px; font-weight: 500; min-height: 44px; }
  .article-footer a:hover { border-color: #9eb48f; text-decoration: none; }
  .article-footer .next { text-align: right; align-items: flex-end; grid-column: 2; }
  .toc { width: 180px; flex-shrink: 0; position: sticky; top: 28px; font-size: 12px; padding-top: 4px; }
  .toc .eyebrow { font-size: 10px; margin-bottom: 12px; }
  .toc nav { border-left: 1px solid var(--border); padding-left: 11px; max-height: 55vh; overflow: auto; margin-bottom: 24px; }
  .toc nav a { display: flex; align-items: center; padding: 5px 0; font-size: 12px; min-height: 30px; color: var(--muted); line-height: 1.4; margin-left: -12px; padding-left: 11px; border-left: 2px solid transparent; }
  .toc nav a:hover { color: var(--accent); text-decoration: none; }
  .toc nav a.current { color: var(--accent); border-left-color: var(--accent); }
  .toc nav a.subheading { padding-left: 22px; font-size: 11px; }
  .live-link { display: flex; align-items: center; gap: 6px; padding: 8px 0; min-height: 36px; }
  .docs-index { max-width: 980px; width: 100%; }
  .docs-index h1 { font-size: 34px; }
  .start-banner { display: flex; align-items: center; gap: 15px; padding: 22px; background: #e6eedb; border: 1px solid #d6e2c6; border-radius: 10px; margin-bottom: 32px; color: #335335; }
  .start-icon { display: flex; }
  .start-banner > span:nth-child(2) { flex: 1; }
  .start-banner strong { font-weight: 550; font-size: 15px; }
  .start-banner small { display: block; font-size: 13px; color: #55684a; margin-top: 4px; }
  .whats-new { padding: 18px 20px; margin-bottom: 32px; }
  .whats-new-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; }
  .whats-new h2 { font-size: 17px; }
  .whats-new > p { margin-top: 6px; font-size: 13px; }
  .whats-new ul { list-style: none; margin: 12px 0 0; padding: 0; }
  .whats-new li { border-top: 1px solid var(--border-soft); }
  .whats-new li a { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; padding: 11px 2px; color: var(--text); min-height: 44px; }
  .whats-new li a .muted { flex-basis: 100%; font-size: 13px; }
  .index-group { margin-top: 28px; }
  .index-group h2 { font-size: 18px; margin-bottom: 15px; }
  .guide-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
  .guide-card { padding: 20px; color: var(--text); }
  .guide-card:hover { border-color: #9eb48f; text-decoration: none; }
  .guide-card h3 { display: flex; justify-content: space-between; gap: 10px; font-size: 15px; }
  .guide-card p { color: var(--muted); font-size: 13px; margin-top: 8px; line-height: 1.7; }
  @media (max-width: 1300px) { .toc { display: none; } .toc-inline { display: block; } .reading-area { padding: 30px 28px 50px; } .docs-layout { grid-template-columns: 200px minmax(0, 1fr); } }
  @media (max-width: 1000px) {
    .docs-layout { grid-template-columns: minmax(0, 1fr); }
    .topics { border-right: 0; border-bottom: 1px solid var(--border); padding: 12px 24px; }
    .topics .all-docs { display: none; }
    .topics-toggle { display: flex; }
    .topics-body { display: none; padding-top: 12px; }
    .topics-body.open { display: block; }
    .topics input { margin: 0 0 12px; max-width: 320px; }
    .topics nav { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 0 24px; }
    .topics section { margin: 0 0 12px; }
  }
  @media (max-width: 600px) { .reading-area { padding: 25px 18px 40px; } .guide-grid { grid-template-columns: 1fr; } .article-heading h1, .docs-index h1 { font-size: 29px; } .article-footer { grid-template-columns: 1fr; } .article-footer .next { grid-column: 1; } .topics { padding: 10px 16px; } }
  @media print {
    .docs-layout, .reading-area { display: block; padding: 0; }
    .topics, .toc, .toc-inline, .article-footer, .article-body :global(.heading-anchor), .article-body :global(.copy-code), .help-copy span, .whats-new button { display: none; }
    article, .docs-index { max-width: none; }
    .article-body { color: var(--text); }
    .article-body :global(a[data-external])::after { content: " (" attr(href) ")"; }
    .article-body :global(table) { display: table; overflow: visible; }
    .article-body :global(tr), .article-body :global(blockquote), .guide-card, .start-banner { break-inside: avoid; }
    .article-body :global(pre) { padding: 12px 14px; }
    .guide-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  }
</style>
