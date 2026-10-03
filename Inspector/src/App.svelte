<script lang="ts">
  import { tick } from "svelte";
  import ClipboardPanel from "./lib/ClipboardPanel.svelte";
  import CommandsPanel from "./lib/CommandsPanel.svelte";
  import DocsPanel from "./lib/DocsPanel.svelte";
  import HomePanel from "./lib/HomePanel.svelte";
  import Icon from "./lib/Icon.svelte";
  import LogList from "./lib/LogList.svelte";
  import MappingsPanel from "./lib/MappingsPanel.svelte";
  import PluginsPanel from "./lib/PluginsPanel.svelte";
  import RuntimePanel from "./lib/RuntimePanel.svelte";
  import { router } from "./lib/router.svelte";
  import { paths } from "./lib/routes";
  import { store } from "./lib/store.svelte";

  const sections = [
    { id: "home", href: "/", label: "Home", group: "Explore" },
    { id: "docs", href: paths.docs(), label: "Documentation", group: "Explore" },
    { id: "mappings", href: paths.mappings(), label: "Key mappings", group: "Your Flash" },
    { id: "commands", href: paths.commands(), label: "Commands", group: "Your Flash" },
    { id: "plugins", href: paths.plugins(), label: "Plugins", group: "Your Flash" },
    { id: "state", href: "/state", label: "Runtime & config", group: "Inspect" },
    { id: "logs", href: "/logs", label: "Live logs", group: "Inspect" },
    { id: "clipboard", href: "/clipboard", label: "Clipboard", group: "Inspect" },
  ];
  const route = $derived(router.route);
  let search = $state("");
  let searchInput = $state<HTMLInputElement>();
  let mobileNav = $state(false);
  let content = $state<HTMLElement>();
  const current = $derived(sections.find((section) => section.id === route.page)?.label ?? "Page not found");
  const docs = $derived(store.state.docs ?? []);
  const plugins = $derived(store.state.plugins ?? []);
  const commands = $derived(store.state.commands ?? []);
  const mappings = $derived(store.state.mappings ?? { normal_leader: "", rows: [] });
  const results = $derived.by(() => {
    const q = search.trim().toLowerCase();
    if (!q) return [];
    const matches = (text: string) => text.toLowerCase().includes(q);
    const matchesFound = [
      ...docs.filter((doc) => matches([doc.title, doc.name, doc.summary, doc.body, ...(doc.aliases ?? [])].join(" "))).map((doc) => ({ title: doc.title, summary: doc.summary, kind: "Guide", icon: "docs", href: paths.docs(doc.name) })),
      ...commands.filter((command) => matches([command.name, command.syntax, command.description, ...(command.aliases ?? [])].join(" "))).map((command) => ({ title: command.name, summary: command.description ?? command.source, kind: "Command", icon: "commands", href: paths.commands(command.name) })),
      ...(mappings.effective_rows ?? mappings.rows).filter((row) => matches(row.key + " " + row.action)).map((row) => ({ title: row.key, summary: row.action, kind: "Mapping", icon: "mappings", href: paths.mappings(row.key) })),
      ...plugins.filter((plugin) => matches([plugin.id, plugin.name, plugin.description].join(" "))).map((plugin) => ({ title: plugin.name || plugin.id, summary: plugin.description ?? plugin.state, kind: "Plugin", icon: "plugins", href: paths.plugins(plugin.id) })),
    ];
    const rank = (title: string) => {
      const name = title.toLowerCase().replace(/^:/, "");
      const needle = q.replace(/^:/, "");
      return name === needle ? 0 : name.startsWith(needle) ? 1 : name.includes(needle) ? 2 : 3;
    };
    return matchesFound.sort((a, b) => rank(a.title) - rank(b.title));
  });

  $effect(() => {
    store.start();
    const stopRouter = router.start(content!, () => { search = ""; mobileNav = false; });
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault(); searchInput?.focus();
      }
      if (event.key === "Escape") { search = ""; mobileNav = false; searchInput?.blur(); }
    };
    window.addEventListener("keydown", onKey);
    return () => { window.removeEventListener("keydown", onKey); stopRouter(); store.stop(); };
  });
  // Guides arrive with the first snapshot; reveal a linked heading once it renders.
  $effect(() => { void docs; void tick().then(() => router.revealAnchor()); });
  $effect(() => { document.title = `${current} · Flash Help`; });
</script>

