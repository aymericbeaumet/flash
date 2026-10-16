<script lang="ts">
  import type { InspectorState } from "./types";
  import ConfigJSON from "./ConfigJSON.svelte";
  import { duration } from "./format";
  import { now } from "./clock.svelte";
  let { state: snapshot, connected, onrefresh }: { state: InspectorState; connected: boolean; onrefresh: () => void } = $props();
  let configQuery = $state("");
  let draft = $state("");
  let loaded = $state("");
  let filePath = $state("");
  let started = $state(false);
  let busy = $state(false);
  let note = $state("");
  let editorError = $state("");
  const runtime = $derived(snapshot.runtime);
  const dirty = $derived(draft !== loaded);
  const yesNo = (value: boolean | undefined, yes: string, no: string) => value === undefined ? "Waiting for snapshot" : value ? yes : no;

  $effect(() => {
    if (!connected || started) return;
    started = true;
    void loadConfig();
  });

  async function loadConfig() {
    try {
      const response = await fetch("/api/config");
      const payload: unknown = await response.json();
      if (!response.ok) {
        editorError = messageFrom(payload, response.statusText);
        return;
      }
      if (!isRecord(payload)) return;
      const toml = typeof payload.toml === "string" ? payload.toml : "";
      if (draft === loaded) {
        draft = toml;
        loaded = toml;
      }
      if (typeof payload.path === "string") filePath = payload.path;
    } catch (caught) {
      editorError = caught instanceof Error ? caught.message : "Could not load configuration";
    }
  }

  async function saveConfig() {
    busy = true;
    editorError = "";
    note = "";
    try {
      const response = await fetch("/api/config", {
        method: "PUT",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: draft,
      });
      const payload: unknown = await response.json().catch(() => null);
      if (!response.ok) {
        editorError = messageFrom(payload, response.statusText);
        return;
      }
      loaded = draft;
      note = "Saved. Flash reloads the file.";
    } catch (caught) {
      editorError = caught instanceof Error ? caught.message : "Could not save configuration";
    } finally {
      busy = false;
    }
  }

  async function purgeDefaults() {
    busy = true;
    editorError = "";
    note = "";
    try {
      const response = await fetch("/api/config/purge", {
        method: "POST",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: draft,
      });
      const payload: unknown = await response.json().catch(() => null);
      if (!response.ok || !isRecord(payload) || typeof payload.toml !== "string") {
        editorError = messageFrom(payload, response.statusText);
        return;
      }
      if (payload.toml === draft) {
        note = "No default values to remove.";
        return;
      }
      draft = payload.toml;
      note = "Defaults removed in the editor. Save to write the file.";
    } catch (caught) {
      editorError = caught instanceof Error ? caught.message : "Could not purge defaults";
    } finally {
      busy = false;
    }
  }

  function isRecord(value: unknown): value is Record<string, unknown> {
    return !!value && typeof value === "object";
  }

  function messageFrom(payload: unknown, fallback: string): string {
    if (isRecord(payload) && typeof payload.error === "string" && payload.error) return payload.error;
    return fallback || "Request failed";
  }
</script>

