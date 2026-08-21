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
  uptime_ms?: number | null;
  source_count?: number;
  command_count?: number;
  restart_count?: number;
  last_error?: string | null;
  last_log?: string | null;
  cpu_percent?: number | null;
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
}

export interface MappingsState {
  normal_leader: string;
  rows: MappingRow[];
}

export interface ClipboardEntry {
  /// One-line label.
  preview: string;
  /// Full text — copied back to the system clipboard on click.
  value: string;
}

export interface DocTopic {
  name: string;
  title: string;
  summary: string;
  /** Raw Markdown — the Docs tab renders it client-side. */
  body: string;
  aliases?: string[];
}

export interface InspectorState {
  mode?: string;
  overlay?: string;
  focused_app?: FocusedApp;
  config?: Record<string, unknown>;
  plugins?: PluginInfo[];
  commands?: CommandInfo[];
  docs?: DocTopic[];
  clipboard?: ClipboardEntry[];
  mappings?: MappingsState;
}
