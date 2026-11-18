<script lang="ts">
  import { tick } from "svelte";
  import { followHeadings, type ArticleInfo } from "./article";
  import FreshMark from "./FreshMark.svelte";
  import Markdown from "./Markdown.svelte";
  import type { Rendered } from "./markdown-tree";
  import type { Freshness } from "./reading";
  import { copyText } from "./toasts.svelte";

  /**
   * A rendered page of the documentation with its heading, its outline and
   * its neighbours. The resident's help mounts it; the published site's build
   * renders it to the HTML a page ships, which no browser hydrates. Its
   * styles are the reading area's, in `DocsLayout.svelte`, so they reach
   * that HTML too.
   */
  let {
    article,
    rendered,
    minutes,
    fresh,
    help,
  }: {
    article: ArticleInfo;
    rendered: Rendered;
    minutes: number;
    /** New or updated since this reader last opened it. */
    fresh?: Freshness;
    /** The command that shows a plugin's guide in a terminal. */
    help?: string;
  } = $props();

  let activeHeading = $state("");
  let body = $state<HTMLElement>();

  // The outline follows the section at the top of the reading area.
  $effect(() => {
    const container = body;
    void rendered;
    if (!container) return;
    let stop: (() => void) | undefined;
    void tick().then(() => {
      stop = followHeadings(container, (id) => {
        activeHeading = id;
      });
    });
    return () => stop?.();
  });

  function copyHelp() {
    if (help) void copyText(help, "the help command");
  }
</script>

<article>
  <header class="article-heading">
    <p class="eyebrow"
      >{#each article.crumbs as crumb, position}{#if position}{" › "}{/if}{#if crumb.href}<a
            href={crumb.href}>{crumb.label}</a
          >{:else}{crumb.label}{/if}{/each}</p
    >
    <h1 id={rendered.titleId}>{article.title}<FreshMark state={fresh} /></h1>
    {#if article.summary}<p class="summary">{article.summary}</p>{/if}
    <div class="article-meta">
      <span>{minutes} min read</span>
      {#if help}<span aria-hidden="true">·</span><button
          type="button"
          class="help-copy"
          onclick={copyHelp}
          aria-label="Copy the flash help command for this guide"
          ><code>{help}</code> <span>copy</span></button
        >{/if}
      {#if article.edit}<span aria-hidden="true">·</span><a
          href={article.edit}
          target="_blank"
          rel="noopener noreferrer">Edit on GitHub <span aria-hidden="true">↗</span></a
        >{/if}
    </div>
  </header>
  {#if rendered.headings.length}
    <details class="toc-inline"
      ><summary>On this page</summary><nav aria-label="On this page"
        >{#each rendered.headings as heading}<a
            class:subheading={heading.level === 3}
            href={"#" + heading.id}>{heading.title}</a
          >{/each}</nav
      ></details
    >
  {/if}
  <div class="article-body" bind:this={body}><Markdown nodes={rendered.nodes} /></div>
  <footer class="article-footer">
    {#if article.previous}<a class="prev" href={article.previous.href}
        ><span class="eyebrow">Previous</span>{article.previous.title}</a
      >{:else if article.up}<a class="prev" href={article.up.href}
        ><span class="eyebrow">Up</span>{article.up.title}</a
      >{/if}
    {#if article.next}<a class="next" href={article.next.href}
        ><span class="eyebrow">Next</span>{article.next.title}</a
      >{/if}
  </footer>
</article>
{#if rendered.headings.length}<aside class="toc"
    ><p class="eyebrow">On this page</p><nav aria-label="On this page"
      >{#each rendered.headings as heading}<a
          class:subheading={heading.level === 3}
          class:current={activeHeading === heading.id}
          href={"#" + heading.id}
          aria-current={activeHeading === heading.id ? "location" : undefined}>{heading.title}</a
        >{/each}</nav
    ></aside
  >{/if}