<div class="page"><div class="page-heading"><p class="eyebrow">Inspect</p><h1>Runtime & configuration</h1><p>The state of your running Flash, including permissions, input routing, and resolved settings.</p></div>
  {#if runtime?.config_error}<div class="notice error"><strong>Configuration error</strong><p>{runtime.config_error}</p><a href="/docs/config">Configuration reference →</a></div>{/if}
  <div class="runtime-grid">
    <section class="surface"><h2>Resident app <span class="badge" class:neutral={!connected}>{connected ? "Connected" : "Disconnected"}</span></h2><dl><dt>Version</dt><dd>{runtime?.version ?? "—"}{#if runtime?.build} <span class="muted">({runtime.build})</span>{/if}</dd><dt>Process</dt><dd>{runtime?.pid ?? "—"}</dd><dt>Uptime</dt><dd>{runtime?.started_at_unix_ms == null ? "—" : duration(Math.max(0, now() - runtime.started_at_unix_ms))}</dd><dt>Last change</dt><dd>{snapshot.snapshot_at_unix_ms ? new Date(snapshot.snapshot_at_unix_ms).toLocaleTimeString() : "Waiting for Flash"} <button class="resample" onclick={onrefresh} disabled={!connected}>Refresh</button></dd></dl></section>
    <section class="surface"><h2>Input & permissions</h2><dl><dt>Mode</dt><dd><span class="badge">{snapshot.mode ?? "—"}</span></dd><dt>Overlay</dt><dd>{snapshot.overlay || "None"}</dd><dt>Accessibility</dt><dd>{yesNo(runtime?.accessibility_trusted, "Granted", "Not granted")}</dd><dt>Keyboard capture</dt><dd>{yesNo(runtime?.keyboard_capture_active, "Active", "Inactive")}</dd><dt>Secure input</dt><dd>{yesNo(runtime?.secure_input, "Enabled; capture suspended", "Inactive")}</dd><dt>Advanced mode</dt><dd>{yesNo(runtime?.advanced_mode, "Enabled", "Disabled")}</dd></dl><a href="/docs/normal-mode">How input capture works →</a></section>
    <section class="surface"><h2>Focused application</h2><dl><dt>Application</dt><dd>{snapshot.focused_app?.localized_name ?? "None"}</dd><dt>Bundle ID</dt><dd><code>{snapshot.focused_app?.bundle_id ?? "—"}</code></dd><dt>Process</dt><dd>{snapshot.focused_app?.pid ?? "—"}</dd><dt>Mapping context</dt><dd>{snapshot.mappings?.localized_name ?? "Global"}</dd></dl><a href="/mappings">See effective mappings →</a></section>
    <section class="surface"><h2>Configuration</h2><p class="config-path"><a href="#config-editor"><code>{filePath || runtime?.config_path || "Waiting for config path"}</code></a></p><p class="muted">The editor writes this file. Purge defaults removes assignments that still equal the bundled file and leaves the result here until you save. The JSON below is the resolved configuration: defaults use the base colour, and an override is marked with the layer that set it.</p><a href="/docs/config">Configuration reference →</a></section>
  </div>
  <section class="surface config-editor" id="config-editor">
    <div class="toolbar">
      <strong>flash.toml</strong>
      {#if dirty}<span class="badge">Unsaved</span>{/if}
      <span class="count">{draft.length.toLocaleString()} characters</span>
      <button type="button" onclick={purgeDefaults} disabled={!connected || busy}>Purge defaults</button>
      <button type="button" onclick={saveConfig} disabled={!connected || busy || !dirty}>Save</button>
    </div>
    {#if editorError}<p class="editor-error">{editorError}</p>{/if}
    {#if note}<p class="editor-note">{note}</p>{/if}
    <textarea aria-label="Flash configuration" spellcheck="false" bind:value={draft}></textarea>
  </section>
  <section class="surface config-section"><div class="toolbar"><strong>Resolved configuration</strong><input type="search" aria-label="Filter configuration" placeholder="Find a key, value, or layer…" bind:value={configQuery} /></div>
    <ConfigJSON config={snapshot.config ?? {}} sources={snapshot.config_sources} query={configQuery} />
  </section>
  <details class="surface raw-state"><summary>Raw runtime snapshot</summary><pre>{JSON.stringify({ ...snapshot, docs: undefined, clipboard: undefined, config: undefined, config_sources: undefined }, null, 2)}</pre></details>
</div>

<style>
  .runtime-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 18px; min-width: 0; }
  .runtime-grid section { padding: 24px; min-width: 0; }
  h2 { font-size: 16px; display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 20px; }
  dl { display: grid; grid-template-columns: 140px minmax(0, 1fr); font-size: 12px; gap: 12px 16px; margin: 0; }
  dt { color: var(--muted); }
  dd { margin: 0; overflow-wrap: anywhere; }
  section a { display: inline-block; margin-top: 20px; font-size: 11px; }
  .resample { min-height: 0; padding: 1px 8px; margin-left: 8px; font-size: 10px; }
  section p { font-size: 12px; }
  .config-path { padding: 12px; border-radius: 6px; background: var(--bg); overflow-wrap: anywhere; margin-bottom: 14px; }
  .config-editor { margin-top: 26px; overflow: hidden; min-width: 0; max-width: 100%; }
  .config-editor .toolbar strong { font-size: 13px; }
  .config-editor textarea { display: block; box-sizing: border-box; width: 100%; min-width: 0; max-width: 100%; min-height: 320px; margin: 0; padding: 16px 18px; border: 0; border-radius: 0; resize: vertical; overflow: auto; font-family: var(--mono); font-size: 12px; line-height: 1.55; background: #f5f8f0; }
  .editor-error, .editor-note { margin: 0; padding: 10px 18px; font-size: 12px; }
  .editor-error { color: var(--danger); background: #fff3ef; }
  .editor-note { color: var(--accent); background: var(--accent-soft); }
  .config-section { margin-top: 26px; overflow: hidden; }
  .config-section .toolbar strong { font-size: 13px; }
  .config-section .toolbar input { margin-left: auto; flex: 1; max-width: 300px; }
  summary { cursor: pointer; padding: 16px 20px; font-size: 12px; }
  pre { margin: 0; padding: 20px; background: #f5f8f0; max-height: 600px; }
  .raw-state { margin-top: 18px; overflow: hidden; }
  @media (max-width: 950px) { .runtime-grid { grid-template-columns: 1fr; } }
  @media print {
    .runtime-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .runtime-grid section { break-inside: avoid; }
    section a, .resample { display: none; }
    .config-section, .raw-state { overflow: visible; }
    pre { padding: 12px; }
  }
</style>
