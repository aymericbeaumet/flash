import { duration } from "./format.ts";
import type { EventMonitorInfo, MonitorInfo, MonitorRun } from "./types.ts";

export type MonitorState = MonitorInfo["state"];

/** Worst first: the order of the page and of its summary. */
export const severities: MonitorState[] = ["error", "warning", "unknown", "ok"];

export const stateLabels: Record<MonitorState, string> = { error: "Error", warning: "Warning", unknown: "Unknown", ok: "OK" };

const byName = (a: MonitorInfo, b: MonitorInfo) => a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true }) || a.id.localeCompare(b.id);
const rank = (monitor: MonitorInfo) => (monitor.enabled ? severities.indexOf(monitor.state) : severities.length);

/** Enabled monitors worst first, then by name; disabled ones last. */
export function sortMonitors(monitors: MonitorInfo[]): MonitorInfo[] {
  return [...monitors].sort((a, b) => rank(a) - rank(b) || byName(a, b));
}

/** Enabled value monitors per state; an event monitor has no state to count. */
export function monitorCounts(monitors: (MonitorInfo | EventMonitorInfo)[]): Record<MonitorState, number> {
  const counts: Record<MonitorState, number> = { error: 0, warning: 0, unknown: 0, ok: 0 };
  for (const monitor of monitors) if (monitor.kind !== "event" && monitor.enabled && monitor.state in counts) counts[monitor.state] += 1;
  return counts;
}

/** A run's steps, one command line each, in the order they run. */
export function runSteps(run: string[][] | null | undefined): string[] {
  return (run ?? []).map((step) => step.join(" "));
}

/** How the last run went, in one line: `Running 2 steps`, `Succeeded in 41.2s`,
 * `Step 2 of 2 failed in 3.0s: mo clean exited 1`. Null before the first. */
export function lastRunText(run: MonitorRun | null | undefined): string | null {
  if (!run) return null;
  if (run.status === "running") return `Running ${run.steps === 1 ? "1 step" : `${run.steps} steps`}`;
  const took = run.duration_ms == null ? "" : ` in ${duration(run.duration_ms)}`;
  if (run.status === "succeeded") return `Succeeded${took}`;
  return `Step ${run.failed_step ?? "?"} of ${run.steps} failed${took}: ${[run.failed_command, run.reason].filter(Boolean).join(" ")}`;
}

export interface GaugeScale { min: number; max: number }

const finite = (value: number | null | undefined): value is number => typeof value === "number" && Number.isFinite(value);

/** The smallest 1, 2, 2.5 or 5 times a power of ten at or above `value`. */
export function niceCeil(value: number): number {
  if (value <= 0) return 0;
  const power = 10 ** Math.floor(Math.log10(value));
  for (const step of [1, 2, 2.5, 5, 10]) if (step * power >= value - 1e-9) return step * power;
  return 10 * power;
}

/** The dial's range: 0–100 for what reads as a percentage, else from zero
 * to a round number with headroom past the furthest value or threshold. */
export function gaugeScale(monitor: Pick<MonitorInfo, "value" | "warning" | "error">): GaugeScale {
  const marks = [monitor.value, monitor.warning, monitor.error].filter(finite);
  if (!marks.length) return { min: 0, max: 100 };
  const low = Math.min(0, ...marks);
  const high = Math.max(...marks);
  if (low >= 0 && high <= 100 && high >= 40) return { min: 0, max: 100 };
  const max = high > 0 ? niceCeil(high * 1.25) : 0;
  const min = low < 0 ? -niceCeil(-low * 1.25) : 0;
  return max > min ? { min, max } : { min, max: min + 1 };
}

/** Where `value` sits on the dial, from 0 (left) to 1 (right). */
export function gaugeFraction(value: number, scale: GaugeScale): number {
  return Math.min(1, Math.max(0, (value - scale.min) / (scale.max - scale.min)));
}

export interface GaugeZone { from: number; to: number; state: "ok" | "warning" | "error" }

/** The coloured bands of the dial, as fractions: healthy, warning, error,
 * mirrored when lower values are worse. */
export function gaugeZones(monitor: Pick<MonitorInfo, "direction" | "warning" | "error">, scale: GaugeScale): GaugeZone[] {
  const warning = finite(monitor.warning) ? gaugeFraction(monitor.warning, scale) : null;
  const error = finite(monitor.error) ? gaugeFraction(monitor.error, scale) : null;
  const zones: GaugeZone[] = [];
  if (monitor.direction === "below") {
    if (error !== null) zones.push({ from: 0, to: error, state: "error" });
    if (warning !== null) zones.push({ from: error ?? 0, to: warning, state: "warning" });
    zones.push({ from: warning ?? error ?? 0, to: 1, state: "ok" });
  } else {
    zones.push({ from: 0, to: warning ?? error ?? 1, state: "ok" });
    if (warning !== null) zones.push({ from: warning, to: error ?? 1, state: "warning" });
    if (error !== null) zones.push({ from: error, to: 1, state: "error" });
  }
  return zones.filter((zone) => zone.to > zone.from);
}

/** A number as a dial label or threshold: at most two decimals, no trailing zeros. */
export function formatNumber(value: number): string {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: Math.abs(value) >= 100 ? 0 : 2 }).format(value);
}

/** The thresholds a monitor sets, mildest first. */
export function thresholds(monitor: Pick<MonitorInfo, "warning" | "error">): { state: "warning" | "error"; value: number }[] {
  return [
    ...(finite(monitor.warning) ? [{ state: "warning" as const, value: monitor.warning }] : []),
    ...(finite(monitor.error) ? [{ state: "error" as const, value: monitor.error }] : []),
  ];
}

/** `warning above 80 · error above 92`, or `no thresholds`. */
export function thresholdText(monitor: Pick<MonitorInfo, "direction" | "warning" | "error">): string {
  const parts: string[] = [];
  if (finite(monitor.warning)) parts.push(`warning ${monitor.direction} ${formatNumber(monitor.warning)}`);
  if (finite(monitor.error)) parts.push(`error ${monitor.direction} ${formatNumber(monitor.error)}`);
  return parts.length ? parts.join(" · ") : "no thresholds";
}

/** A point on the dial: a half circle from the left end (0) over the top to the right (1). */
export function dialPoint(fraction: number, radius: number, cx: number, cy: number): [number, number] {
  const angle = Math.PI + fraction * Math.PI;
  return [cx + radius * Math.cos(angle), cy + radius * Math.sin(angle)];
}

/** The SVG path of the dial's arc between two fractions. */
export function dialArc(from: number, to: number, radius: number, cx: number, cy: number): string {
  const [x1, y1] = dialPoint(from, radius, cx, cy);
  const [x2, y2] = dialPoint(to, radius, cx, cy);
  return `M ${x1.toFixed(2)} ${y1.toFixed(2)} A ${radius} ${radius} 0 0 1 ${x2.toFixed(2)} ${y2.toFixed(2)}`;
}
