export interface LogRecord {
  time_unix_ms?: number;
  level?: string;
  source?: string;
  message?: string;
  fields?: Record<string, unknown>;
}

// The snapshot's types are generated from its schema
// (`docs/schema/inspector/state.schema.json`, `scripts/state-types.ts`):
// change the schema, never these.
import type { ClipboardEntry, StateSnapshot } from "./state.generated.ts";

export type {
  ClipboardEntry,
  ClipboardRegister,
  CommandInfo,
  CommandResolution,
  DocTopic,
  EventMonitorInfo,
  FocusedApp,
  KeyboardState,
  MappingRow,
  MappingsState,
  Monitor,
  MonitorInfo,
  MonitorRun,
  PluginInfo,
  SignalCounts,
  StateSnapshot,
  TelemetryExporterState,
  TelemetryReceiverState,
  TelemetryState,
} from "./state.generated.ts";

/**
 * The snapshot as the page holds it: empty until Flash answers, then every
 * section a snapshot or a stream patch has carried.
 */
export type InspectorState = Partial<StateSnapshot>;

/**
 * An entry of `/api/clipboard/history`: the snapshot's entry, with what only
 * a history page carries.
 */
export interface ClipboardHistoryEntry extends ClipboardEntry {
  /** Plain text put back on the clipboard (empty for an image that had none). */
  value?: string;
  /** Formatted copy, shown in a sandboxed frame. */
  html?: string;
}

export type TelemetryKind = "gauge" | "sum" | "histogram" | "exponential_histogram" | "summary";

/** One stream of a received metric: its attributes and current reading. */
export interface TelemetrySeries {
  /** The point's own attributes. */
  attributes: Record<string, string>;
  resource: Record<string, string>;
  scope: string;
  /** A gauge's or sum's latest point; a distribution's latest mean. */
  latest: number | null;
  /** Per second over the latest interval; 0 once the series went quiet. */
  rate: number | null;
  /** A sum's running total. */
  total: number | null;
  /** Oldest first: gauge values, sum increments, distribution window counts. */
  history: number[];
  updated_ms: number;
  time_ms: number | null;
  /** No point for two and a half reporting intervals. */
  quiet: boolean;
  updates: number;
  count?: number | null;
  sum?: number | null;
  mean?: number | null;
  min?: number | null;
  max?: number | null;
  p50?: number | null;
  p90?: number | null;
  p99?: number | null;
}

export interface TelemetryMetric {
  name: string;
  kind: TelemetryKind;
  unit: string;
  description: string;
  temporality: "cumulative" | "delta" | "unspecified";
  monotonic: boolean;
  series: TelemetrySeries[];
}

export interface TelemetryLog {
  time_ms: number;
  severity: string;
  severity_number: number;
  body: string;
  attributes: Record<string, string>;
  service: string;
  scope: string;
  trace_id: string;
  span_id: string;
  event: string;
}

export interface TelemetrySpan {
  trace_id: string;
  span_id: string;
  parent_span_id: string;
  name: string;
  kind: string;
  start_ms: number;
  duration_ms: number;
  status: "ok" | "error" | "unset";
  status_message: string;
  attributes: Record<string, string>;
  events: number;
  service: string;
  scope: string;
}

/** `GET /api/telemetry`: everything the receiver holds, oldest first. */
export interface TelemetryData {
  revision: number;
  metrics: TelemetryMetric[];
  logs: TelemetryLog[];
  spans: TelemetrySpan[];
  limits: { max_series: number; max_points: number; max_logs: number; max_spans: number };
}
