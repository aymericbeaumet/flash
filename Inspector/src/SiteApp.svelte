<script lang="ts">
  import { docsStore } from "./lib/docs.svelte";
  import DocsPanel from "./lib/DocsPanel.svelte";
  import { router } from "./lib/router.svelte";
  import { paths } from "./lib/routes";
  import { buildIndex } from "./lib/search";
  import { sharedCrumbs, type Section } from "./lib/shell";
  import Shell from "./Shell.svelte";

  /**
   * The published site: the manual alone, prerendered, with a note that the
   * live pages are in Flash's own help. Nothing here reads a resident.
   */
  const sections: Section[] = [
    { id: "docs", href: paths.docs(), label: "Documentation", group: "Explore", key: "d" },
  ];
  const route = $derived(router.route);
  const manual = $derived(docsStore.manual);
  const currentPage = $derived(route.page === "docs" ? manual?.page(route.param) : undefined);
  const crumbs = $derived(sharedCrumbs(route, currentPage) ?? []);
  const current = $derived(crumbs[crumbs.length - 1]?.label ?? "Flash");
  const siteName = $derived(manual?.bundle.site.name ?? "Flash");
  /** The tab title names the page, then the site. */
  const title = $derived(
    route.page === "docs" && !route.param ? siteName : `${current} - ${siteName}`,
  );
  const canonical = $derived(
    manual && currentPage
      ? new URL(paths.docs(currentPage.path), manual.bundle.site.url).href
      : undefined,
  );
  /** The footer names where the site's source lives. */
  const host = $derived(
    manual
      ? {
          icon: "docs",
          label: manual.bundle.site.repository_name,
          href: manual.bundle.site.repository,
        }
      : undefined,
  );
  const index = $derived(buildIndex([], [], [], [], docsStore.sections ?? []));

  $effect(() => {
    // Links load prerendered pages until the whole manual is here.
    router.handles = (target) => target.page === "search" || docsStore.complete;
    docsStore.loadWhenIdle();
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

{#snippet status()}{#if manual}<a
      href={manual.bundle.site.repository}
      class="connection repository"
      target="_blank"
      rel="noopener noreferrer"
      title="Flash on GitHub">GitHub <span aria-hidden="true">↗</span></a
    >{/if}{/snippet}

{#snippet page()}<DocsPanel param={route.param} />{/snippet}

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
  searching={!docsStore.sections}
  lost="This address is not part of the Flash documentation. Start from its home page, or search above."
  {host}
  note={{ label: "Your Flash", body: liveNote }}
  {status}
  {page}
  {shortcutNotes}
/>
