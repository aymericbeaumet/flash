<script lang="ts">
  import { paths } from "./routes";
  import { untrack } from "svelte";
  import type { InspectorState } from "./types";
  import {
    blocksSave,
    ConfigChecker,
    lineMarks,
    offsetOfLine,
    summarize,
    type CheckState,
    type EditorDiagnostic,
  } from "./config-check";
  import { keyHelp, schemaAddress, type SchemaNode } from "./config-schema";
  import ConfigJSON from "./ConfigJSON.svelte";
  import { duration } from "./format";
  import { now } from "./clock.svelte";
  import LivePageHeader from "./LivePageHeader.svelte";
  import { describeFailure, requestJSON, withRetry } from "./request";
  import SectionHead from "./SectionHead.svelte";
  import { doneToast } from "./toast";
  import { toasts } from "./toasts.svelte";
  import { keyPathAt } from "./toml-caret";
  let {
    state: snapshot,
    connected,
    onrefresh,
  }: { state: InspectorState; connected: boolean; onrefresh: () => void } = $props();
  let configQuery = $state("");
  let draft = $state("");
  let loaded = $state("");
  let filePath = $state("");
  let started = $state(false);
  let loadingConfig = $state(false);
  let busy = $state(false);
  let loadError = $state("");
  let editorError = $state("");
  let overridesOnly = $state(false);
  let editor = $state<HTMLTextAreaElement>();
  let gutter = $state<HTMLElement>();
  /** Where the caret is, once the editor has had focus. */
  let caret = $state<number | null>(null);
  let schema = $state.raw<SchemaNode | null>(null);
  let schemaAsked = false;
  /** What Flash's check says of the editor's text (`config-check.ts`). */
  let check = $state.raw<CheckState>({ status: "idle", diagnostics: [] });
  const checker = new ConfigChecker(
    (text, signal) =>
      requestJSON("/api/config/check", {
        method: "POST",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: text,
        signal,
      }),
    (state) => {
      check = state;
    },
  );
  /** The editor's rows: the textarea and its gutter share this line height. */
  const lineHeight = 20;
  const runtime = $derived(snapshot.runtime);
  // Sections by value: a push that leaves the configuration alone (the status
  // bar's) does not rebuild its document.
  const noConfig = {};
  const config = $derived(snapshot.config ?? noConfig);
  const configSources = $derived(snapshot.config_sources);
  /** The raw snapshot is encoded only while its section is open. */
  let rawOpen = $state(false);
  const dirty = $derived(draft !== loaded);
  const lines = $derived.by(() => {
    let count = 1;
    for (let at = draft.indexOf("\n"); at !== -1; at = draft.indexOf("\n", at + 1)) count += 1;
    return count;
  });
  const lineNumbers = $derived(Array.from({ length: lines }, (_, index) => index + 1).join("\n"));
  const marks = $derived(lineMarks(check.diagnostics, lines));
  const summary = $derived(summarize(check));
  /** The text has errors: Save waits, and Save anyway writes it as it is. */
  const blocked = $derived(blocksSave(check));
  const help = $derived(schema && caret !== null ? keyHelp(schema, keyPathAt(draft, caret)) : null);
  const yesNo = (value: boolean | undefined, yes: string, no: string) =>
    value === undefined ? "Waiting for snapshot" : value ? yes : no;
  const tone = (value: boolean | undefined, good = true) =>
    value === undefined ? "" : value === good ? "ok" : "warning";

  // The editor loads once Flash answers; a later reconnect retries a failed load.
  $effect(() => {
    if (!connected) return;
    untrack(() => {
      if (started && !loadError) return;
      started = true;
      void loadConfig();
    });
  });

  // The text is checked as it changes, once the file is here and Flash answers.
  $effect(() => {
    const text = draft;
    if (!connected || !started || loadingConfig || loadError) return;
    untrack(() => checker.edit(text));
  });
  $effect(() => () => checker.stop());

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
  // A save writes text Flash has checked: errors hold it until they are fixed
  // or `anyway` is asked for. A check that does not answer holds nothing.
  async function saveConfig(anyway = false) {
    const text = draft;
    busy = true;
    editorError = "";
    toasts.clear("config-editor");
    try {
      if (!anyway) {
        const verdict = await checker.settle(text);
        if (verdict.status === "pending") {
          editorError = "Not saved: the text changed while Flash checked it. Save again.";
          return;
        }
        if (blocksSave(verdict)) {
          editorError =
            "Not saved: Flash reports errors in this text. Fix them, or use Save anyway.";
          return;
        }
      }
      await requestJSON("/api/config", {
        method: "PUT",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: text,
      });
      loaded = text;
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
      const payload = await requestJSON("/api/config/purge", {
        method: "POST",
        headers: { "Content-Type": "text/plain; charset=utf-8" },
        body: draft,
      });
      if (!isRecord(payload) || typeof payload.toml !== "string")
        throw new Error("the purge reply has no toml");
      if (payload.toml === draft) {
        toasts.show(doneToast("config-editor", "No default values to remove."));
        return;
      }
      draft = payload.toml;
      toasts.show(
        doneToast("config-editor", "Defaults removed in the editor. Save to write the file."),
      );
    } catch (caught) {
      editorError = `Could not purge defaults. ${describeFailure(caught)}.`;
    } finally {
      busy = false;
    }
  }

  function isRecord(value: unknown): value is Record<string, unknown> {
    return !!value && typeof value === "object";
  }

  /** The key help reads the schema Flash serves, asked for when the editor first takes focus. */
  function loadSchema() {
    if (schemaAsked) return;
    schemaAsked = true;
    requestJSON(schemaAddress)
      .then((value) => {
        if (isRecord(value)) schema = value as SchemaNode;
      })
      .catch(() => {
        // No help without it; the next focus asks again.
        schemaAsked = false;
      });
  }
  function trackCaret() {
    if (editor) caret = editor.selectionStart;
  }
  /** Moves the caret to a diagnostic's place and brings its line into view. */
  function reveal(diagnostic: EditorDiagnostic) {
    if (!editor || diagnostic.line === undefined) return;
    const offset = offsetOfLine(draft, diagnostic.line, diagnostic.column);
    editor.focus();
    editor.setSelectionRange(offset, offset);
    const row = Math.min(diagnostic.line, lines) - 1;
    editor.scrollTop = Math.max(0, row * lineHeight - editor.clientHeight / 2 + lineHeight);
    caret = offset;
  }
