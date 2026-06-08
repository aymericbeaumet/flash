<script lang="ts">
  import CommandsPanel from "./lib/CommandsPanel.svelte";
  import LogList from "./lib/LogList.svelte";
  import PluginsPanel from "./lib/PluginsPanel.svelte";
  import { store } from "./lib/store.svelte";

  type Tab = "logs" | "plugins" | "commands" | "state";
  let tab = $state<Tab>("logs");

  $effect(() => {
    store.start();
    return () => store.stop();
  });

  const plugins = $derived(store.state.plugins ?? []);
  const commands = $derived(store.state.commands ?? []);
  const focused = $derived(store.state.focused_app);

  const tabs: { id: Tab; label: string }[] = [
    { id: "logs", label: "Logs" },
    { id: "plugins", label: "Plugins" },
    { id: "commands", label: "Commands" },
    { id: "state", label: "State" },
  ];

  const stateSummary = $derived(
    JSON.stringify(
      {
        mode: store.state.mode,
        overlay: store.state.overlay,
        focused_app: focused,
      },
      null,
      2,
    ),
  );
  const configJSON = $derived(JSON.stringify(store.state.config ?? {}, null, 2));
</script>

<header>
  <strong class="brand">Flash Inspector</strong>
  <nav>
    {#each tabs as t}
      <button class:active={tab === t.id} onclick={() => (tab = t.id)}>
        {t.label}
        {#if t.id === "plugins"}<span class="pill">{plugins.length}</span>{/if}
        {#if t.id === "commands"}<span class="pill">{commands.length}</span>{/if}
      </button>
    {/each}
  </nav>
  <span class="conn" class:on={store.connected}>
    {store.connected ? "live" : "offline"}
  </span>
</header>

<main>
  {#if tab === "logs"}
    <LogList logs={store.logs} />
  {:else if tab === "plugins"}
    <PluginsPanel {plugins} />
  {:else if tab === "commands"}
    <CommandsPanel {commands} />
  {:else}
    <div class="state-grid">
      <section>
        <h2>Current State</h2>
        <pre>{stateSummary}</pre>
      </section>
      <section>
        <h2>Resolved Config</h2>
        <pre>{configJSON}</pre>
      </section>
    </div>
  {/if}
</main>

<style>
  header {
    height: 40px;
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 0 14px;
    border-bottom: 1px solid var(--border);
    background: var(--panel);
  }
  .brand {
    color: var(--accent);
    letter-spacing: 0.3px;
  }
  nav {
    display: flex;
    gap: 4px;
  }
  nav button {
    min-width: 0;
    background: transparent;
    border: 1px solid transparent;
  }
  nav button.active {
    border-color: var(--border);
    background: var(--bg);
    color: var(--accent);
  }
  .pill {
    margin-left: 4px;
    padding: 0 5px;
    border-radius: 8px;
    background: var(--panel-strong);
    color: var(--muted);
    font-size: 10px;
  }
  .conn {
    margin-left: auto;
    font-size: 11px;
    color: var(--muted);
    text-transform: uppercase;
  }
  .conn::before {
    content: "";
    display: inline-block;
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: #d9574f;
    margin-right: 6px;
    vertical-align: middle;
  }
  .conn.on {
    color: var(--accent);
  }
  .conn.on::before {
    background: #4ad97f;
  }
  main {
    height: calc(100vh - 40px);
    min-height: 0;
  }
  .state-grid {
    height: 100%;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1px;
    background: var(--border);
  }
  section {
    overflow: auto;
    min-height: 0;
    background: var(--bg);
    padding: 10px 12px;
  }
  h2 {
    margin: 0 0 8px;
    font-size: 12px;
    color: var(--accent);
  }
  pre {
    margin: 0;
    white-space: pre-wrap;
    word-break: break-word;
  }
</style>
