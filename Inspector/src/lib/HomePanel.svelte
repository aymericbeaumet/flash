<script lang="ts">
  import Icon from "./Icon.svelte";
  import { paths } from "./routes";
  import type { InspectorState } from "./types";
  let { state, connected }: { state: InspectorState; connected: boolean } = $props();
  const features = [
    { title: "Point with your keyboard", text: "Click a label, refine a grid, or move the pointer. Reach anything on screen.", topic: "hints", icon: "grid", label: "Hints & grid" },
    { title: "Find it with flashlight", text: "Apps, tabs, terminal windows, emoji, and quick answers in one command bar.", topic: "flashlight", icon: "search", label: "Search & answers" },
    { title: "Make macOS modal", text: "Navigate, scroll, switch tabs, and act with a consistent set of keys.", topic: "normal-mode", icon: "mappings", label: "Modes & navigation" },
    { title: "Build your own workspace", text: "Live status bars, desktop widgets, and popups, composed in your config.", topic: "widgets", icon: "settings", label: "Status & widgets" },
  ];
  const running = $derived((state.plugins ?? []).filter((plugin) => plugin.state === "running" || plugin.state === "ready").length);
  const failed = $derived((state.plugins ?? []).filter((plugin) => ["failed", "crashed", "error"].includes(plugin.state)).length);
  const mappings = $derived(state.mappings?.effective_rows ?? state.mappings?.rows ?? []);
</script>

