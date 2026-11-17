export interface LogRecord {
  time_unix_ms?: number;
  level?: string;
  source?: string;
  message?: string;
  fields?: Record<string, unknown>;
}

export interface PluginInfo {
  id: string;
  name: string;
  version: string;
  description?: string;
  origin?: string;
  root?: string;
  /** stopped | installing | launching | running | published | failed | manifest_only */
  state: string;
  /** resident | on_demand | publish_then_exit | manifest_only */
  activation?: string;
  pid?: number | null;
  /** When the running process started; the page derives its uptime. */
  started_at_unix_ms?: number | null;
  source_count?: number;
  command_count?: number;
  restart_count?: number;
  last_error?: string | null;
  last_log?: string | null;
  /** Cumulative CPU time, sampled with the snapshot (`snapshot_at_unix_ms`). */
  cpu_time_ms?: number | null;
  /** Resident memory, sampled with the snapshot. */
  memory_bytes?: number | null;
  only_bundle_ids?: string[];
  priority?: number;
  /** Each segment's value as a bounded preview; the top-level `commands` lists this plugin's commands by `source`. */
  status_segments?: Record<string, string>;
  [key: string]: unknown;
}

export interface CommandInfo {
  name: string;
  syntax?: string;
  aliases?: string[];
  description?: string;
  source: string;
  source_kind: "core" | "plugin";
  command?: string;
  subcommand?: string;
}

export interface FocusedApp {
  bundle_id?: string | null;
  localized_name?: string | null;
  pid?: number | null;
}

export interface MappingRow {
  scope: string;
  key: string;
  action: string;
  /** What this binding does, including its flags. The row's ? shows it, and search ranks it. */
  explanation?: string;
  /** `default`, `config` or `config:<file>`, or `plugin:<name>`. */
  origin?: string;
}

/** How one command Flash asks of the focused app resolves there, in dispatch order. */
export interface CommandResolution {
  /** The binding key: the command line with its bool flags (`tab new`, `app reload --force`). */
  command: string;
  /** Sources (and Flash's own step) that get first try: `source:<id>`, `flash:<step>`. */
  claimed_by: string[];
  /** What runs otherwise: `cmd+t`, `cmd+k, cmd+w`, `menu File › New Tab`, `none`, or null for nothing. */
  binding: string | null;
  /** Who declared the binding: a plugin id, `flash` for Flash's own scrolling. */
  source: string | null;
}

export interface MappingsState {
  normal_leader: string;
  rows: MappingRow[];
  effective_rows?: MappingRow[];
  commands?: CommandResolution[];
  bundle_id?: string | null;
  localized_name?: string | null;
}

export interface ClipboardEntry {
  /** 32 lowercase hex characters. Image bytes load from `/api/clipboard/<id>`. */
  id: string;
  /** `text`, `image`, `html`, or `files`. */
  kind: string;
  /** One-line label. */
  preview: string;
  /** Plain text put back on the clipboard (empty for an image that had none). Present from
   * `/api/clipboard/history`; the state snapshot carries only the preview. */
  value?: string;
  /** Formatted copy, shown in a sandboxed frame. From `/api/clipboard/history` only. */
  html?: string;
  /** Present when this entry has an image to render. */
  mime?: string;
  /** Paths from a file copy. */
  files?: string[];
  /** Present, and true, only for a pinned entry: it lists first and is never trimmed. */
  pinned?: boolean;
}

/** A plugin's own help topic; the help renders it at `/docs/<name>`. */
export interface DocTopic {
  name: string;
  title: string;
  summary: string;
  /** Raw Markdown, authored by the plugin: rendered as untrusted content. */
  body: string;
}

export interface ClipboardRegister {
  name: string;
  text: string;
  kind: "unnamed" | "yank" | "named" | "clipboard";
  /** Snapshot contains a preview; the resident keeps the full value for paste. */
  truncated?: boolean;
}

/** The keyboard page's model: the layout, the hint alphabet and what the keys do. */
export interface KeyboardState {
  /** `qwerty`, `colemak`, `dvorak` or `bepo`. */
  layout: string;
  /** Four rows of ten keys: number, top, home, bottom. */
  rows: string[];
  /** The hint alphabet, best key first. */
  alphabet: string;
  key_scores: Record<string, number>;
  /** The mouse grid's keys, one string per row. */
  grid_keys: string[];
  label_order: string;
  /** The zone keys of `label_order = "zones"`, one string per keyboard row. */
  zone_rows: string[];
  navigation: { left: string; down: string; up: string; right: string; quadrants: string[] };
  adjust_digits: string;
  held_button?: string | null;
}

/** How a monitor's last run went. */
export interface MonitorRun {
  status: "running" | "succeeded" | "failed";
  started_ms: number;
  ended_ms: number | null;
  duration_ms: number | null;
  steps: number;
  /** The step that failed, from 1, its command and why. */
  failed_step: number | null;
  failed_command: string | null;
  reason: string | null;
  /** The tail of the failing step's output, or of the last step's. */
  output: string;
}

