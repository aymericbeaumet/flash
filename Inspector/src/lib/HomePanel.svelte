<script lang="ts">
  import { tick } from "svelte";
  import Icon from "./Icon.svelte";
  import { monitorCounts } from "./monitors";
  import PageHeader from "./PageHeader.svelte";
  import SectionHead from "./SectionHead.svelte";
  import { buildOnboarding, loadReadGuides, markGuideRead, markGuideUnread, type Step, type StepStatus } from "./onboarding";
  import { paths } from "./routes";
  import { copyText } from "./toasts.svelte";
  import type { InspectorState } from "./types";

  let { snapshot, connected }: { snapshot: InspectorState; connected: boolean } = $props();
  let revision = $state(0);
  let filter = $state<"all" | "todo" | "done">("all");
  let openId = $state<string | null>(null);
  let chosen = $state(false);

  const model = $derived.by(() => {
    revision;
    return buildOnboarding(snapshot, connected, loadReadGuides());
  });
  const visible = $derived(model.sections.map((section) => ({
    ...section,
    steps: section.steps.filter((step) => matches(step, filter)),
  })).filter((section) => section.steps.length > 0));

  $effect(() => {
    if (chosen) return;
    openId = model.blockers[0]?.id ?? model.next?.id ?? null;
  });

  function matches(step: Step, which: typeof filter): boolean {
    if (which === "all") return true;
    if (which === "done") return step.status === "done";
    return step.status === "todo" || step.status === "attention";
  }

  function toggle(id: string) {
    chosen = true;
    openId = openId === id ? null : id;
  }

  async function show(id: string) {
    chosen = true;
    filter = "all";
    openId = id;
    await tick();
    document.getElementById(`step-${id}`)?.scrollIntoView({ block: "nearest" });
  }

  function toggleGuide(step: Step) {
    if (!step.guide) return;
    if (step.status === "done") markGuideUnread(step.guide);
    else markGuideRead(step.guide);
    revision += 1;
  }

  function copySnippet(step: Step) {
    if (step.snippet) void copyText(step.snippet, "the TOML for this step");
  }

  // The instrument strip: what is true on this Mac now, each a way into its page.
  const runtime = $derived(snapshot.runtime);
  const pluginList = $derived(snapshot.plugins ?? []);
  const pluginsRunning = $derived(pluginList.filter((plugin) => plugin.state === "running" || plugin.state === "ready").length);
  const pluginsFailing = $derived(pluginList.filter((plugin) => !!plugin.last_error || ["failed", "crashed", "error"].includes(plugin.state)).length);
  const monitors = $derived(monitorCounts(snapshot.monitors ?? []));
  const known = $derived(snapshot.snapshot_at_unix_ms != null);
  const gauges = $derived([
    { label: "Mode", href: "/mappings", value: snapshot.mode ? snapshot.mode.toUpperCase() : "—", detail: snapshot.hint_session && snapshot.hint_session !== "idle" ? `hints ${snapshot.hint_session}` : `app ${snapshot.focused_app?.localized_name ?? "—"}`, state: "neutral" },
    { label: "Input", href: "/state", value: !known ? "—" : runtime?.accessibility_trusted && runtime?.keyboard_capture_active ? "Captured" : runtime?.accessibility_trusted ? "No tap" : "No access", detail: runtime?.secure_input ? "secure input on" : runtime?.accessibility_trusted ? "accessibility granted" : "grant accessibility", state: !known ? "neutral" : runtime?.accessibility_trusted && runtime?.keyboard_capture_active && !runtime?.secure_input ? "ok" : "warning" },
    { label: "Plugins", href: "/plugins", value: known ? `${pluginsRunning}/${pluginList.length}` : "—", detail: pluginsFailing ? `${pluginsFailing} need attention` : "running / loaded", state: pluginsFailing ? "error" : known ? "ok" : "neutral" },
    { label: "Monitors", href: "/monitors", value: snapshot.monitors?.length ? String(monitors.error + monitors.warning) : "—", detail: !snapshot.monitors?.length ? "none reported" : monitors.error ? `${monitors.error} error · ${monitors.warning} warning` : monitors.warning ? `${monitors.warning} warning` : "all within thresholds", state: monitors.error ? "error" : monitors.warning ? "warning" : snapshot.monitors?.length ? "ok" : "neutral" },
    { label: "Telemetry", href: "/telemetry", value: !known || !snapshot.telemetry ? "—" : snapshot.telemetry.receiver.enabled ? (snapshot.telemetry.receiver.listening ? "Receiving" : "Not listening") : "Off", detail: !snapshot.telemetry?.receiver.enabled ? (snapshot.telemetry?.exporter.enabled ? "exporting · receiver off" : "OpenTelemetry in and out") : `${snapshot.telemetry.receiver.series} series${snapshot.telemetry.exporter.enabled ? " · exporting" : ""}`, state: !snapshot.telemetry?.receiver.enabled ? "neutral" : snapshot.telemetry.receiver.listening ? "ok" : "error" },
    { label: "Config", href: "/state#config-editor", value: !known ? "—" : runtime?.config_error ? "Error" : "Loaded", detail: runtime?.config_error ? "see Runtime & config" : (runtime?.config_path ?? "").replace(/^\/Users\/[^/]+/, "~"), state: !known ? "neutral" : runtime?.config_error ? "error" : "ok" },
  ]);

  function label(status: StepStatus): string {
    if (status === "done") return "Done";
    if (status === "attention") return "Needs attention";
    if (status === "waiting") return "Waiting";
    return "To do";
  }
