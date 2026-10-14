export interface LogRecord {
  time_unix_ms?: number;
  level?: string;
  source?: string;
  message?: string;
  fields?: Record<string, unknown>;
}

export interface PluginCommand {
  command: string;
  subcommand: string;
  description: string;
}

export interface PluginInfo {
  id: string;
  name: string;
  version: string;
  description?: string;
  origin?: string;
  root?: string;
  /** stopped | installing | launching | running | failed | manifest_only */
  state: string;
  /** resident | on_demand | manifest_only */
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
  commands?: PluginCommand[];
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

/** How one action resolves in the focused app, in dispatch order. */
export interface ActionResolution {
  action: string;
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
  actions?: ActionResolution[];
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
  /** Plain text put back on the clipboard. Empty for an image that had none. */
  value: string;
  /** Formatted copy, shown in a sandboxed frame. */
  html?: string;
  /** Present when this entry has an image to render. */
  mime?: string;
  /** Paths from a file copy. */
  files?: string[];
}

export interface DocTopic {
  name: string;
  title: string;
  summary: string;
  /** Raw Markdown — the Docs tab renders it client-side. */
  body: string;
  aliases?: string[];
  /** The section Flash files the guide under; topics arrive in reading order. */
  group?: string;
  /** The published manual page with the long-form reference, if any. */
  manual?: string | null;
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

export interface InspectorState {
  /** When Flash took this snapshot: it pushes one on each change. */
  snapshot_at_unix_ms?: number;
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
  /** `idle`, `discovering`, `labels`, `grid`, `search`, `adjusting`, `pointer`, `bigram` or `confirming`. */
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
  mappings?: MappingsState;
}
