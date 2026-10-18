import type { InspectorState, MappingRow } from "./types.ts";

/** Guides the homepage can mark read. Opening the guide does it; Flash never sees the list. */
export const guideTopics = ["getting-started", "hints", "normal-mode", "config"] as const;

export type GuideTopic = (typeof guideTopics)[number];

const readKey = "flash.help.read-guides";

export type StepStatus = "done" | "todo" | "attention" | "waiting";
export type StepSection = "setup" | "read" | "configure" | "further";

export interface Step {
  id: string;
  section: StepSection;
  title: string;
  /** What is true on this Mac right now. */
  evidence: string;
  body: string;
  status: StepStatus;
  href?: string;
  hrefLabel?: string;
  snippet?: string;
  /** Set on read-steps so the page can toggle the browser mark. */
  guide?: GuideTopic;
}

export interface OnboardingSection {
  id: StepSection;
  title: string;
  intro: string;
  steps: Step[];
}

export interface Onboarding {
  title: string;
  lede: string;
  done: number;
  total: number;
  /** Config errors, a missing permission, secure input, failed plugins. */
  blockers: Step[];
  /** First unfinished recommendation, after blockers. */
  next: Step | null;
  /** Other unfinished checklist items after `next`. */
  later: number;
  sections: OnboardingSection[];
}

export function isGuideTopic(topic: string): topic is GuideTopic {
  return (guideTopics as readonly string[]).includes(topic);
}

export function loadReadGuides(): Set<string> {
  try {
    if (typeof localStorage === "undefined") return new Set();
    const parsed = JSON.parse(localStorage.getItem(readKey) ?? "[]") as unknown;
    if (!Array.isArray(parsed)) return new Set();
    return new Set(parsed.filter((item): item is string => typeof item === "string" && isGuideTopic(item)));
  } catch {
    return new Set();
  }
}

function storeReadGuides(ids: Set<string>) {
  if (typeof localStorage === "undefined") return;
  localStorage.setItem(readKey, JSON.stringify([...ids].filter(isGuideTopic).sort()));
}

/** Remember that this browser opened a tracked guide. Unknown topics are ignored. */
export function markGuideRead(topic: string) {
  if (!isGuideTopic(topic)) return;
  const ids = loadReadGuides();
  if (ids.has(topic)) return;
  ids.add(topic);
  storeReadGuides(ids);
}

export function markGuideUnread(topic: string) {
  if (!isGuideTopic(topic)) return;
  const ids = loadReadGuides();
  if (!ids.delete(topic)) return;
  storeReadGuides(ids);
}

