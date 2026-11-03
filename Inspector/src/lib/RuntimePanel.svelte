<script lang="ts">
  import { paths } from "./routes";
  import { untrack } from "svelte";
  import type { InspectorState } from "./types";
  import ConfigJSON from "./ConfigJSON.svelte";
  import { duration } from "./format";
  import { now } from "./clock.svelte";
  import PageHeader from "./PageHeader.svelte";
  import { describeFailure, requestJSON, withRetry } from "./request";
  import SectionHead from "./SectionHead.svelte";
  import { doneToast } from "./toast";
  import { toasts } from "./toasts.svelte";
  let { state: snapshot, connected, onrefresh }: { state: InspectorState; connected: boolean; onrefresh: () => void } = $props();
  let configQuery = $state("");
  let draft = $state("");
  let loaded = $state("");
  let filePath = $state("");
  let started = $state(false);
  let loadingConfig = $state(false);
  let busy = $state(false);
  let loadError = $state("");
  let editorError = $state("");
  const runtime = $derived(snapshot.runtime);
  // Sections by value: a push that leaves the configuration alone (the status
  // bar's) does not rebuild its document.
  const noConfig = {};
  const config = $derived(snapshot.config ?? noConfig);
  const configSources = $derived(snapshot.config_sources);
  /** The raw snapshot is encoded only while its section is open. */
  let rawOpen = $state(false);
  const dirty = $derived(draft !== loaded);
  const yesNo = (value: boolean | undefined, yes: string, no: string) => value === undefined ? "Waiting for snapshot" : value ? yes : no;
  const tone = (value: boolean | undefined, good = true) => value === undefined ? "" : value === good ? "ok" : "warning";

  // The editor loads once Flash answers; a later reconnect retries a failed load.
  $effect(() => {
    if (!connected) return;
    untrack(() => {
      if (started && !loadError) return;
      started = true;
      void loadConfig();
    });
  });

  async function loadConfig() {
    loadingConfig = true;
    loadError = "";
    try {
      const payload = await withRetry((signal) => requestJSON("/api/config", { signal }));
      if (!isRecord(payload)) throw new Error("the configuration reply is not an object");
      const toml = typeof payload.toml === "string" ? payload.toml : "";
      if (draft === loaded) {
        draft = toml;
        loaded = toml;
      }
      if (typeof payload.path === "string") filePath = payload.path;
    } catch (caught) {
      loadError = `Could not load the configuration file. ${describeFailure(caught)}.`;
    } finally {
      loadingConfig = false;
    }
  }

  // The editor's outcomes: a confirmation is a toast, a refusal stays by the text it refuses.
  async function saveConfig() {
    busy = true;
    editorError = "";
    toasts.clear("config-editor");
    try {
      await requestJSON("/api/config", { method: "PUT", headers: { "Content-Type": "text/plain; charset=utf-8" }, body: draft });
      loaded = draft;
      toasts.show(doneToast("config-editor", "Saved. Flash reloads the file."));
    } catch (caught) {
      editorError = `Not saved; your edits are still here. ${describeFailure(caught)}.`;
    } finally {
      busy = false;
    }
  }

  async function purgeDefaults() {
    busy = true;
    editorError = "";
    toasts.clear("config-editor");
    try {
      const payload = await requestJSON("/api/config/purge", { method: "POST", headers: { "Content-Type": "text/plain; charset=utf-8" }, body: draft });
      if (!isRecord(payload) || typeof payload.toml !== "string") throw new Error("the purge reply has no toml");
      if (payload.toml === draft) {
        toasts.show(doneToast("config-editor", "No default values to remove."));
        return;
      }
      draft = payload.toml;
      toasts.show(doneToast("config-editor", "Defaults removed in the editor. Save to write the file."));
    } catch (caught) {
      editorError = `Could not purge defaults. ${describeFailure(caught)}.`;
    } finally {
      busy = false;
    }
  }

  function isRecord(value: unknown): value is Record<string, unknown> {
    return !!value && typeof value === "object";
  }
</script>

