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
  import LivePageHeader from "./lib/LivePageHeader.svelte";
  import LogList from "./lib/LogList.svelte";
  import MappingsPanel from "./lib/MappingsPanel.svelte";
  import { monitorCounts } from "./lib/monitors";
  import MonitorsPanel from "./lib/MonitorsPanel.svelte";
  import { markGuideRead } from "./lib/onboarding";
  import PluginsPanel from "./lib/PluginsPanel.svelte";
  import { freshness, loadSeen } from "./lib/reading";
  import RuntimePanel from "./lib/RuntimePanel.svelte";
  import TelemetryPanel from "./lib/TelemetryPanel.svelte";
  import { configToast, doneToast, failedToast } from "./lib/toast";
  import { toasts } from "./lib/toasts.svelte";
  import { router } from "./lib/router.svelte";
  import { paths } from "./lib/routes";
  import { buildIndex } from "./lib/search";
  import { sharedCrumbs, type Crumb, type Section } from "./lib/shell";
  import { store } from "./lib/store.svelte";
  import Shell from "./Shell.svelte";

  /**
   * The resident's help: the manual and the plugins' guides beside the live
   * pages, which read Flash's state from its stream.
   */
  const sections: Section[] = [
    { id: "home", href: "/", label: "Home", group: "Explore", key: "h" },
    { id: "docs", href: paths.docs(), label: "Documentation", group: "Explore", key: "d" },
    {
      id: "mappings",
      href: paths.mappings(),
      label: "Key mappings",
      group: "Your Flash",
      key: "m",
    },
    { id: "commands", href: paths.commands(), label: "Commands", group: "Your Flash", key: "c" },
    { id: "plugins", href: paths.plugins(), label: "Plugins", group: "Your Flash", key: "p" },
    { id: "state", href: "/state", label: "Runtime & config", group: "Inspect", key: "r" },
    { id: "monitors", href: "/monitors", label: "Monitors", group: "Inspect", key: "o" },
    { id: "telemetry", href: "/telemetry", label: "Telemetry", group: "Inspect", key: "t" },
    { id: "logs", href: "/logs", label: "Live logs", group: "Inspect", key: "l" },
    { id: "clipboard", href: "/clipboard", label: "Clipboard", group: "Inspect", key: "b" },
  ];
  const route = $derived(router.route);
  let content = $state<HTMLElement>();
  const docs = $derived(store.state.docs ?? []);
  const plugins = $derived(store.state.plugins ?? []);
  const commands = $derived(store.state.commands ?? []);
  const mappings = $derived(store.state.mappings ?? { normal_leader: "", rows: [] });
  const loaded = $derived(store.state.snapshot_at_unix_ms != null);
  const monitorAlarm = $derived.by(() => {
    const counts = monitorCounts(store.state.monitors ?? []);
    return counts.error
      ? { count: counts.error, state: "error" }
      : counts.warning
        ? { count: counts.warning, state: "warning" }
        : null;
  });
  const manual = $derived(docsStore.manual);
  const currentPage = $derived(route.page === "docs" ? manual?.page(route.param) : undefined);
  /** A plugin's guide, at a docs path the manual leaves free. */
  const currentGuide = $derived(
    route.page === "docs" && manual && !currentPage
      ? docs.find((doc) => doc.name === route.param)
      : undefined,
  );
  const section = $derived(sections.find((candidate) => candidate.id === route.page));
  const hasFresh = $derived(freshness(docsStore.readable(docs), loadSeen()).size > 0);
  // How long the page has been without its stream; the clock ticks only then.
  const offlineFor = $derived(store.connected ? 0 : now() - store.offlineSince);
  // A first connection gets a moment before the page calls Flash unreachable.
  const offline = $derived(!store.connected && (store.everConnected || offlineFor > 2500));
  const snapshotAt = $derived(store.state.snapshot_at_unix_ms);
  const connectionMessage = $derived(
    snapshotAt
      ? `Connection to Flash lost. Showing the snapshot from ${clockTime(snapshotAt)}; it may be stale. Reconnecting automatically.`
      : "Connecting to Flash. Live information will appear when the resident app is available.",
  );
  /** The path shown in the top bar. */
  const crumbs = $derived.by((): Crumb[] => {
    if (route.page === "home") return [];
    const shared = sharedCrumbs(route, currentPage, currentGuide);
    if (shared) return shared;
    const list: Crumb[] = [{ label: section?.label ?? route.page, href: section?.href }];
    if (route.page === "plugins" && route.param) {
      list.push({
        label: plugins.find((plugin) => plugin.id === route.param)?.name ?? route.param,
      });
    } else if ((route.page === "mappings" || route.page === "commands") && route.param) {
      list.push({ label: `“${route.param}”` });
    }
    return list;
  });
  const current = $derived(crumbs[crumbs.length - 1]?.label ?? "Flash");
  const title = $derived(route.page === "home" ? "Flash" : `${current} · Flash`);
  const index = $derived(
    buildIndex(
      docs,
      commands,
      mappings.effective_rows ?? mappings.rows,
      plugins,
      docsStore.sections ?? [],
    ),
  );

  // Runs once: nothing it reads may restart the stream.
  $effect(() =>
    untrack(() => {
      store.start();
      // A live page needs the manual only for the sidebar's reading marks:
      // it loads once the page is idle, or as soon as a manual page or a
      // search asks for it (below).
      if (router.route.page !== "docs" && router.route.page !== "search") docsStore.loadWhenIdle();
      return () => store.stop();
    }),
  );
  $effect(() => {
    if (route.page === "docs" || route.page === "search") void docsStore.load();
  });
  // Configuration diagnostics that appear, change or clear while the page is
  // open reach the reader on any page; the runtime page lists them in full.
  let configShown: string | null | undefined;
  $effect(() => {
    const runtime = store.state.runtime;
    if (!runtime) return;
    const error = runtime.config_error ?? null;
    untrack(() => {
      const options = configToast(configShown, error, () => {
        if (router.route.page === "state") content?.scrollTo({ top: 0 });
        else router.navigate("/state");
      });
      configShown = error;
      if (options) toasts.show(options);
    });
  });
  // A manual that failed to load retries once Flash answers again.
  $effect(() => {
    if (store.connected && docsStore.error) void docsStore.load();
  });
  // The plugins' guides arrive with the snapshot, after the first render;
  // reveal a linked heading once it renders.
  $effect(() => {
    void docs;
    void tick().then(() => router.revealAnchor());
  });
  // The home page's checklist counts the guides this browser has opened.
  $effect(() => {
    if (currentPage) markGuideRead(currentPage.path);
  });

  /** The runtime page's Refresh says how it went. */
  async function refresh() {
    await store.refresh();
    toasts.show(
      store.refreshError
        ? failedToast("refresh", `${store.refreshError} The page keeps the last snapshot.`)
        : doneToast("refresh", "Refreshed: the page shows Flash's latest snapshot."),
    );
  }