export function buildOnboarding(
  state: InspectorState,
  connected: boolean,
  read: ReadonlySet<string>,
): Onboarding {
  const known = state.snapshot_at_unix_ms != null;
  const rows = state.mappings?.rows ?? [];
  const runtime = state.runtime;
  const config = record(state.config);
  const setup: Step[] = [
    residentStep(connected, known),
    accessibilityStep(known, runtime?.accessibility_trusted),
    keyboardStep(known, runtime),
    configStep(known, runtime?.config_path, runtime?.config_error, hasUserOverride(state.config_sources)),
  ];
  const readSteps: Step[] = [
    guideStep("getting-started", "Read Getting started", "One shortcut, then the grid, search, and NORMAL mode.", read),
    guideStep("hints", "Read hints", "Labels, clicks, and what to do when an app draws nothing.", read),
    guideStep("normal-mode", "Read NORMAL mode", "How keys are captured, and how you type again.", read),
    guideStep("config", "Read configuration", "The TOML file, layers, and what a save applies.", read),
  ];
  const configure: Step[] = [
    mappingStep(known, rows, {
      id: "hints",
      title: "Map a hint shortcut",
      match: (row) => row.action.startsWith("flash mouse_target"),
      done: "Press it, type the letters on a control, then Escape to cancel.",
      missing: "Nothing is bound to flash mouse_target yet. The starter file uses ⌘⇧Space.",
      href: "/docs/getting-started",
      hrefLabel: "Getting started",
      snippet: `[mode.all.mappings]\n"cmd+shift+space" = ["flash", "mouse_target"]`,
    }),
    mappingStep(known, rows, {
      id: "grid",
      title: "Map the keyboard grid",
      match: (row) => row.action.startsWith("flash mouse_grid"),
      done: "Each key zooms into that cell. Backspace steps back.",
      missing: "No key runs flash mouse_grid. Add one when you want to click by screen position.",
      href: "/docs/mouse-grid",
      hrefLabel: "Grid",
      snippet: `[mode.all.mappings]\n"cmd+shift+alt+space" = ["flash", "mouse_grid"]`,
    }),
    mappingStep(known, rows, {
      id: "flashlight",
      title: "Map flashlight",
      match: (row) => row.action.includes("flashlight"),
      done: "Keep the space after :flashlight so search opens directly.",
      missing: "No key opens flashlight. Search covers apps, tabs, emoji, and small calculations.",
      href: "/docs/flashlight",
      hrefLabel: "Flashlight",
      snippet: `[mode.all.mappings]\n"cmd+ctrl+alt+space" = ["flash", "enter_command_mode", "--input=:flashlight "]`,
    }),
    normalStep(known, rows),
    statusBarStep(known, config),
    pluginsStep(known, state.plugins ?? []),
  ];
  const further: Step[] = [
    mappingStep(known, rows, {
      id: "bigram",
      section: "further",
      title: "Jump to a letter",
      match: (row) => row.action.startsWith("flash mouse_bigram"),
      done: "Type the two letters you see. The defaults bind this to s in NORMAL.",
      missing: "No key runs flash mouse_bigram. In NORMAL the default is s.",
      href: "/docs/hints",
      hrefLabel: "Hints",
    }),
    widgetsStep(known, config),
    popupsStep(known, config),
    appsStep(known, config),
  ];
  const sections: OnboardingSection[] = [
    {
      id: "setup",
      title: "Set up this Mac",
      intro: "Flash checks these itself. They update as soon as the resident changes.",
      steps: setup,
    },
    {
      id: "read",
      title: "Read next",
      intro: "Opening a guide from here marks it read in this browser. Flash does not store that.",
      steps: readSteps,
    },
    {
      id: "configure",
      title: "Make it yours",
      intro: "Saved mappings and the status bar, read from the running configuration.",
      steps: configure,
    },
    {
      id: "further",
      title: "Get more out of Flash",
      intro: "Optional. Done items are already on this Mac; the rest are there when you want them.",
      steps: further,
    },
  ];
  const tracked = [...setup, ...readSteps, ...configure];
  const scored = known ? tracked : [];
  const settled = scored.filter((step) => step.status !== "waiting");
  const done = settled.filter((step) => step.status === "done").length;
  const blockers = scored.filter((step) => step.status === "attention");
  const todos = scored.filter((step) => step.status === "todo");
  const next = todos[0] ?? null;
  const later = next ? todos.length - 1 : 0;
  return {
    title: headline(known, connected, blockers.length, next, done, settled.length),
    lede: lede(known, connected, done, settled.length, blockers.length),
    done,
    total: settled.length,
    blockers,
    next,
    later,
    sections,
  };
}

function headline(
  known: boolean,
  connected: boolean,
  blockers: number,
  next: Step | null,
  done: number,
  total: number,
): string {
  if (!known && !connected) return "Waiting for Flash";
  if (blockers > 0) return "Something still needs you";
  if (next) return "Pick up where you left off";
  if (total > 0 && done === total) return "You're set up";
  return "Your Flash, on this Mac";
}

function lede(known: boolean, connected: boolean, done: number, total: number, blockers: number): string {
  if (!known && !connected) {
    return "Open this page from a running Flash with flash help_show. The list fills in from that Mac.";
  }
  if (total === 0) return "Live state is on its way.";
  if (blockers > 0) {
    return `${done} of ${total} checklist items are done. ${blockers === 1 ? "One item needs" : `${blockers} items need`} attention.`;
  }
  if (done === total) return "Permissions, guides, and the recommended setup are all in place on this Mac.";
  return `${done} of ${total} checklist items are already done on this Mac.`;
}

function residentStep(connected: boolean, known: boolean): Step {
  if (connected) {
    return step("setup", "resident", "done", "Flash is connected", "This page is receiving live updates.", "Changes to permissions, config, mappings, and plugins show up here without a reload.");
  }
  if (known) {
    return step("setup", "resident", "done", "Flash is connected", "Showing the last snapshot while the page reconnects.", "The checklist stays on the last snapshot until the event stream returns.");
  }
  return step("setup", "resident", "waiting", "Flash is connected", "No snapshot yet.", "The resident serves this page. Until it connects, nothing below can say what this Mac has done.");
}

