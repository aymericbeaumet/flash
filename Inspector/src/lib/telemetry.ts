// The telemetry page's pure parts: reading `/api/telemetry`, formatting
// readings, sparklines, the status-format snippets that bring a metric to the
// bar, and the waterfall rows of each trace.
import type { TelemetryData, TelemetryKind, TelemetryLog, TelemetryMetric, TelemetrySeries, TelemetrySpan } from "./types.ts";

/** At most one `/api/telemetry` request per this many milliseconds. */
export const FETCH_INTERVAL_MS = 1000;
/** Traces the waterfall shows, newest first. */
export const TRACE_LIMIT = 50;

const finite = (value: number | null | undefined): value is number => typeof value === "number" && Number.isFinite(value);

/** Whether a reply has the shape the page reads. */
export function isTelemetryData(value: unknown): value is TelemetryData {
  if (!value || typeof value !== "object") return false;
  const data = value as Record<string, unknown>;
  return Array.isArray(data.metrics) && Array.isArray(data.logs) && Array.isArray(data.spans);
}

/** How long to wait before the next fetch so requests stay one interval apart. */
export function fetchDelay(lastFetchAt: number, now: number, interval = FETCH_INTERVAL_MS): number {
  return Math.max(0, Math.min(interval, lastFetchAt + interval - now));
}

export function isDistribution(kind: TelemetryKind): boolean {
  return kind === "histogram" || kind === "exponential_histogram" || kind === "summary";
}

/** `sum · delta · monotonic`, `gauge`, `histogram · cumulative`. */
export function kindLabel(metric: Pick<TelemetryMetric, "kind" | "temporality" | "monotonic">): string {
  const parts: string[] = [metric.kind.replace("_", " ")];
  if (metric.kind !== "gauge" && metric.temporality !== "unspecified") parts.push(metric.temporality);
  if (metric.kind === "sum" && metric.monotonic) parts.push("monotonic");
  return parts.join(" · ");
}

function trim(text: string): string {
  return text.includes(".") ? text.replace(/0+$/, "").replace(/\.$/, "") : text;
}

/** A reading in a narrow cell: `42`, `1,234`, `12.5k`, `3.2M`, `0.25`, `0.00123`; `—` when unknown. */
export function formatValue(value: number | null | undefined): string {
  if (!finite(value)) return "—";
  const abs = Math.abs(value);
  const sign = value < 0 ? "-" : "";
  if (abs >= 1e9) return `${sign}${trim((abs / 1e9).toFixed(2))}G`;
  if (abs >= 1e6) return `${sign}${trim((abs / 1e6).toFixed(2))}M`;
  if (abs >= 1e5) return `${sign}${trim((abs / 1e3).toFixed(1))}k`;
  if (Number.isInteger(value)) return new Intl.NumberFormat("en-US").format(value);
  if (abs >= 100) return `${sign}${trim(abs.toFixed(1))}`;
  if (abs >= 1) return `${sign}${trim(abs.toFixed(2))}`;
  if (abs === 0) return "0";
  return `${sign}${trim(abs.toPrecision(3))}`;
}

/** A rate per second: `2.5/s`; `—` when unknown. */
export function formatRate(value: number | null | undefined): string {
  return finite(value) ? `${formatValue(value)}/s` : "—";
}

/** A span's length: `850 µs`, `12.3 ms`, `1.24 s`. */
export function formatDuration(ms: number): string {
  if (!finite(ms) || ms < 0) return "—";
  if (ms < 1) return `${Math.round(ms * 1000)} µs`;
  if (ms < 1000) return `${trim(ms.toFixed(ms < 10 ? 2 : 1))} ms`;
  return `${trim((ms / 1000).toFixed(2))} s`;
}

/** An SVG path through `values`, scaled into `width` × `height` with the
 * largest at the top; a flat series is a level line through the middle.
 * Empty when there are fewer than two finite values. */
export function sparklinePath(values: number[], width: number, height: number, inset = 1): string {
  const points = values.filter((value) => Number.isFinite(value));
  if (points.length < 2) return "";
  const min = Math.min(...points);
  const max = Math.max(...points);
  const span = max - min;
  const step = (width - inset * 2) / (points.length - 1);
  const round = (n: number) => Math.round(n * 100) / 100;
  return points
    .map((value, index) => {
      const x = inset + index * step;
      const y = span === 0 ? height / 2 : inset + (1 - (value - min) / span) * (height - inset * 2);
      return `${index === 0 ? "M" : "L"}${round(x)} ${round(y)}`;
    })
    .join(" ");
}

/** A series' attributes on one line, `type=input · model=sonnet`, sorted;
 * its sender is the resource's `service.name`. */
export function seriesLabel(series: Pick<TelemetrySeries, "attributes" | "resource">): { attributes: string; service: string } {
  const attributes = Object.keys(series.attributes)
    .sort()
    .map((key) => `${key}=${series.attributes[key]}`)
    .join(" · ");
  return { attributes, service: series.resource["service.name"] ?? "" };
}

/** Series in a stable order, by their attributes, so live updates never reshuffle rows. */
export function sortSeries(series: TelemetrySeries[]): TelemetrySeries[] {
  const key = (item: TelemetrySeries) => `${seriesLabel(item).service}\u0000${seriesLabel(item).attributes}`;
  return [...series].sort((a, b) => key(a).localeCompare(key(b)));
}

function haystack(record: Record<string, string>): string {
  return Object.entries(record).map(([key, value]) => `${key}=${value}`).join(" ");
}

/** Metrics whose name, description or series attributes contain every word
 * of `query`. A metric matched by name keeps all its series; otherwise only
 * the matching ones. */
