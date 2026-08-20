<script lang="ts">
  import { marked } from "marked";
  import type { DocTopic } from "./types";

  let { docs, topic }: { docs: DocTopic[]; topic: string } = $props();

  let query = $state("");

  const normalize = (s: string) => s.trim().toLowerCase();

  // Mirror HelpDocs.normalize: a topic resolves by name or alias.
  const selected = $derived.by(() => {
    const want = normalize(topic);
    if (!want) return null;
    return (
      docs.find(
        (d) =>
          normalize(d.name) === want ||
          (d.aliases ?? []).some((a) => normalize(a) === want),
      ) ?? null
    );
  });

  const sidebar = $derived.by(() => {
    const q = normalize(query);
    const rows = q
      ? docs.filter(
          (d) =>
            normalize(d.title).includes(q) ||
            normalize(d.name).includes(q) ||
            normalize(d.summary).includes(q) ||
            (d.aliases ?? []).some((a) => normalize(a).includes(q)),
        )
      : docs;
    return [...rows].sort((a, b) => a.title.localeCompare(b.title));
  });

  // All resolvable topic names + aliases, for turning cross-references into links.
  const topicKeys = $derived(
    new Set(
      docs.flatMap((d) => [
        d.name.toLowerCase(),
        ...(d.aliases ?? []).map((a) => a.toLowerCase()),
      ]),
    ),
  );

  // Turn cross-references rendered as inline code into clickable links:
  //   `:help <topic>` / a bare topic name → that Docs topic (#docs/<topic>)
  //   `:command …`                        → the Commands tab (#commands)
  // Operates on the rendered HTML and only matches bare `<code>` spans (inline
  // code), never `<pre><code class=…>` code blocks, so examples stay literal.
  function linkifyCodeRefs(html: string, keys: Set<string>): string {
    return html.replace(/<code>([^<]+)<\/code>/g, (whole, inner: string) => {
      const help = inner.match(/^:help\s+([\w-]+)$/i);
      if (help && keys.has(help[1].toLowerCase()))
        return `<a class="xref" href="#docs/${encodeURIComponent(help[1].toLowerCase())}">${whole}</a>`;
      if (keys.has(inner.toLowerCase()))
        return `<a class="xref" href="#docs/${encodeURIComponent(inner.toLowerCase())}">${whole}</a>`;
      if (/^:[a-z][\w-]*(\s.*)?$/i.test(inner))
        return `<a class="xref" href="#commands">${whole}</a>`;
      return whole;
    });
  }

  // Trusted, loopback-only Markdown authored in HelpDocs.swift — raw HTML
  // (e.g. <details> collapsibles) is intentionally passed through. gfm autolinks
  // bare URLs; we then linkify cross-references.
  const bodyHtml = $derived.by(() => {
    if (!selected) return "";
    const raw = marked.parse(selected.body, { async: false, gfm: true }) as string;
    return linkifyCodeRefs(raw, topicKeys);
  });

  function openTopic(name: string) {
    location.hash = "docs/" + encodeURIComponent(name);
  }
</script>

