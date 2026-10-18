import assert from "node:assert/strict";
import test from "node:test";
import { buildOnboarding, type Step } from "./src/lib/onboarding.ts";
import type { InspectorState, MappingRow } from "./src/lib/types.ts";

function row(scope: string, key: string, action: string, origin = "default"): MappingRow {
  return { scope, key, action, origin };
}

function find(steps: Step[], id: string): Step {
  const step = steps.find((item) => item.id === id);
  assert.ok(step, id);
  return step;
}

const ready: InspectorState = {
  snapshot_at_unix_ms: 1,
  runtime: {
    accessibility_trusted: true,
    keyboard_capture_active: true,
    secure_input: false,
    config_path: "/Users/ab/.config/flash/flash.toml",
    config_error: null,
  },
  config: {
    statusbar: { enabled: true },
    widgets: { cpu: { enabled: true }, hidden: { enabled: false } },
    popup: { popups: { btop: { kind: "terminal" } } },
    mode: { apps: { "com.apple.finder": {} } },
  },
  config_sources: { statusbar: { $: { layer: "config", where: "config · flash.toml" } } },
  plugins: [
    { id: "cpu", name: "CPU", version: "1", state: "running" },
    { id: "tmux", name: "tmux", version: "1", state: "ready" },
  ],
  mappings: {
    normal_leader: "<space>",
    rows: [
      row("all", "cmd+shift+space", "flash mouse_target", "config"),
      row("all", "cmd+shift+alt+space", "flash mouse_grid", "config"),
      row("all", "cmd+ctrl+alt+space", 'flash enter_command_mode --input=:flashlight ', "config"),
      row("all", "cmd+ctrl+[", "flash enter_normal_mode", "config"),
      row("all", "cmd+ctrl+i", "flash enter_insert_mode", "config"),
      row("normal", "s", "flash mouse_bigram"),
      row("normal", "ctrl+s", "flash mouse_bigram --secondary"),
    ],
  },
};

test("an empty page waits instead of inventing failures", () => {
  const model = buildOnboarding({}, false, new Set());
  assert.equal(model.title, "Waiting for Flash");
  assert.equal(model.total, 0);
  assert.equal(model.blockers.length, 0);
  assert.equal(model.next, null);
  assert.equal(find(model.sections[0].steps, "accessibility").status, "waiting");
  assert.equal(find(model.sections[1].steps, "read-getting-started").status, "todo");
});

test("a configured Mac is done except for guides it has not opened", () => {
  const model = buildOnboarding(ready, true, new Set(["hints"]));
  const steps = model.sections.flatMap((section) => section.steps);
  assert.equal(model.blockers.length, 0);
  assert.equal(find(steps, "accessibility").status, "done");
  assert.equal(find(steps, "keyboard").status, "done");
  assert.match(find(steps, "config").evidence, /~\/\.config\/flash\/flash\.toml/);
  assert.match(find(steps, "config").evidence, /overrides bundled defaults/);
  assert.equal(find(steps, "hints").evidence, "all cmd+shift+space");
  assert.equal(find(steps, "grid").status, "done");
  assert.equal(find(steps, "flashlight").status, "done");
  assert.match(find(steps, "normal").evidence, /enters/);
  assert.equal(find(steps, "statusbar").status, "done");
  assert.match(find(steps, "plugins").evidence, /2 running/);
  assert.equal(find(steps, "read-hints").status, "done");
  assert.equal(find(steps, "read-getting-started").status, "todo");
  assert.equal(model.next?.id, "read-getting-started");
  assert.equal(find(steps, "bigram").status, "done");
  assert.match(find(steps, "bigram").evidence, /normal s/);
  assert.match(find(steps, "widgets").evidence, /Enabled: cpu/);
  assert.match(find(steps, "popups").evidence, /btop/);
  assert.match(find(steps, "apps").evidence, /com\.apple\.finder/);
  assert.equal(model.title, "Pick up where you left off");
  const tracked = steps.filter((step) => step.section !== "further");
  assert.equal(model.total, tracked.length);
  assert.equal(model.done, tracked.filter((step) => step.status === "done").length);
});

