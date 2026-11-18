<script lang="ts">
  import { tick, untrack, type Snippet } from "svelte";
  import Icon from "./lib/Icon.svelte";
  import PageHeader from "./lib/PageHeader.svelte";
  import { prepareOnIntent } from "./lib/prefetch";
  import { router } from "./lib/router.svelte";
  import { paths } from "./lib/routes";
  import {
    search as runSearch,
    searchSummary,
    type SearchIndex,
    type SearchStage,
  } from "./lib/search";
  import type { Crumb, Section } from "./lib/shell";
  import Toaster from "./lib/Toaster.svelte";

  /**
   * What the resident's help and the published site share: the sidebar, the
   * top bar with its path and its search, the search and not-found pages, the
   * shortcuts sheet, the toasts, the router and the keyboard. Each product
   * names its sections and fills in its own pages and marks.
   */
  let {
    sections,
    home,
    crumbs,
    index,
    searchLabel,
    searchPlaceholder,
    searchHint,
    searchStage = "complete",
    onsearch,
    neighbours,
    prepare,
    lost,
    host,
    version,
    note,
    badge,
    status,
    banner,
    page,
    shortcutNotes,
    content = $bindable(),
  }: {
    sections: Section[];
    /** Where the brand leads, and what it is called there. */
    home: { href: string; label: string };
    /** The path to the page shown; empty on the home page. */
    crumbs: Crumb[];
    /** What search finds. */
    index: SearchIndex;
    searchLabel: string;
    searchPlaceholder: string;
    /** What the search page says before a query is typed. */
    searchHint: string;
    /** Whether the index is whole: results from part of it are never shown as final. */
    searchStage?: SearchStage;
    /** Search is about to be used: the field took focus, or a query is here. */
    onsearch?: () => void;
    /** Where `[` and `]` lead from the page shown. */
    neighbours?: { previous?: string; next?: string };
    /** Readies the page a link leads to, while the pointer rests on it or the keyboard reaches it. */
    prepare?: (url: URL) => void;
    /** What the not-found page says. */
    lost: string;
    /** Who serves the page, at the foot of the sidebar; a link when `href` is set. */
    host?: { icon: string; label: string; href?: string };
    /** The running Flash's version. */
    version?: string;
    /** A note closing the sidebar's navigation. */
    note?: { label: string; body: Snippet };
    /** What a section's link shows beside its label. */
    badge?: Snippet<[Section]>;
    /** The top bar's mark, a `.connection` link. */
    status?: Snippet;
    /** What stands between the top bar and the page. */
    banner?: Snippet;
    /** The page shown, when it is neither search nor a missing address. */
    page: Snippet;
    /** What the shortcuts sheet says after search and navigation. */
    shortcutNotes: Snippet;
    /** The scrolling element the pages render in. */
    content?: HTMLElement;
  } = $props();

  const groups = $derived([...new Set(sections.map((item) => item.group))]);
  const homePage = $derived(sections.find((item) => item.id === "home"));
  const route = $derived(router.route);
  let search = $state("");
  let searchInput = $state<HTMLInputElement>();
  let selectedResult = $state(0);
  let mobileNav = $state(false);
  let shortcuts = $state(false);
  let pendingG = $state(false);
  /** How much of the window's bottom the toasts cover; the content scrolls clear of it. */
  let toastSpace = $state(0);
  const results = $derived(route.page === "search" ? runSearch(index, route.param) : []);
  let announcement = $state("");

  // Runs once: nothing it reads may restart the router.
  $effect(() =>
    untrack(() => {
      const stopRouter = router.start(content!, () => {
        mobileNav = false;
        shortcuts = false;
        selectedResult = 0;
        if (router.route.page !== "search") search = "";
      });
      const stopPreparing = prepareOnIntent(window, (url) => {
        if (url.origin === location.origin) prepare?.(url);
      });
      window.addEventListener("keydown", onKey);
      return () => {
        window.removeEventListener("keydown", onKey);
        stopPreparing();
        stopRouter();
      };
    }),
  );
  // What search reads is fetched the first time it is needed: as the search
  // field takes focus, before the first word is typed.
  $effect(() => {
    if (route.page === "search" || search) onsearch?.();
  });
  // A reload of /search?q= restores the query in the box. Only the address
  // drives this: a keystroke reaches the box before it reaches the address.
  $effect(() => {
    if (route.page !== "search") return;
    const query = route.param;
    if (untrack(() => search) !== query) search = query;
  });
  $effect(() => {
    const label = crumbs[crumbs.length - 1]?.label ?? home.label;
    void tick().then(() => {
      announcement = label;
    });
  });

  function typing(event: KeyboardEvent): boolean {
    const target = event.target;
    return (
      target instanceof HTMLElement &&
      (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName))
    );
  }
  function onKey(event: KeyboardEvent) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
      event.preventDefault();
      searchInput?.focus();
      searchInput?.select();
      return;
    }
    if (event.key === "Escape") {
      shortcuts = false;
      mobileNav = false;
      pendingG = false;
      if (document.activeElement === searchInput) {
        search = "";
        if (route.page === "search") history.back();
      }
      if (
        document.activeElement instanceof HTMLElement &&
        (document.activeElement.isContentEditable ||
          ["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement.tagName))
      ) {
        document.activeElement.blur();
      }
      return;
    }
    if (typing(event) || event.metaKey || event.ctrlKey || event.altKey) return;
    if (pendingG) {
      pendingG = false;
      const target = sections.find((candidate) => candidate.key === event.key);
      if (target) {
        event.preventDefault();
        router.navigate(target.href);
      }
      return;
    }
    switch (event.key) {
      case "/":
        event.preventDefault();
        searchInput?.focus();
        searchInput?.select();
        break;
      case "?":
        event.preventDefault();
        shortcuts = !shortcuts;
        break;
      case "g":
        pendingG = true;
        setTimeout(() => {
          pendingG = false;
        }, 1200);
        break;
      case "[":
      case "]": {
        const target = event.key === "[" ? neighbours?.previous : neighbours?.next;
        if (target) {
          event.preventDefault();
          router.navigate(target);
        }
        break;
      }
    }
  }
  function onSearchInput() {
    const query = search.trim();
    if (route.page === "search") router.replace(paths.search(query));
    else if (query) router.navigate(paths.search(query));
    selectedResult = 0;
  }
  function onSearchKey(event: KeyboardEvent) {
    if (route.page !== "search" || !results.length) return;
    if (event.key === "ArrowDown") {
      event.preventDefault();
      selectedResult = Math.min(selectedResult + 1, results.length - 1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      selectedResult = Math.max(selectedResult - 1, 0);
    } else if (event.key === "Enter") {
      event.preventDefault();
      router.navigate(results[selectedResult].href);
      searchInput?.blur();
    }
  }
</script>

<a
  class="skip-link"
  href="#main-content"
  onclick={(event) => {
    event.preventDefault();
    content?.focus();
  }}>Skip to content</a
>
<div class="sr-only" aria-live="polite">{announcement}</div>
<div class="workspace">
  {#if mobileNav}<button
      type="button"
      class="scrim"
      aria-label="Close navigation"
      onclick={() => (mobileNav = false)}
    ></button>{/if}
  <aside class="sidebar" class:expanded={mobileNav} id="sidebar">
    <a href={home.href} class="brand" aria-label={home.label}
      ><span class="brand-mark"><Icon name="bolt" size={20} /></span><span class="brand-text"
        >Flash</span
      ></a
    >
    <nav aria-label="Main navigation">
      {#each groups as group}
        <div class="nav-group"
          ><div class="nav-label">{group}</div>
          {#each sections.filter((candidate) => candidate.group === group) as item}
            <a
              href={item.href}
              class:active={route.page === item.id}
              aria-current={route.page === item.id ? "page" : undefined}
              ><Icon name={item.id} size={16} /><span>{item.label}</span>{@render badge?.(item)}<kbd
                class="nav-key"
                aria-hidden="true">g {item.key}</kbd
              ></a
            >
          {/each}
        </div>
      {/each}
      {#if note}<div class="nav-group live-note"
          ><div class="nav-label">{note.label}</div><p>{@render note.body()}</p></div
        >{/if}
    </nav>
    <div class="sidebar-footer"
      >{#if host?.href}<a
          class="local-mark"
          href={host.href}
          target="_blank"
          rel="noopener noreferrer"
          ><Icon name={host.icon} size={14} />
          {host.label} <span aria-hidden="true">↗</span></a
        >{:else if host}<span class="local-mark"
          ><Icon name={host.icon} size={14} /> {host.label}</span
        >{/if}<a href={paths.docs("privacy")}>Privacy & permissions</a><button
        type="button"
        class="shortcut-hint"
        onclick={() => (shortcuts = true)}>Keyboard shortcuts <kbd>?</kbd></button
      >{#if version}<span class="version">Flash {version}</span>{/if}</div
    >
  </aside>
  <div class="main-column">
    <header class="topbar">
      <button
        class="mobile-toggle"
        aria-label="Toggle navigation"
        aria-expanded={mobileNav}
        aria-controls="sidebar"
        onclick={() => (mobileNav = !mobileNav)}><Icon name="menu" /></button
      >
      {#if crumbs.length}<nav class="breadcrumb" aria-label="Breadcrumb"
          ><ol
            >{#each crumbs as crumb, position}<li
                >{#if crumb.href && position < crumbs.length - 1}<a href={crumb.href}
                    >{crumb.label}</a
                  >{:else}<strong aria-current={position === crumbs.length - 1 ? "page" : undefined}
                    >{crumb.label}</strong
                  >{/if}</li
              >{/each}</ol
          ></nav
        >{/if}
      <form
        class="searchbox"
        role="search"
        action={paths.search()}
        onsubmit={(event) => {
          event.preventDefault();
          if (results[selectedResult]) router.navigate(results[selectedResult].href);
        }}
        ><Icon name="search" size={15} /><input
          bind:this={searchInput}
          bind:value={search}
          oninput={onSearchInput}
          onkeydown={onSearchKey}
          onfocus={() => onsearch?.()}
          type="search"
          name="q"
          aria-label={searchLabel}
          placeholder={searchPlaceholder}
        /><kbd>/</kbd></form
      >
      {@render status?.()}
    </header>
    {@render banner?.()}
    <main
      id="main-content"
      tabindex="-1"
      bind:this={content}
      style:--toast-space={toastSpace ? `${toastSpace}px` : undefined}
    >
      {#if route.page === "search"}
        <div class="page">
          <PageHeader
            id="search"
            title="Search"
            purpose={route.param
              ? searchSummary(results.length, route.param, searchStage)
              : searchHint}
          />
          {#if route.param}<div class="search-results surface" aria-live="polite">
              {#each results as result, position}<a
                  href={result.href}
                  class:selected={position === selectedResult}
                  onmouseenter={() => (selectedResult = position)}
                  ><span class="result-icon"><Icon name={result.icon} size={16} /></span><span
                    ><strong
                      >{result.title}{#if result.section}<span class="result-section">
                          › {result.section}</span
                        >{/if}</strong
                    ><span class="result-summary">{result.summary}</span></span
                  ><span class="badge neutral">{result.kind}</span><Icon
                    name="arrow"
                    size={15}
                  /></a
                >{/each}
              {#if results.length === 0}<div class="empty"
                  ><strong>{searchStage === "loading" ? "Searching…" : "No matches"}</strong>Try
                  fewer words, or a command name such as <code>mouse target</code>.</div
                >{/if}
              {#if searchStage === "loading" && results.length}<p class="empty"
                  >Still searching the text of every page: more results may follow.</p
                >{:else if searchStage === "failed"}<p class="empty"
                  >Part of the search did not load, so results may be missing. Type again to retry.</p
                >{/if}
              {#if results.length >= 80}<p class="empty"
                  >Showing the first 80 matches. Add another word to narrow your search.</p
                >{/if}
            </div>{/if}
        </div>
      {:else if route.page === "not-found"}<div class="page"
          ><PageHeader id="not-found" title="Page not found" purpose={lost} /><p
            class="not-found-links"
            >{#if homePage}<a href={homePage.href}>Home →</a>{/if}<a href={paths.docs()}
              >Documentation →</a
            ></p
          ></div
        >
      {:else}{@render page()}{/if}
    </main>
  </div>
  {#if shortcuts}
    <div class="sheet-backdrop" role="presentation" onclick={() => (shortcuts = false)}></div>
    <div class="sheet surface" role="dialog" aria-modal="true" aria-labelledby="shortcuts-title">
      <div class="sheet-head"
        ><h2 id="shortcuts-title"
          ><span class="rivet" aria-hidden="true"></span>Keyboard shortcuts</h2
        ><button type="button" onclick={() => (shortcuts = false)}>Close</button></div
      >
      <h3>Search</h3>
      <dl>
        <dt><kbd>/</kbd></dt><dd>Focus search</dd>
        <dt><kbd>⌘ K</kbd></dt><dd>Focus search</dd>
        <dt><kbd>↓</kbd></dt><dd>Next result</dd>
        <dt><kbd>↑</kbd></dt><dd>Previous result</dd>
        <dt><kbd>↩</kbd></dt><dd>Open selected result</dd>
        <dt><kbd>Esc</kbd></dt><dd>Leave the focused field or close this sheet</dd>
      </dl>
      <h3>Navigation</h3>
      <dl>
        <dt><kbd>[</kbd></dt><dd>Previous page</dd>
        <dt><kbd>]</kbd></dt><dd>Next page</dd>
        {#each sections as item}<dt><kbd>g</kbd> <kbd>{item.key}</kbd></dt><dd
            >Go to {item.label}</dd
          >{/each}
        <dt><kbd>?</kbd></dt><dd>Show or hide this sheet</dd>
      </dl>
      {@render shortcutNotes()}
    </div>
  {/if}
</div>
<Toaster fallback={() => content} bind:space={toastSpace} />

<style>
  .workspace {
    display: grid;
    grid-template-columns: 248px minmax(0, 1fr);
    height: 100dvh;
  }
  .sidebar {
    background: var(--sidebar);
    border-right: 1px solid var(--border);
    display: flex;
    flex-direction: column;
    padding: 18px 12px 16px;
    overflow: auto;
  }
  .brand {
    display: flex;
    align-items: center;
    gap: 11px;
    color: var(--text);
    font-size: 18px;
    font-weight: 650;
    line-height: 1.15;
    padding: 0 6px;
    text-decoration: none;
    letter-spacing: -0.01em;
  }
  .brand:hover {
    color: var(--text);
    text-decoration: none;
  }
  /* A brass plate with a rivet in each corner. */
  .brand-mark {
    display: grid;
    place-items: center;
    flex: none;
    width: 36px;
    height: 36px;
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: 6px;
    background:
      radial-gradient(circle at 4px 4px, var(--accent-dim) 1.2px, transparent 1.8px),
      radial-gradient(circle at calc(100% - 4px) 4px, var(--accent-dim) 1.2px, transparent 1.8px),
      radial-gradient(circle at 4px calc(100% - 4px), var(--accent-dim) 1.2px, transparent 1.8px),
      radial-gradient(
        circle at calc(100% - 4px) calc(100% - 4px),
        var(--accent-dim) 1.2px,
        transparent 1.8px
      ),
      var(--raised);
    box-shadow: var(--engrave);
  }
  .sidebar nav {
    margin-top: 26px;
  }
  .nav-group {
    margin-bottom: 18px;
  }
  .nav-label {
    padding: 0 10px;
    margin-bottom: 4px;
    font: 500 12px var(--mono);
    letter-spacing: 0.14em;
    text-transform: uppercase;
    color: var(--faint);
  }
  .sidebar nav a {
    display: flex;
    align-items: center;
    gap: 10px;
    min-height: 36px;
    padding: 6px 10px;
    margin: 1px 0;
    border-radius: 5px;
    color: var(--muted);
    font-size: 13px;
    font-weight: 500;
    text-decoration: none;
    white-space: nowrap;
  }
  .sidebar nav a > span:nth-child(2) {
    min-width: 0;
  }
  .sidebar nav a:hover {
    background: var(--raised);
    color: var(--text);
    text-decoration: none;
  }
  .sidebar nav a.active {
    background: var(--raised);
    color: var(--text);
    font-weight: 600;
    box-shadow:
      inset 2px 0 0 var(--accent),
      var(--engrave);
  }
  .sidebar nav a.active :global(svg) {
    color: var(--accent);
  }
  .nav-key {
    display: none;
    flex: none;
    margin-left: auto;
    font-size: 12px;
    padding: 0 4px;
    color: var(--muted);
  }
  .sidebar nav a:hover .nav-key,
  .sidebar nav a:focus-visible .nav-key {
    display: inline-block;
  }
  .sidebar-footer {
    display: flex;
    flex-direction: column;
    margin-top: auto;
    padding: 14px 10px 0;
    border-top: 1px solid var(--border);
    font-size: 12px;
    color: var(--muted);
  }
  .local-mark {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 12px;
    color: var(--muted);
    margin-bottom: 4px;
  }
  a.local-mark:hover {
    color: var(--accent);
  }
  .live-note p {
    padding: 4px 10px 0;
    font-size: 12px;
    line-height: 1.6;
    color: var(--muted);
  }
  .live-note :global(kbd) {
    font-size: 12px;
    padding: 0 4px;
  }
  .sidebar-footer a {
    display: flex;
    min-height: 32px;
    align-items: center;
  }
  .shortcut-hint {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    justify-content: space-between;
    border: 0;
    background: none;
    padding: 4px 0;
    min-height: 32px;
    color: var(--accent);
    font-size: 12px;
    box-shadow: none;
  }
  .shortcut-hint:hover {
    background: none;
    color: var(--accent-strong);
  }
  .version {
    margin-top: 6px;
    font: 12px var(--mono);
    color: var(--faint);
  }
  .main-column {
    display: flex;
    flex-direction: column;
    min-width: 0;
    min-height: 0;
  }
  .topbar {
    min-height: 56px;
    display: flex;
    align-items: center;
    gap: 20px;
    padding: 10px 32px;
    border-bottom: 1px solid var(--border);
    background: var(--sidebar);
  }
  .breadcrumb {
    min-width: 0;
    font-size: 13px;
    color: var(--muted);
  }
  .breadcrumb ol {
    display: flex;
    align-items: center;
    gap: 8px;
    list-style: none;
    margin: 0;
    padding: 0;
    white-space: nowrap;
    overflow: hidden;
  }
  .breadcrumb li {
    display: flex;
    align-items: center;
    gap: 8px;
    min-width: 0;
  }
  .breadcrumb li + li::before {
    content: "›";
    color: var(--faint);
  }
  .breadcrumb a {
    color: var(--muted);
    min-height: 32px;
    display: inline-flex;
    align-items: center;
  }
  .breadcrumb a:hover {
    color: var(--accent);
  }
  .breadcrumb strong {
    font-weight: 500;
    color: var(--text);
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .searchbox {
    margin-left: auto;
    display: flex;
    align-items: center;
    gap: 8px;
    width: min(320px, 34vw);
    border: 1px solid var(--border);
    border-radius: 5px;
    padding: 0 10px;
    color: var(--faint);
    background: var(--inset);
    box-shadow: var(--well);
  }
  .searchbox:focus-within {
    border-color: var(--accent-dim);
  }
  .searchbox input {
    border: 0;
    background: none;
    box-shadow: none;
    width: 100%;
    min-height: 34px;
    padding: 4px 0;
    font-size: 13px;
    outline-offset: 0;
  }
  .searchbox input:focus-visible {
    outline: none;
  }
  .searchbox kbd {
    font-size: 12px;
    padding: 0 5px;
    color: var(--muted);
  }
  /* The top bar's mark: each product draws its own link and picks its state. */
  .topbar :global(.connection) {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 7px;
    padding: 0 10px;
    color: var(--amber);
    background: var(--amber-soft);
    border: 1px solid rgba(227, 165, 63, 0.35);
    border-radius: 5px;
    font: 12px var(--mono);
    letter-spacing: 0.08em;
    text-transform: uppercase;
    white-space: nowrap;
    min-width: 32px;
    min-height: 32px;
  }
  .topbar :global(.connection:hover) {
    text-decoration: none;
    color: var(--amber);
  }
  .topbar :global(.connection.offline) {
    color: var(--danger);
    background: var(--danger-soft);
    border-color: rgba(229, 115, 94, 0.4);
  }
  .topbar :global(.connection.connected) {
    color: var(--muted);
    background: none;
    border-color: transparent;
  }
  .topbar :global(.connection.repository) {
    color: var(--muted);
    background: none;
    border-color: var(--border);
  }
  .topbar :global(.connection.repository:hover) {
    color: var(--accent);
    border-color: var(--accent-dim);
  }
  .topbar :global(.connection i) {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: var(--verdigris);
    box-shadow: 0 0 0 2px var(--verdigris-soft);
  }
  main {
    flex: 1;
    overflow: auto;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }
  main:focus {
    outline: none;
  }
  main > :global(*) {
    flex: none;
  }
  /* Room under the last line, so no toast covers the end of a page for good. */
  main::after {
    content: "";
    flex: none;
    height: var(--toast-space, 0px);
  }
  .mobile-toggle {
    display: none;
    padding: 6px;
    min-width: 40px;
  }
  .scrim {
    display: none;
  }
  .search-results {
    overflow: hidden;
  }
  .search-results a {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 11px 16px;
    border-bottom: 1px solid var(--border-soft);
    color: var(--text);
    text-decoration: none;
    min-height: 44px;
  }
  .search-results a:hover,
  .search-results a.selected {
    background: var(--hover);
  }
  .search-results a.selected {
    box-shadow: inset 2px 0 0 var(--accent);
  }
  .result-icon {
    display: grid;
    place-items: center;
    width: 30px;
    height: 30px;
    border-radius: 5px;
    border: 1px solid var(--border);
    background: var(--raised);
    color: var(--accent);
    flex-shrink: 0;
  }
  .search-results a > span:nth-child(2) {
    flex: 1;
    min-width: 0;
  }
  .search-results strong {
    font-weight: 600;
    font-size: 14px;
  }
  .result-section {
    font-weight: 400;
    color: var(--muted);
  }
  .result-summary {
    display: block;
    font-size: 13px;
    color: var(--muted);
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    margin-top: 2px;
  }
  .search-results a > :global(svg:last-child) {
    color: var(--faint);
  }
  .skip-link {
    position: fixed;
    top: -100px;
    left: 12px;
    z-index: 100;
    background: var(--raised);
    color: var(--text);
    border: 1px solid var(--border);
    padding: 10px;
  }
  .skip-link:focus {
    top: 12px;
  }
  .sheet-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(4, 6, 8, 0.66);
    z-index: 20;
  }
  .sheet {
    position: fixed;
    z-index: 21;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    width: min(600px, calc(100vw - 32px));
    max-height: calc(100dvh - 32px);
    overflow: auto;
    padding: 20px 24px;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.6);
  }
  .sheet-head {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    margin-bottom: 10px;
  }
  .sheet h2 {
    display: flex;
    align-items: center;
    gap: 10px;
    font-size: 17px;
  }
  .sheet :global(h3) {
    color: var(--muted);
    font: 500 12px var(--mono);
    text-transform: uppercase;
    letter-spacing: 0.12em;
    margin: 16px 0 6px;
  }
  .sheet :global(dl) {
    display: grid;
    grid-template-columns: 94px minmax(0, 1fr);
    gap: 2px 18px;
    margin: 0;
    font-size: 13px;
  }
  .sheet :global(dt) {
    white-space: nowrap;
  }
  .sheet :global(dt),
  .sheet :global(dd) {
    display: flex;
    align-items: center;
    gap: 4px;
    min-height: 30px;
  }
  .sheet :global(dd) {
    margin: 0;
    color: var(--muted);
  }
  .sheet :global(p) {
    margin-top: 16px;
    font-size: 13px;
  }
  @media (max-width: 1150px) {
    .topbar {
      padding: 10px 22px;
      gap: 14px;
    }
  }
  @media (max-width: 850px) {
    .breadcrumb li:not(:nth-last-child(-n + 2)) {
      display: none;
    }
    .breadcrumb li:nth-last-child(2)::before {
      content: "…";
    }
    .searchbox {
      width: min(260px, 35vw);
    }
  }
  .not-found-links {
    display: flex;
    gap: 24px;
    font-size: 14px;
  }
  @media (max-width: 700px) {
    .workspace {
      grid-template-columns: minmax(0, 1fr);
    }
    .sidebar {
      display: none;
    }
    .sidebar.expanded {
      display: flex;
      position: fixed;
      inset: 0 auto 0 0;
      width: min(290px, 86vw);
      z-index: 31;
      box-shadow: 15px 0 40px rgba(0, 0, 0, 0.6);
    }
    .scrim {
      display: block;
      position: fixed;
      inset: 0;
      z-index: 30;
      background: rgba(4, 6, 8, 0.66);
      border: 0;
      border-radius: 0;
      padding: 0;
      min-height: 0;
    }
    .mobile-toggle {
      display: flex;
    }
    .topbar {
      padding: 10px 14px;
      gap: 10px;
    }
    .breadcrumb li:not(:last-child) {
      display: none;
    }
    .breadcrumb li:last-child::before {
      content: none;
    }
    .searchbox {
      width: auto;
      flex: 1;
    }
    .searchbox kbd {
      display: none;
    }
    .topbar :global(.connection span) {
      display: none;
    }
    .sheet :global(dl) {
      grid-template-columns: 80px minmax(0, 1fr);
      gap: 2px 8px;
    }
  }
  @media print {
    .workspace,
    .main-column,
    main {
      display: block;
      height: auto;
      overflow: visible;
    }
    main::after {
      content: none;
    }
    .sidebar,
    .topbar,
    .skip-link,
    .sheet,
    .sheet-backdrop,
    .scrim {
      display: none !important;
    }
    .search-results {
      overflow: visible;
      min-height: 0;
      border: 0;
    }
    .search-results a {
      break-inside: avoid;
      padding: 8px 0;
    }
  }
</style>
