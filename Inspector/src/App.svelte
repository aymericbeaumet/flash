<script lang="ts">
  import { tick } from "svelte";
  import ClipboardPanel from "./lib/ClipboardPanel.svelte";
  import CommandsPanel from "./lib/CommandsPanel.svelte";
  import DocsPanel from "./lib/DocsPanel.svelte";
  import HomePanel from "./lib/HomePanel.svelte";
  import Icon from "./lib/Icon.svelte";
  import LogList from "./lib/LogList.svelte";
  import MappingsPanel from "./lib/MappingsPanel.svelte";
  import { markGuideRead } from "./lib/onboarding";
  import PluginsPanel from "./lib/PluginsPanel.svelte";
  import { freshness, loadSeen } from "./lib/reading";
  import RuntimePanel from "./lib/RuntimePanel.svelte";
  import { router } from "./lib/router.svelte";
  import { paths } from "./lib/routes";
  import { buildIndex, search as runSearch } from "./lib/search";
  import { store } from "./lib/store.svelte";
  import { neighbours } from "./lib/topics";

  const sections = [
    { id: "home", href: "/", label: "Home", group: "Explore", key: "h" },
    { id: "docs", href: paths.docs(), label: "Documentation", group: "Explore", key: "d" },
    { id: "mappings", href: paths.mappings(), label: "Key mappings", group: "Your Flash", key: "m" },
    { id: "commands", href: paths.commands(), label: "Commands", group: "Your Flash", key: "c" },
    { id: "plugins", href: paths.plugins(), label: "Plugins", group: "Your Flash", key: "p" },
    { id: "state", href: "/state", label: "Runtime & config", group: "Inspect", key: "r" },
    { id: "logs", href: "/logs", label: "Live logs", group: "Inspect", key: "l" },
    { id: "clipboard", href: "/clipboard", label: "Clipboard", group: "Inspect", key: "b" },
  ];
  const route = $derived(router.route);
  $effect(() => { if (route.page === "docs") markGuideRead(route.param); });
  let search = $state("");
  let searchInput = $state<HTMLInputElement>();
  let selectedResult = $state(0);
  let mobileNav = $state(false);
  let shortcuts = $state(false);
  let pendingG = $state(false);
  let content = $state<HTMLElement>();
  const docs = $derived(store.state.docs ?? []);
  const plugins = $derived(store.state.plugins ?? []);
  const commands = $derived(store.state.commands ?? []);
  const mappings = $derived(store.state.mappings ?? { normal_leader: "", rows: [] });
  const loaded = $derived(store.state.snapshot_at_unix_ms != null);
  const currentDoc = $derived(route.page === "docs" ? docs.find((doc) => doc.name === route.param || (doc.aliases ?? []).includes(route.param)) : undefined);
  const section = $derived(sections.find((candidate) => candidate.id === route.page));
  const freshCount = $derived(freshness(docs, loadSeen()).size);
  const connectionMessage = $derived(store.state.snapshot_at_unix_ms
    ? "Connection interrupted. Showing the last received snapshot; reconnecting automatically."
    : "Connecting to Flash. Live information will appear when the resident app is available.");
  /** The path shown in the top bar: every crumb but the last is a link. */
  const crumbs = $derived.by(() => {
    const list: { label: string; href?: string }[] = [];
    if (route.page === "home") return list;
    if (route.page === "search") return [...list, { label: "Search" }, ...(route.param ? [{ label: `“${route.param}”` }] : [])];
    if (route.page === "not-found") return [...list, { label: "Page not found" }];
    list.push({ label: section?.label ?? route.page, href: section?.href });
    if (route.page === "docs" && route.param) {
      if (currentDoc?.group) list.push({ label: currentDoc.group, href: paths.docs() });
      list.push({ label: currentDoc?.title ?? route.param });
    } else if (route.page === "plugins" && route.param) {
      list.push({ label: plugins.find((plugin) => plugin.id === route.param)?.name ?? route.param });
    } else if ((route.page === "mappings" || route.page === "commands") && route.param) {
      list.push({ label: `“${route.param}”` });
    }
    return list;
  });
  const current = $derived(crumbs[crumbs.length - 1]?.label ?? "Flash Help");
  const index = $derived(buildIndex(docs, commands, mappings.effective_rows ?? mappings.rows, plugins));
  const results = $derived(route.page === "search" ? runSearch(index, route.param) : []);
  let announcement = $state("");

  $effect(() => {
    store.start();
    const stopRouter = router.start(content!, () => { mobileNav = false; shortcuts = false; selectedResult = 0; if (router.route.page !== "search") search = ""; });
    window.addEventListener("keydown", onKey);
    return () => { window.removeEventListener("keydown", onKey); stopRouter(); store.stop(); };
  });
  // A reload of /search?q= restores the query in the box.
  $effect(() => { if (route.page === "search" && search !== route.param) search = route.param; });
  // Guides arrive with the first snapshot; reveal a linked heading once it renders.
  $effect(() => { void docs; void tick().then(() => router.revealAnchor()); });
  $effect(() => { document.title = route.page === "home" ? "Flash Help" : `${current} · Flash Help`; });
  $effect(() => { const title = current; void tick().then(() => { announcement = route.page === "home" ? "Flash Help home" : title; }); });

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
        if (route.page !== "docs" || !currentDoc) break;
        const { previous, next } = neighbours(docs, currentDoc.name);
        const target = event.key === "[" ? previous : next;
        if (target) { event.preventDefault(); router.navigate(paths.docs(target.name)); }
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