</script>

<div class="page">
  <LivePageHeader
    id="state"
    title="Runtime & configuration"
    purpose="The running resident: permissions, input routing and resolved settings."
    manual={paths.docs("configuration")}
  >
    {#snippet actions()}<button
        type="button"
        class="refresh"
        onclick={onrefresh}
        disabled={!connected}>Refresh</button
      >{/snippet}
    {#snippet help()}
      <p
        >Flash pushes a new snapshot whenever something here changes; Refresh asks for one now,
        which also resamples plugin CPU time and memory.</p
      >
      <p
        >The editor writes your configuration file. <strong>Purge defaults</strong> removes
        assignments that still equal the bundled file and leaves the result in the editor until you
        save. Flash checks the text as you type, as <code>flash config check</code> does: a line
        with a problem is marked in the gutter, and <strong>Save</strong> waits while the text has
        errors unless you choose <strong>Save anyway</strong>. Under the editor is what the schema
        says about the key the caret is on.</p
      ><p
        >The JSON is the resolved configuration: defaults keep the base colour, and an override is
        marked with the layer that set it. <strong>Overrides only</strong> hides every value that still
        holds its default.</p
      >
    {/snippet}
  </LivePageHeader>
  {#if runtime?.config_error}<div class="notice error"
      ><strong>Configuration error</strong><p>{runtime.config_error}</p><a
        href={paths.docs("configuration")}>Configuration reference →</a
      ></div
    >{/if}
  <div class="runtime-grid">
    <section class="surface"
      ><SectionHead id="resident-title" title="Resident app" /><dl
        ><dt>Connection</dt><dd
          ><span class="badge {connected ? 'ok' : 'error'}"
            >{connected ? "Live" : "Disconnected"}</span
          ></dd
        ><dt>Version</dt><dd
          >{runtime?.version ?? "—"}{#if runtime?.build}<span class="muted"
              >&nbsp;build {runtime.build}</span
            >{/if}</dd
        ><dt>Process</dt><dd>{runtime?.pid ?? "—"}</dd><dt>Uptime</dt><dd
          >{runtime?.started_at_unix_ms == null
            ? "—"
            : duration(Math.max(0, now() - runtime.started_at_unix_ms))}</dd
        ><dt>Last change</dt><dd
          >{snapshot.snapshot_at_unix_ms
            ? new Date(snapshot.snapshot_at_unix_ms).toLocaleTimeString()
            : "Waiting for Flash"}</dd
        ></dl
      ></section
    >
    <section class="surface"
      ><SectionHead id="input-title" title="Input & permissions"
        >{#snippet actions()}<a href={paths.docs("normal-mode", "input-capture-and-latency")}
            >How input capture works →</a
          >{/snippet}</SectionHead
      ><dl
        ><dt>Mode</dt><dd><span class="badge">{snapshot.mode ?? "—"}</span></dd><dt>Overlay</dt><dd
          >{snapshot.overlay || "None"}</dd
        ><dt>Accessibility</dt><dd class={tone(runtime?.accessibility_trusted)}
          >{yesNo(runtime?.accessibility_trusted, "Granted", "Not granted")}</dd
        ><dt>Keyboard capture</dt><dd class={tone(runtime?.keyboard_capture_active)}
          >{yesNo(runtime?.keyboard_capture_active, "Active", "Inactive")}</dd
        ><dt>Secure input</dt><dd class={tone(runtime?.secure_input, false)}
          >{yesNo(runtime?.secure_input, "Enabled; capture suspended", "Inactive")}</dd
        ><dt>Advanced mode</dt><dd>{yesNo(runtime?.advanced_mode, "Enabled", "Disabled")}</dd></dl
      ></section
    >
    <section class="surface"
      ><SectionHead id="focus-title" title="Focused application"
        >{#snippet actions()}<a href="/mappings">Effective mappings →</a>{/snippet}</SectionHead
      ><dl
        ><dt>Application</dt><dd>{snapshot.focused_app?.localized_name ?? "None"}</dd><dt
          >Bundle ID</dt
        ><dd><code>{snapshot.focused_app?.bundle_id ?? "—"}</code></dd><dt>Process</dt><dd
          >{snapshot.focused_app?.pid ?? "—"}</dd
        ><dt>Mapping context</dt><dd>{snapshot.mappings?.localized_name ?? "Global"}</dd></dl
      ></section
    >
    <section class="surface"
      ><SectionHead id="config-title" title="Configuration"
        >{#snippet actions()}<a href={paths.docs("configuration")}>Reference →</a
          >{/snippet}</SectionHead
      ><dl
        ><dt>File</dt><dd
          ><a href="#config-editor"
            ><code>{filePath || runtime?.config_path || "Waiting for config path"}</code></a
          ></dd
        ><dt>Status</dt><dd class={runtime ? (runtime.config_error ? "warning" : "ok") : ""}
          >{runtime
            ? runtime.config_error
              ? "Error, see above"
              : "Loaded without error"
            : "Waiting for snapshot"}</dd
        ></dl
      ></section
    >
  </div>
  <section class="surface config-editor" id="config-editor">
    <div class="toolbar">
      <strong>flash.toml</strong>
      {#if dirty}<span class="badge warning">Unsaved</span>{/if}
      {#if summary}<span
          class="badge {blocked
            ? 'error'
            : check.status === 'checked' && !check.diagnostics.length
              ? 'ok'
              : 'neutral'}"
          role="status">{summary}</span
        >{/if}
      <span class="count">{draft.length.toLocaleString()} characters</span>
      <button type="button" onclick={purgeDefaults} disabled={!connected || busy || loadingConfig}
        >Purge defaults</button
      >
      {#if blocked && dirty}<button
          type="button"
          onclick={() => saveConfig(true)}
          disabled={!connected || busy}
          title="Write the file with the errors Flash reports">Save anyway</button
        >{/if}
      <button
        type="button"
        class="primary"
        onclick={() => saveConfig()}
        disabled={!connected || busy || !dirty || blocked}
        title={blocked && dirty ? "Flash reports errors in this text" : undefined}>Save</button
      >
    </div>
    {#if loadingConfig}<p class="editor-note muted-note" role="status"
        >Loading the configuration file…</p
      >{/if}
    {#if loadError}<div class="failure" role="alert"
        ><strong>{loadError}</strong><button type="button" onclick={loadConfig}>Retry</button></div
      >{/if}
    {#if editorError}<p class="editor-error" role="alert">{editorError}</p>{/if}
    <div class="editor">
      <div class="gutter" style:width="{String(lines).length + 3}ch" aria-hidden="true"
        ><div class="rows" bind:this={gutter}
          >{#each marks as mark (mark.line)}<span
              class="mark {mark.severity}"
              style:top="{14 + (mark.line - 1) * lineHeight}px"
              title={mark.title}
            ></span>{/each}<pre>{lineNumbers}</pre></div
        ></div
      >
      <textarea
        aria-label="Flash configuration"
        spellcheck="false"
        wrap="off"
        bind:this={editor}
        bind:value={draft}
        onscroll={() => {
          if (gutter && editor) gutter.scrollTop = editor.scrollTop;
        }}
        onfocus={() => {
          loadSchema();
          trackCaret();
        }}
        oninput={trackCaret}
        onkeyup={trackCaret}
        onclick={trackCaret}
        onselect={trackCaret}></textarea>
    </div>
    {#if help}<div class="key-help"
        ><p
          ><code>{help.key}</code>{#if help.type}<span class="kind"
              >{help.type}{#if help.values}: {help.values.join(", ")}{/if}</span
            >{/if}{#if help.unknown}<span class="kind">not a key of Flash's schema</span>{/if}</p
        >{#if help.description}<p class="about"
            >{#if help.from}<span class="kind">From <code>{help.from}</code>:</span>
            {/if}{help.description}</p
          >{/if}</div
      >{/if}
    {#if check.status === "failed"}<p class="editor-note muted-note" role="status"
        >Flash did not check this text. {check.error}. Save still asks Flash to parse it.</p
      >{/if}
    {#if check.diagnostics.length}<ol
        class="diagnostics"
        class:stale={check.status === "pending"}
        aria-label="Configuration diagnostics"
        >{#each check.diagnostics as diagnostic, index (index)}<li
            >{#if diagnostic.line !== undefined}<button
                type="button"
                onclick={() => reveal(diagnostic)}
                ><span class="badge {diagnostic.severity}">{diagnostic.severity}</span><span
                  class="place">Line {diagnostic.line}</span
                ><span class="message">{diagnostic.message}</span></button
              >{:else}<div
                ><span class="badge {diagnostic.severity}">{diagnostic.severity}</span><span
                  class="place">{diagnostic.file ?? "No line"}</span
                ><span class="message">{diagnostic.message}</span></div
              >{/if}</li
          >{/each}</ol
      >{/if}
  </section>
  <section class="surface config-section"
    ><div class="toolbar"
      ><strong>Resolved configuration</strong><input
        type="search"
        aria-label="Filter configuration"
        placeholder="Find a key, value, or layer…"
        bind:value={configQuery}
      /><label class="only"
        ><input type="checkbox" bind:checked={overridesOnly} /> Overrides only</label
      ></div
    >
    <ConfigJSON {config} sources={configSources} query={configQuery} {overridesOnly} />
  </section>
  <details
    class="surface raw-state"
    ontoggle={(event) => {
      rawOpen = event.currentTarget.open;
    }}
    ><summary>Raw runtime snapshot</summary>{#if rawOpen}<pre
        >{JSON.stringify(
          {
            ...snapshot,
            docs: undefined,
            clipboard: undefined,
            config: undefined,
            config_sources: undefined,
          },
          null,
          2,
        )}</pre
      >{/if}</details
  >
</div>

<style>
  .refresh {
    min-height: 30px;
    padding: 2px 12px;
    font-size: 12px;
  }
  .runtime-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 12px;
    min-width: 0;
  }
  .runtime-grid section {
    padding: 12px 16px 14px;
    min-width: 0;
  }
  .runtime-grid :global(.section-actions a) {
    font-size: 12px;
  }
  dl {
    display: grid;
    grid-template-columns: 140px minmax(0, 1fr);
    font-size: 13px;
    gap: 6px 16px;
    margin: 0;
  }
  dt {
    color: var(--muted);
  }
  dd {
    margin: 0;
    overflow-wrap: anywhere;
  }
  dd.ok {
    color: var(--verdigris);
  }
  dd.warning {
    color: var(--amber);
  }
  .notice p {
    margin-top: 4px;
  }
  .config-editor {
    margin-top: 16px;
    overflow: hidden;
    min-width: 0;
    max-width: 100%;
  }
  .config-editor .toolbar strong,
  .config-section .toolbar strong {
    font: 600 13px var(--mono);
  }
  .primary {
    color: var(--accent);
    border-color: var(--accent-dim);
  }
  /* The textarea is what resizes: the gutter is as tall, holds its rows out of
     the layout and follows the textarea's scroll. */
  .editor {
    display: flex;
    align-items: stretch;
    min-width: 0;
    background: var(--inset);
  }
  .gutter,
  .config-editor textarea {
    font-family: var(--mono);
    font-size: 13px;
    line-height: 20px;
  }
  .gutter {
    position: relative;
    flex: none;
    color: var(--faint);
    border-right: 1px solid var(--border-soft);
    user-select: none;
  }
  .rows {
    position: absolute;
    inset: 0;
    overflow: hidden;
    padding: 14px 0 48px;
  }
  .gutter pre {
    position: relative;
    pointer-events: none;
    margin: 0;
    padding: 0 10px 0 12px;
    max-height: none;
    overflow: visible;
    font: inherit;
    text-align: right;
    color: inherit;
    background: none;
    font-variant-numeric: tabular-nums;
  }
  .mark {
    position: absolute;
    left: 0;
    right: 0;
    height: 20px;
    border-left: 3px solid var(--amber);
    background: var(--amber-soft);
  }
  .mark.error {
    border-left-color: var(--danger);
    background: var(--danger-soft);
  }
  .config-editor textarea {
    display: block;
    box-sizing: border-box;
    flex: 1;
    min-width: 0;
    min-height: 320px;
    margin: 0;
    padding: 14px 16px;
    border: 0;
    border-radius: 0;
    resize: vertical;
    overflow: auto;
    color: var(--text);
    background: var(--inset);
  }
  .config-editor textarea:focus-visible {
    outline: 1px solid var(--accent-dim);
    outline-offset: -1px;
  }
  .editor-error,
  .editor-note {
    margin: 0;
    padding: 8px 16px;
    font-size: 13px;
  }
  .editor-error {
    color: var(--danger);
    background: var(--danger-soft);
  }
  .editor-note {
    color: var(--verdigris);
    background: var(--verdigris-soft);
  }
  .editor-note.muted-note {
    color: var(--muted);
    background: var(--raised);
  }
  .key-help {
    max-height: 132px;
    overflow: auto;
    padding: 8px 16px;
    font-size: 13px;
    border-top: 1px solid var(--border);
    background: var(--raised);
  }
  .key-help p {
    margin: 0;
  }
  .key-help .about {
    margin-top: 4px;
    color: var(--muted);
  }
  .key-help .kind {
    margin-left: 10px;
    font: 12px var(--mono);
    color: var(--faint);
  }
  .key-help .about .kind {
    margin-left: 0;
  }
  .diagnostics {
    margin: 0;
    padding: 0;
    list-style: none;
    max-height: 240px;
    overflow: auto;
    border-top: 1px solid var(--border);
  }
  .diagnostics.stale {
    opacity: 0.6;
  }
  .diagnostics li + li {
    border-top: 1px solid var(--border-soft);
  }
  .diagnostics button,
  .diagnostics div {
    display: flex;
    align-items: baseline;
    gap: 10px;
    box-sizing: border-box;
    width: 100%;
    min-height: 30px;
    padding: 6px 16px;
    font-size: 13px;
    text-align: left;
    color: var(--text);
    background: none;
    border: 0;
    border-radius: 0;
  }
  .diagnostics button:hover,
  .diagnostics button:focus-visible {
    background: var(--hover);
  }
  .diagnostics .place {
    flex: none;
    min-width: 64px;
    font: 12px var(--mono);
    color: var(--muted);
    font-variant-numeric: tabular-nums;
  }
  .diagnostics .message {
    min-width: 0;
    overflow-wrap: anywhere;
  }
  .config-section {
    margin-top: 16px;
    overflow: hidden;
  }
  .only {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 13px;
    color: var(--muted);
    white-space: nowrap;
  }
  .config-section .toolbar .only input {
    flex: none;
    min-width: 0;
    margin: 0;
  }
  .config-section .toolbar input {
    margin-left: auto;
    flex: 1;
    max-width: 300px;
  }
  summary {
    cursor: pointer;
    padding: 12px 16px;
    font-size: 13px;
    color: var(--accent);
  }
  pre {
    margin: 0;
    padding: 16px;
    background: var(--inset);
    max-height: 600px;
    color: var(--text);
  }
  .raw-state {
    margin-top: 12px;
    overflow: hidden;
  }
  @media (max-width: 950px) {
    .runtime-grid {
      grid-template-columns: 1fr;
    }
  }
  @media print {
    .runtime-grid {
      grid-template-columns: repeat(2, minmax(0, 1fr));
    }
    .runtime-grid section {
      break-inside: avoid;
    }
    .refresh {
      display: none;
    }
    .config-section,
    .raw-state {
      overflow: visible;
    }
    .diagnostics,
    .key-help {
      max-height: none;
    }
    pre {
      padding: 12px;
    }
  }
</style>
