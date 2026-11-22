<script lang="ts">
  import DocsLayout from "./lib/DocsLayout.svelte";
  import DocsNotice from "./lib/DocsNotice.svelte";
  import type { ManualIndex } from "./lib/docsite";
  import { router } from "./lib/router.svelte";
  import { paths } from "./lib/routes";
  import { manualEntries } from "./lib/search";
  import { sharedCrumbs, type Section } from "./lib/shell";
  import Shell from "./Shell.svelte";
  import { island } from "./site/island";
  import { preparePage } from "./site/navigation";
  import { siteSearch } from "./site/search.svelte";

  /**
   * The published site: the manual alone, a page per document, with a note
   * that the live pages are in Flash's own help. A page ships its article as
   * HTML; this app draws what surrounds it from the navigation every page
   * shares. Nothing here reads a resident.
   */
  let { manual }: { manual: ManualIndex } = $props();

  const sections: Section[] = [
    { id: "docs", href: paths.docs(), label: "Documentation", group: "Explore", key: "d" },
  ];
  /** What this document was rendered as: a page, whose article it holds, the search or the not-found page. */
  const served = router.route;
  const held = $derived(served.page === "docs" ? manual.page(served.param) : undefined);
  const route = $derived(router.route);
  const currentPage = $derived(route.page === "docs" ? manual.page(route.param) : undefined);
  const crumbs = $derived(sharedCrumbs(route, currentPage) ?? []);
  const current = $derived(crumbs[crumbs.length - 1]?.label ?? "Flash");
  /** The tab title names the page, then the site. */
  const title = $derived(
    route.page === "docs" && !route.param ? manual.site.name : `${current} - ${manual.site.name}`,
  );
  const canonical = $derived(
    currentPage ? new URL(paths.docs(currentPage.path), manual.site.url).href : undefined,
  );
  /** The footer names where the site's source lives. */
  const host = $derived({
    icon: "docs",
    label: manual.site.repository_name,
    href: manual.site.repository,
  });
  const index = $derived({ entries: manualEntries(siteSearch.sections ?? []) });
  /** The pages `[` and `]` lead to. */
  const neighbours = $derived.by(() => {
    if (!currentPage) return undefined;
    const { previous, next } = manual.neighbours(currentPage.path);
    return {
      previous: previous && paths.docs(previous.path),
      next: next && paths.docs(next.path),
    };
  });
  const label = $derived(
    currentPage
      ? `${currentPage.trail[currentPage.trail.length - 1] ?? "Documentation"} · ${currentPage.heading ?? currentPage.title}`
      : "Documentation",
  );
  /**
   * Where the page shown lives, when this document holds another's article
   * or none: an alias in another spelling, or a history entry of an earlier
   * document. The not-found document at a page's own address stays, rather
   * than load itself again.
   */
  const elsewhere = $derived.by(() => {
    if (!currentPage || currentPage === held) return undefined;
    const target = paths.docs(currentPage.path);
    return served.page === "not-found" && location.pathname === target ? undefined : target;
  });

  $effect(() => {
    if (!elsewhere) return;
    if (location.pathname === elsewhere) location.reload();
    else location.replace(elsewhere + location.hash);
  });
</script>

<svelte:head>
  <title>{title}</title>
  {#if canonical}
    <link rel="canonical" href={canonical} />
    <meta property="og:title" content={current} />
    <meta property="og:url" content={canonical} />
  {/if}
</svelte:head>

{#snippet liveNote()}Your key mappings, commands, plugins, runtime, monitors, logs and clipboard are
  live pages in Flash's own help: press <kbd>?</kbd> in NORMAL mode or run
  <code>:help</code>.{/snippet}

{#snippet status()}<a
    href={manual.site.repository}
    class="connection repository"
    target="_blank"
    rel="noopener noreferrer"
    title="Flash on GitHub">GitHub <span aria-hidden="true">↗</span></a
  >{/snippet}

{#snippet page()}<DocsLayout
    index={manual}
    active={currentPage?.path}
    {label}
    island={currentPage && currentPage === held ? island : undefined}
    ><DocsNotice param={route.param} waiting={!!elsewhere} /></DocsLayout
  >{/snippet}

{#snippet shortcutNotes()}
  <p class="muted">Shortcuts pause while you type in a field.</p>
{/snippet}

<Shell
  {sections}
  home={{ href: paths.docs(), label: "Flash documentation home" }}
  {crumbs}
  {index}
  searchLabel="Search the documentation"
  searchPlaceholder="Search the docs…"
  searchHint="Type a feature, command or setting. Every word must match."
  searchStage={siteSearch.stage}
  onsearch={() => void siteSearch.load()}
  {neighbours}
  prepare={preparePage}
  lost="This address is not part of the Flash documentation. Start from its home page, or search above."
  {host}
  note={{ label: "Your Flash", body: liveNote }}
  {status}
  {page}
  {shortcutNotes}
/>