<a class="skip-link" href="#main-content" onclick={(event) => { event.preventDefault(); content?.focus(); }}>Skip to content</a>
<div class="workspace">
  <aside class="sidebar" class:expanded={mobileNav}>
    <a href="/" class="brand" aria-label="Flash Help home"><span class="brand-mark"><Icon name="bolt" size={24} /></span><span>Flash<span class="brand-sub">Help & reference</span></span></a>
    <nav aria-label="Main navigation">
      {#each ["Explore", "Your Flash", "Inspect"] as group}
        <div class="nav-group"><div class="eyebrow">{group}</div>
          {#each sections.filter((section) => section.group === group) as section}
            <a href={section.href} class:active={route.page === section.id} aria-current={route.page === section.id ? "page" : undefined}><Icon name={section.id} /><span>{section.label}</span>{#if section.id === "plugins"}<span class="nav-count">{plugins.length}</span>{/if}</a>
          {/each}
        </div>
      {/each}
    </nav>
    <div class="sidebar-footer"><span class="local-mark"><Icon name="shield" size={15} /> On your Mac</span><p>Documentation and live information,<br />directly from your running Flash.</p><a href={paths.docs("privacy")}>Privacy & permissions <span>↗</span></a></div>
  </aside>
  <div class="main-column">
    <header class="topbar">
      <button class="mobile-toggle" aria-label="Toggle navigation" aria-expanded={mobileNav} onclick={() => mobileNav = !mobileNav}><Icon name="menu" /></button>
      <div class="breadcrumb"><span>Flash Help</span><Icon name="chevron" size={12} /><strong>{current}</strong></div>
      <div class="searchbox"><Icon name="search" size={16} /><input bind:this={searchInput} bind:value={search} type="search" aria-label="Search all documentation, commands, mappings and plugins" placeholder="Search anything…" /><kbd>⌘ K</kbd></div>
      <a href="/state" class="connection" class:connected={store.connected}><i></i>{store.connected ? "Live" : "Reconnecting"}</a>
    </header>
    {#if !store.connected}<div class="connection-note" role="status">{store.state.snapshot_at_unix_ms ? "Connection interrupted. Showing the last received snapshot; reconnecting automatically." : "Connecting to Flash. Live information will appear when the resident app is available."}</div>{/if}
    <main id="main-content" tabindex="-1" bind:this={content}>
      {#if search.trim()}
        <div class="page"><div class="page-heading"><p class="eyebrow">Across your Flash</p><h1>Search results</h1><p>{results.length} results for “{search}”</p></div><div class="search-results surface">
          {#each results.slice(0, 80) as result}<a href={result.href}><span class="result-icon"><Icon name={result.icon} /></span><span><strong>{result.title}</strong><span class="result-summary">{result.summary}</span></span><span class="badge neutral">{result.kind}</span><Icon name="arrow" size={16} /></a>{/each}
          {#if results.length === 0}<div class="empty"><strong>No matches yet</strong>Try a feature, command, key, or plugin name.</div>{/if}
          {#if results.length > 80}<p class="empty">Showing the first 80 matches. Add another word to narrow your search.</p>{/if}
        </div></div>
      {:else if route.page === "home"}<HomePanel state={store.state} connected={store.connected} />
      {:else if route.page === "docs"}<DocsPanel {docs} topic={route.param} />
      {:else if route.page === "mappings"}<MappingsPanel {mappings} filter={route.param} />
      {:else if route.page === "commands"}<CommandsPanel {commands} filter={route.param} />
      {:else if route.page === "plugins"}<PluginsPanel {plugins} filter={route.param} sampledAt={store.state.snapshot_at_unix_ms} onresample={() => store.refresh()} />
      {:else if route.page === "state"}<RuntimePanel state={store.state} connected={store.connected} onrefresh={() => store.refresh()} />
      {:else if route.page === "logs"}<div class="page log-page"><div class="page-heading"><p class="eyebrow">Inspect</p><h1>Live logs</h1><p>Follow what Flash is doing. Select a record to inspect its full details.</p></div><div class="surface log-surface"><LogList logs={store.logs} /></div></div>
      {:else if route.page === "clipboard"}<ClipboardPanel entries={store.state.clipboard ?? []} />
      {:else}<div class="page"><div class="page-heading"><p class="eyebrow">Flash Help</p><h1>Page not found</h1><p>This address is not part of Flash Help. Start from the homepage, browse the guides, or search above.</p></div><p class="not-found-links"><a href="/">Help homepage →</a><a href={paths.docs()}>All guides →</a></p></div>{/if}
    </main>
  </div>
</div>

<style>
  .workspace { display: grid; grid-template-columns: 224px minmax(0, 1fr); height: 100dvh; }
  .sidebar { background: #f1f4ee; border-right: 1px solid var(--border); display: flex; flex-direction: column; padding: 29px 18px 22px; overflow: auto; }
  .brand { display: flex; align-items: center; gap: 10px; color: var(--text); font-size: 23px; font-weight: 650; line-height: 1.2; padding: 0 8px; text-decoration: none; }
  .brand-mark { display: grid; place-items: center; color: #eff6e7; background: #2e5b43; width: 38px; height: 43px; border-radius: 11px; }
  .brand-sub { display: block; font-size: 11px; font-weight: 400; color: var(--muted); margin-top: 4px; letter-spacing: .02em; }
  nav { margin-top: 36px; }
  .nav-group { margin-bottom: 27px; }
  .nav-group .eyebrow { padding: 0 12px; margin-bottom: 9px; font-size: 9px; }
  nav a { display: flex; align-items: center; gap: 11px; min-height: 41px; padding: 9px 12px; margin: 3px 0; border-radius: 7px; color: #59665c; font-size: 12px; font-weight: 500; text-decoration: none; }
  nav a:hover { background: #e7ede1; }
  nav a.active { background: #e0e9d8; color: #244f38; font-weight: 600; }
  .nav-count { margin-left: auto; font-size: 10px; opacity: .7; }
  .sidebar-footer { margin-top: auto; padding: 20px 10px 0; border-top: 1px solid var(--border); font-size: 10px; color: var(--muted); }
  .local-mark { display: flex; align-items: center; gap: 6px; font-size: 11px; font-weight: 600; color: #4d5e4f; }
  .sidebar-footer p { margin: 8px 0 12px; line-height: 1.7; }
  .sidebar-footer a { display: flex; justify-content: space-between; }
  .main-column { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
  .topbar { min-height: 72px; display: flex; align-items: center; gap: 24px; padding: 15px 40px; border-bottom: 1px solid var(--border); background: #ffffffc9; }
  .breadcrumb { display: flex; align-items: center; gap: 9px; font-size: 11px; white-space: nowrap; color: var(--muted); }
  .breadcrumb strong { font-weight: 500; color: var(--text); }
  .searchbox { margin-left: auto; display: flex; align-items: center; gap: 8px; width: min(300px, 34vw); border: 1px solid var(--border); border-radius: 7px; padding: 0 10px; color: var(--muted); background: #f8faf6; }
  .searchbox input { border: 0; background: none; width: 100%; min-height: 34px; padding: 4px 0; font-size: 12px; outline-offset: 0; }
  .searchbox kbd { font-size: 9px; padding: 0 4px; color: var(--muted); }
  .connection { display: flex; align-items: center; gap: 6px; color: var(--muted); font-size: 11px; white-space: nowrap; }
  .connection i { width: 6px; height: 6px; border-radius: 50%; background: #c99c55; }
  .connection.connected i { background: #5c9662; box-shadow: 0 0 0 3px #e9f1e4; }
  .connection-note { padding: 8px 24px; font-size: 11px; color: #78642c; background: #fff9e6; border-bottom: 1px solid #e7ddba; }
  main { flex: 1; overflow: auto; min-height: 0; }
  .mobile-toggle { display: none; padding: 6px; }
  .search-results { overflow: hidden; }
  .search-results a { display: flex; align-items: center; gap: 16px; padding: 17px 20px; border-bottom: 1px solid var(--border-soft); color: var(--text); text-decoration: none; }
  .search-results a:hover { background: #f5f8f0; }
  .result-icon { display: grid; place-items: center; width: 34px; height: 34px; border-radius: 8px; background: var(--accent-soft); color: var(--accent); flex-shrink: 0; }
  .search-results a > span:nth-child(2) { flex: 1; min-width: 0; }
  .result-summary { display: block; font-size: 12px; color: var(--muted); overflow: hidden; white-space: nowrap; text-overflow: ellipsis; margin-top: 3px; }
  .log-page { height: 100%; display: flex; flex-direction: column; }
  .log-surface { flex: 1; min-height: 320px; overflow: hidden; }
  .skip-link { position: fixed; top: -100px; left: 12px; z-index: 100; background: #fff; border: 1px solid var(--border); padding: 10px; }
  .skip-link:focus { top: 12px; }
  @media (max-width: 1150px) { .topbar { padding: 14px 24px; gap: 16px; } .workspace { grid-template-columns: 205px minmax(0, 1fr); } }
  @media (max-width: 850px) { .breadcrumb > span, .breadcrumb :global(svg) { display: none; } .topbar { gap: 14px; } .searchbox { width: min(260px, 35vw); } }
  .not-found-links { display: flex; gap: 24px; font-size: 13px; }
  @media (max-width: 700px) { .workspace { grid-template-columns: minmax(0, 1fr); } .sidebar { display: none; } .sidebar.expanded { display: flex; position: fixed; top: 64px; bottom: 0; left: 0; width: 235px; z-index: 5; box-shadow: 15px 0 40px #26342125; } .sidebar.expanded .brand { display: none; } .sidebar.expanded nav { margin-top: 0; } .mobile-toggle { display: flex; } .topbar { min-height: 64px; padding: 12px 18px; gap: 10px; } .breadcrumb { display: none; } .searchbox { width: auto; flex: 1; } .searchbox kbd { display: none; } .connection { font-size: 10px; } }
  @media print {
    .workspace, .main-column, main, .log-page { display: block; height: auto; overflow: visible; }
    .sidebar, .topbar, .connection-note, .skip-link { display: none !important; }
    .search-results, .log-surface { overflow: visible; min-height: 0; border: 0; }
    .search-results a { break-inside: avoid; padding: 10px 0; }
  }
</style>