test("a starter install still needs the commented shortcuts", () => {
  const model = buildOnboarding({
    snapshot_at_unix_ms: 2,
    runtime: {
      accessibility_trusted: true,
      keyboard_capture_active: true,
      secure_input: false,
      config_path: "/Users/ab/.config/flash/flash.toml",
      config_error: null,
    },
    config: { statusbar: { enabled: false }, widgets: {}, popup: { popups: {} }, mode: { apps: {} } },
    plugins: [{ id: "cpu", name: "CPU", version: "1", state: "running" }],
    mappings: { normal_leader: "<space>", rows: [row("all", "cmd+shift+space", "flash mouse_target", "config")] },
  }, true, new Set());
  const steps = model.sections.flatMap((section) => section.steps);
  assert.equal(find(steps, "hints").status, "done");
  assert.equal(find(steps, "grid").status, "todo");
  assert.match(find(steps, "grid").snippet ?? "", /mouse_grid/);
  assert.equal(find(steps, "flashlight").status, "todo");
  assert.equal(find(steps, "normal").status, "todo");
  assert.match(find(steps, "normal").evidence, /No key enters NORMAL/);
  assert.equal(find(steps, "statusbar").status, "todo");
  assert.equal(model.next?.id, "read-getting-started");
});

test("permission, config, and plugin failures are the missing list", () => {
  const model = buildOnboarding({
    snapshot_at_unix_ms: 3,
    runtime: {
      accessibility_trusted: false,
      keyboard_capture_active: false,
      secure_input: false,
      config_path: "/Users/ab/.config/flash/flash.toml",
      config_error: 'popup.bonsai.size must be "COLUMNSxROWS"',
    },
    plugins: [{ id: "feed", name: "Feed", version: "1", state: "failed", last_error: "dns" }],
    mappings: { normal_leader: "", rows: [] },
  }, true, new Set());
  assert.deepEqual(model.blockers.map((step) => step.id), ["accessibility", "config", "plugins"]);
  assert.equal(model.title, "Something still needs you");
  assert.match(model.blockers[1].evidence, /COLUMNSxROWS/);
  assert.match(model.blockers[2].evidence, /feed/);
  const keyboard = find(model.sections[0].steps, "keyboard");
  assert.equal(keyboard.status, "waiting");
});

test("secure input is its own attention item once Accessibility is granted", () => {
  const model = buildOnboarding({
    snapshot_at_unix_ms: 4,
    runtime: { accessibility_trusted: true, keyboard_capture_active: false, secure_input: true, config_error: null },
    plugins: [],
    mappings: { normal_leader: "", rows: [] },
  }, true, new Set());
  const keyboard = find(model.sections[0].steps, "keyboard");
  assert.equal(keyboard.status, "attention");
  assert.match(keyboard.evidence, /Secure input/);
});

test("one side of NORMAL is not enough", () => {
  const model = buildOnboarding({
    snapshot_at_unix_ms: 5,
    runtime: { accessibility_trusted: true, keyboard_capture_active: true, config_error: null },
    plugins: [{ id: "cpu", name: "CPU", version: "1", state: "running" }],
    mappings: {
      normal_leader: "<space>",
      rows: [row("all", "cmd+ctrl+[", "flash enter_normal_mode")],
    },
    config: { statusbar: { enabled: false } },
  }, true, new Set( ["getting-started", "hints", "normal-mode", "config"]));
  const normal = find(model.sections[2].steps, "normal");
  assert.equal(normal.status, "todo");
  assert.match(normal.evidence, /all cmd\+ctrl\+\[ enters NORMAL/);
  assert.match(normal.evidence, /No key returns to INSERT/);
});