</script>

<svelte:head>
  <title>{title}</title>
</svelte:head>

{#snippet badge(item: Section)}{#if item.id === "plugins"}<span class="nav-count"
      >{plugins.length}</span
    >{/if}{#if item.id === "monitors" && monitorAlarm}<span
      class="nav-alarm nav-alarm-{monitorAlarm.state}"
      title="{monitorAlarm.count} {monitorAlarm.state === 'error' ? 'in error' : 'warning'}"
      >{monitorAlarm.count}</span
    >{/if}{#if item.id === "docs" && hasFresh}<span class="nav-fresh"
      ><FreshMark state="new" label="New or updated pages since your last visit" /></span
    >{/if}{/snippet}

{#snippet status()}<a
    href="/state"
    class="connection"
    class:connected={store.connected}
    class:offline
    aria-label={store.connected ? "Live connection to Flash" : connectionMessage}
    title={store.connected ? "Live connection to Flash" : connectionMessage}
    >{#if store.connected}<i></i>Live{:else}<Icon name="warning" size={16} /><span
        >{offline ? "Offline" : "Connecting"}</span
      >{/if}</a
  >{/snippet}

{#snippet banner()}<span class="sr-only" role="status"
    >{store.connected
      ? "Connected to Flash. Live information is current."
      : connectionMessage}</span
  >
  {#if offline}
    <div class="offline-banner" role="alert">
      <Icon name="warning" size={18} />
      <div>
        {#if store.everConnected && snapshotAt}<strong
            >Flash stopped answering {ago(store.offlineSince, now())}.</strong
          >
          Everything below is the snapshot from {clockTime(snapshotAt)} and may be stale.
        {:else if snapshotAt}<strong>Flash is not answering.</strong> Everything below is the
          snapshot from {clockTime(snapshotAt)} and may be stale.
        {:else}<strong>Flash is not answering.</strong> No live information yet.{/if}
        <span class="offline-hint"
          >If Flash quit or restarted, reopen help with <kbd>?</kbd> in NORMAL or
          <code>:help</code>. This page reconnects by itself.</span
        >
      </div>
      <button type="button" onclick={() => store.reconnect()}
        ><Icon name="refresh" size={14} /> Reconnect now</button
      >
    </div>
  {/if}{/snippet}

{#snippet page()}{#if route.page === "home"}<HomePanel
      snapshot={store.state}
      connected={store.connected}
    />
  {:else if route.page === "docs"}<DocsPanel param={route.param} {docs} />
  {:else if route.page === "mappings"}<MappingsPanel
      {mappings}
      keyboard={store.state.keyboard}
      {commands}
      filter={route.param}
    />
  {:else if route.page === "commands"}<CommandsPanel
      {commands}
      rows={mappings.effective_rows ?? mappings.rows}
      filter={route.param}
    />
  {:else if route.page === "plugins"}<PluginsPanel
      {plugins}
      {commands}
      filter={route.param}
      sampledAt={store.state.snapshot_at_unix_ms}
      onresample={() => store.refresh()}
    />
  {:else if route.page === "state"}<RuntimePanel
      state={store.state}
      connected={store.connected}
      onrefresh={refresh}
    />
  {:else if route.page === "monitors"}<MonitorsPanel monitors={store.state.monitors} {loaded} />
  {:else if route.page === "telemetry"}<TelemetryPanel telemetry={store.state.telemetry} {loaded} />
  {:else if route.page === "logs"}<div class="page log-page"
      ><LivePageHeader
        id="logs"
        title="Live logs"
        purpose="What Flash and its plugins are doing, newest last."
        manual={paths.docs("troubleshooting")}
        >{#snippet help()}<p
            >Flash streams structured diagnostics here as they happen. Filter by level or source,
            search messages and fields, and select a record to read or copy it as JSON. The tail
            follows new records until you scroll up or pause it.</p
          >{/snippet}</LivePageHeader
      ><div class="surface log-surface"><LogList logs={store.logs} /></div></div
    >
  {:else if route.page === "clipboard"}<ClipboardPanel
      entries={store.state.clipboard ?? []}
      registers={store.state.clipboard_registers ?? []}
      nextOffset={store.state.clipboard_next_offset ?? null}
      total={store.state.clipboard_total ?? 0}
    />{/if}{/snippet}

{#snippet shortcutNotes()}
  <h3>Clipboard history</h3>
  <dl>
    <dt><kbd>j</kbd> <kbd>k</kbd></dt><dd>Next or previous entry</dd>
    <dt><kbd>↩</kbd></dt><dd>Copy the selected entry</dd>
    <dt><kbd>space</kbd></dt><dd>Expand or collapse it</dd>
    <dt><kbd>⌫</kbd></dt><dd>Delete it from history</dd>
  </dl>
  <p class="muted"
    >Shortcuts pause while you type in a field. Flash's own keys are on the <a
      href={paths.mappings()}>key mappings</a
    > page.</p
  >
{/snippet}

<Shell
  {sections}
  home={{ href: "/", label: "Flash help home" }}
  {crumbs}
  {index}
  searchLabel="Search all documentation, commands, mappings and plugins"
  searchPlaceholder="Search anything…"
  searchHint="Type a feature, command, key or plugin name. Every word must match."
  lost="This address is not part of Flash's help. Start from its home page, browse the documentation, or search above."
  host={{ icon: "shield", label: "Served by Flash on this Mac" }}
  version={store.state.runtime?.version}
  {badge}
  {status}
  {banner}
  {page}
  {shortcutNotes}
  bind:content
/>

<style>
  .nav-count {
    margin-left: auto;
    font: 12px var(--mono);
    color: var(--faint);
  }
  .nav-alarm {
    margin-left: auto;
    min-width: 20px;
    padding: 0 6px;
    border-radius: 9px;
    font: 600 12px/18px var(--mono);
    text-align: center;
  }
  .nav-alarm-error {
    color: var(--danger);
    background: var(--danger-soft);
    box-shadow: inset 0 0 0 1px rgba(229, 115, 94, 0.4);
  }
  .nav-alarm-warning {
    color: var(--amber);
    background: var(--amber-soft);
    box-shadow: inset 0 0 0 1px rgba(227, 165, 63, 0.4);
  }
  .nav-fresh {
    margin-left: auto;
  }
  /* The shell shows a link's shortcut in the badge's place while it is pointed at. */
  :global(.sidebar nav a:hover) .nav-count,
  :global(.sidebar nav a:hover) .nav-fresh,
  :global(.sidebar nav a:hover) .nav-alarm {
    display: none;
  }
  .offline-banner {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 32px;
    border-bottom: 1px solid rgba(229, 115, 94, 0.35);
    background: #1f1617;
    color: var(--text);
    font-size: 13px;
  }
  .offline-banner > :global(svg) {
    flex: none;
    color: var(--danger);
  }
  .offline-banner strong {
    color: var(--danger);
    font-weight: 600;
  }
  .offline-banner > div {
    flex: 1;
    min-width: 0;
  }
  .offline-hint {
    display: block;
    color: var(--muted);
    margin-top: 2px;
  }
  .offline-banner button {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    flex: none;
    min-height: 32px;
    font-size: 12px;
  }
  /* Percentage height does not resolve against main's flex size, so this page
     grows as a flex child and the record list fills the space under the heading. */
  .log-page {
    flex: 1 1 auto;
    width: 100%;
    min-width: 0;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    padding-bottom: 16px;
  }
  .log-surface {
    flex: 1;
    min-width: 0;
    min-height: 0;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
  @media (max-width: 1150px) {
    .offline-banner {
      padding: 10px 22px;
    }
  }
  @media (max-width: 700px) {
    .offline-banner {
      padding: 10px 14px;
      flex-wrap: wrap;
    }
  }
  @media print {
    .log-page {
      display: block;
      height: auto;
      overflow: visible;
    }
    .offline-banner {
      display: none !important;
    }
    .log-surface {
      overflow: visible;
      min-height: 0;
      border: 0;
    }
  }
</style>