<div class="page">
  <PageHeader id="state" title="Runtime & configuration" purpose="The running resident: permissions, input routing and resolved settings." manual={paths.docs("configuration")} live>
    {#snippet actions()}<button type="button" class="refresh" onclick={onrefresh} disabled={!connected}>Refresh</button>{/snippet}
    {#snippet help()}
      <p>Flash pushes a new snapshot whenever something here changes; Refresh asks for one now, which also resamples plugin CPU time and memory.</p>
      <p>The editor writes your configuration file. <strong>Purge defaults</strong> removes assignments that still equal the bundled file and leaves the result in the editor until you save. The JSON is the resolved configuration: defaults keep the base colour, and an override is marked with the layer that set it.</p>
    {/snippet}
  </PageHeader>
  {#if runtime?.config_error}<div class="notice error"><strong>Configuration error</strong><p>{runtime.config_error}</p><a href={paths.docs("configuration")}>Configuration reference →</a></div>{/if}
  <div class="runtime-grid">
    <section class="surface"><SectionHead id="resident-title" title="Resident app" /><dl><dt>Connection</dt><dd><span class="badge {connected ? 'ok' : 'error'}">{connected ? "Live" : "Disconnected"}</span></dd><dt>Version</dt><dd>{runtime?.version ?? "—"}{#if runtime?.build}<span class="muted">&nbsp;build {runtime.build}</span>{/if}</dd><dt>Process</dt><dd>{runtime?.pid ?? "—"}</dd><dt>Uptime</dt><dd>{runtime?.started_at_unix_ms == null ? "—" : duration(Math.max(0, now() - runtime.started_at_unix_ms))}</dd><dt>Last change</dt><dd>{snapshot.snapshot_at_unix_ms ? new Date(snapshot.snapshot_at_unix_ms).toLocaleTimeString() : "Waiting for Flash"}</dd></dl></section>
    <section class="surface"><SectionHead id="input-title" title="Input & permissions">{#snippet actions()}<a href={paths.docs("normal-mode", "input-capture-and-latency")}>How input capture works →</a>{/snippet}</SectionHead><dl><dt>Mode</dt><dd><span class="badge">{snapshot.mode ?? "—"}</span></dd><dt>Overlay</dt><dd>{snapshot.overlay || "None"}</dd><dt>Accessibility</dt><dd class={tone(runtime?.accessibility_trusted)}>{yesNo(runtime?.accessibility_trusted, "Granted", "Not granted")}</dd><dt>Keyboard capture</dt><dd class={tone(runtime?.keyboard_capture_active)}>{yesNo(runtime?.keyboard_capture_active, "Active", "Inactive")}</dd><dt>Secure input</dt><dd class={tone(runtime?.secure_input, false)}>{yesNo(runtime?.secure_input, "Enabled; capture suspended", "Inactive")}</dd><dt>Advanced mode</dt><dd>{yesNo(runtime?.advanced_mode, "Enabled", "Disabled")}</dd></dl></section>
    <section class="surface"><SectionHead id="focus-title" title="Focused application">{#snippet actions()}<a href="/mappings">Effective mappings →</a>{/snippet}</SectionHead><dl><dt>Application</dt><dd>{snapshot.focused_app?.localized_name ?? "None"}</dd><dt>Bundle ID</dt><dd><code>{snapshot.focused_app?.bundle_id ?? "—"}</code></dd><dt>Process</dt><dd>{snapshot.focused_app?.pid ?? "—"}</dd><dt>Mapping context</dt><dd>{snapshot.mappings?.localized_name ?? "Global"}</dd></dl></section>
    <section class="surface"><SectionHead id="config-title" title="Configuration">{#snippet actions()}<a href={paths.docs("configuration")}>Reference →</a>{/snippet}</SectionHead><dl><dt>File</dt><dd><a href="#config-editor"><code>{filePath || runtime?.config_path || "Waiting for config path"}</code></a></dd><dt>Status</dt><dd class={runtime ? (runtime.config_error ? "warning" : "ok") : ""}>{runtime ? (runtime.config_error ? "Error, see above" : "Loaded without error") : "Waiting for snapshot"}</dd></dl></section>
  </div>
  <section class="surface config-editor" id="config-editor">
    <div class="toolbar">
      <strong>flash.toml</strong>
      {#if dirty}<span class="badge warning">Unsaved</span>{/if}
      <span class="count">{draft.length.toLocaleString()} characters</span>
      <button type="button" onclick={purgeDefaults} disabled={!connected || busy || loadingConfig}>Purge defaults</button>
      <button type="button" class="primary" onclick={saveConfig} disabled={!connected || busy || !dirty}>Save</button>
    </div>
    {#if loadingConfig}<p class="editor-note muted-note" role="status">Loading the configuration file…</p>{/if}
    {#if loadError}<div class="failure" role="alert"><strong>{loadError}</strong><button type="button" onclick={loadConfig}>Retry</button></div>{/if}
    {#if editorError}<p class="editor-error" role="alert">{editorError}</p>{/if}
    <textarea aria-label="Flash configuration" spellcheck="false" bind:value={draft}></textarea>
  </section>
  <section class="surface config-section"><div class="toolbar"><strong>Resolved configuration</strong><input type="search" aria-label="Filter configuration" placeholder="Find a key, value, or layer…" bind:value={configQuery} /></div>
    <ConfigJSON {config} sources={configSources} query={configQuery} />
  </section>
  <details class="surface raw-state" ontoggle={(event) => { rawOpen = event.currentTarget.open; }}><summary>Raw runtime snapshot</summary>{#if rawOpen}<pre>{JSON.stringify({ ...snapshot, docs: undefined, clipboard: undefined, config: undefined, config_sources: undefined }, null, 2)}</pre>{/if}</details>
</div>

<style>
  .refresh { min-height: 30px; padding: 2px 12px; font-size: 12px; }
  .runtime-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; min-width: 0; }
  .runtime-grid section { padding: 12px 16px 14px; min-width: 0; }
  .runtime-grid :global(.section-actions a) { font-size: 12px; }
  dl { display: grid; grid-template-columns: 140px minmax(0, 1fr); font-size: 13px; gap: 6px 16px; margin: 0; }
  dt { color: var(--muted); }
  dd { margin: 0; overflow-wrap: anywhere; }
  dd.ok { color: var(--verdigris); }
  dd.warning { color: var(--amber); }
  .notice p { margin-top: 4px; }
  .config-editor { margin-top: 16px; overflow: hidden; min-width: 0; max-width: 100%; }
  .config-editor .toolbar strong, .config-section .toolbar strong { font: 600 13px var(--mono); }
  .primary { color: var(--accent); border-color: var(--accent-dim); }
  .config-editor textarea { display: block; box-sizing: border-box; width: 100%; min-width: 0; max-width: 100%; min-height: 320px; margin: 0; padding: 14px 16px; border: 0; border-radius: 0; resize: vertical; overflow: auto; font-family: var(--mono); font-size: 13px; line-height: 1.55; color: var(--text); background: var(--inset); }
  .config-editor textarea:focus-visible { outline: 1px solid var(--accent-dim); outline-offset: -1px; }
  .editor-error, .editor-note { margin: 0; padding: 8px 16px; font-size: 13px; }
  .editor-error { color: var(--danger); background: var(--danger-soft); }
  .editor-note { color: var(--verdigris); background: var(--verdigris-soft); }
  .editor-note.muted-note { color: var(--muted); background: var(--raised); }
  .config-section { margin-top: 16px; overflow: hidden; }
  .config-section .toolbar input { margin-left: auto; flex: 1; max-width: 300px; }
  summary { cursor: pointer; padding: 12px 16px; font-size: 13px; color: var(--accent); }
  pre { margin: 0; padding: 16px; background: var(--inset); max-height: 600px; color: var(--text); }
  .raw-state { margin-top: 12px; overflow: hidden; }
  @media (max-width: 950px) { .runtime-grid { grid-template-columns: 1fr; } }
  @media print {
    .runtime-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .runtime-grid section { break-inside: avoid; }
    .refresh { display: none; }
    .config-section, .raw-state { overflow: visible; }
    pre { padding: 12px; }
  }
</style>