<div class="page home">
  <section class="hero">
    <div class="hero-copy"><p class="eyebrow">Your keyboard, all of macOS</p><h1>A little guidance.<br />A lot more possibility.</h1><p class="intro">Get to know Flash, make it yours, and see what’s happening on your Mac. Your guide and your running app, together.</p><div class="hero-actions"><a class="primary" href="/docs/getting-started">Start with the essentials <Icon name="arrow" size={16} /></a><a class="secondary" href="/mappings">Explore your mappings <span>↗</span></a></div></div>
    <div class="keyboard-art" aria-hidden="true"><div class="art-caption"><span>LESS REACHING. MORE DOING.</span><i></i></div><div class="key-row"><span>q</span><span>w</span><span>e</span><span>r</span><span>t</span></div><div class="key-row"><span>a</span><span>s</span><span>d</span><span class="hint-key">f<small>HINTS</small></span><span>g</span></div><div class="key-row"><span>z</span><span>x</span><span>c</span><span>v</span><span>b</span></div><div class="art-footer"><span class="tiny-bolt"><Icon name="bolt" size={14} /></span>ONE KEY. EVERYWHERE.</div></div>
  </section>

  {#if state.runtime?.config_error}<div class="notice error"><strong>Your configuration needs attention.</strong> {state.runtime.config_error} <a href="/state">Inspect configuration →</a></div>{/if}
  {#if state.runtime?.accessibility_trusted === false}<div class="notice"><strong>Accessibility is not granted.</strong> Enable Flash in System Settings to use keyboard navigation and hints. <a href="/docs/troubleshooting">View troubleshooting →</a></div>{/if}

  <section class="runtime-strip surface" aria-label="Current runtime summary"><div class="live-title"><span class="live-dot" class:offline={!connected}></span><span><strong>Your Flash, right now</strong><small>{connected ? "Updates live from the resident app" : "Waiting for a live connection"}</small></span></div><a href="/state"><span class="stat-label">Mode</span><strong class="mode">{state.mode ?? "—"}</strong></a><a href="/state"><span class="stat-label">Focused app</span><strong>{state.focused_app?.localized_name ?? "No focused app"}</strong></a><a href="/plugins"><span class="stat-label">Plugins</span><strong>{running} running{#if failed}<span class="failed"> · {failed} failed</span>{/if}</strong></a><a href="/state" class="runtime-arrow" aria-label="Inspect full runtime"><Icon name="arrow" size={19} /></a></section>

  <section class="feature-section"><div class="section-heading"><div><p class="eyebrow">Find your next move</p><h2>One tool. Many ways to work.</h2></div><a href="/docs">All documentation <Icon name="arrow" size={15} /></a></div><div class="feature-grid">{#each features as feature}<a class="feature-card surface" href={paths.docs(feature.topic)}><span class="feature-icon"><Icon name={feature.icon} size={22} /></span><span class="feature-label">{feature.label}</span><h3>{feature.title}</h3><p>{feature.text}</p><span class="card-arrow"><Icon name="arrow" size={17} /></span></a>{/each}</div></section>

  <div class="bottom-grid"><section class="quick-reference surface"><div class="section-heading"><h2>Make yourself at home</h2><Icon name="commands" size={20} /></div><a href="/mappings"><span><strong>Your key mappings</strong><small>{mappings.length} effective bindings from your current configuration</small></span><kbd>?</kbd></a><a href="/commands"><span><strong>The command catalog</strong><small>{(state.commands ?? []).length} built-in and plugin commands to explore</small></span><kbd>:</kbd></a><a href="/docs/config"><span><strong>One file. Your workflow.</strong><small>Configure Flash in TOML; changes apply when you save</small></span><Icon name="arrow" size={16} /></a></section><section class="extend-card"><p class="eyebrow">Made to be extended</p><h2>More Flash,<br />your way.</h2><p>Discover the plugins powering your workspace, or build something of your own.</p><a href="/plugins">Meet your plugins <Icon name="arrow" size={16} /></a><a href="/docs/plugins" class="sub-link">Read the plugin guide</a></section></div>
  <footer class="home-footer"><span>Open this page with <code>:help</code>. Jump to a guide with <code>:help &lt;topic&gt;</code>.</span><span>Flash {state.runtime?.version ?? ""}</span></footer>
</div>

<style>
  .home { max-width: 1370px; }
  .hero { display: grid; grid-template-columns: 1.3fr 1fr; align-items: center; gap: 40px; padding: 15px 0 40px; }
  .hero .eyebrow { color: #6b805c; font-size: 10px; margin-bottom: 18px; }
  .hero h1 { font-size: clamp(32px, 3.3vw, 49px); letter-spacing: -.05em; line-height: 1.13; font-weight: 550; }
  .intro { margin-top: 18px; max-width: 460px; font-size: 14px; color: var(--muted); line-height: 1.75; }
  .hero-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 16px; margin-top: 24px; font-size: 11px; }
  .primary { display: flex; align-items: center; gap: 13px; background: #2b533d; color: white; border-radius: 7px; padding: 11px 15px; font-weight: 500; }
  .primary:hover { background: #1c402c; text-decoration: none; }
  .secondary { display: flex; gap: 8px; font-size: 11px; }
  .keyboard-art { max-width: 335px; justify-self: end; width: 100%; padding: 24px 24px 17px; border-radius: 18px; background: linear-gradient(145deg, #e7eddd, #eff1e4); border: 1px solid #dfe6d5; transform: rotate(-3deg); box-shadow: 0 10px 30px #44563407; }
  .art-caption { font-size: 7px; letter-spacing: .16em; color: #839073; display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px; }
  .art-caption i { width: 5px; height: 5px; background: #83a070; border-radius: 50%; }
  .key-row { display: flex; gap: 7px; margin-bottom: 7px; }
  .key-row:nth-child(3) { margin-left: 7px; margin-right: -7px; }
  .key-row:nth-child(4) { margin-left: 14px; margin-right: -14px; }
  .key-row > span { flex: 1; height: 43px; background: #f9faf3; border: 1px solid #d7decb; border-bottom: 3px solid #ced7c0; border-radius: 7px; display: flex; align-items: center; justify-content: center; font-family: var(--mono); font-size: 14px; color: #95a088; }
  .key-row > span.hint-key { background: #d5e49a; border-color: #b7cb71; color: #4a6123; position: relative; font-size: 18px; transform: translateY(-3px); box-shadow: 0 4px 8px #78895420; }
  .hint-key small { position: absolute; bottom: 4px; font-size: 5px; letter-spacing: .08em; }
  .art-footer { margin-top: 20px; display: flex; align-items: center; gap: 8px; font-size: 6px; color: #8a977c; letter-spacing: .17em; }
  .tiny-bolt { display: flex; }
  .runtime-strip { display: grid; grid-template-columns: 1.4fr .7fr 1fr .8fr auto; gap: 20px; align-items: center; padding: 21px 24px; font-size: 12px; }
  .live-title { display: flex; gap: 11px; align-items: center; }
  .live-title strong { font-weight: 550; }
  .live-title small { display: block; color: var(--muted); font-size: 10px; margin-top: 3px; }
  .live-dot { width: 7px; height: 7px; background: #6b9560; box-shadow: 0 0 0 4px #eff4e9; border-radius: 50%; flex-shrink: 0; }
  .live-dot.offline { background: #c5a458; }
  .runtime-strip a { color: var(--text); min-width: 0; }
  .runtime-strip a strong { display: block; font-size: 12px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .stat-label { display: block; font-size: 9px; color: var(--muted); margin-bottom: 4px; }
  .mode { text-transform: uppercase; letter-spacing: .06em; color: var(--accent); }
  .failed { color: var(--danger); }
  .runtime-arrow { display: flex; }
  .feature-section { margin-top: 36px; }
  .section-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 19px; }
  .section-heading .eyebrow { margin-bottom: 7px; }
  .section-heading h2 { font-size: 21px; }
  .section-heading > a { display: flex; gap: 7px; align-items: center; font-size: 11px; white-space: nowrap; }
  .feature-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 14px; }
  .feature-card { padding: 23px 20px 21px; color: var(--text); position: relative; text-decoration: none; transition: transform 150ms, border-color 150ms; }
  .feature-card:hover { transform: translateY(-3px); border-color: #a3b396; }
  .feature-icon { color: #5a7350; display: flex; margin-bottom: 24px; }
  .feature-label { display: block; font-size: 8px; letter-spacing: .09em; text-transform: uppercase; color: var(--muted); margin-bottom: 7px; }
  .feature-card h3 { font-size: 15px; line-height: 1.4; }
  .feature-card p { color: var(--muted); font-size: 11px; line-height: 1.8; margin: 9px 0 24px; }
  .card-arrow { display: flex; color: #79906d; }
  .bottom-grid { display: grid; grid-template-columns: 1.45fr 1fr; gap: 20px; margin-top: 24px; }
  .quick-reference { padding: 24px; }
  .quick-reference h2 { font-size: 17px; }
  .quick-reference .section-heading { margin-bottom: 5px; }
  .quick-reference > a { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 17px 0; border-bottom: 1px solid var(--border-soft); color: var(--text); }
  .quick-reference > a:last-child { border-bottom: 0; padding-bottom: 0; }
  .quick-reference strong { font-size: 12px; font-weight: 500; }
  .quick-reference small { display: block; color: var(--muted); font-size: 10px; margin-top: 4px; }
  .extend-card { padding: 26px 28px; background: #e8eedf; border: 1px solid #dce5d0; border-radius: 12px; }
  .extend-card .eyebrow { font-size: 8px; }
  .extend-card h2 { margin-top: 12px; font-size: 29px; line-height: 1.15; }
  .extend-card p:not(.eyebrow) { max-width: 300px; font-size: 11px; color: #6b7863; margin-top: 11px; line-height: 1.8; }
  .extend-card a { display: flex; align-items: center; gap: 12px; margin-top: 15px; font-size: 11px; }
  .extend-card .sub-link { font-size: 10px; color: var(--muted); margin-top: 8px; }
  .home-footer { display: flex; justify-content: space-between; gap: 20px; color: #85907f; font-size: 9px; margin-top: 25px; }
  @media (max-width: 1200px) { .feature-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } .runtime-strip { grid-template-columns: 1.3fr .6fr 1fr .8fr; gap: 14px; } .runtime-arrow { display: none; } .hero { gap: 24px; } .keyboard-art { padding: 20px 16px; } }
  @media (max-width: 950px) { .hero { grid-template-columns: 1fr; } .keyboard-art { display: none; } .runtime-strip { grid-template-columns: repeat(3, 1fr); } .live-title { grid-column: 1 / -1; } .bottom-grid { grid-template-columns: 1fr; } }
  @media (max-width: 450px) { .feature-grid { grid-template-columns: 1fr; } .feature-card { padding: 20px; } .feature-icon { margin-bottom: 15px; } .runtime-strip { padding: 18px; gap: 16px 10px; } .section-heading { align-items: flex-start; } .section-heading > a { font-size: 10px; } .home-footer { flex-direction: column; gap: 5px; } }
  @media print {
    .hero { grid-template-columns: 1fr; padding-bottom: 24px; }
    .keyboard-art, .runtime-arrow, .card-arrow { display: none; }
    .primary { color: var(--accent); background: none; border: 1px solid var(--accent); }
    .feature-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .runtime-strip { grid-template-columns: repeat(3, minmax(0, 1fr)); }
    .live-title { grid-column: 1 / -1; }
    .runtime-strip, .feature-card, .quick-reference, .extend-card { break-inside: avoid; }
    .bottom-grid { grid-template-columns: 1fr; }
  }
</style>