</script>

<div class="page home">
  <PageHeader id="home" title={model.title} purpose={model.lede} manual={paths.docs("getting-started")} live>
    {#snippet help()}
      <p>This page checks your Mac against what Flash needs and suggests what to set up next. Flash reports permissions, the configuration file, shortcuts, plugins and the status bar itself; the guides you have read are remembered by this browser only.</p>
      <p>Open it with <code>flash help show</code>, or jump to a guide with <code>flash help show --topic=&lt;topic&gt;</code>.</p>
    {/snippet}
  </PageHeader>

  <nav class="gauges" aria-label="This Mac now">
    {#each gauges as gauge}<a class="gauge-tile surface" data-state={gauge.state} href={gauge.href}><span class="gauge-label"><i class="lamp" aria-hidden="true"></i>{gauge.label}</span><strong>{gauge.value}</strong><span class="gauge-detail">{gauge.detail}</span></a>{/each}
  </nav>

  {#if model.total > 0}
    <div class="progress-row">
      <div class="progress" role="progressbar" aria-valuenow={model.done} aria-valuemin="0" aria-valuemax={model.total} aria-label="Checklist progress">
        <span style:width="{model.total === 0 ? 0 : (model.done / model.total) * 100}%"></span>
      </div>
      <p class="progress-label">{model.done} of {model.total} done</p>
      <div class="hero-actions">
        <a href={paths.docs("getting-started")}>Start with the essentials <Icon name="arrow" size={14} /></a>
        <a href={paths.docs()}>All documentation <Icon name="arrow" size={14} /></a>
      </div>
    </div>
  {/if}

  {#if model.blockers.length > 0 || model.next}
    <section class="missing surface" aria-labelledby="missing-title">
      <SectionHead id="missing-title" title="What is missing" count={model.blockers.length || undefined} />
      {#if model.blockers.length > 0}
        <ul>
          {#each model.blockers as blocker}
            <li>
              {#if blocker.href}
                <a class="next" href={blocker.href}>
                  <strong>{blocker.title}</strong>
                  <span>{blocker.evidence}</span>
                </a>
              {:else}
                <button type="button" onclick={() => show(blocker.id)}>
                  <strong>{blocker.title}</strong>
                  <span>{blocker.evidence}</span>
                </button>
              {/if}
            </li>
          {/each}
        </ul>
      {:else if model.next}
        {#if model.next.href}
          <a class="next" href={model.next.href}>
            <span class="eyebrow">Next</span>
            <strong>{model.next.title}</strong>
            <span>{model.next.evidence}</span>
          </a>
        {:else}
          <button type="button" class="next" onclick={() => show(model.next?.id ?? "")}>
            <span class="eyebrow">Next</span>
            <strong>{model.next.title}</strong>
            <span>{model.next.evidence}</span>
          </button>
        {/if}
        {#if model.later > 0}<p class="later">{model.later} more after this.</p>{/if}
      {/if}
    </section>
  {/if}

  <div class="list-head">
    <SectionHead id="checklist-title" title="Checklist">
      {#snippet actions()}
        <div class="segmented" role="group" aria-label="Filter checklist">
          <button type="button" class:active={filter === "all"} aria-pressed={filter === "all"} onclick={() => filter = "all"}>All</button>
          <button type="button" class:active={filter === "todo"} aria-pressed={filter === "todo"} onclick={() => filter = "todo"}>Still to do</button>
          <button type="button" class:active={filter === "done"} aria-pressed={filter === "done"} onclick={() => filter = "done"}>Done</button>
        </div>
      {/snippet}
    </SectionHead>
  </div>

  {#if visible.length === 0}
    <p class="empty-filter">Nothing in this filter.</p>
  {/if}

  {#each visible as section (section.id)}
    <section class="group" aria-labelledby="group-{section.id}">
      <div class="group-heading">
        <h3 id="group-{section.id}">{section.title}</h3>
        <p>{section.intro}</p>
      </div>
      <div class="steps surface">
        {#each section.steps as step (step.id)}
          <article class="step" class:open={openId === step.id} id="step-{step.id}">
            <h4>
              <button type="button" class="step-toggle" aria-expanded={openId === step.id} aria-controls="step-body-{step.id}" onclick={() => toggle(step.id)}>
                <span class="mark" data-status={step.status} aria-hidden="true">{step.status === "done" ? "✓" : step.status === "attention" ? "!" : step.status === "waiting" ? "…" : ""}</span>
                <span class="step-copy"><span class="step-title">{step.title}</span><span class="evidence">{step.evidence}</span></span>
                <span class="badge" data-status={step.status}>{label(step.status)}</span>
              </button>
            </h4>
            <div class="step-body" class:shown={openId === step.id} id="step-body-{step.id}">
                <p>{step.body}</p>
                {#if step.snippet}
                  <pre class="well">{step.snippet}</pre>
                  <button type="button" class="copy" onclick={() => copySnippet(step)}>Copy</button>
                {/if}
                <div class="step-links">
                  {#if step.href}<a href={step.href} onclick={() => step.guide && markGuideRead(step.guide)}>{step.hrefLabel} <Icon name="arrow" size={14} /></a>{/if}
                  {#if step.guide}
                    <button type="button" onclick={() => toggleGuide(step)}>{step.status === "done" ? "Mark as unread" : "Mark as read"}</button>
                  {/if}
                </div>
              </div>
          </article>
        {/each}
      </div>
    </section>
  {/each}
</div>

<style>
  .home { max-width: 1040px; }
  .gauges { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 8px; margin-bottom: 18px; }
  .gauge-tile { display: flex; flex-direction: column; gap: 2px; min-width: 0; padding: 10px 12px; color: var(--text); border-top: 2px solid var(--border-strong); }
  .gauge-tile:hover { text-decoration: none; border-color: var(--border-strong); color: var(--text); background: var(--raised); }
  .gauge-tile[data-state="ok"] { border-top-color: rgba(111, 181, 163, .6); }
  .gauge-tile[data-state="warning"] { border-top-color: var(--amber); }
  .gauge-tile[data-state="error"] { border-top-color: var(--danger); }
  .gauge-label { display: flex; align-items: center; gap: 8px; font: 500 12px var(--mono); letter-spacing: .12em; text-transform: uppercase; color: var(--muted); }
  .lamp { width: 8px; height: 8px; border-radius: 50%; background: var(--faint); box-shadow: 0 0 0 2px var(--panel), 0 0 0 3px var(--accent-dim); }
  [data-state="ok"] .lamp { background: var(--verdigris); }
  [data-state="warning"] .lamp { background: var(--amber); }
  [data-state="error"] .lamp { background: var(--danger); }
  .gauge-tile strong { font: 600 20px/1.3 var(--mono); margin-top: 4px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  [data-state="warning"] strong { color: var(--amber); }
  [data-state="error"] strong { color: var(--danger); }
  .gauge-detail { font-size: 12px; color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .progress-row { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 16px; margin-bottom: 18px; }
  /* A brass bar over a ruled track: one tick per checklist item. */
  .progress { position: relative; flex: 1 1 260px; height: 8px; border-radius: 2px; background: var(--inset); box-shadow: var(--well); overflow: hidden; }
  .progress span { display: block; height: 100%; background: var(--accent); border-radius: 2px; }
  .progress-label { font: 12px var(--mono); color: var(--muted); font-variant-numeric: tabular-nums; }
  .hero-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 18px; margin-left: auto; }
  .hero-actions a { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; min-height: 32px; }
  .missing { margin-bottom: 18px; padding: 10px 16px 6px; border-left: 2px solid var(--amber); }
  .missing ul { list-style: none; margin: 0; padding: 0; }
  .missing li { border-top: 1px solid var(--border-soft); }
  .missing button, .next { display: flex; flex-direction: column; align-items: flex-start; gap: 2px; width: 100%; text-align: left; border: 0; background: transparent; border-radius: 0; padding: 9px 2px; min-height: 0; color: inherit; }
  .next { color: inherit; text-decoration: none; }
  .missing button:hover, .next:hover { background: var(--hover); text-decoration: none; color: inherit; }
  .missing strong, .next strong { font-size: 14px; }
  .missing span, .next span, .later { color: var(--muted); font-size: 13px; }
  .next { border-radius: 5px; }
  .later { margin: 0 2px 10px; }
  .list-head { margin-top: 6px; }
  .empty-filter { color: var(--muted); margin: 12px 0 0; }
  .group { margin-top: 14px; }
  .group-heading { display: flex; align-items: baseline; flex-wrap: wrap; gap: 4px 12px; margin-bottom: 8px; }
  .group-heading h3 { font-size: 14px; }
  .group-heading p { color: var(--muted); font-size: 13px; }
  .steps { overflow: hidden; }
  .step + .step { border-top: 1px solid var(--border-soft); }
  .step h4 { margin: 0; font-size: inherit; font-weight: inherit; }
  .step-toggle { display: grid; grid-template-columns: 22px minmax(0, 1fr) auto; gap: 12px; align-items: center; width: 100%; text-align: left; border: 0; background: transparent; border-radius: 0; min-height: 44px; padding: 8px 14px; }
  .step-toggle:hover { background: var(--hover); }
  .mark { width: 20px; height: 20px; border-radius: 50%; display: grid; place-items: center; font: 600 12px var(--mono); background: var(--inset); border: 1px solid var(--border-strong); color: var(--muted); }
  .mark[data-status="done"] { background: var(--verdigris-soft); border-color: rgba(111, 181, 163, .5); color: var(--verdigris); }
  .mark[data-status="attention"] { background: var(--danger-soft); border-color: rgba(229, 115, 94, .5); color: var(--danger); }
  .step-copy { min-width: 0; display: flex; align-items: baseline; flex-wrap: wrap; gap: 2px 12px; }
  .step-title { font-weight: 600; font-size: 14px; }
  .evidence { color: var(--muted); font-size: 13px; overflow-wrap: anywhere; }
  .badge[data-status="done"] { background: var(--verdigris-soft); border-color: rgba(111, 181, 163, .3); color: var(--verdigris); }
  .badge[data-status="attention"] { background: var(--danger-soft); border-color: rgba(229, 115, 94, .35); color: var(--danger); }
  .badge[data-status="waiting"], .badge[data-status="todo"] { background: rgba(166, 157, 139, .08); border-color: var(--border); color: var(--muted); }
  .step-body { display: none; padding: 0 14px 14px 48px; }
  .step-body.shown { display: block; }
  .step-body p { color: var(--text); font-size: 13px; max-width: 72ch; }
  .step-body pre { margin: 10px 0 0; padding: 10px 12px; max-width: 100%; color: var(--code); }
  .copy { margin-top: 8px; min-height: 30px; font-size: 12px; }
  .step-links { display: flex; flex-wrap: wrap; align-items: center; gap: 10px 16px; margin-top: 10px; }
  .step-links a { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; }
  .step-links button { min-height: 30px; font-size: 12px; }
  @media (max-width: 1100px) { .gauges { grid-template-columns: repeat(3, minmax(0, 1fr)); } }
  @media (max-width: 640px) {
    .gauges { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .step-toggle { grid-template-columns: 22px minmax(0, 1fr); }
    .step-toggle .badge { grid-column: 2; justify-self: start; }
    .step-body { padding-left: 14px; }
    .hero-actions { margin-left: 0; }
  }
  @media print {
    .gauges { grid-template-columns: repeat(5, minmax(0, 1fr)); }
    .missing button, .next, .step-toggle, .copy { border: 0; }
    .step-body { display: block; }
    .step { break-inside: avoid; }
  }
</style>
