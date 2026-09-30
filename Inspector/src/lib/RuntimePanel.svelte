<script lang="ts">
  import type { InspectorState } from "./types";
  import { duration } from "./format";
  let { state: snapshot, connected }: { state: InspectorState; connected: boolean } = $props();
  let configQuery = $state("");
  let showJSON = $state(false);
  const runtime = $derived(snapshot.runtime);
  const configEntries = $derived(Object.entries(snapshot.config ?? {}).filter(([key, value]) => `${key} ${JSON.stringify(value)}`.toLowerCase().includes(configQuery.toLowerCase())));
  const yesNo = (value: boolean | undefined, yes: string, no: string) => value === undefined ? "Waiting for snapshot" : value ? yes : no;
</script>

<div class="page"><div class="page-heading"><p class="eyebrow">Inspect</p><h1>Runtime & configuration</h1><p>The state of your running Flash, including permissions, input routing, and resolved settings.</p></div>
  {#if runtime?.config_error}<div class="notice error"><strong>Configuration error</strong><p>{runtime.config_error}</p><a href="#docs/config">Configuration reference →</a></div>{/if}
  <div class="runtime-grid">
    <section class="surface"><h2>Resident app <span class="badge" class:neutral={!connected}>{connected ? "Connected" : "Disconnected"}</span></h2><dl><dt>Version</dt><dd>{runtime?.version ?? "—"}{#if runtime?.build} <span class="muted">({runtime.build})</span>{/if}</dd><dt>Process</dt><dd>{runtime?.pid ?? "—"}</dd><dt>Uptime</dt><dd>{runtime?.uptime_seconds == null ? "—" : duration(runtime.uptime_seconds * 1000)}</dd><dt>Snapshot</dt><dd>{snapshot.snapshot_at_unix_ms ? new Date(snapshot.snapshot_at_unix_ms).toLocaleTimeString() : "Waiting for Flash"}</dd></dl></section>
    <section class="surface"><h2>Input & permissions</h2><dl><dt>Mode</dt><dd><span class="badge">{snapshot.mode ?? "—"}</span></dd><dt>Overlay</dt><dd>{snapshot.overlay || "None"}</dd><dt>Accessibility</dt><dd>{yesNo(runtime?.accessibility_trusted, "Granted", "Not granted")}</dd><dt>Keyboard capture</dt><dd>{yesNo(runtime?.keyboard_capture_active, "Active", "Inactive")}</dd><dt>Secure input</dt><dd>{yesNo(runtime?.secure_input, "Enabled; capture suspended", "Inactive")}</dd><dt>Advanced mode</dt><dd>{yesNo(runtime?.advanced_mode, "Enabled", "Disabled")}</dd></dl><a href="#docs/normal-mode">How input capture works →</a></section>
    <section class="surface"><h2>Focused application</h2><dl><dt>Application</dt><dd>{snapshot.focused_app?.localized_name ?? "None"}</dd><dt>Bundle ID</dt><dd><code>{snapshot.focused_app?.bundle_id ?? "—"}</code></dd><dt>Process</dt><dd>{snapshot.focused_app?.pid ?? "—"}</dd><dt>Mapping context</dt><dd>{snapshot.mappings?.localized_name ?? "Global"}</dd></dl><a href="#mappings">See effective mappings →</a></section>
    <section class="surface"><h2>Configuration</h2><p class="config-path"><code>{runtime?.config_path ?? "Waiting for config path"}</code></p><p class="muted">The values below are the resolved configuration. Save your TOML file to apply changes live.</p><a href="#docs/config">Configuration reference →</a></section>
  </div>
  <section class="surface config-section"><div class="toolbar"><strong>Resolved configuration</strong><input type="search" aria-label="Filter configuration" placeholder="Find a section or value…" bind:value={configQuery} /><button onclick={() => showJSON = !showJSON}>{showJSON ? "Section view" : "View JSON"}</button></div>
    {#if showJSON}<pre class="config-json">{JSON.stringify(snapshot.config ?? {}, null, 2)}</pre>{:else}<div class="config-groups">{#each configEntries as [key, value]}<details><summary><code>{key}</code><span>{typeof value === "object" && value !== null ? `${Object.keys(value).length} entries` : String(value)}</span></summary><pre>{JSON.stringify(value, null, 2)}</pre></details>{/each}{#if !configEntries.length}<p class="empty">No configuration sections match.</p>{/if}</div>{/if}
  </section>
  <details class="surface raw-state"><summary>Raw runtime snapshot</summary><pre>{JSON.stringify({ ...snapshot, docs: undefined, clipboard: undefined, config: undefined }, null, 2)}</pre></details>
</div>

<style>
  .runtime-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 18px; }
  .runtime-grid section { padding: 24px; min-width: 0; }
  h2 { font-size: 16px; display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 20px; }
  dl { display: grid; grid-template-columns: 140px minmax(0, 1fr); font-size: 12px; gap: 12px 16px; margin: 0; }
  dt { color: var(--muted); }
  dd { margin: 0; overflow-wrap: anywhere; }
  section a { display: inline-block; margin-top: 20px; font-size: 11px; }
  section p { font-size: 12px; }
  .config-path { padding: 12px; border-radius: 6px; background: var(--bg); overflow-wrap: anywhere; margin-bottom: 14px; }
  .config-section { margin-top: 26px; overflow: hidden; }
  .config-section .toolbar strong { font-size: 13px; }
  .config-section .toolbar input { margin-left: auto; flex: 1; max-width: 300px; }
  .config-section .toolbar button { font-size: 11px; }
  summary { cursor: pointer; padding: 16px 20px; font-size: 12px; }
  .config-groups details { border-bottom: 1px solid var(--border-soft); }
  .config-groups details:last-child { border: 0; }
  .config-groups summary span { float: right; color: var(--muted); font-size: 11px; max-width: 65%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  pre { margin: 0; padding: 20px; background: #f5f8f0; max-height: 600px; }
  .raw-state { margin-top: 18px; overflow: hidden; }
  @media (max-width: 950px) { .runtime-grid { grid-template-columns: 1fr; } }
</style>