function accessibilityStep(known: boolean, trusted: boolean | undefined): Step {
  if (!known || trusted == null) {
    return step("setup", "accessibility", "waiting", "Grant Accessibility", "Not reported yet.", "Hints and clicks need Flash turned on under System Settings → Privacy & Security → Accessibility.", "/docs/troubleshooting", "Troubleshooting");
  }
  if (trusted) {
    return step("setup", "accessibility", "done", "Grant Accessibility", "Accessibility is granted.", "That grant is what lets Flash see controls and install the keyboard tap. After an update, macOS can leave the toggle on and drop the grant: remove Flash with − and add it again.", "/docs/troubleshooting", "Troubleshooting");
  }
  return step("setup", "accessibility", "attention", "Grant Accessibility", "Accessibility is not granted, so hints and NORMAL mode cannot see or click controls.", "System Settings → Privacy & Security → Accessibility. Turn Flash on. Flash also opens that pane itself the first time it needs the grant.", "/docs/troubleshooting", "Troubleshooting");
}

function keyboardStep(known: boolean, runtime: InspectorState["runtime"]): Step {
  if (!known || runtime?.accessibility_trusted == null) {
    return step("setup", "keyboard", "waiting", "Keyboard capture is on", "Not reported yet.", "The tap installs with Accessibility. While secure input is on, hints fall back to Flash's own window.", "/docs/troubleshooting", "Troubleshooting");
  }
  if (runtime.secure_input) {
    return step("setup", "keyboard", "attention", "Keyboard capture is on", "Secure input is on, so the tap sees no keys.", "A password field you are typing in is left alone, and hints read keys only when Flash's window is key. If an app left secure input on after that, Flash asks it to release the hold.", "/docs/troubleshooting", "Troubleshooting");
  }
  if (runtime.keyboard_capture_active) {
    return step("setup", "keyboard", "done", "Keyboard capture is on", "The keyboard tap is installed.", "NORMAL and hints can run while another app is focused. Unmapped NORMAL keys are swallowed instead of typed.");
  }
  if (!runtime.accessibility_trusted) {
    return step("setup", "keyboard", "waiting", "Keyboard capture is on", "Waiting for Accessibility.", "The tap installs once that grant is on.", "/docs/troubleshooting", "Troubleshooting");
  }
  return step("setup", "keyboard", "attention", "Keyboard capture is on", "Accessibility is on, but the keyboard tap is not installed.", "Quit Flash and open it again. If it stays off, remove Flash from the Accessibility list and add it back.", "/docs/troubleshooting", "Troubleshooting");
}

function configStep(known: boolean, path: string | undefined, error: string | null | undefined, customized: boolean): Step {
  const shown = path ? displayPath(path) : "the config file";
  if (!known) {
    return step("setup", "config", "waiting", "Configuration loads", "Not reported yet.", "Flash reads ~/.config/flash/flash.toml and applies a save immediately.", "/docs/config", "Configuration");
  }
  if (error) {
    return step("setup", "config", "attention", "Configuration loads", error, `Fix ${shown} and save. Flash keeps running on the last good configuration until this parses.`, "/state", "Inspect configuration");
  }
  const extra = customized ? " Your file overrides bundled defaults." : "";
  return step("setup", "config", "done", "Configuration loads", `${shown} loads with no error.${extra}`, "Open it from the menu-bar bolt (Open Configuration). A save reloads mappings, the bar, widgets, and plugins.", "/docs/config", "Configuration");
}

function guideStep(topic: GuideTopic, title: string, body: string, read: ReadonlySet<string>): Step {
  const done = read.has(topic);
  return {
    id: `read-${topic}`,
    section: "read",
    title,
    evidence: done ? "Opened in this browser." : "Not opened from this browser yet.",
    body,
    status: done ? "done" : "todo",
    href: `/docs/${topic}`,
    hrefLabel: "Open the guide",
    guide: topic,
  };
}

interface MappingSpec {
  id: string;
  section?: StepSection;
  title: string;
  match: (row: MappingRow) => boolean;
  done: string;
  missing: string;
  href: string;
  hrefLabel: string;
  snippet?: string;
}

function mappingStep(known: boolean, rows: MappingRow[], spec: MappingSpec): Step {
  const section = spec.section ?? "configure";
  if (!known) {
    return step(section, spec.id, "waiting", spec.title, "Not reported yet.", spec.missing, spec.href, spec.hrefLabel, spec.snippet);
  }
  const hits = rows.filter(spec.match);
  if (hits.length === 0) {
    return step(section, spec.id, "todo", spec.title, spec.missing, spec.done, spec.href, spec.hrefLabel, spec.snippet);
  }
  return step(section, spec.id, "done", spec.title, describeKeys(hits), spec.done, spec.href, spec.hrefLabel);
}

