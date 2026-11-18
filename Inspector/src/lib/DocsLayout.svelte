<script lang="ts">
  import type { Snippet } from "svelte";
  import type { Attachment } from "svelte/attachments";
  import type { ManualIndex, NavNode } from "./docsite";
  import FreshMark from "./FreshMark.svelte";
  import Icon from "./Icon.svelte";
  import type { Freshness } from "./reading";
  import { paths } from "./routes";
  import type { DocTopic } from "./types";

  /**
   * The documentation view's frame: the manual's navigation beside the
   * reading area. The resident's help renders a page into the reading area;
   * a published page already holds its article there as HTML, which `island`
   * adopts instead. The reading area's styles are the article's too, by
   * name, so they reach an article this component did not render.
   */
  let {
    index,
    guides = [],
    active,
    fresh,
    label,
    island,
    children,
  }: {
    /** The manual's navigation; null until it loads. */
    index: ManualIndex | null;
    /** The plugins' guides, which only the resident has. */
    guides?: DocTopic[];
    /** The page shown: a manual page's path or a guide's name. */
    active?: string;
    /** Pages and guides new or updated for this reader, where reading is tracked. */
    fresh?: ReadonlyMap<string, Freshness>;
    /** What the collapsed navigation names: where the reader is. */
    label: string;
    /** Takes the reading area as the page shipped it, in place of `children`. */
    island?: Attachment<HTMLElement>;
    children?: Snippet;
  } = $props();

  type Link = { name: string; title: string; href: string; nested: boolean };
  /** Links under an optional subgroup heading. */
  type Group = { title?: string; links: Link[] };
  type Section = { title?: string; groups: Group[] };

  let query = $state("");
  let topicsOpen = $state(false);

  const normalize = (text: string) => text.trim().toLowerCase();
  const guideGroup = "Plugin guides";

  /** The sidebar: the manual's navigation, then the plugins' guides in the resident's help. */
  const sections = $derived.by((): Section[] => {
    if (!index) return [];
    const filter = normalize(query);
    const known = index;
    const walk = (nodes: NavNode[], depth: number, trail: string[]): Group[] => {
      const groups: Group[] = [];
      for (const node of nodes) {
        if (node.items) {
          const inner = walk(node.items, depth + 1, [...trail, node.title]);
          if (!inner.length) continue;
          // A group's own links follow its heading; its subgroups keep theirs.
          if (inner[0].title === undefined) groups.push({ ...inner.shift()!, title: node.title });
          else groups.push({ title: node.title, links: [] });
          groups.push(...inner);
          continue;
        }
        const path = node.path ?? "";
        const target = known.page(path);
        if (
          filter &&
          !normalize(
            [node.title, target?.heading ?? "", ...(target?.aliases ?? []), ...trail].join(" "),
          ).includes(filter)
        )
          continue;
        const link = { name: path, title: node.title, href: paths.docs(path), nested: depth > 1 };
        // Links after a subgroup stay in its run: the list is flat.
        if (groups.length) groups[groups.length - 1].links.push(link);
        else groups.push({ links: [link] });
      }
      return groups;
    };
    const out: Section[] = [];
    for (const node of known.nav) {
      if (!node.items) {
        const groups = walk([node], 0, []);
        if (!groups.length) continue;
        const last = out[out.length - 1];
        if (last && last.title === undefined) last.groups[0].links.push(...groups[0].links);
        else out.push({ groups });
        continue;
      }
      const groups = walk(node.items, 1, [node.title]);
      if (groups.length) out.push({ title: node.title, groups });
    }
    const listed = guides.filter(
      (doc) =>
        !known.page(doc.name) &&
        (!filter || normalize([doc.title, doc.name, doc.summary].join(" ")).includes(filter)),
    );
    if (listed.length)
      out.push({
        title: guideGroup,
        groups: [
          {
            links: listed.map((doc) => ({
              name: doc.name,
              title: doc.title,
              href: paths.docs(doc.name),
              nested: false,
            })),
          },
        ],
      });
    return out;
  });

  $effect(() => {
    void active;
    topicsOpen = false;
  });
</script>