export function filterMetrics(metrics: TelemetryMetric[], query: string): TelemetryMetric[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return metrics;
  const matches = (text: string) => words.every((word) => text.toLowerCase().includes(word));
  const result: TelemetryMetric[] = [];
  for (const metric of metrics) {
    const head = `${metric.name} ${metric.description} ${metric.unit}`;
    if (matches(head)) { result.push(metric); continue; }
    const series = metric.series.filter((item) => matches(`${head} ${haystack(item.attributes)} ${haystack(item.resource)}`));
    if (series.length) result.push({ ...metric, series });
  }
  return result;
}

/** The status-format values that read a metric: the bridge to the bar,
 * widgets and monitors. */
export function snippets(metric: Pick<TelemetryMetric, "name" | "kind">): string[] {
  const list = [`#{flash.otel:${metric.name}}`];
  if (metric.kind === "sum") list.push(`#{flash.otel.total:${metric.name}}`);
  if (metric.kind !== "gauge") list.push(`#{flash.otel.rate:${metric.name}}`);
  if (metric.kind === "histogram" || metric.kind === "exponential_histogram") list.push(`#{flash.otel.p95:${metric.name}}`);
  return list;
}

/** OTLP severity numbers: 1–4 trace … 21–24 fatal; the text when there is no number. */
export function severityLevel(log: Pick<TelemetryLog, "severity" | "severity_number">): "trace" | "debug" | "info" | "warn" | "error" | "fatal" {
  const n = log.severity_number;
  if (n >= 21) return "fatal";
  if (n >= 17) return "error";
  if (n >= 13) return "warn";
  if (n >= 9) return "info";
  if (n >= 5) return "debug";
  if (n >= 1) return "trace";
  const text = log.severity.toLowerCase();
  if (text.startsWith("fatal") || text.startsWith("crit")) return "fatal";
  if (text.startsWith("err")) return "error";
  if (text.startsWith("warn")) return "warn";
  if (text.startsWith("debug")) return "debug";
  if (text.startsWith("trace")) return "trace";
  return "info";
}

/** Log records newest first, optionally only those of one trace. */
export function recentLogs(logs: TelemetryLog[], trace = ""): TelemetryLog[] {
  return logs.filter((log) => !trace || log.trace_id === trace).reverse();
}

export interface WaterfallRow {
  span: TelemetrySpan;
  depth: number;
  /** Where the bar starts and how wide it is, as percentages of the trace. */
  offset: number;
  width: number;
}

export interface TraceGroup {
  traceId: string;
  start: number;
  end: number;
  duration: number;
  /** The first root's name: what the trace did. */
  name: string;
  services: string[];
  error: boolean;
  rows: WaterfallRow[];
}

/** Spans grouped by trace, newest trace first, each laid out as a waterfall:
 * parents before their children, siblings by start, depth from the parent
 * chain. A span whose parent the receiver does not hold is a root. */
export function traceGroups(spans: TelemetrySpan[], limit = TRACE_LIMIT, only = ""): TraceGroup[] {
  const byTrace = new Map<string, TelemetrySpan[]>();
  for (const span of spans) {
    if (only && span.trace_id !== only) continue;
    const list = byTrace.get(span.trace_id);
    if (list) list.push(span);
    else byTrace.set(span.trace_id, [span]);
  }
  const groups: TraceGroup[] = [];
  for (const [traceId, members] of byTrace) {
    const start = Math.min(...members.map((span) => span.start_ms));
    const end = Math.max(...members.map((span) => span.start_ms + Math.max(0, span.duration_ms)));
    const duration = Math.max(0, end - start);
    const ids = new Set(members.map((span) => span.span_id));
    const children = new Map<string, TelemetrySpan[]>();
    const roots: TelemetrySpan[] = [];
    for (const span of members) {
      if (span.parent_span_id && span.parent_span_id !== span.span_id && ids.has(span.parent_span_id)) {
        const list = children.get(span.parent_span_id);
        if (list) list.push(span);
        else children.set(span.parent_span_id, [span]);
      } else {
        roots.push(span);
      }
    }
    const byStart = (a: TelemetrySpan, b: TelemetrySpan) => a.start_ms - b.start_ms || a.name.localeCompare(b.name);
    const rows: WaterfallRow[] = [];
    const visited = new Set<string>();
    const place = (span: TelemetrySpan, depth: number) => {
      if (visited.has(span.span_id)) return;
      visited.add(span.span_id);
      const offset = duration > 0 ? ((span.start_ms - start) / duration) * 100 : 0;
      const width = duration > 0 ? (Math.max(0, span.duration_ms) / duration) * 100 : 100;
      rows.push({ span, depth, offset: Math.min(100, Math.max(0, offset)), width: Math.min(100 - Math.min(100, Math.max(0, offset)), Math.max(0, width)) });
      for (const child of (children.get(span.span_id) ?? []).sort(byStart)) place(child, depth + 1);
    };
    for (const root of roots.sort(byStart)) place(root, 0);
    // Spans caught in a parent cycle have no root: show them flat.
    for (const span of [...members].sort(byStart)) place(span, 0);
    const services = [...new Set(members.map((span) => span.service).filter(Boolean))].sort();
    groups.push({
      traceId, start, end, duration, services, rows,
      name: rows[0]?.span.name ?? "",
      error: members.some((span) => span.status === "error"),
    });
  }
  return groups.sort((a, b) => b.start - a.start).slice(0, limit);
}

/** A trace id shortened for a label: its first eight characters. */
export function shortTrace(traceId: string): string {
  return traceId.slice(0, 8);
}
