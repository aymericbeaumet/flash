/**
 * Which page of the documentation covers a built-in command or a mode, so
 * the live pages can link a binding or a command to its explanation. A
 * command without an entry of its own falls back to its topic's page, then
 * to the command reference. `docs.test.ts` checks every target against the
 * real pages and their headings.
 */
export interface DocTarget {
  page: string;
  anchor?: string;
}

const reference: DocTarget = { page: "commands", anchor: "command-reference" };

/** Commands whose page is not their topic's. */
export const commandDocs: Record<string, DocTarget> = {
  "mode normal": { page: "normal-mode" },
  "mode insert": { page: "insert-mode" },
  "mode command": { page: "command-mode" },
  "mode flashlight": { page: "flashlight", anchor: "open-it" },
  "mode terminal": { page: "terminal-mode" },
  "mode hold": { page: "hold-mode" },
  "mode visual": { page: "visual-mode" },
  "selection swap_ends": { page: "visual-mode", anchor: "operators" },
  "mode layer": { page: "layers" },
  "mode leave": { page: "modes", anchor: "leave-a-mode" },
  "mouse grid": { page: "mouse-grid" },
  "input focus": { page: "normal-mode", anchor: "default-keys-in-detail" },
  "window switch": { page: "windows", anchor: "switch-to-any-window" },
  "window focus": { page: "windows", anchor: "focus-a-nearby-window" },
  "window move": { page: "windows", anchor: "place-the-focused-window" },
  "status set": { page: "commands", anchor: "pushed-status-values" },
  "status clear": { page: "commands", anchor: "pushed-status-values" },
  "resident doctor": { page: "troubleshooting" },
};

/** Each built-in topic's page; topics not listed use the command reference. */
export const topicDocs: Record<string, DocTarget> = {
  mouse: { page: "hints", anchor: "choose-an-action" },
  hints: { page: "hints" },
  selection: { page: "hold-mode" },
  scroll: { page: "normal-mode", anchor: "scrolling" },
  move: { page: "normal-mode", anchor: "arrows-or-scrolling" },
  cursor: { page: "normal-mode", anchor: "vim-motions-in-text" },
  tab: { page: "normal-mode", anchor: "source-commands" },
  app: { page: "normal-mode", anchor: "source-commands" },
  history: { page: "normal-mode", anchor: "source-commands" },
  pane: { page: "normal-mode", anchor: "source-commands" },
  resource: { page: "normal-mode", anchor: "source-commands" },
  document: { page: "normal-mode", anchor: "source-commands" },
  url: { page: "normal-mode", anchor: "source-commands" },
  mark: { page: "marks" },
  movement: { page: "normal-mode", anchor: "movement-history" },
  window: { page: "windows" },
  desktop: { page: "commands", anchor: "system-surfaces" },
  missioncontrol: { page: "commands", anchor: "system-surfaces" },
  appwindows: { page: "commands", anchor: "system-surfaces" },
  launchpad: { page: "commands", anchor: "system-surfaces" },
  notificationcenter: { page: "commands", anchor: "system-surfaces" },
  controlcenter: { page: "commands", anchor: "system-surfaces" },
  mode: { page: "modes" },
  macro: { page: "normal-mode", anchor: "repeat-and-macros" },
  popup: { page: "popups" },
  help: { page: "help" },
  mappings: { page: "mappings" },
  plugins: { page: "plugins", anchor: "enable-and-configure" },
  monitors: { page: "monitors" },
  telemetry: { page: "telemetry" },
  logs: { page: "troubleshooting" },
  commands: { page: "commands" },
  audio: { page: "audio" },
  volume: { page: "audio" },
  system: { page: "commands", anchor: "system-and-processes" },
  display: { page: "commands", anchor: "system-and-processes" },
  screen: { page: "commands", anchor: "system-and-processes" },
  screensaver: { page: "commands", anchor: "system-and-processes" },
  appearance: { page: "commands", anchor: "system-and-processes" },
  trash: { page: "commands", anchor: "system-and-processes" },
  process: { page: "commands", anchor: "system-and-processes" },
  updates: { page: "updates", anchor: "commands" },
  status: { page: "statusbar" },
  clipboard: { page: "clipboard" },
  register: { page: "clipboard" },
  notes: { page: "commands", anchor: "notes-reminders-and-contacts" },
  reminders: { page: "commands", anchor: "notes-reminders-and-contacts" },
  contacts: { page: "commands", anchor: "notes-reminders-and-contacts" },
  calendar: { page: "calendar" },
  resident: { page: "commands", anchor: "status-doctor-config-events-and-shell-queries" },
  config: { page: "configuration" },
  startup: { page: "startup" },
  cli: { page: "commands", anchor: "status-doctor-config-events-and-shell-queries" },
  events: { page: "ipc-protocol", anchor: "events" },
};

/** The page covering `name` (`window move`), or the command reference. */
export function commandDoc(name: string): DocTarget {
  const words = name.trim().split(/\s+/);
  return commandDocs[words.slice(0, 2).join(" ")] ?? topicDocs[words[0]] ?? reference;
}

/** The command a mapping's action runs (`flash window move --x` → `window move`), or nothing for a program. */
export function commandOfAction(action: string): string | undefined {
  const words = action.trim().split(/\s+/);
  if (words[0] !== "flash" || words.length < 3) return undefined;
  return `${words[1]} ${words[2]}`;
}

/** Each mode of the mappings page, by its id there, to its page. */
export function modeDoc(mode: string): DocTarget {
  if (mode.startsWith("layers.")) return { page: "layers" };
  const pages: Record<string, DocTarget> = {
    all: { page: "modes", anchor: "which-keys-a-mode-reads" },
    normal: { page: "normal-mode" },
    insert: { page: "insert-mode" },
    command: { page: "command-mode" },
    terminal: { page: "terminal-mode" },
    hyper: { page: "hyper-mode" },
    hold: { page: "hold-mode" },
    text: { page: "normal-mode", anchor: "vim-motions-in-text" },
    visual: { page: "visual-mode" },
  };
  return pages[mode] ?? { page: "modes" };
}
