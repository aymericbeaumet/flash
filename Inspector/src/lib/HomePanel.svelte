<script lang="ts">
  import { tick } from "svelte";
  import Icon from "./Icon.svelte";
  import { buildOnboarding, loadReadGuides, markGuideRead, markGuideUnread, type Step, type StepStatus } from "./onboarding";
  import { paths } from "./routes";
  import type { InspectorState } from "./types";

  let { snapshot, connected }: { snapshot: InspectorState; connected: boolean } = $props();
  let revision = $state(0);
  let filter = $state<"all" | "todo" | "done">("all");
  let openId = $state<string | null>(null);
  let chosen = $state(false);
  let copied = $state<string | null>(null);

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

  async function copySnippet(step: Step) {
    if (!step.snippet) return;
    try {
      await navigator.clipboard.writeText(step.snippet);
      copied = step.id;
    } catch {
      copied = null;
    }
  }

  function label(status: StepStatus): string {
    if (status === "done") return "Done";
    if (status === "attention") return "Needs attention";
    if (status === "waiting") return "Waiting";
    return "To do";
  }
</script>

<div class="page home">
  <header class="intro">
    <p class="eyebrow">On this Mac</p>
    <h1>{model.title}</h1>
    <p class="lede">{model.lede}</p>
    {#if model.total > 0}
      <div class="progress" role="progressbar" aria-valuenow={model.done} aria-valuemin="0" aria-valuemax={model.total} aria-label="Checklist progress">
        <span style:width="{model.total === 0 ? 0 : (model.done / model.total) * 100}%"></span>
      </div>
      <p class="progress-label">{model.done} of {model.total} done</p>
    {/if}
    <div class="hero-actions">
      <a class="primary" href={paths.docs("getting-started")}>Start with the essentials <Icon name="arrow" size={16} /></a>
      <a class="text-link" href={paths.docs()}>All documentation <Icon name="arrow" size={15} /></a>
      <a class="text-link" href={paths.mappings()}>Your key mappings <Icon name="arrow" size={15} /></a>
    </div>
  </header>

  {#if model.blockers.length > 0 || model.next}
    <section class="missing surface" aria-label="What is missing">
      <h2>What is missing</h2>
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
    <h2>Checklist</h2>
    <div class="segmented" role="group" aria-label="Filter checklist">
      <button type="button" class:active={filter === "all"} aria-pressed={filter === "all"} onclick={() => filter = "all"}>All</button>
      <button type="button" class:active={filter === "todo"} aria-pressed={filter === "todo"} onclick={() => filter = "todo"}>Still to do</button>
      <button type="button" class:active={filter === "done"} aria-pressed={filter === "done"} onclick={() => filter = "done"}>Done</button>
    </div>
  </div>

  {#if visible.length === 0}
    <p class="empty-filter">Nothing in this filter.</p>
  {/if}

  {#each visible as section (section.id)}
    <section class="group" aria-labelledby="group-{section.id}">
      <div class="group-heading">
        <h2 id="group-{section.id}">{section.title}</h2>
        <p>{section.intro}</p>
      </div>
      <div class="steps">
        {#each section.steps as step (step.id)}
          <article class="surface step" class:open={openId === step.id} id="step-{step.id}">
            <h3>
              <button type="button" class="step-toggle" aria-expanded={openId === step.id} aria-controls="step-body-{step.id}" onclick={() => toggle(step.id)}>
                <span class="mark" data-status={step.status} aria-hidden="true">{step.status === "done" ? "✓" : step.status === "attention" ? "!" : step.status === "waiting" ? "…" : ""}</span>
                <span class="step-copy"><span class="step-title">{step.title}</span><span class="evidence">{step.evidence}</span></span>
                <span class="badge" data-status={step.status}>{label(step.status)}</span>
              </button>
            </h3>
            <div class="step-body" class:shown={openId === step.id} id="step-body-{step.id}">
                <p>{step.body}</p>
                {#if step.snippet}
                  <pre>{step.snippet}</pre>
                  <button type="button" class="copy" onclick={() => copySnippet(step)}>{copied === step.id ? "Copied" : "Copy"}</button>
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

  <footer class="home-footer">
    <span>Open this page with <code>flash help_show</code>. Jump to a guide with <code>flash help_show --topic=&lt;topic&gt;</code>.</span>
    <span>Flash {snapshot.runtime?.version ?? ""}</span>
  </footer>
</div>

<style>
  .home { max-width: 880px; }
  .intro { padding: 8px 0 8px; }
  .lede { margin-top: 12px; max-width: 62ch; color: var(--muted); font-size: 15px; line-height: 1.6; }
  .progress { height: 8px; margin-top: 22px; border-radius: 99px; background: var(--panel-strong); overflow: hidden; }
  .progress span { display: block; height: 100%; background: var(--accent); border-radius: inherit; }
  .progress-label { margin-top: 8px; font-size: 12px; color: var(--muted); font-variant-numeric: tabular-nums; }
  .hero-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 16px 18px; margin-top: 22px; }
  .primary { display: inline-flex; align-items: center; gap: 10px; background: #2b533d; color: white; border-radius: 7px; padding: 11px 15px; font-weight: 500; font-size: 13px; }
  .primary:hover { background: #1c402c; text-decoration: none; }
  .text-link { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; }
  .missing { margin-top: 28px; padding: 18px 18px 8px; }
  .missing h2, .list-head h2, .group-heading h2 { font-size: 16px; }
  .missing ul { list-style: none; margin: 12px 0 0; padding: 0; }
  .missing li { border-top: 1px solid var(--border-soft); }
  .missing button, .next { display: flex; flex-direction: column; align-items: flex-start; gap: 3px; width: 100%; text-align: left; border: 0; background: transparent; border-radius: 0; padding: 12px 2px; min-height: 0; }
  .next { color: inherit; text-decoration: none; }
  .missing button:hover, .next:hover { background: #f7faf4; }
  .missing strong, .next strong { font-size: 14px; }
  .missing span, .next span, .later { color: var(--muted); font-size: 13px; }
  .next { border-radius: 8px; }
  .later { margin: 0 2px 12px; }
  .list-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; margin: 32px 0 8px; flex-wrap: wrap; }
  .empty-filter { color: var(--muted); margin: 12px 0 0; }
  .group { margin-top: 22px; }
  .group-heading p { margin-top: 4px; color: var(--muted); font-size: 13px; max-width: 68ch; }
  .steps { display: flex; flex-direction: column; gap: 8px; margin-top: 12px; }
  .step { overflow: hidden; }
  .step h3 { margin: 0; font-size: inherit; font-weight: inherit; }
  .step-toggle { display: grid; grid-template-columns: 22px minmax(0, 1fr) auto; gap: 10px; align-items: center; width: 100%; text-align: left; border: 0; background: transparent; border-radius: 0; min-height: 0; padding: 12px 14px; }
  .step-toggle:hover { background: #f8faf6; }
  .mark { width: 22px; height: 22px; border-radius: 50%; display: grid; place-items: center; font-size: 12px; background: var(--panel-strong); color: var(--muted); }
  .mark[data-status="done"] { background: var(--accent-soft); color: var(--accent); }
  .mark[data-status="attention"] { background: #fbeae6; color: var(--danger); }
  .step-copy { min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .step-title { font-weight: 600; font-size: 14px; }
  .evidence { color: var(--muted); font-size: 13px; overflow-wrap: anywhere; }
  .badge[data-status="done"] { background: var(--accent-soft); }
  .badge[data-status="attention"] { background: #fbeae6; color: var(--danger); }
  .badge[data-status="waiting"], .badge[data-status="todo"] { background: #f0f2ee; color: var(--muted); }
  .step-body { display: none; padding: 0 14px 14px 46px; }
  .step-body.shown { display: block; }
  .step-body p { color: var(--text); font-size: 14px; max-width: 68ch; }
  .step-body pre { margin: 12px 0 0; padding: 12px 14px; background: #f6f7f4; border: 1px solid var(--border-soft); border-radius: 8px; max-width: 100%; }
  .copy { margin-top: 8px; }
  .step-links { display: flex; flex-wrap: wrap; align-items: center; gap: 12px 16px; margin-top: 12px; }
  .step-links a { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; }
  .home-footer { display: flex; justify-content: space-between; gap: 16px; flex-wrap: wrap; color: #85907f; font-size: 12px; margin-top: 28px; }
  @media (max-width: 640px) {
    .step-toggle { grid-template-columns: 22px minmax(0, 1fr); }
    .step-toggle .badge { grid-column: 2; justify-self: start; }
    .step-body { padding-left: 14px; }
  }
  @media print {
    .missing button, .next, .step-toggle, .copy { border: 0; }
    .step-body { display: block; }
    .step { break-inside: avoid; }
  }
</style>