<div class="docs">
  <aside class="topics">
    <input type="search" placeholder="filter topics" bind:value={query} />
    <nav>
      {#each sidebar as d (d.name)}
        <button
          class:active={selected?.name === d.name}
          onclick={() => openTopic(d.name)}
          title={d.summary}
        >
          <span class="t-title">{d.title}</span>
          <span class="t-name">{d.name}</span>
        </button>
      {/each}
      {#if sidebar.length === 0}
        <p class="dim">no topics</p>
      {/if}
    </nav>
  </aside>

  <article class="content">
    {#if selected}
      <!-- eslint-disable-next-line svelte/no-at-html-tags -->
      <div class="doc-body">{@html bodyHtml}</div>
    {:else if topic.trim()}
      <div class="empty">
        <h2>Unknown topic</h2>
        <p>No documentation topic named <code>{topic}</code>.</p>
      </div>
    {:else}
      <div class="index">
        <h1>Flash Docs</h1>
        <p class="lede">
          Runtime documentation, served live from the app. Pick a topic, or open
          one directly with <code>:help &lt;topic&gt;</code>.
        </p>
        <ul>
          {#each sidebar as d (d.name)}
            <li>
              <button class="link" onclick={() => openTopic(d.name)}>
                {d.title}
              </button>
              <span class="summary">{d.summary}</span>
            </li>
          {/each}
        </ul>
      </div>
    {/if}
  </article>
</div>

<style>
  .docs {
    height: 100%;
    min-height: 0;
    display: grid;
    grid-template-columns: 240px minmax(0, 1fr);
  }
  .topics {
    min-height: 0;
    min-width: 0;
    display: grid;
    grid-template-rows: auto minmax(0, 1fr);
    border-right: 1px solid var(--border);
    background: var(--panel);
  }
  .topics input {
    margin: 8px;
    width: calc(100% - 16px);
  }
  .topics nav {
    overflow: auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
    gap: 1px;
    padding: 0 6px 8px;
  }
  .topics button {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 1px;
    text-align: left;
    width: 100%;
    min-width: 0;
    height: auto;
    min-height: 38px;
    padding: 5px 8px;
    border-radius: 5px;
    border: 1px solid transparent;
    background: transparent;
  }
  .topics button:hover {
    background: var(--bg);
  }
  .topics button.active {
    border-color: var(--border);
    background: var(--bg);
  }
  .t-title {
    color: var(--text);
    overflow-wrap: anywhere;
  }
  .topics button.active .t-title {
    color: var(--accent);
  }
  .t-name {
    font-size: 10px;
    color: var(--muted);
    overflow-wrap: anywhere;
  }
  .content {
    overflow: auto;
    min-height: 0;
    min-width: 0;
    padding: 18px 26px 60px;
  }
  .doc-body {
    max-width: 760px;
    line-height: 1.55;
  }
  .empty,
  .index {
    max-width: 760px;
  }
  .index .lede {
    color: var(--muted);
  }
  .index ul {
    list-style: none;
    padding: 0;
    margin: 16px 0 0;
  }
  .index li {
    padding: 7px 0;
    border-bottom: 1px solid var(--border-soft);
  }
  .index .summary {
    display: block;
    color: var(--muted);
    font-size: 12px;
    margin-top: 2px;
  }
  button.link {
    padding: 0;
    border: none;
    background: none;
    color: var(--accent);
    font-weight: 600;
  }
  button.link:hover {
    text-decoration: underline;
  }
  .dim {
    color: var(--muted);
    padding: 6px 8px;
  }

  /* Injected Markdown is unscoped; target it through the .doc-body wrapper. */
  :global(.doc-body h1) {
    font-size: 20px;
    margin: 0 0 12px;
    color: var(--accent);
  }
  :global(.doc-body h2) {
    font-size: 15px;
    margin: 22px 0 8px;
    padding-top: 12px;
    border-top: 1px solid var(--border-soft);
    color: var(--text);
  }
  :global(.doc-body h3) {
    font-size: 13px;
    margin: 16px 0 6px;
    color: var(--text);
  }
  :global(.doc-body p) {
    margin: 8px 0;
  }
  :global(.doc-body ul),
  :global(.doc-body ol) {
    margin: 8px 0;
    padding-left: 22px;
  }
  :global(.doc-body li) {
    margin: 3px 0;
  }
  :global(.doc-body a) {
    color: var(--accent);
  }
  :global(.doc-body a.xref) {
    text-decoration: none;
  }
  :global(.doc-body a.xref:hover) {
    text-decoration: underline;
  }
  :global(.doc-body code) {
    background: var(--panel-strong);
    border-radius: 3px;
    padding: 1px 4px;
    font-family: var(--mono, ui-monospace, monospace);
    font-size: 12px;
    color: #8bd3ff;
  }
  :global(.doc-body pre) {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 6px;
    padding: 10px 12px;
    overflow: auto;
  }
  :global(.doc-body pre code) {
    background: none;
    padding: 0;
    color: var(--text);
  }
  :global(.doc-body table) {
    border-collapse: collapse;
    margin: 10px 0;
  }
  :global(.doc-body th),
  :global(.doc-body td) {
    border: 1px solid var(--border);
    padding: 4px 9px;
    text-align: left;
  }
  :global(.doc-body th) {
    background: var(--panel);
    color: var(--accent);
  }
  :global(.doc-body blockquote) {
    margin: 10px 0;
    padding: 2px 12px;
    border-left: 3px solid var(--border);
    color: var(--muted);
  }
  :global(.doc-body details) {
    margin: 10px 0;
    padding: 6px 12px;
    border: 1px solid var(--border);
    border-radius: 6px;
    background: var(--panel);
  }
  :global(.doc-body summary) {
    cursor: pointer;
    color: var(--accent);
    font-weight: 600;
  }
</style>
