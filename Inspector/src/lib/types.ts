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
  state: string;
  pid?: number | null;
  uptime_ms?: number | null;
  heartbeat_age_ms?: number | null;
  snapshot_age_ms?: number | null;
  source_count?: number;
  command_count?: number;
  target_count?: number;
  candidate_count?: number;
  restart_count?: number;
  last_error?: string | null;
  last_log?: string | null;
  cpu_percent?: number | null;
  memory_bytes?: number | null;
  bundle_ids?: string[];
  volatile?: boolean;
  priority?: number;
  commands?: PluginCommand[];
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

export interface InspectorState {
  mode?: string;
  overlay?: string;
  focused_app?: FocusedApp;
  config?: Record<string, unknown>;
  plugins?: PluginInfo[];
  commands?: CommandInfo[];
}
