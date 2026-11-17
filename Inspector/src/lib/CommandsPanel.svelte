<script lang="ts">
  import { commandDoc, commandOfAction } from "./command-docs";
  import Icon from "./Icon.svelte";
  import { paths } from "./routes";
  import PageHeader from "./PageHeader.svelte";
  import SourceBadge from "./SourceBadge.svelte";
  import { sourceFromCommand } from "./source";
  import type { CommandInfo, MappingRow } from "./types";

  let { commands, rows = [], filter = "" }: { commands: CommandInfo[]; rows?: MappingRow[]; filter?: string } = $props();

  /** The keys bound to each command, in the modes they act in. */
  const keysByCommand = $derived.by(() => {
    const out = new Map<string, MappingRow[]>();
    for (const row of rows) {
      const name = commandOfAction(row.action);
      if (!name) continue;
      out.set(name, [...(out.get(name) ?? []), row]);
    }
    return out;
  });
  /** A built-in command's page of the documentation; a plugin command's plugin. */
  function docHref(command: CommandInfo): string {
    if (command.source_kind === "plugin") return paths.plugins(command.source);
    const target = commandDoc(command.name);
    return paths.docs(target.page, target.anchor);
  }
  const shown = 3;
  let query = $state("");
  let source = $state("all");

  $effect(() => { query = filter; source = "all"; });

  const coreCount = $derived(commands.filter((command) => command.source_kind === "core").length);
  const byName = new Intl.Collator(undefined, { sensitivity: "base", numeric: true });
  const bySource = new Intl.Collator(undefined, { sensitivity: "base" });
  /** Every command in order with its search text, once per catalog rather than per keystroke. */
  const catalog = $derived(
    [...commands]
      .sort((a, b) => byName.compare(a.name, b.name) || bySource.compare(a.source, b.source))
      .map((command) => ({ command, text: [command.name, command.syntax, command.source, command.description, ...(command.aliases ?? [])].join(" ").toLowerCase() })),
  );
  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    return catalog.filter((entry) => (source === "all" || entry.command.source_kind === source) && (!q || entry.text.includes(q))).map((entry) => entry.command);
  });
</script>

<div class="page">
  <PageHeader id="commands" title="Commands" purpose="Everything you can ask Flash to do, with your plugins' commands." manual={paths.docs("commands")}>
    {#snippet help()}
      <p>Open the command line with <code>flash mode command</code> from a terminal, or bind <kbd>:</kbd> to <code>mode command</code> in NORMAL. Enter a command and press <kbd>Return</kbd>; <kbd>Tab</kbd> completes the topic, then the action. Every command also runs from a shell as <code>flash &lt;topic&gt; &lt;action&gt;</code>.</p>
    {/snippet}
  </PageHeader>
  <div class="surface catalog">
    <div class="toolbar">
      <input type="search" aria-label="Search commands" placeholder="Search commands, aliases, or descriptions…" bind:value={query} />
      <div class="segmented" aria-label="Command source">
        {#each [{ id: "all", label: "All", count: commands.length }, { id: "core", label: "Built-in", count: coreCount }, { id: "plugin", label: "Plugins", count: commands.length - coreCount }] as item}
          <button class:active={source === item.id} aria-pressed={source === item.id} onclick={() => source = item.id}>{item.label} <span>{item.count}</span></button>
        {/each}
      </div>
      <span class="count">{filtered.length} {filtered.length === 1 ? "command" : "commands"}</span>
    </div>
    {#if filtered.length}
      <div class="table-wrap">
        <table class="data-table">
          <thead><tr><th>Command & usage</th><th>What it does</th><th>Keys</th><th>Source</th></tr></thead>
          <tbody>
            {#each filtered as command, index (command.name + command.source + index)}
              <tr>
                <td class="command-cell"><code class="command-name">{command.name}</code><a class="doc-link" href={docHref(command)} aria-label="Documentation for {command.name}" title="Documentation for {command.name}"><Icon name="docs" size={13} /></a>{#if command.syntax && command.syntax !== command.name}<code class="syntax">{command.syntax}</code>{/if}{#if command.aliases?.length}<span class="aliases">Also {command.aliases.join(", ")}</span>{/if}</td>
                <td class="description">{command.description || "No description provided."}</td>
                <td class="keys">{#each (keysByCommand.get(command.name) ?? []).slice(0, shown) as row}<span class="bound"><kbd>{row.key}</kbd><span class="scope">{row.scope}</span></span>{/each}{#if (keysByCommand.get(command.name)?.length ?? 0) > shown}<a class="more" href={paths.mappings(command.name)}>+{(keysByCommand.get(command.name)?.length ?? 0) - shown} more</a>{/if}</td>
                <td><SourceBadge {...sourceFromCommand(command.source_kind, command.source)} /></td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    {:else}
      <div class="empty"><strong>{commands.length ? "No commands match" : "Waiting for the command catalog"}</strong><p>{commands.length ? "Try a different name, description, or source." : "Commands will appear when Flash sends its runtime snapshot."}</p>{#if query || source !== "all"}<button onclick={() => { query = ""; source = "all"; }}>Clear filters</button>{/if}</div>
    {/if}
  </div>
</div>

<style>
  .catalog { overflow: hidden; }
  .segmented button span { color: var(--faint); margin-left: 4px; font: 12px var(--mono); }
  .segmented button.active span { color: inherit; opacity: .8; }
  .data-table { min-width: 590px; }
  .command-cell { width: 32%; }
  .doc-link { display: inline-flex; vertical-align: -2px; margin-left: 6px; color: var(--muted); }
  .doc-link:hover { color: var(--accent); }
  .keys { width: 16%; font-size: 12px; }
  .bound { display: flex; align-items: center; gap: 5px; margin: 1px 0; white-space: nowrap; }
  .bound .scope { color: var(--muted); font: 11px var(--mono); }
  .more { font-size: 12px; }
  .command-name { color: var(--accent); font-weight: 600; white-space: nowrap; font-size: 13px; }
  .syntax { display: block; color: var(--muted); margin-top: 4px; font-size: 12px; overflow-wrap: anywhere; }
  .aliases { display: block; font-size: 12px; margin-top: 4px; color: var(--muted); }
  .description { width: 40%; color: var(--text); font-size: 13px; }
  .empty button { margin-top: 16px; font-size: 12px; }
  @media print {
    .catalog { overflow: visible; border: 0; }
    .data-table { min-width: 0; }
  }
</style>