function normalStep(known: boolean, rows: MappingRow[]): Step {
  const enter = rows.filter((row) => row.action.startsWith("flash enter_normal_mode"));
  const leave = rows.filter((row) => row.action.startsWith("flash enter_insert_mode"));
  const snippet = `[mode.all.mappings]\n"cmd+ctrl+[" = ["flash", "enter_normal_mode"]\n"cmd+ctrl+i" = ["flash", "enter_insert_mode"]`;
  if (!known) {
    return step("configure", "normal", "waiting", "Enter and leave NORMAL", "Not reported yet.", "NORMAL captures unmapped keys. You need an explicit way in and a way back to typing.", "/docs/normal-mode", "NORMAL mode", snippet);
  }
  if (enter.length > 0 && leave.length > 0) {
    return step("configure", "normal", "done", "Enter and leave NORMAL", `${describeKeys(enter)} enters. ${describeKeys(leave)} returns to typing.`, "While NORMAL is on, f opens hints and : opens commands. Clicking a text field, Find, and a new tab also return to typing.", "/docs/normal-mode", "NORMAL mode");
  }
  const missing = enter.length === 0 && leave.length === 0
    ? "No key enters NORMAL, and no key returns to INSERT."
    : enter.length === 0
      ? `No key enters NORMAL. ${describeKeys(leave)} returns to typing.`
      : `${describeKeys(enter)} enters NORMAL. No key returns to INSERT.`;
  return step("configure", "normal", "todo", "Enter and leave NORMAL", missing, "Add both shortcuts. Unmapped NORMAL keys are swallowed, so the way back matters as much as the way in.", "/docs/normal-mode", "NORMAL mode", snippet);
}

function statusBarStep(known: boolean, config: Record<string, unknown> | null): Step {
  const snippet = `[statusbar]\nenabled = true`;
  if (!known) {
    return step("configure", "statusbar", "waiting", "Turn on the status bar", "Not reported yet.", "The bar is a tmux-format strip for mode, metrics, links, and popups. It is off until you enable it.", "/docs/statusbar", "Status bar", snippet);
  }
  const enabled = record(config?.statusbar)?.enabled === true;
  if (enabled) {
    return step("configure", "statusbar", "done", "Turn on the status bar", "The status bar is enabled.", "Templates, popups, and plugin segments reload when you save. The bar hides the native menu bar on the displays it occupies.", "/docs/statusbar", "Status bar");
  }
  return step("configure", "statusbar", "todo", "Turn on the status bar", "The status bar is off.", "Enable it when you want mode, metrics, or popup tools on screen. Widgets do not need the bar.", "/docs/statusbar", "Status bar", snippet);
}

function pluginsStep(known: boolean, plugins: NonNullable<InspectorState["plugins"]>): Step {
  if (!known) {
    return step("configure", "plugins", "waiting", "Plugins are healthy", "Not reported yet.", "Bundled plugins start with Flash. A failed one is listed on the Plugins page.", "/plugins", "Plugins");
  }
  const failed = plugins.filter((plugin) => ["failed", "crashed", "error"].includes(plugin.state));
  const running = plugins.filter((plugin) => plugin.state === "running" || plugin.state === "ready");
  if (failed.length > 0) {
    const names = failed.slice(0, 3).map((plugin) => plugin.id).join(", ");
    const more = failed.length > 3 ? ` and ${failed.length - 3} more` : "";
    const raw = failed[0]?.last_error ? ` ${failed[0].id}: ${failed[0].last_error}` : "";
    const detail = raw.length > 180 ? `${raw.slice(0, 177)}…` : raw;
    return step("configure", "plugins", "attention", "Plugins are healthy", `${failed.length} failed (${names}${more}).${detail}`, "Open the plugin for its last log. :plugins reload restarts them, including ones parked in failed.", "/plugins", "Plugins");
  }
  if (running.length > 0) {
    return step("configure", "plugins", "done", "Plugins are healthy", `${running.length} running.`, "Plugins add catalogs, actions, status values, and answers. Disable one with [plugins] disabled.", "/docs/plugins", "Plugins");
  }
  return step("configure", "plugins", "todo", "Plugins are healthy", "No plugin is running yet.", "They start with the resident. If this stays empty, open Plugins and check the last error.", "/plugins", "Plugins");
}

