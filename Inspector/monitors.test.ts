import test from "node:test";
import assert from "node:assert/strict";
import { dialPoint, formatNumber, gaugeFraction, gaugeScale, gaugeZones, lastRunText, monitorCounts, niceCeil, runSteps, sortMonitors, thresholds, thresholdText } from "./src/lib/monitors.ts";
import { parseRoute } from "./src/lib/routes.ts";
import type { MonitorInfo } from "./src/lib/types.ts";

const monitor = (id: string, overrides: Partial<MonitorInfo> = {}): MonitorInfo => ({
  id, name: id, origin: "default", enabled: true, value: 50, display: "50%", state: "ok", direction: "above",
  warning: 80, error: 90, interval_s: 5, message: "", detail: "", since_ms: 0, last_alert_ms: null, expression: `#{${id}}`, ...overrides,
});

test("a run lists its steps in order and says how its last run went", () => {
  assert.deepEqual(runSteps([["bonsai", "clean", "--all", "--force"], ["mo", "clean"]]), ["bonsai clean --all --force", "mo clean"]);
  assert.deepEqual(runSteps(null), []);
  const base = { started_ms: 0, ended_ms: 3000, duration_ms: 3000, steps: 2, failed_step: null, failed_command: null, reason: null, output: "" };
  assert.equal(lastRunText(null), null);
  assert.equal(lastRunText({ ...base, status: "running", ended_ms: null, duration_ms: null }), "Running 2 steps");
  assert.equal(lastRunText({ ...base, status: "succeeded" }), "Succeeded in 3.0s");
  assert.equal(
    lastRunText({ ...base, status: "failed", failed_step: 2, failed_command: "mo clean", reason: "exited 1" }),
    "Step 2 of 2 failed in 3.0s: mo clean exited 1",
  );
});

test("monitors sort worst first, by name within a state, disabled last", () => {
  const sorted = sortMonitors([
    monitor("zeta"),
    monitor("off", { enabled: false, state: "error" }),
    monitor("beta", { state: "warning" }),
    monitor("alpha"),
    monitor("disk", { state: "error" }),
    monitor("net", { state: "unknown", value: null }),
  ]);
  assert.deepEqual(sorted.map((item) => item.id), ["disk", "beta", "net", "alpha", "zeta", "off"]);
});

test("counts cover enabled monitors only", () => {
  assert.deepEqual(monitorCounts([monitor("a", { state: "error" }), monitor("b", { state: "error", enabled: false }), monitor("c")]), { error: 1, warning: 0, unknown: 0, ok: 1 });
});

test("a percentage reads on a 0–100 dial; other values get round headroom", () => {
  assert.deepEqual(gaugeScale(monitor("cpu", { value: 34, warning: 75, error: 90 })), { min: 0, max: 100 });
  assert.deepEqual(gaugeScale(monitor("latency", { value: null, warning: 150, error: 400 })), { min: 0, max: 500 });
  assert.deepEqual(gaugeScale(monitor("tiny", { value: 3, warning: 5, error: 8 })), { min: 0, max: 10 });
  assert.deepEqual(gaugeScale(monitor("none", { value: null, warning: null, error: null })), { min: 0, max: 100 });
  assert.deepEqual(gaugeScale(monitor("cold", { value: -12, warning: null, error: null })), { min: -20, max: 0 });
  assert.deepEqual([0.8, 1, 2.1, 3, 7, 120].map(niceCeil), [1, 1, 2.5, 5, 10, 200]);
});

test("the dial clamps values outside its range", () => {
  assert.equal(gaugeFraction(150, { min: 0, max: 100 }), 1);
  assert.equal(gaugeFraction(-5, { min: 0, max: 100 }), 0);
  assert.equal(gaugeFraction(25, { min: 0, max: 100 }), 0.25);
});

test("bands run healthy, warning, error in the direction that is worse", () => {
  const scale = { min: 0, max: 100 };
  assert.deepEqual(gaugeZones(monitor("cpu"), scale), [
    { from: 0, to: 0.8, state: "ok" },
    { from: 0.8, to: 0.9, state: "warning" },
    { from: 0.9, to: 1, state: "error" },
  ]);
  assert.deepEqual(gaugeZones(monitor("battery", { direction: "below", warning: 20, error: 10 }), scale), [
    { from: 0, to: 0.1, state: "error" },
    { from: 0.1, to: 0.2, state: "warning" },
    { from: 0.2, to: 1, state: "ok" },
  ]);
  assert.deepEqual(gaugeZones(monitor("only-error", { warning: null }), scale), [
    { from: 0, to: 0.9, state: "ok" },
    { from: 0.9, to: 1, state: "error" },
  ]);
  assert.deepEqual(gaugeZones(monitor("unset", { warning: null, error: null }), scale), [{ from: 0, to: 1, state: "ok" }]);
});

test("thresholds read in the monitor's own direction", () => {
  assert.equal(thresholdText(monitor("cpu", { warning: 75, error: 90.5 })), "warning above 75 · error above 90.5");
  assert.equal(thresholdText(monitor("battery", { direction: "below", warning: 20, error: null })), "warning below 20");
  assert.equal(thresholdText(monitor("none", { warning: null, error: null })), "no thresholds");
  assert.deepEqual(thresholds(monitor("cpu")), [{ state: "warning", value: 80 }, { state: "error", value: 90 }]);
  assert.equal(formatNumber(1234.5678), "1,235");
  assert.equal(formatNumber(3.14159), "3.14");
});

test("the dial runs from the left over the top to the right", () => {
  const [lx, ly] = dialPoint(0, 10, 50, 50);
  const [tx, ty] = dialPoint(0.5, 10, 50, 50);
  const [rx, ry] = dialPoint(1, 10, 50, 50);
  assert.deepEqual([Math.round(lx), Math.round(ly)], [40, 50]);
  assert.deepEqual([Math.round(tx), Math.round(ty)], [50, 40]);
  assert.deepEqual([Math.round(rx), Math.round(ry)], [60, 50]);
});

test("/monitors is a page without a detail segment", () => {
  assert.deepEqual(parseRoute({ pathname: "/monitors", search: "" }), { page: "monitors", param: "" });
  assert.deepEqual(parseRoute({ pathname: "/monitors/cpu", search: "" }), { page: "not-found", param: "" });
});
