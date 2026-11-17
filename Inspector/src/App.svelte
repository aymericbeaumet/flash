<script lang="ts">
  import { tick, untrack } from "svelte";
  import ClipboardPanel from "./lib/ClipboardPanel.svelte";
  import { now } from "./lib/clock.svelte";
  import CommandsPanel from "./lib/CommandsPanel.svelte";
  import { docsStore } from "./lib/docs.svelte";
  import DocsPanel from "./lib/DocsPanel.svelte";
  import { ago, clockTime } from "./lib/format";
  import HomePanel from "./lib/HomePanel.svelte";
  import FreshMark from "./lib/FreshMark.svelte";
  import Icon from "./lib/Icon.svelte";
  import LogList from "./lib/LogList.svelte";
  import MappingsPanel from "./lib/MappingsPanel.svelte";
  import { monitorCounts } from "./lib/monitors";
  import MonitorsPanel from "./lib/MonitorsPanel.svelte";
  import PageHeader from "./lib/PageHeader.svelte";
  import PluginsPanel from "./lib/PluginsPanel.svelte";
  import { renderMarkdown } from "./lib/markdown";
  import { prepareOnIntent } from "./lib/prefetch";
  import { freshness, loadSeen } from "./lib/reading";
  import RuntimePanel from "./lib/RuntimePanel.svelte";
  import TelemetryPanel from "./lib/TelemetryPanel.svelte";
  import { configToast, doneToast, failedToast } from "./lib/toast";
  import Toaster from "./lib/Toaster.svelte";
  import { toasts } from "./lib/toasts.svelte";
  import { router } from "./lib/router.svelte";
  import { parseRoute, paths, site } from "./lib/routes";
  import { buildIndex, search as runSearch } from "./lib/search";
  import { store } from "./lib/store.svelte";

  /**
   * The resident's help has every page; the published site is the manual
   * alone, with a note that the live pages are in Flash's own help.
   */
  const published = site.public;
  const allSections = [
    { id: "home", href: "/", label: "Home", group: "Explore", key: "h" },
    { id: "docs", href: paths.docs(), label: "Documentation", group: "Explore", key: "d" },
    { id: "mappings", href: paths.mappings(), label: "Key mappings", group: "Your Flash", key: "m" },
    { id: "commands", href: paths.commands(), label: "Commands", group: "Your Flash", key: "c" },
    { id: "plugins", href: paths.plugins(), label: "Plugins", group: "Your Flash", key: "p" },
    { id: "state", href: "/state", label: "Runtime & config", group: "Inspect", key: "r" },
    { id: "monitors", href: "/monitors", label: "Monitors", group: "Inspect", key: "o" },
    { id: "telemetry", href: "/telemetry", label: "Telemetry", group: "Inspect", key: "t" },
    { id: "logs", href: "/logs", label: "Live logs", group: "Inspect", key: "l" },
    { id: "clipboard", href: "/clipboard", label: "Clipboard", group: "Inspect", key: "b" },
  ];
  const sections = published ? allSections.filter((item) => item.id === "docs") : allSections;
  const groups = published ? ["Explore"] : ["Explore", "Your Flash", "Inspect"];
  const route = $derived(router.route);
  let search = $state("");
  let searchInput = $state<HTMLInputElement>();
  let selectedResult = $state(0);
  let mobileNav = $state(false);
  let shortcuts = $state(false);
  let pendingG = $state(false);
  let content = $state<HTMLElement>();
  /** How much of the window's bottom the toasts cover; the content scrolls clear of it. */
  let toastSpace = $state(0);
  const docs = $derived(store.state.docs ?? []);
  const plugins = $derived(store.state.plugins ?? []);
  const commands = $derived(store.state.commands ?? []);
  const mappings = $derived(store.state.mappings ?? { normal_leader: "", rows: [] });
  const loaded = $derived(store.state.snapshot_at_unix_ms != null);
  const monitorAlarm = $derived.by(() => {
    const counts = monitorCounts(store.state.monitors ?? []);
    return counts.error ? { count: counts.error, state: "error" } : counts.warning ? { count: counts.warning, state: "warning" } : null;
  });
  const manual = $derived(docsStore.manual);
  const currentPage = $derived(route.page === "docs" ? manual?.page(route.param) : undefined);
  /** A plugin's guide, at a docs path the manual leaves free. */
  const currentGuide = $derived(route.page === "docs" && manual && !currentPage ? docs.find((doc) => doc.name === route.param) : undefined);
  const section = $derived(sections.find((candidate) => candidate.id === route.page));
  const hasFresh = $derived(freshness(docsStore.readable(docs), loadSeen()).size > 0);
  // How long the page has been without its stream; the clock ticks only then.
  const offlineFor = $derived(store.connected ? 0 : now() - store.offlineSince);
  // A first connection gets a moment before the page calls Flash unreachable.
  const offline = $derived(!published && !store.connected && (store.everConnected || offlineFor > 2500));
  const snapshotAt = $derived(store.state.snapshot_at_unix_ms);
  const connectionMessage = $derived(snapshotAt
    ? `Connection to Flash lost. Showing the snapshot from ${clockTime(snapshotAt)}; it may be stale. Reconnecting automatically.`
    : "Connecting to Flash. Live information will appear when the resident app is available.");
  /** The path shown in the top bar: every crumb but the last is a link. */
  const crumbs = $derived.by(() => {
    const list: { label: string; href?: string }[] = [];
    if (route.page === "home") return list;
    if (route.page === "search") return [...list, { label: "Search" }, ...(route.param ? [{ label: `“${route.param}”` }] : [])];
    if (route.page === "not-found") return [...list, { label: "Page not found" }];
    if (route.page === "docs") {
      list.push({ label: "Documentation", href: paths.docs() });
      if (currentPage?.path) list.push(...currentPage.trail.map((label) => ({ label })), { label: currentPage.heading ?? currentPage.title });
      else if (currentGuide) list.push({ label: "Plugin guides" }, { label: currentGuide.title });
      else if (route.param && !currentPage) list.push({ label: route.param });
      return list;
    }
    list.push({ label: section?.label ?? route.page, href: section?.href });
    if (route.page === "plugins" && route.param) {
      list.push({ label: plugins.find((plugin) => plugin.id === route.param)?.name ?? route.param });
    } else if ((route.page === "mappings" || route.page === "commands") && route.param) {
      list.push({ label: `“${route.param}”` });
    }
    return list;
  });
  const current = $derived(crumbs[crumbs.length - 1]?.label ?? "Flash");
  const siteName = $derived(manual?.bundle.site.name ?? "Flash");
  /** The tab title; the published site names the page then the site, as before. */
  const title = $derived(published
    ? (route.page === "docs" && !route.param ? siteName : `${current} - ${siteName}`)
    : route.page === "home" ? "Flash" : `${current} · Flash`);
  const canonical = $derived(published && manual && route.page === "docs" && currentPage ? new URL(paths.docs(currentPage.path), manual.bundle.site.url).href : undefined);
  const index = $derived(buildIndex(published ? [] : docs, published ? [] : commands, published ? [] : (mappings.effective_rows ?? mappings.rows), published ? [] : plugins, docsStore.sections ?? []));
  const results = $derived(route.page === "search" ? runSearch(index, route.param) : []);
  let announcement = $state("");

  // Runs once: nothing it reads may restart the stream or the router.
  $effect(() => untrack(() => {
    const idle = (callback: () => void) => ("requestIdleCallback" in window ? requestIdleCallback(callback, { timeout: 2000 }) : setTimeout(callback, 200));
    if (published) {
      // Links load prerendered pages until the whole manual is here.
      router.handles = (target) => target.page === "search" || docsStore.complete;
      idle(() => { void docsStore.load(); });
    } else {
      store.start();
      // A live page needs the manual only for the sidebar's reading marks:
      // it loads once the page is idle, or as soon as a manual page or a
      // search asks for it (below).
      if (router.route.page === "docs" || router.route.page === "search") void docsStore.load();
      else idle(() => { void docsStore.load(); });
    }
    const stopRouter = router.start(content!, () => { mobileNav = false; shortcuts = false; selectedResult = 0; if (router.route.page !== "search") search = ""; });
    // A manual page renders while its link is pointed at or focused; the
    // click then only mounts it.
    const stopPreparing = prepareOnIntent(window, (url) => {
      if (url.origin !== location.origin || !router.handles(parseRoute(url))) return;
      const target = parseRoute(url);
      const known = docsStore.manual;
      const page = target.page === "docs" ? known?.page(target.param) : undefined;
      if (known && page?.markdown) renderMarkdown(page.markdown, known.context(page.file));
    });
    window.addEventListener("keydown", onKey);
    return () => { window.removeEventListener("keydown", onKey); stopPreparing(); stopRouter(); if (!published) store.stop(); };
  }));
  $effect(() => { if (!published && (route.page === "docs" || route.page === "search")) void docsStore.load(); });
  // Configuration diagnostics that appear, change or clear while the page is
  // open reach the reader on any page; the runtime page lists them in full.
  let configShown: string | null | undefined;
  $effect(() => {
    const runtime = store.state.runtime;
    if (!runtime) return;
    const error = runtime.config_error ?? null;
    untrack(() => {
      const options = configToast(configShown, error, () => { if (router.route.page === "state") content?.scrollTo({ top: 0 }); else router.navigate("/state"); });
      configShown = error;
      if (options) toasts.show(options);
    });
  });
  // A manual that failed to load retries once Flash answers again.
  $effect(() => { if (!published && store.connected && docsStore.error) void docsStore.load(); });
  // Search reads the manual's sections, fetched the first time it is needed:
  // as the search field takes focus, before the first word is typed.
  $effect(() => { if (route.page === "search" || search) void docsStore.loadSections(); });
  // A reload of /search?q= restores the query in the box.
  $effect(() => { if (route.page === "search" && search !== route.param) search = route.param; });
  // Pages arrive after the first render; reveal a linked heading once it renders.
  $effect(() => { void docs; void docsStore.bundle; void docsStore.complete; void tick().then(() => router.revealAnchor()); });
  $effect(() => { const label = current; void tick().then(() => { announcement = route.page === "home" ? "Flash help home" : label; }); });

  /** The runtime page's Refresh says how it went. */
  async function refresh() {
    await store.refresh();
    toasts.show(store.refreshError ? failedToast("refresh", `${store.refreshError} The page keeps the last snapshot.`) : doneToast("refresh", "Refreshed: the page shows Flash's latest snapshot."));
  }
  function typing(event: KeyboardEvent): boolean {
    const target = event.target;
    return target instanceof HTMLElement && (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName));
  }
  function onKey(event: KeyboardEvent) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") { event.preventDefault(); searchInput?.focus(); searchInput?.select(); return; }
    if (event.key === "Escape") {
      shortcuts = false; mobileNav = false; pendingG = false;
      if (document.activeElement === searchInput) { search = ""; if (route.page === "search") history.back(); }
      if (document.activeElement instanceof HTMLElement && (document.activeElement.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement.tagName))) {
        document.activeElement.blur();
      }
      return;
    }
    if (typing(event) || event.metaKey || event.ctrlKey || event.altKey) return;
    if (pendingG) {
      pendingG = false;
      const target = sections.find((candidate) => candidate.key === event.key);
      if (target) { event.preventDefault(); router.navigate(target.href); }
      return;
    }
    switch (event.key) {
      case "/": event.preventDefault(); searchInput?.focus(); searchInput?.select(); break;
      case "?": event.preventDefault(); shortcuts = !shortcuts; break;
      case "g": pendingG = true; setTimeout(() => { pendingG = false; }, 1200); break;
      case "[": case "]": {
        let target: string | undefined;
        if (route.page === "docs" && currentPage && manual) {
          const { previous, next } = manual.neighbours(currentPage.path);
          const page = event.key === "[" ? previous : next;
          target = page && paths.docs(page.path);
        }
        if (target) { event.preventDefault(); router.navigate(target); }
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
    if (event.key === "ArrowDown") { event.preventDefault(); selectedResult = Math.min(selectedResult + 1, results.length - 1); }
    else if (event.key === "ArrowUp") { event.preventDefault(); selectedResult = Math.max(selectedResult - 1, 0); }
    else if (event.key === "Enter") { event.preventDefault(); router.navigate(results[selectedResult].href); searchInput?.blur(); }
  }
</script>

<svelte:head>
  <title>{title}</title>
  {#if canonical && manual}
    <link rel="canonical" href={canonical} />
    <meta property="og:title" content={current} />
    <meta property="og:url" content={canonical} />
  {/if}
</svelte:head>

<a class="skip-link" href="#main-content" onclick={(event) => { event.preventDefault(); content?.focus(); }}>Skip to content</a>
<div class="sr-only" aria-live="polite">{announcement}</div>
<div class="workspace">
  {#if mobileNav}<button type="button" class="scrim" aria-label="Close navigation" onclick={() => mobileNav = false}></button>{/if}
  <aside class="sidebar" class:expanded={mobileNav} id="sidebar">
    <a href={published ? paths.docs() : "/"} class="brand" aria-label={published ? "Flash documentation home" : "Flash help home"}><span class="brand-mark"><Icon name="bolt" size={20} /></span><span class="brand-text">Flash</span></a>
    <nav aria-label="Main navigation">
      {#each groups as group}
        <div class="nav-group"><div class="nav-label">{group}</div>
          {#each sections.filter((candidate) => candidate.group === group) as item}
            <a href={item.href} class:active={route.page === item.id} aria-current={route.page === item.id ? "page" : undefined}><Icon name={item.id} size={16} /><span>{item.label}</span>{#if item.id === "plugins"}<span class="nav-count">{plugins.length}</span>{/if}{#if item.id === "monitors" && monitorAlarm}<span class="nav-alarm nav-alarm-{monitorAlarm.state}" title="{monitorAlarm.count} {monitorAlarm.state === 'error' ? 'in error' : 'warning'}">{monitorAlarm.count}</span>{/if}{#if item.id === "docs" && hasFresh}<span class="nav-fresh"><FreshMark state="new" label="New or updated pages since your last visit" /></span>{/if}<kbd class="nav-key" aria-hidden="true">g {item.key}</kbd></a>
          {/each}
        </div>
      {/each}
      {#if published}<div class="nav-group live-note"><div class="nav-label">Your Flash</div><p>Your key mappings, commands, plugins, runtime, monitors, logs and clipboard are live pages in Flash's own help: press <kbd>?</kbd> in NORMAL mode or run <code>:help</code>.</p></div>{/if}
    </nav>
    <div class="sidebar-footer">{#if published && manual}<a class="local-mark" href={manual.bundle.site.repository} target="_blank" rel="noopener noreferrer"><Icon name="docs" size={14} /> {manual.bundle.site.repository_name} <span aria-hidden="true">↗</span></a>{:else if !published}<span class="local-mark"><Icon name="shield" size={14} /> Served by Flash on this Mac</span>{/if}<a href={paths.docs("privacy")}>Privacy & permissions</a><button type="button" class="shortcut-hint" onclick={() => shortcuts = true}>Keyboard shortcuts <kbd>?</kbd></button>{#if store.state.runtime?.version}<span class="version">Flash {store.state.runtime.version}</span>{/if}</div>
  </aside>
  <div class="main-column">
    <header class="topbar">
      <button class="mobile-toggle" aria-label="Toggle navigation" aria-expanded={mobileNav} aria-controls="sidebar" onclick={() => mobileNav = !mobileNav}><Icon name="menu" /></button>
      {#if crumbs.length}<nav class="breadcrumb" aria-label="Breadcrumb"><ol>{#each crumbs as crumb, position}<li>{#if crumb.href && position < crumbs.length - 1}<a href={crumb.href}>{crumb.label}</a>{:else}<strong aria-current={position === crumbs.length - 1 ? "page" : undefined}>{crumb.label}</strong>{/if}</li>{/each}</ol></nav>{/if}
      <form class="searchbox" role="search" action={paths.search()} onsubmit={(event) => { event.preventDefault(); if (results[selectedResult]) router.navigate(results[selectedResult].href); }}><Icon name="search" size={15} /><input bind:this={searchInput} bind:value={search} oninput={onSearchInput} onkeydown={onSearchKey} onfocus={() => void docsStore.loadSections()} type="search" name="q" aria-label={published ? "Search the documentation" : "Search all documentation, commands, mappings and plugins"} placeholder={published ? "Search the docs…" : "Search anything…"} /><kbd>/</kbd></form>
      {#if published}{#if manual}<a href={manual.bundle.site.repository} class="connection repository" target="_blank" rel="noopener noreferrer" title="Flash on GitHub">GitHub <span aria-hidden="true">↗</span></a>{/if}
      {:else}<a href="/state" class="connection" class:connected={store.connected} class:offline aria-label={store.connected ? "Live connection to Flash" : connectionMessage} title={store.connected ? "Live connection to Flash" : connectionMessage}>{#if store.connected}<i></i>Live{:else}<Icon name="warning" size={16} /><span>{offline ? "Offline" : "Connecting"}</span>{/if}</a>{/if}
    </header>
    {#if !published}<span class="sr-only" role="status">{store.connected ? "Connected to Flash. Live information is current." : connectionMessage}</span>{/if}
    {#if offline}
      <div class="offline-banner" role="alert">
        <Icon name="warning" size={18} />
        <div>
          {#if store.everConnected && snapshotAt}<strong>Flash stopped answering {ago(store.offlineSince, now())}.</strong> Everything below is the snapshot from {clockTime(snapshotAt)} and may be stale.
          {:else if snapshotAt}<strong>Flash is not answering.</strong> Everything below is the snapshot from {clockTime(snapshotAt)} and may be stale.
          {:else}<strong>Flash is not answering.</strong> No live information yet.{/if}
          <span class="offline-hint">If Flash quit or restarted, reopen help with <kbd>?</kbd> in NORMAL or <code>:help</code>. This page reconnects by itself.</span>
        </div>
        <button type="button" onclick={() => store.reconnect()}><Icon name="refresh" size={14} /> Reconnect now</button>
      </div>
    {/if}
    <main id="main-content" tabindex="-1" bind:this={content} style:--toast-space={toastSpace ? `${toastSpace}px` : undefined}>
      {#if route.page === "search"}
        <div class="page">
          <PageHeader id="search" title="Search" purpose={route.param ? `${results.length} ${results.length === 1 ? "result" : "results"} for “${route.param}”` : published ? "Type a feature, command or setting. Every word must match." : "Type a feature, command, key or plugin name. Every word must match."} />
          {#if route.param}<div class="search-results surface" aria-live="polite">
            {#each results as result, position}<a href={result.href} class:selected={position === selectedResult} onmouseenter={() => selectedResult = position}><span class="result-icon"><Icon name={result.icon} size={16} /></span><span><strong>{result.title}{#if result.section}<span class="result-section"> › {result.section}</span>{/if}</strong><span class="result-summary">{result.summary}</span></span><span class="badge neutral">{result.kind}</span><Icon name="arrow" size={15} /></a>{/each}
            {#if results.length === 0}<div class="empty"><strong>{published && !docsStore.sections ? "Searching…" : "No matches"}</strong>Try fewer words, or a command name such as <code>mouse target</code>.</div>{/if}
            {#if results.length >= 80}<p class="empty">Showing the first 80 matches. Add another word to narrow your search.</p>{/if}
          </div>{/if}
        </div>
      {:else if route.page === "home"}<HomePanel snapshot={store.state} connected={store.connected} />
      {:else if route.page === "docs"}<DocsPanel param={route.param} {docs} />
      {:else if route.page === "mappings"}<MappingsPanel {mappings} keyboard={store.state.keyboard} {commands} filter={route.param} />
      {:else if route.page === "commands"}<CommandsPanel {commands} rows={mappings.effective_rows ?? mappings.rows} filter={route.param} />
      {:else if route.page === "plugins"}<PluginsPanel {plugins} {commands} filter={route.param} sampledAt={store.state.snapshot_at_unix_ms} onresample={() => store.refresh()} />
      {:else if route.page === "state"}<RuntimePanel state={store.state} connected={store.connected} onrefresh={refresh} />
      {:else if route.page === "monitors"}<MonitorsPanel monitors={store.state.monitors} {loaded} />
      {:else if route.page === "telemetry"}<TelemetryPanel telemetry={store.state.telemetry} {loaded} />
      {:else if route.page === "logs"}<div class="page log-page"><PageHeader id="logs" title="Live logs" purpose="What Flash and its plugins are doing, newest last." manual={paths.docs("troubleshooting")} live>{#snippet help()}<p>Flash streams structured diagnostics here as they happen. Filter by level or source, search messages and fields, and select a record to read or copy it as JSON. The tail follows new records until you scroll up or pause it.</p>{/snippet}</PageHeader><div class="surface log-surface"><LogList logs={store.logs} /></div></div>
      {:else if route.page === "clipboard"}<ClipboardPanel entries={store.state.clipboard ?? []} registers={store.state.clipboard_registers ?? []} nextOffset={store.state.clipboard_next_offset ?? null} total={store.state.clipboard_total ?? 0} />
      {:else}<div class="page"><PageHeader id="not-found" title="Page not found" purpose={published ? "This address is not part of the Flash documentation. Start from its home page, or search above." : "This address is not part of Flash's help. Start from its home page, browse the documentation, or search above."} /><p class="not-found-links">{#if !published}<a href="/">Home →</a>{/if}<a href={paths.docs()}>Documentation →</a></p></div>{/if}
    </main>
  </div>
  {#if shortcuts}
    <div class="sheet-backdrop" role="presentation" onclick={() => shortcuts = false}></div>
    <div class="sheet surface" role="dialog" aria-modal="true" aria-labelledby="shortcuts-title">
      <div class="sheet-head"><h2 id="shortcuts-title"><span class="rivet" aria-hidden="true"></span>Keyboard shortcuts</h2><button type="button" onclick={() => shortcuts = false}>Close</button></div>
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
        {#each sections as item}<dt><kbd>g</kbd> <kbd>{item.key}</kbd></dt><dd>Go to {item.label}</dd>{/each}
        <dt><kbd>?</kbd></dt><dd>Show or hide this sheet</dd>
      </dl>
      {#if !published}
        <h3>Clipboard history</h3>
        <dl>
          <dt><kbd>j</kbd> <kbd>k</kbd></dt><dd>Next or previous entry</dd>
          <dt><kbd>↩</kbd></dt><dd>Copy the selected entry</dd>
          <dt><kbd>space</kbd></dt><dd>Expand or collapse it</dd>
          <dt><kbd>⌫</kbd></dt><dd>Delete it from history</dd>
        </dl>
        <p class="muted">Shortcuts pause while you type in a field. Flash's own keys are on the <a href={paths.mappings()}>key mappings</a> page.</p>
      {:else}
        <p class="muted">Shortcuts pause while you type in a field.</p>
      {/if}
    </div>
  {/if}
</div>
<Toaster fallback={() => content} bind:space={toastSpace} />

<style>
  .workspace { display: grid; grid-template-columns: 248px minmax(0, 1fr); height: 100dvh; }
  .sidebar { background: var(--sidebar); border-right: 1px solid var(--border); display: flex; flex-direction: column; padding: 18px 12px 16px; overflow: auto; }
  .brand { display: flex; align-items: center; gap: 11px; color: var(--text); font-size: 18px; font-weight: 650; line-height: 1.15; padding: 0 6px; text-decoration: none; letter-spacing: -.01em; }
  .brand:hover { color: var(--text); text-decoration: none; }
  /* A brass plate with a rivet in each corner. */
  .brand-mark { display: grid; place-items: center; flex: none; width: 36px; height: 36px; color: var(--accent); border: 1px solid var(--accent-dim); border-radius: 6px; background:
    radial-gradient(circle at 4px 4px, var(--accent-dim) 1.2px, transparent 1.8px),
    radial-gradient(circle at calc(100% - 4px) 4px, var(--accent-dim) 1.2px, transparent 1.8px),
    radial-gradient(circle at 4px calc(100% - 4px), var(--accent-dim) 1.2px, transparent 1.8px),
    radial-gradient(circle at calc(100% - 4px) calc(100% - 4px), var(--accent-dim) 1.2px, transparent 1.8px),
    var(--raised); box-shadow: var(--engrave); }
  .sidebar nav { margin-top: 26px; }
  .nav-group { margin-bottom: 18px; }
  .nav-label { padding: 0 10px; margin-bottom: 4px; font: 500 12px var(--mono); letter-spacing: .14em; text-transform: uppercase; color: var(--faint); }
  .sidebar nav a { display: flex; align-items: center; gap: 10px; min-height: 36px; padding: 6px 10px; margin: 1px 0; border-radius: 5px; color: var(--muted); font-size: 13px; font-weight: 500; text-decoration: none; white-space: nowrap; }
  .sidebar nav a > span:nth-child(2) { min-width: 0; }
  .sidebar nav a:hover { background: var(--raised); color: var(--text); text-decoration: none; }
  .sidebar nav a.active { background: var(--raised); color: var(--text); font-weight: 600; box-shadow: inset 2px 0 0 var(--accent), var(--engrave); }
  .sidebar nav a.active :global(svg) { color: var(--accent); }
  .nav-count { margin-left: auto; font: 12px var(--mono); color: var(--faint); }
  .nav-alarm { margin-left: auto; min-width: 20px; padding: 0 6px; border-radius: 9px; font: 600 12px/18px var(--mono); text-align: center; }
  .nav-alarm-error { color: var(--danger); background: var(--danger-soft); box-shadow: inset 0 0 0 1px rgba(229, 115, 94, .4); }
  .nav-alarm-warning { color: var(--amber); background: var(--amber-soft); box-shadow: inset 0 0 0 1px rgba(227, 165, 63, .4); }
  .nav-fresh { margin-left: auto; }
  .nav-key { display: none; flex: none; margin-left: auto; font-size: 12px; padding: 0 4px; color: var(--muted); }
  .sidebar nav a:hover .nav-key, .sidebar nav a:focus-visible .nav-key { display: inline-block; }
  .sidebar nav a:hover .nav-count, .sidebar nav a:hover .nav-fresh, .sidebar nav a:hover .nav-alarm { display: none; }
  .sidebar-footer { display: flex; flex-direction: column; margin-top: auto; padding: 14px 10px 0; border-top: 1px solid var(--border); font-size: 12px; color: var(--muted); }
  .local-mark { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); margin-bottom: 4px; }
  a.local-mark:hover { color: var(--accent); }
  .live-note p { padding: 4px 10px 0; font-size: 12px; line-height: 1.6; color: var(--muted); }
  .live-note kbd { font-size: 12px; padding: 0 4px; }
  .sidebar-footer a { display: flex; min-height: 32px; align-items: center; }
  .shortcut-hint { display: flex; align-items: center; gap: 8px; width: 100%; justify-content: space-between; border: 0; background: none; padding: 4px 0; min-height: 32px; color: var(--accent); font-size: 12px; box-shadow: none; }
  .shortcut-hint:hover { background: none; color: var(--accent-strong); }
  .version { margin-top: 6px; font: 12px var(--mono); color: var(--faint); }
  .main-column { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
  .topbar { min-height: 56px; display: flex; align-items: center; gap: 20px; padding: 10px 32px; border-bottom: 1px solid var(--border); background: var(--sidebar); }
  .breadcrumb { min-width: 0; font-size: 13px; color: var(--muted); }
  .breadcrumb ol { display: flex; align-items: center; gap: 8px; list-style: none; margin: 0; padding: 0; white-space: nowrap; overflow: hidden; }
  .breadcrumb li { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .breadcrumb li + li::before { content: "›"; color: var(--faint); }
  .breadcrumb a { color: var(--muted); min-height: 32px; display: inline-flex; align-items: center; }
  .breadcrumb a:hover { color: var(--accent); }
  .breadcrumb strong { font-weight: 500; color: var(--text); overflow: hidden; text-overflow: ellipsis; }
  .searchbox { margin-left: auto; display: flex; align-items: center; gap: 8px; width: min(320px, 34vw); border: 1px solid var(--border); border-radius: 5px; padding: 0 10px; color: var(--faint); background: var(--inset); box-shadow: var(--well); }
  .searchbox:focus-within { border-color: var(--accent-dim); }
  .searchbox input { border: 0; background: none; box-shadow: none; width: 100%; min-height: 34px; padding: 4px 0; font-size: 13px; outline-offset: 0; }
  .searchbox input:focus-visible { outline: none; }
  .searchbox kbd { font-size: 12px; padding: 0 5px; color: var(--muted); }
  .connection { display: flex; align-items: center; justify-content: center; gap: 7px; padding: 0 10px; color: var(--amber); background: var(--amber-soft); border: 1px solid rgba(227, 165, 63, .35); border-radius: 5px; font: 12px var(--mono); letter-spacing: .08em; text-transform: uppercase; white-space: nowrap; min-width: 32px; min-height: 32px; }
  .connection:hover { text-decoration: none; color: var(--amber); }
  .connection.offline { color: var(--danger); background: var(--danger-soft); border-color: rgba(229, 115, 94, .4); }
  .connection.connected { color: var(--muted); background: none; border-color: transparent; }
  .connection.repository { color: var(--muted); background: none; border-color: var(--border); }
  .connection.repository:hover { color: var(--accent); border-color: var(--accent-dim); }
  .connection i { width: 7px; height: 7px; border-radius: 50%; background: var(--verdigris); box-shadow: 0 0 0 2px var(--verdigris-soft); }
  .offline-banner { display: flex; align-items: center; gap: 12px; padding: 10px 32px; border-bottom: 1px solid rgba(229, 115, 94, .35); background: #1f1617; color: var(--text); font-size: 13px; }
  .offline-banner > :global(svg) { flex: none; color: var(--danger); }
  .offline-banner strong { color: var(--danger); font-weight: 600; }
  .offline-banner > div { flex: 1; min-width: 0; }
  .offline-hint { display: block; color: var(--muted); margin-top: 2px; }
  .offline-banner button { display: inline-flex; align-items: center; gap: 6px; flex: none; min-height: 32px; font-size: 12px; }
  main { flex: 1; overflow: auto; min-height: 0; display: flex; flex-direction: column; }
  main:focus { outline: none; }
  main > :global(*) { flex: none; }
  /* Room under the last line, so no toast covers the end of a page for good. */
  main::after { content: ""; flex: none; height: var(--toast-space, 0px); }
  .mobile-toggle { display: none; padding: 6px; min-width: 40px; }
  .scrim { display: none; }
  .search-results { overflow: hidden; }
  .search-results a { display: flex; align-items: center; gap: 14px; padding: 11px 16px; border-bottom: 1px solid var(--border-soft); color: var(--text); text-decoration: none; min-height: 44px; }
  .search-results a:hover, .search-results a.selected { background: var(--hover); }
  .search-results a.selected { box-shadow: inset 2px 0 0 var(--accent); }
  .result-icon { display: grid; place-items: center; width: 30px; height: 30px; border-radius: 5px; border: 1px solid var(--border); background: var(--raised); color: var(--accent); flex-shrink: 0; }
  .search-results a > span:nth-child(2) { flex: 1; min-width: 0; }
  .search-results strong { font-weight: 600; font-size: 14px; }
  .result-section { font-weight: 400; color: var(--muted); }
  .result-summary { display: block; font-size: 13px; color: var(--muted); overflow: hidden; white-space: nowrap; text-overflow: ellipsis; margin-top: 2px; }
  .search-results a > :global(svg:last-child) { color: var(--faint); }
  /* Percentage height does not resolve against main's flex size, so this page
     grows as a flex child and the record list fills the space under the heading. */
  .log-page { flex: 1 1 auto; width: 100%; min-width: 0; min-height: 0; display: flex; flex-direction: column; overflow: hidden; padding-bottom: 16px; }
  .log-surface { flex: 1; min-width: 0; min-height: 0; overflow: hidden; display: flex; flex-direction: column; }
  .skip-link { position: fixed; top: -100px; left: 12px; z-index: 100; background: var(--raised); color: var(--text); border: 1px solid var(--border); padding: 10px; }
  .skip-link:focus { top: 12px; }
  .sheet-backdrop { position: fixed; inset: 0; background: rgba(4, 6, 8, .66); z-index: 20; }
  .sheet { position: fixed; z-index: 21; top: 50%; left: 50%; transform: translate(-50%, -50%); width: min(600px, calc(100vw - 32px)); max-height: calc(100dvh - 32px); overflow: auto; padding: 20px 24px; box-shadow: 0 24px 60px rgba(0, 0, 0, .6); }
  .sheet-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-bottom: 10px; }
  .sheet h2 { display: flex; align-items: center; gap: 10px; font-size: 17px; }
  .sheet h3 { color: var(--muted); font: 500 12px var(--mono); text-transform: uppercase; letter-spacing: .12em; margin: 16px 0 6px; }
  .sheet dl { display: grid; grid-template-columns: 94px minmax(0, 1fr); gap: 2px 18px; margin: 0; font-size: 13px; }
  .sheet dt { white-space: nowrap; }
  .sheet dt, .sheet dd { display: flex; align-items: center; gap: 4px; min-height: 30px; }
  .sheet dd { margin: 0; color: var(--muted); }
  .sheet p { margin-top: 16px; font-size: 13px; }
  @media (max-width: 1150px) { .topbar { padding: 10px 22px; gap: 14px; } .offline-banner { padding: 10px 22px; } }
  @media (max-width: 850px) { .breadcrumb li:not(:nth-last-child(-n+2)) { display: none; } .breadcrumb li:nth-last-child(2)::before { content: "…"; } .searchbox { width: min(260px, 35vw); } }
  .not-found-links { display: flex; gap: 24px; font-size: 14px; }
  @media (max-width: 700px) {
    .workspace { grid-template-columns: minmax(0, 1fr); }
    .sidebar { display: none; }
    .sidebar.expanded { display: flex; position: fixed; inset: 0 auto 0 0; width: min(290px, 86vw); z-index: 31; box-shadow: 15px 0 40px rgba(0, 0, 0, .6); }
    .scrim { display: block; position: fixed; inset: 0; z-index: 30; background: rgba(4, 6, 8, .66); border: 0; border-radius: 0; padding: 0; min-height: 0; }
    .mobile-toggle { display: flex; }
    .topbar { padding: 10px 14px; gap: 10px; }
    .offline-banner { padding: 10px 14px; flex-wrap: wrap; }
    .breadcrumb li:not(:last-child) { display: none; }
    .breadcrumb li:last-child::before { content: none; }
    .searchbox { width: auto; flex: 1; }
    .searchbox kbd { display: none; }
    .connection span { display: none; }
    .sheet dl { grid-template-columns: 80px minmax(0, 1fr); gap: 2px 8px; }
  }
  @media print {
    .workspace, .main-column, main, .log-page { display: block; height: auto; overflow: visible; }
    main::after { content: none; }
    .sidebar, .topbar, .skip-link, .sheet, .sheet-backdrop, .scrim, .offline-banner { display: none !important; }
    .search-results, .log-surface { overflow: visible; min-height: 0; border: 0; }
    .search-results a { break-inside: avoid; padding: 8px 0; }
  }
</style>