function widgetsStep(known: boolean, config: Record<string, unknown> | null): Step {
  const snippet = `[widgets.cpu]\nanchor = "top_right"\nfont_size = 16\ntemplate = "CPU #[meter=20]#{flash.plugin.cpu.percent}#[nometer] #{flash.plugin.cpu.percent}%%"`;
  const names = enabledNames(record(config?.widgets));
  if (!known) {
    return step("further", "widgets", "waiting", "Add a desktop widget", "Not reported yet.", "A widget is a status-format panel on the desktop, above the wallpaper and below every window.", "/docs/widgets", "Widgets", snippet);
  }
  if (names.length > 0) {
    return step("further", "widgets", "done", "Add a desktop widget", `Enabled: ${listNames(names)}.`, "Widgets are click-through and draw on every Space. Delete the table, or set enabled = false, to remove one.", "/docs/widgets", "Widgets");
  }
  return step("further", "widgets", "todo", "Add a desktop widget", "No widget is enabled.", "Use the same format as the status bar. A widget does not require the bar to be on.", "/docs/widgets", "Widgets", snippet);
}

function popupsStep(known: boolean, config: Record<string, unknown> | null): Step {
  const snippet = `[popup.btop]\ncommand = ["btop"]\nsize = "90%x85%"\npersistent = true`;
  const names = Object.keys(record(record(config?.popup)?.popups) ?? {});
  if (!known) {
    return step("further", "popups", "waiting", "Add a popup", "Not reported yet.", "A popup is a real terminal: a status-format page, or a command such as btop.", "/docs/popups", "Popups", snippet);
  }
  if (names.length > 0) {
    return step("further", "popups", "done", "Add a popup", `Configured: ${listNames(names)}.`, "Hover a status-bar label that names one, or map enter_terminal_mode --name=<popup>.", "/docs/popups", "Popups");
  }
  return step("further", "popups", "todo", "Add a popup", "No popup is configured.", "Text popups render a status format. Terminal popups run an argv in their own PTY.", "/docs/popups", "Popups", snippet);
}

function appsStep(known: boolean, config: Record<string, unknown> | null): Step {
  const names = Object.keys(record(record(config?.mode)?.apps) ?? {});
  if (!known) {
    return step("further", "apps", "waiting", "Scope keys to one app", "Not reported yet.", "A [mode.apps.<bundle id>] table replaces keys while that app is focused.", "/docs/config", "Configuration");
  }
  if (names.length > 0) {
    return step("further", "apps", "done", "Scope keys to one app", `App tables: ${listNames(names)}.`, "Those mappings apply only while that bundle is focused. Everything else still uses the shared tables.", "/docs/mappings", "Mapping syntax");
  }
  return step("further", "apps", "todo", "Scope keys to one app", "Every mapping applies in every app.", "Add a table named with the app's bundle id when one app needs its own keys.", "/docs/config", "Configuration");
}

function step(
  section: StepSection,
  id: string,
  status: StepStatus,
  title: string,
  evidence: string,
  body: string,
  href?: string,
  hrefLabel?: string,
  snippet?: string,
): Step {
  return { id, section, title, evidence, body, status, href, hrefLabel, snippet: status === "done" ? undefined : snippet };
}

function describeKeys(rows: MappingRow[]): string {
  const shown = rows.slice(0, 4).map((row) => `${row.scope} ${row.key}`);
  const extra = rows.length > shown.length ? ` and ${rows.length - shown.length} more` : "";
  return shown.join(", ") + extra;
}

function listNames(names: string[]): string {
  const shown = names.slice(0, 4);
  const extra = names.length > shown.length ? ` and ${names.length - shown.length} more` : "";
  return shown.join(", ") + extra;
}

function displayPath(path: string): string {
  return path.replace(/^\/Users\/[^/]+/, "~");
}

function enabledNames(table: Record<string, unknown> | null): string[] {
  if (!table) return [];
  return Object.entries(table)
    .filter(([, value]) => record(value)?.enabled !== false)
    .map(([name]) => name);
}

function hasUserOverride(node: unknown): boolean {
  const rec = record(node);
  if (!rec) return false;
  const mark = record(rec.$);
  if (mark && typeof mark.layer === "string" && mark.layer !== "default") return true;
  return Object.entries(rec).some(([key, value]) => key !== "$" && hasUserOverride(value));
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}
