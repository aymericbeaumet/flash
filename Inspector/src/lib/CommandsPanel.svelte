<script lang="ts">
  import Icon from "./Icon.svelte";
  import type { CommandInfo } from "./types";

  let { commands, filter = "" }: { commands: CommandInfo[]; filter?: string } = $props();
  let query = $state("");
  let source = $state("all");

  $effect(() => { query = filter; source = "all"; });

  const coreCount = $derived(commands.filter((command) => command.source_kind === "core").length);
  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    return commands.filter((command) =>
      (source === "all" || command.source_kind === source) &&
      (!q || [command.name, command.syntax, command.source, command.description, ...(command.aliases ?? [])].join(" ").toLowerCase().includes(q)),
    ).sort((a, b) => {
      if (a.source_kind !== b.source_kind) return a.source_kind === "core" ? -1 : 1;
      return a.source.localeCompare(b.source) || a.name.localeCompare(b.name);
    });
  });
</script>

<div class="page">
  <div class="page-heading">
    <p class="eyebrow">Your Flash</p>
    <h1>Commands</h1>
    <p>Everything you can ask Flash to do, including commands contributed by your loaded plugins.</p>
  </div>
  <div class="command-guide">
    <span class="guide-icon"><Icon name="commands" size={22} /></span>
    <div><strong>Start with a colon.</strong><p>In NORMAL mode, press <kbd>:</kbd>, enter a command, then press <kbd>Return</kbd>. <kbd>Tab</kbd> completes command names.</p></div>
    <a href="#docs/commands">Command guide <Icon name="arrow" size={15} /></a>
  </div>
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
          <thead><tr><th>Command & usage</th><th>What it does</th><th>Source</th></tr></thead>
          <tbody>
            {#each filtered as command, index (command.name + command.source + index)}
              <tr>
                <td class="command-cell"><code class="command-name">{command.name}</code>{#if command.syntax && command.syntax !== command.name}<code class="syntax">{command.syntax}</code>{/if}{#if command.aliases?.length}<span class="aliases">Also {command.aliases.join(", ")}</span>{/if}</td>
                <td class="description">{command.description || "No description provided."}</td>
                <td>{#if command.source_kind === "plugin"}<a class="badge neutral" href={"#plugins/" + encodeURIComponent(command.source)}>{command.source} <Icon name="chevron" size={11} /></a>{:else}<span class="badge">Built-in</span>{/if}</td>
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
  .command-guide { display: flex; align-items: center; gap: 15px; padding: 19px 22px; margin-bottom: 25px; background: #edf2e7; border: 1px solid #dfe7d7; border-radius: 10px; }
  .guide-icon { color: var(--accent); flex-shrink: 0; }
  .command-guide strong { font-size: 13px; font-weight: 600; }
  .command-guide p { margin-top: 4px; color: var(--muted); font-size: 12px; }
  .command-guide kbd { font-size: 10px; padding: 0 5px; }
  .command-guide a { margin-left: auto; display: flex; align-items: center; gap: 7px; font-size: 12px; white-space: nowrap; }
  .catalog { overflow: hidden; }
  .segmented button span { color: var(--muted); margin-left: 4px; font-size: 10px; }
  .data-table { min-width: 590px; }
  .command-cell { width: 36%; }
  .command-name { color: var(--accent); font-weight: 600; white-space: nowrap; }
  .syntax { display: block; color: var(--muted); margin-top: 6px; font-size: 10px; overflow-wrap: anywhere; }
  .aliases { display: block; font-size: 10px; margin-top: 5px; color: var(--muted); }
  .description { width: 48%; color: #58655c; font-size: 12px; }
  .empty button { margin-top: 16px; font-size: 12px; }
  @media (max-width: 900px) { .command-guide { align-items: flex-start; flex-wrap: wrap; }.command-guide a { margin-left: 37px; } }
</style>