<a class="skip-link" href="#main-content" onclick={(event) => { event.preventDefault(); content?.focus(); }}>Skip to content</a>
<div class="sr-only" aria-live="polite">{announcement}</div>
<div class="workspace">
  {#if mobileNav}<button type="button" class="scrim" aria-label="Close navigation" onclick={() => mobileNav = false}></button>{/if}
  <aside class="sidebar" class:expanded={mobileNav} id="sidebar">
    <a href="/" class="brand" aria-label="Flash Help home"><span class="brand-mark"><Icon name="bolt" size={24} /></span><span>Flash<span class="brand-sub">Help & reference</span></span></a>
    <nav aria-label="Main navigation">
      {#each ["Explore", "Your Flash", "Inspect"] as group}
        <div class="nav-group"><div class="eyebrow">{group}</div>
          {#each sections.filter((candidate) => candidate.group === group) as item}
            <a href={item.href} class:active={route.page === item.id} aria-current={route.page === item.id ? "page" : undefined}><Icon name={item.id} /><span>{item.label}</span>{#if item.id === "plugins"}<span class="nav-count">{plugins.length}</span>{/if}{#if item.id === "docs" && freshCount}<span class="badge fresh nav-fresh" title="Guides new or updated since your last visit">{freshCount}</span>{/if}<kbd class="nav-key" aria-hidden="true">g {item.key}</kbd></a>
          {/each}
        </div>
      {/each}
    </nav>
    <div class="sidebar-footer"><span class="local-mark"><Icon name="shield" size={15} /> On your Mac</span><p>Documentation and live information,<br />directly from your running Flash.</p><a href={paths.docs("privacy")}>Privacy & permissions</a><button type="button" class="shortcut-hint" onclick={() => shortcuts = true}>Keyboard shortcuts <kbd>?</kbd></button></div>
  </aside>
  <div class="main-column">
    <header class="topbar">
      <button class="mobile-toggle" aria-label="Toggle navigation" aria-expanded={mobileNav} aria-controls="sidebar" onclick={() => mobileNav = !mobileNav}><Icon name="menu" /></button>
      {#if crumbs.length}<nav class="breadcrumb" aria-label="Breadcrumb"><ol>{#each crumbs as crumb, position}<li>{#if crumb.href && position < crumbs.length - 1}<a href={crumb.href}>{crumb.label}</a>{:else}<strong aria-current={position === crumbs.length - 1 ? "page" : undefined}>{crumb.label}</strong>{/if}</li>{/each}</ol></nav>{/if}
      <form class="searchbox" role="search" onsubmit={(event) => { event.preventDefault(); if (results[selectedResult]) router.navigate(results[selectedResult].href); }}><Icon name="search" size={16} /><input bind:this={searchInput} bind:value={search} oninput={onSearchInput} onkeydown={onSearchKey} type="search" aria-label="Search all documentation, commands, mappings and plugins" placeholder="Search anything…" /><kbd>/</kbd></form>
      <a href="/state" class="connection" class:connected={store.connected} aria-label={store.connected ? "Live connection to Flash" : connectionMessage} title={store.connected ? "Live connection to Flash" : connectionMessage}>{#if store.connected}<i></i>Live{:else}<Icon name="warning" size={18} />{/if}</a>
    </header>
    <span class="sr-only" role="status">{store.connected ? "Connected to Flash. Live information is current." : connectionMessage}</span>
    <main id="main-content" tabindex="-1" bind:this={content}>
      {#if route.page === "search"}
        <div class="page"><div class="page-heading"><p class="eyebrow">Across your Flash</p><h1>Search</h1><p aria-live="polite">{route.param ? `${results.length} ${results.length === 1 ? "result" : "results"} for “${route.param}”` : "Type a feature, command, key or plugin name. Every word must match."}</p></div>
          {#if route.param}<div class="search-results surface">
            {#each results as result, position}<a href={result.href} class:selected={position === selectedResult} onmouseenter={() => selectedResult = position}><span class="result-icon"><Icon name={result.icon} /></span><span><strong>{result.title}{#if result.section}<span class="result-section"> › {result.section}</span>{/if}</strong><span class="result-summary">{result.summary}</span></span><span class="badge neutral">{result.kind}</span><Icon name="arrow" size={16} /></a>{/each}
            {#if results.length === 0}<div class="empty"><strong>No matches</strong>Try fewer words, or a command name such as <code>mouse_target</code>.</div>{/if}
            {#if results.length >= 80}<p class="empty">Showing the first 80 matches. Add another word to narrow your search.</p>{/if}
          </div>{/if}
        </div>
      {:else if route.page === "home"}<HomePanel snapshot={store.state} connected={store.connected} />
      {:else if route.page === "docs"}<DocsPanel {docs} topic={route.param} loading={!loaded} version={store.state.runtime?.version} />
      {:else if route.page === "mappings"}<MappingsPanel {mappings} keyboard={store.state.keyboard} {commands} filter={route.param} />
      {:else if route.page === "commands"}<CommandsPanel {commands} filter={route.param} />
      {:else if route.page === "plugins"}<PluginsPanel {plugins} filter={route.param} sampledAt={store.state.snapshot_at_unix_ms} onresample={() => store.refresh()} />
      {:else if route.page === "state"}<RuntimePanel state={store.state} connected={store.connected} onrefresh={() => store.refresh()} />
      {:else if route.page === "logs"}<div class="page log-page"><div class="page-heading"><p class="eyebrow">Inspect</p><h1>Live logs</h1><p>Follow what Flash is doing. Select a record to inspect its full details.</p></div><div class="surface log-surface"><LogList logs={store.logs} /></div></div>
      {:else if route.page === "clipboard"}<ClipboardPanel entries={store.state.clipboard ?? []} registers={store.state.clipboard_registers ?? []} nextOffset={store.state.clipboard_next_offset ?? null} total={store.state.clipboard_total ?? 0} />
      {:else}<div class="page"><div class="page-heading"><p class="eyebrow">Flash Help</p><h1>Page not found</h1><p>This address is not part of Flash Help. Start from the homepage, browse the guides, or search above.</p></div><p class="not-found-links"><a href="/">Help homepage →</a><a href={paths.docs()}>All guides →</a></p></div>{/if}
    </main>
  </div>
  {#if shortcuts}
    <div class="sheet-backdrop" role="presentation" onclick={() => shortcuts = false}></div>
    <div class="sheet surface" role="dialog" aria-modal="true" aria-labelledby="shortcuts-title">
      <div class="sheet-head"><h2 id="shortcuts-title">Keyboard shortcuts</h2><button type="button" onclick={() => shortcuts = false}>Close</button></div>
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
        <dt><kbd>[</kbd></dt><dd>Previous guide</dd>
        <dt><kbd>]</kbd></dt><dd>Next guide</dd>
        {#each sections as item}<dt><kbd>g</kbd> <kbd>{item.key}</kbd></dt><dd>Go to {item.label}</dd>{/each}
        <dt><kbd>?</kbd></dt><dd>Show or hide this sheet</dd>
      </dl>
      <p class="muted">Shortcuts pause while you type in a field. Flash's own keys are on the <a href="/mappings">key mappings</a> page.</p>
    </div>
  {/if}
</div>

<style>
  .workspace { display: grid; grid-template-columns: 270px minmax(0, 1fr); height: 100dvh; }
  .sidebar { background: #f1f4ee; border-right: 1px solid var(--border); display: flex; flex-direction: column; padding: 29px 14px 22px; overflow: auto; }
  .brand { display: flex; align-items: center; gap: 10px; color: var(--text); font-size: 23px; font-weight: 650; line-height: 1.2; padding: 0 8px; text-decoration: none; }
  .brand-mark { display: grid; place-items: center; color: #eff6e7; background: #2e5b43; width: 38px; height: 43px; border-radius: 11px; }
  .brand-sub { display: block; font-size: 12px; font-weight: 400; color: var(--muted); margin-top: 4px; letter-spacing: .02em; }
  nav { margin-top: 36px; }
  .nav-group { margin-bottom: 24px; }
  .nav-group .eyebrow { padding: 0 12px; margin-bottom: 9px; font-size: 10px; }
  nav a { display: flex; align-items: center; gap: 8px; min-height: 42px; padding: 9px; margin: 3px 0; border-radius: 7px; color: #4f5c52; font-size: 13px; font-weight: 500; text-decoration: none; white-space: nowrap; }
  nav a > span:nth-child(2) { min-width: 0; }
  nav a:hover { background: #e7ede1; }
  nav a.active { background: #e0e9d8; color: #244f38; font-weight: 600; }
  .nav-count { margin-left: auto; font-size: 11px; opacity: .8; }
  .nav-fresh { margin-left: auto; }
  .nav-key { display: none; flex: none; margin-left: auto; font-size: 10px; padding: 0 4px; opacity: .6; }
  nav a:hover .nav-key, nav a:focus-visible .nav-key { display: inline-block; }
  nav a:hover .nav-count, nav a:hover .nav-fresh { display: none; }
  .sidebar-footer { margin-top: auto; padding: 20px 10px 0; border-top: 1px solid var(--border); font-size: 12px; color: var(--muted); }
  .local-mark { display: flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 600; color: #3f4f42; }
  .sidebar-footer p { margin: 8px 0 12px; line-height: 1.6; }
  .sidebar-footer a { display: flex; min-height: 32px; align-items: center; }
  .shortcut-hint { display: flex; align-items: center; gap: 8px; width: 100%; justify-content: space-between; border: 0; background: none; padding: 6px 0; min-height: 32px; color: var(--accent); font-size: 12px; }
  .shortcut-hint:hover { background: none; text-decoration: underline; }
  .main-column { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
  .topbar { min-height: 72px; display: flex; align-items: center; gap: 24px; padding: 15px 40px; border-bottom: 1px solid var(--border); background: #ffffffc9; }
  .breadcrumb { min-width: 0; font-size: 13px; color: var(--muted); }
  .breadcrumb ol { display: flex; align-items: center; gap: 8px; list-style: none; margin: 0; padding: 0; white-space: nowrap; overflow: hidden; }
  .breadcrumb li { display: flex; align-items: center; gap: 8px; min-width: 0; }
  .breadcrumb li + li::before { content: "›"; color: #9aa69b; }
  .breadcrumb a { color: var(--muted); min-height: 32px; display: inline-flex; align-items: center; }
  .breadcrumb strong { font-weight: 500; color: var(--text); overflow: hidden; text-overflow: ellipsis; }
  .searchbox { margin-left: auto; display: flex; align-items: center; gap: 8px; width: min(320px, 34vw); border: 1px solid var(--border); border-radius: 7px; padding: 0 10px; color: var(--muted); background: #f8faf6; }
  .searchbox input { border: 0; background: none; width: 100%; min-height: 38px; padding: 4px 0; font-size: 14px; outline-offset: 0; }
  .searchbox kbd { font-size: 10px; padding: 0 5px; color: var(--muted); }
  .connection { display: flex; align-items: center; justify-content: center; gap: 6px; color: #996e2c; background: #fff5dc; border-radius: 8px; font-size: 12px; white-space: nowrap; min-width: 32px; min-height: 32px; }
  .connection.connected { color: var(--muted); background: none; }
  .connection i { width: 6px; height: 6px; border-radius: 50%; background: #c99c55; }
  .connection.connected i { background: #5c9662; box-shadow: 0 0 0 3px #e9f1e4; }
  main { flex: 1; overflow: auto; min-height: 0; display: flex; flex-direction: column; }
  main:focus { outline: none; }
  main > :global(*) { flex: none; }
  .mobile-toggle { display: none; padding: 6px; min-width: 40px; }
  .scrim { display: none; }
  .search-results { overflow: hidden; }
  .search-results a { display: flex; align-items: center; gap: 16px; padding: 15px 20px; border-bottom: 1px solid var(--border-soft); color: var(--text); text-decoration: none; min-height: 44px; }
  .search-results a:hover, .search-results a.selected { background: #f5f8f0; }
  .search-results a.selected { box-shadow: inset 3px 0 0 var(--accent); }
  .result-icon { display: grid; place-items: center; width: 34px; height: 34px; border-radius: 8px; background: var(--accent-soft); color: var(--accent); flex-shrink: 0; }
  .search-results a > span:nth-child(2) { flex: 1; min-width: 0; }
  .result-section { font-weight: 400; color: var(--muted); }
  .result-summary { display: block; font-size: 13px; color: var(--muted); overflow: hidden; white-space: nowrap; text-overflow: ellipsis; margin-top: 3px; }
  /* Percentage height does not resolve against main's flex size, so this page
     grows as a flex child and the record list fills the space under the heading. */
  .log-page { flex: 1 1 auto; width: 100%; min-width: 0; min-height: 0; display: flex; flex-direction: column; overflow: hidden; padding-bottom: 16px; }
  .log-surface { flex: 1; min-width: 0; min-height: 0; overflow: hidden; display: flex; flex-direction: column; }
  .skip-link { position: fixed; top: -100px; left: 12px; z-index: 100; background: #fff; border: 1px solid var(--border); padding: 10px; }
  .skip-link:focus { top: 12px; }
  .sheet-backdrop { position: fixed; inset: 0; background: #1f2a2166; z-index: 20; }
  .sheet { position: fixed; z-index: 21; top: 50%; left: 50%; transform: translate(-50%, -50%); width: min(600px, calc(100vw - 32px)); max-height: calc(100dvh - 32px); overflow: auto; padding: 22px 24px; box-shadow: 0 20px 60px #1f2a2133; }
  .sheet-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-bottom: 14px; }
  .sheet h2 { font-size: 18px; }
  .sheet h3 { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .1em; margin: 16px 0 8px; }
  .sheet dl { display: grid; grid-template-columns: 94px minmax(0, 1fr); gap: 4px 18px; margin: 0; font-size: 14px; }
  .sheet dt { white-space: nowrap; }
  .sheet dt, .sheet dd { display: flex; align-items: center; min-height: 32px; }
  .sheet dd { margin: 0; color: var(--muted); }
  .sheet p { margin-top: 16px; font-size: 13px; }
  @media (max-width: 1150px) { .topbar { padding: 14px 24px; gap: 16px; } }
  @media (max-width: 850px) { .breadcrumb li:not(:nth-last-child(-n+2)) { display: none; } .breadcrumb li:nth-last-child(2)::before { content: "…"; } .topbar { gap: 14px; } .searchbox { width: min(260px, 35vw); } }
  .not-found-links { display: flex; gap: 24px; font-size: 14px; }
  @media (max-width: 700px) {
    .workspace { grid-template-columns: minmax(0, 1fr); }
    .sidebar { display: none; }
    .sidebar.expanded { display: flex; position: fixed; inset: 0 auto 0 0; width: min(300px, 86vw); z-index: 31; box-shadow: 15px 0 40px #26342140; padding-top: 20px; }
    .scrim { display: block; position: fixed; inset: 0; z-index: 30; background: #1f2a2166; border: 0; border-radius: 0; padding: 0; min-height: 0; }
    .mobile-toggle { display: flex; }
    .topbar { min-height: 64px; padding: 12px 16px; gap: 10px; }
    .breadcrumb li:not(:last-child) { display: none; }
    .breadcrumb li:last-child::before { content: none; }
    .searchbox { width: auto; flex: 1; }
    .searchbox kbd { display: none; }
    .connection { font-size: 11px; }
    .sheet dl { grid-template-columns: 80px minmax(0, 1fr); gap: 4px 8px; font-size: 13px; }
  }
  @media print {
    .workspace, .main-column, main, .log-page { display: block; height: auto; overflow: visible; }
    .sidebar, .topbar, .skip-link, .sheet, .sheet-backdrop, .scrim { display: none !important; }
    .search-results, .log-surface { overflow: visible; min-height: 0; border: 0; }
    .search-results a { break-inside: avoid; padding: 10px 0; }
  }
</style>