<div class="docs-layout">
  <aside class="topics" aria-label="Documentation">
    <a class="all-docs" href={paths.docs()}
      ><Icon name="docs" size={16} /> Documentation <FreshMark
        state={fresh?.size ? "new" : undefined}
        label="New or updated pages since your last visit"
      /></a
    >
    <button
      type="button"
      class="topics-toggle"
      aria-expanded={topicsOpen}
      aria-controls="guide-list"
      onclick={() => (topicsOpen = !topicsOpen)}
      ><Icon name="docs" size={16} /><span>{label}</span><Icon name="chevron" size={12} /></button
    >
    <div class="topics-body" class:open={topicsOpen} id="guide-list">
      <input
        type="search"
        placeholder="Find a page…"
        aria-label="Filter documentation pages"
        bind:value={query}
      />
      <nav aria-label="Documentation pages"
        >{#each sections as section}<section
            >{#if section.title}<h2 class="eyebrow">{section.title}</h2
              >{/if}{#each section.groups as group}{#if group.title}<h3 class="subgroup"
                  >{group.title}</h3
                >{/if}{#each group.links as link}<a
                  class:active={link.name === active}
                  class:nested={link.nested}
                  href={link.href}
                  aria-current={link.name === active ? "page" : undefined}
                  ><span>{link.title}</span>{#if fresh}<FreshMark
                      state={fresh.get(link.name)}
                    />{/if}</a
                >{/each}{/each}</section
          >{/each}{#if !sections.length && query}<p class="muted no-topics"
            >Nothing matches “{query}”.</p
          >{/if}</nav
      >
    </div>
  </aside>
  {#if island}<div class="reading-area" {@attach island}></div>{:else}<div class="reading-area"
      >{@render children?.()}</div
    >{/if}
</div>

<style>
  .docs-layout {
    display: grid;
    grid-template-columns: 228px minmax(0, 1fr);
    min-height: 100%;
  }
  .topics {
    border-right: 1px solid var(--border);
    padding: 20px 12px;
    background: var(--sidebar);
  }
  .all-docs {
    display: flex;
    align-items: center;
    gap: 8px;
    font: 600 12px var(--mono);
    letter-spacing: 0.1em;
    text-transform: uppercase;
    padding: 0 8px;
    margin-bottom: 14px;
    color: var(--text);
  }
  .all-docs:hover {
    color: var(--accent);
    text-decoration: none;
  }
  .topics-toggle {
    display: none;
    width: 100%;
    align-items: center;
    gap: 10px;
    text-align: left;
    font-size: 13px;
  }
  .topics-toggle span:nth-child(2) {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .topics input {
    width: 100%;
    font-size: 13px;
    margin-bottom: 18px;
  }
  .topics section {
    margin-bottom: 18px;
  }
  .topics h2 {
    padding: 0 9px;
    margin-bottom: 4px;
    font-size: 12px;
    letter-spacing: 0.14em;
    color: var(--faint);
  }
  .topics .subgroup {
    padding: 0 9px;
    margin: 10px 0 2px;
    font-size: 12px;
    font-weight: 500;
    color: var(--muted);
  }
  .topics nav a {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    font-size: 13px;
    color: var(--muted);
    padding: 6px 9px;
    min-height: 34px;
    border-radius: 5px;
    line-height: 1.35;
  }
  .topics nav a.nested {
    padding-left: 19px;
  }
  .topics nav a.active {
    background: var(--raised);
    color: var(--text);
    font-weight: 550;
    box-shadow: inset 2px 0 0 var(--accent);
  }
  .topics nav a:hover {
    background: var(--raised);
    color: var(--text);
    text-decoration: none;
  }
  .no-topics {
    font-size: 13px;
    padding: 10px;
  }
  .reading-area {
    display: flex;
    align-items: flex-start;
    justify-content: center;
    gap: 38px;
    padding: 30px 36px 64px;
    min-width: 0;
  }
  /*
   * The article, by name rather than by this component's own elements: a
   * published page holds it as HTML this component adopts.
   */
  .reading-area :global {
    article {
      flex: 1;
      min-width: 0;
      max-width: 760px;
    }
    .article-heading {
      position: relative;
      padding-bottom: 20px;
      margin-bottom: 26px;
      border-bottom: 1px solid var(--border);
    }
    .article-heading::after {
      content: "";
      position: absolute;
      left: 0;
      bottom: -1px;
      width: 48px;
      height: 1px;
      background: var(--accent);
    }
    .article-heading .eyebrow {
      margin-bottom: 12px;
    }
    .article-heading .eyebrow a {
      color: inherit;
    }
    .article-heading h1 {
      font-size: 32px;
      letter-spacing: -0.02em;
      display: flex;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
    }
    .summary {
      font-size: 16px;
      color: var(--muted);
      margin-top: 12px;
      line-height: 1.65;
    }
    .article-meta {
      display: flex;
      align-items: center;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 14px;
      color: var(--muted);
      font-size: 12px;
      min-height: 36px;
    }
    .help-copy {
      border: 0;
      background: none;
      padding: 0;
      min-height: 36px;
      max-width: 100%;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      color: var(--muted);
      font-size: 12px;
      text-align: left;
      box-shadow: none;
    }
    .help-copy:hover {
      background: none;
      color: var(--accent);
    }
    .article-meta code {
      font-size: 12px;
      overflow-wrap: anywhere;
    }
    .toc-inline {
      display: none;
      margin-bottom: 22px;
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 8px 14px;
      background: var(--panel);
    }
    .toc-inline summary {
      cursor: pointer;
      font-weight: 600;
      font-size: 13px;
      min-height: 32px;
      display: flex;
      align-items: center;
    }
    .toc-inline nav {
      display: flex;
      flex-direction: column;
      padding-top: 6px;
    }
    .toc-inline nav a {
      padding: 6px 0;
      min-height: 36px;
      display: flex;
      align-items: center;
      font-size: 14px;
    }
    .toc-inline nav a.subheading {
      padding-left: 14px;
    }
    .article-body {
      font-size: 15px;
      line-height: 1.75;
      color: #d9d1c0;
      overflow-wrap: anywhere;
    }
    .article-body h2,
    .article-body h3,
    .article-body h4 {
      color: var(--text);
      scroll-margin-top: 24px;
    }
    .article-body .heading-anchor {
      margin-left: 8px;
      color: var(--accent-dim);
      text-decoration: none;
      font-weight: 400;
      opacity: 0;
    }
    .article-body :is(h2, h3, h4):hover .heading-anchor,
    .article-body .heading-anchor:focus-visible {
      opacity: 1;
    }
    @media (hover: none) {
      .article-body .heading-anchor {
        opacity: 0.7;
      }
    }
    .article-body h2 {
      margin: 36px 0 12px;
      font-size: 22px;
      padding-bottom: 6px;
      border-bottom: 1px solid var(--border-soft);
    }
    .article-body h3 {
      margin: 26px 0 8px;
      font-size: 17px;
    }
    .article-body h4 {
      margin: 20px 0 8px;
      font-size: 15px;
    }
    .article-body p {
      margin: 12px 0;
    }
    .article-body strong {
      color: var(--text);
    }
    .article-body ul,
    .article-body ol {
      padding-left: 24px;
      margin: 12px 0 18px;
    }
    .article-body li {
      margin: 5px 0;
    }
    .article-body li::marker {
      color: var(--accent-dim);
    }
    .article-body li.task {
      list-style: none;
      margin-left: -20px;
    }
    .article-body code {
      background: var(--raised);
      border: 1px solid var(--border-soft);
      padding: 1px 5px;
      border-radius: 4px;
      color: var(--code);
      font-size: 0.86em;
      overflow-wrap: anywhere;
    }
    .article-body pre {
      position: relative;
      background: var(--inset);
      border: 1px solid var(--border-soft);
      border-left: 2px solid var(--accent-dim);
      box-shadow: var(--well);
      border-radius: 5px;
      padding: 16px 18px;
      margin: 18px 0;
      color: var(--code);
      max-width: 100%;
    }
    .article-body pre code {
      background: none;
      border: 0;
      padding: 0;
      border-radius: 0;
      font-size: 13px;
      overflow-wrap: normal;
    }
    /* Code: comments recede, strings take verdigris, keys and tables brass. */
    .article-body .tok-comment {
      color: var(--faint);
      font-style: italic;
    }
    .article-body .tok-string {
      color: var(--verdigris);
    }
    .article-body .tok-number {
      color: var(--copper);
    }
    .article-body .tok-keyword {
      color: var(--steel);
    }
    .article-body .tok-key {
      color: var(--accent);
    }
    .article-body .tok-section {
      color: var(--accent-strong);
      font-weight: 600;
    }
    .article-body .tok-variable {
      color: var(--amber);
    }
    .article-body .tok-flag {
      color: var(--steel);
    }
    .article-body .tok-function {
      color: var(--accent);
    }
    .article-body .tok-type {
      color: var(--steel);
    }
    .article-body .copy-code {
      position: absolute;
      top: 8px;
      right: 8px;
      min-height: 28px;
      padding: 2px 10px;
      font: 12px var(--sans);
      opacity: 0.85;
    }
    .article-body .copy-code:hover,
    .article-body .copy-code:focus-visible {
      opacity: 1;
    }
    .article-body table {
      display: block;
      max-width: 100%;
      overflow: auto;
      border-collapse: collapse;
      font-size: 13px;
      margin: 18px 0;
    }
    .article-body th {
      text-align: left;
      font: 500 12px var(--mono);
      letter-spacing: 0.06em;
      text-transform: uppercase;
      background: var(--raised);
      color: var(--muted);
    }
    .article-body th,
    .article-body td {
      padding: 8px 12px;
      border: 1px solid var(--border);
      min-width: 90px;
      overflow-wrap: break-word;
    }
    .article-body .align-center {
      text-align: center;
    }
    .article-body .align-right {
      text-align: right;
    }
    .article-body blockquote {
      margin: 18px 0;
      padding: 4px 18px;
      border-left: 2px solid var(--verdigris);
      background: var(--verdigris-soft);
      color: var(--text);
      border-radius: 0 5px 5px 0;
    }
    /* Admonitions: a hairline panel with a brass rule, amber or oxide for caution. */
    .article-body .admonition {
      margin: 18px 0;
      padding: 4px 18px;
      border: 1px solid var(--border-soft);
      border-left: 2px solid var(--accent);
      background: var(--panel);
      border-radius: 0 5px 5px 0;
    }
    .article-body .admonition-title {
      margin: 10px 0 4px;
      font: 600 12px var(--mono);
      letter-spacing: 0.1em;
      text-transform: uppercase;
      color: var(--accent);
    }
    .article-body :is(.admonition.tip, .admonition.success, .admonition.info) {
      border-left-color: var(--verdigris);
    }
    .article-body :is(.admonition.tip, .admonition.success, .admonition.info) .admonition-title {
      color: var(--verdigris);
    }
    .article-body :is(.admonition.warning, .admonition.caution, .admonition.attention) {
      border-left-color: var(--amber);
    }
    .article-body
      :is(.admonition.warning, .admonition.caution, .admonition.attention)
      .admonition-title {
      color: var(--amber);
    }
    .article-body :is(.admonition.danger, .admonition.error, .admonition.failure, .admonition.bug) {
      border-left-color: var(--danger);
    }
    .article-body
      :is(.admonition.danger, .admonition.error, .admonition.failure, .admonition.bug)
      .admonition-title {
      color: var(--danger);
    }
    .article-body img {
      max-width: 100%;
      height: auto;
      border: 1px solid var(--border-soft);
      border-radius: 5px;
    }
    .article-body details {
      padding: 10px 14px;
      border: 1px solid var(--border);
      border-radius: 5px;
      margin: 14px 0;
      background: var(--panel);
    }
    .article-body summary {
      cursor: pointer;
      color: var(--accent);
      font-weight: 500;
    }
    .article-body hr {
      border: 0;
      border-top: 1px solid var(--border);
      margin: 30px 0;
    }
    .article-body a {
      text-decoration: underline;
      text-decoration-color: var(--accent-dim);
      text-underline-offset: 3px;
    }
    .article-body a[data-external]::after {
      content: " ↗";
      font-size: 0.8em;
      color: var(--muted);
    }
    /* A live page of the resident's help, named on the published site. */
    .article-body .live-link {
      color: var(--text);
      border-bottom: 1px dotted var(--accent-dim);
      cursor: help;
    }
    .article-body kbd {
      font-size: 12px;
    }
    .article-footer {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 12px;
      padding-top: 20px;
      margin-top: 34px;
      border-top: 1px solid var(--border);
    }
    .article-footer a {
      display: flex;
      flex-direction: column;
      gap: 3px;
      padding: 12px 14px;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--panel);
      box-shadow: var(--engrave);
      color: var(--text);
      font-size: 14px;
      font-weight: 500;
      min-height: 44px;
    }
    .article-footer a:hover {
      border-color: var(--accent-dim);
      text-decoration: none;
      color: var(--text);
    }
    .article-footer .next {
      text-align: right;
      align-items: flex-end;
      grid-column: 2;
    }
    .toc {
      width: 190px;
      flex-shrink: 0;
      position: sticky;
      top: 24px;
      font-size: 12px;
      padding-top: 4px;
    }
    .toc .eyebrow {
      margin-bottom: 10px;
    }
    .toc nav {
      border-left: 1px solid var(--border);
      padding-left: 11px;
      max-height: 55vh;
      overflow: auto;
      margin-bottom: 20px;
    }
    .toc nav a {
      display: flex;
      align-items: center;
      padding: 4px 0;
      font-size: 12px;
      min-height: 30px;
      color: var(--muted);
      line-height: 1.4;
      margin-left: -12px;
      padding-left: 11px;
      border-left: 2px solid transparent;
    }
    .toc nav a:hover {
      color: var(--accent);
      text-decoration: none;
    }
    .toc nav a.current {
      color: var(--accent);
      border-left-color: var(--accent);
    }
    .toc nav a.subheading {
      padding-left: 22px;
    }
  }
  @media (max-width: 1300px) {
    .reading-area :global {
      .toc {
        display: none;
      }
      .toc-inline {
        display: block;
      }
    }
    .reading-area {
      padding: 26px 26px 50px;
    }
    .docs-layout {
      grid-template-columns: 204px minmax(0, 1fr);
    }
  }
  @media (max-width: 1000px) {
    .docs-layout {
      grid-template-columns: minmax(0, 1fr);
    }
    .topics {
      border-right: 0;
      border-bottom: 1px solid var(--border);
      padding: 10px 22px;
    }
    .topics .all-docs {
      display: none;
    }
    .topics-toggle {
      display: flex;
    }
    .topics-body {
      display: none;
      padding-top: 12px;
    }
    .topics-body.open {
      display: block;
    }
    .topics input {
      margin: 0 0 12px;
      max-width: 320px;
    }
    .topics nav {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
      gap: 0 24px;
    }
    .topics section {
      margin: 0 0 12px;
    }
  }
  @media (max-width: 600px) {
    .reading-area {
      padding: 20px 14px 40px;
    }
    .reading-area :global {
      .article-heading h1 {
        font-size: 26px;
      }
      .article-footer {
        grid-template-columns: 1fr;
      }
      .article-footer .next {
        grid-column: 1;
      }
    }
    .topics {
      padding: 10px 14px;
    }
  }
  @media print {
    .docs-layout,
    .reading-area {
      display: block;
      padding: 0;
    }
    .topics {
      display: none;
    }
    .reading-area :global {
      .toc,
      .toc-inline,
      .article-footer,
      .article-body .heading-anchor,
      .article-body .copy-code,
      .help-copy span {
        display: none;
      }
      article {
        max-width: none;
      }
      .article-body {
        color: var(--text);
      }
      .article-body a[data-external]::after {
        content: " (" attr(href) ")";
      }
      .article-body table {
        display: table;
        overflow: visible;
      }
      .article-body tr,
      .article-body blockquote,
      .article-body .admonition {
        break-inside: avoid;
      }
      .article-body pre {
        padding: 12px 14px;
        box-shadow: none;
      }
    }
  }
</style>