/** A watched value and its thresholds, as the resident last evaluated it. */
export interface MonitorInfo {
  id: string;
  name: string;
  /** `default` for a bundled monitor, `config` for one from the user's file. */
  origin: "default" | "config";
  enabled: boolean;
  /** The last sample, or null before the first or when it could not be read. */
  value: number | null;
  /** The sample as the bar would print it. */
  display: string;
  state: "ok" | "warning" | "error" | "unknown";
  /** `above`: higher is worse. `below`: lower is worse. */
  direction: "above" | "below";
  warning: number | null;
  error: number | null;
  interval_s: number;
  /** Why the monitor is in its state, when Flash says. */
  message: string;
  /** What is failing (the plugins a count counts); empty when the monitor names nothing. */
  detail: string;
  /** When the monitor entered its current state. */
  since_ms: number;
  last_alert_ms: number | null;
  /** The status-format expression that yields the value. */
  expression: string;
  /** `value` watches an expression; `event` watches host events. */
  kind: "value" | "event";
  /** What runs when it fires, in order: Flash commands or executables, or null. */
  run: string[][] | null;
  /** The whole run's bound, and the wait between two runs, in seconds. */
  timeout_s: number;
  cooldown_s: number;
  /** How often it ran since launch; when it last started, across restarts. */
  runs: number;
  last_run_ms: number | null;
  last_run: MonitorRun | null;
}

/** A monitor that watches host events: the names and globs a plugin's `listen` takes. */
export interface EventMonitorInfo {
  id: string;
  name: string;
  origin: "default" | "config";
  kind: "event";
  enabled: boolean;
  state: "ok";
  event: string[];
  /** The bundle identifier app events are narrowed to. */
  app: string | null;
  message: string;
  run: string[][] | null;
  timeout_s: number;
  cooldown_s: number;
  runs: number;
  last_run_ms: number | null;
  last_run: MonitorRun | null;
}

export interface InspectorState {
  /** When Flash took this snapshot: it pushes one on each change. */
  snapshot_at_unix_ms?: number;
  /** The snapshot's number, one more than the last; a stream `patch` names the one it builds on. */
  snapshot_seq?: number;
  runtime?: {
    version?: string;
    build?: string;
    pid?: number;
    /** When the resident started; the page derives its uptime. */
    started_at_unix_ms?: number;
    accessibility_trusted?: boolean;
    keyboard_capture_active?: boolean;
    secure_input?: boolean;
    advanced_mode?: boolean;
    config_path?: string;
    config_error?: string | null;
  };
  mode?: string;
  /** `idle`, `discovering`, `labels`, `grid`, `search`, `adjusting`, `pointer`, `bigram`, `confirming` or `window_switcher`. */
  hint_session?: string;
  keyboard?: KeyboardState;
  overlay?: string | null;
  focused_app?: FocusedApp;
  config?: Record<string, unknown>;
  /** Sparse tree parallel to `config`. A node's `$` is `{ layer, where }` when a later layer overrode the default. */
  config_sources?: { $?: { layer?: string; where?: string }; [key: string]: unknown };
  plugins?: PluginInfo[];
  commands?: CommandInfo[];
  docs?: DocTopic[];
  clipboard?: ClipboardEntry[];
  /** Populated Vim-style text registers from the resident process. */
  clipboard_registers?: ClipboardRegister[];
  /** Offset of the next clipboard page, or null when this is the full history. */
  clipboard_next_offset?: number | null;
  /** Number of entries retained by core clipboard history. */
  clipboard_total?: number;
  mappings?: MappingsState;
  /** Absent when the resident has no monitors to report. */
  monitors?: (MonitorInfo | EventMonitorInfo)[];
  /** The OTLP receiver and exporter; `/api/telemetry` carries what was received. */
  telemetry?: TelemetryState;
}

/** A count per OTLP signal. */
export interface SignalCounts {
  metrics: number;
  logs: number;
  traces: number;
}

/** `[telemetry.receiver]`: the loopback OTLP/HTTP listener and what it took in. */
export interface TelemetryReceiverState {
  enabled: boolean;
  port: number;
  listening: boolean;
  /** Why the listener could not bind, when it could not. */
  error: string | null;
  /** Requests answered with an error, by HTTP status. */
  refused: Record<string, number>;
  last_refusal: string | null;
  requests: SignalCounts;
  accepted: SignalCounts;
  rejected: SignalCounts;
  evicted_series: number;
  last_received_ms: number | null;
  /** What the store holds now. */
  series: number;
  logs: number;
  spans: number;
  /** Bumped on every request the store took; the page refetches on a change. */
  revision: number;
  limits: { max_series: number; max_points: number; max_logs: number; max_spans: number };
  /** `http://127.0.0.1:<port>` while listening. */
  endpoint?: string;
}

/** `[telemetry.exporter]`: Flash's own telemetry, sent to the user's endpoint. */
export interface TelemetryExporterState {
  enabled: boolean;
  endpoint: string;
  /** Why the configured exporter stays off, when it does. */
  blocked: string | null;
  protocol: string;
  compression: string;
  signals: string[];
  interval_s: number;
  /** Header names only: their values are credentials and never leave Flash. */
  headers: string[];
  service_name: string;
  sent: SignalCounts;
  dropped: SignalCounts;
  failures: number;
  retrying: string[];
  last_error: string | null;
  last_success_ms: number | null;
}

export interface TelemetryState {
  receiver: TelemetryReceiverState;
  exporter: TelemetryExporterState;
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
