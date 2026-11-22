// The config editor's check of its text: what `POST /api/config/check`
// answers (the rows `flash config check` prints, placed), when to ask, and
// what the editor draws from it. Pure: the panel supplies the request and
// the clock.

import { contractError, describeFailure } from "./request.ts";

export interface EditorDiagnostic {
  /**
   * `error`: the edited text raised it, so a save asks first. `warning`:
   * another file raised it (the bundled defaults), which this text cannot
   * fix and a save does not wait for.
   */
  severity: "error" | "warning";
  /** 1-based, in the edited text; absent when the loader could not place it. */
  line?: number;
  column?: number;
  message: string;
  /** Where another file raised it. */
  file?: string;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);
const position = (value: unknown, name: string): number | undefined => {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "number" || !Number.isInteger(value))
    throw contractError(`the check reply has a diagnostic whose ${name} is not a number`);
  return value;
};

/** The reply of `POST /api/config/check` as the editor's diagnostics, in the server's order. */
export function readCheckReply(payload: unknown): EditorDiagnostic[] {
  if (!isRecord(payload) || typeof payload.path !== "string" || !Array.isArray(payload.diagnostics))
    throw contractError("the check reply has no path and diagnostics");
  const checked = payload.path;
  return payload.diagnostics.map((row: unknown) => {
    if (!isRecord(row) || typeof row.path !== "string" || typeof row.message !== "string")
      throw contractError("the check reply has a diagnostic without a path and a message");
    const line = position(row.line, "line");
    const column = position(row.column, "column");
    if (row.path !== checked) {
      const place = line === undefined ? "" : `:${line}${column === undefined ? "" : `:${column}`}`;
      return { severity: "warning", message: row.message, file: row.path + place };
    }
    const diagnostic: EditorDiagnostic = { severity: "error", message: row.message };
    if (line !== undefined) diagnostic.line = line;
    if (column !== undefined) diagnostic.column = column;
    return diagnostic;
  });
}

export interface CheckState {
  /**
   * `idle`: nothing was checked. `pending`: the text changed and its check
   * has not answered, so `diagnostics` are the last verdict's. `checked`:
   * `diagnostics` describe the text. `failed`: the check did not answer.
   */
  status: "idle" | "pending" | "checked" | "failed";
  diagnostics: EditorDiagnostic[];
  /** Why the check did not answer. */
  error?: string;
}

/** The text was checked and has errors: a save asks before it writes. */
export function blocksSave(state: CheckState): boolean {
  return (
    state.status === "checked" &&
    state.diagnostics.some((diagnostic) => diagnostic.severity === "error")
  );
}

const count = (total: number, noun: string) => `${total} ${noun}${total === 1 ? "" : "s"}`;

/** The check in a few words, for the editor's toolbar. */
export function summarize(state: CheckState): string {
  if (state.status === "idle") return "";
  if (state.status === "pending") return "Checking…";
  if (state.status === "failed") return "Not checked";
  const errors = state.diagnostics.filter((diagnostic) => diagnostic.severity === "error").length;
  const warnings = state.diagnostics.length - errors;
  if (!errors && !warnings) return "No problems";
  return [errors && count(errors, "error"), warnings && count(warnings, "warning")]
    .filter(Boolean)
    .join(", ");
}

export interface CheckClock {
  setTimer(callback: () => void, delayMs: number): unknown;
  clearTimer(handle: unknown): void;
}

const browserClock: CheckClock = {
  setTimer: (callback, delayMs) => setTimeout(callback, delayMs),
  clearTimer: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/**
 * Checks the editor's text once typing pauses. Every edit starts a new
 * generation: the check of an earlier one is abandoned and its reply, when
 * one still arrives, is dropped, so the state only ever describes the latest
 * text or says a check is pending.
 */
export class ConfigChecker {
  private state: CheckState = { status: "idle", diagnostics: [] };
  private text: string | null = null;
  private generation = 0;
  private timer: unknown;
  private running: { generation: number; done: Promise<void>; abort: AbortController } | null =
    null;
  private readonly request: (text: string, signal: AbortSignal) => Promise<unknown>;
  private readonly onchange: (state: CheckState) => void;
  private readonly clock: CheckClock;
  private readonly delayMs: number;

  constructor(
    request: (text: string, signal: AbortSignal) => Promise<unknown>,
    onchange: (state: CheckState) => void,
    clock: CheckClock = browserClock,
    delayMs = 350,
  ) {
    this.request = request;
    this.onchange = onchange;
    this.clock = clock;
    this.delayMs = delayMs;
  }

  /** The editor holds `text`: check it after the pause, unless its verdict is here or on its way. */
  edit(text: string) {
    if (text === this.text && this.state.status !== "failed") return;
    this.text = text;
    this.generation += 1;
    this.cancel();
    this.set({ status: "pending", diagnostics: this.state.diagnostics });
    this.timer = this.clock.setTimer(() => {
      this.timer = undefined;
      void this.run();
    }, this.delayMs);
  }

  /**
   * The verdict on `text`, asked for now rather than after the pause. An
   * edit made meanwhile answers `pending`: that verdict is not `text`'s.
   */
  async settle(text: string): Promise<CheckState> {
    this.edit(text);
    if (this.timer !== undefined) {
      this.clock.clearTimer(this.timer);
      this.timer = undefined;
      await this.run();
    } else if (this.running) await this.running.done;
    return this.state;
  }

  /** The editor is gone: nothing answers after this. */
  stop() {
    this.generation += 1;
    this.cancel();
  }

  private cancel() {
    if (this.timer !== undefined) this.clock.clearTimer(this.timer);
    this.timer = undefined;
    this.running?.abort.abort();
    this.running = null;
  }

  private run(): Promise<void> {
    const generation = this.generation;
    const abort = new AbortController();
    const done = this.request(this.text ?? "", abort.signal)
      .then(readCheckReply)
      .then(
        (diagnostics) => {
          if (generation === this.generation) this.set({ status: "checked", diagnostics });
        },
        (error: unknown) => {
          if (generation === this.generation)
            this.set({ status: "failed", diagnostics: [], error: describeFailure(error) });
        },
      )
      .finally(() => {
        if (this.running?.generation === generation) this.running = null;
      });
    this.running = { generation, done, abort };
    return done;
  }

  private set(state: CheckState) {
    this.state = state;
    this.onchange(state);
  }
}

export interface LineMark {
  line: number;
  severity: EditorDiagnostic["severity"];
  /** Every message on the line. */
  title: string;
}

/**
 * The gutter's marks: one per line with a diagnostic, in line order, an
 * error outranking a warning. A line outside the text marks its nearest end.
 */
export function lineMarks(diagnostics: EditorDiagnostic[], lineCount: number): LineMark[] {
  const marks = new Map<number, LineMark>();
  for (const diagnostic of diagnostics) {
    if (diagnostic.line === undefined) continue;
    const line = Math.min(Math.max(diagnostic.line, 1), Math.max(lineCount, 1));
    const mark = marks.get(line);
    if (!mark) marks.set(line, { line, severity: diagnostic.severity, title: diagnostic.message });
    else {
      if (diagnostic.severity === "error") mark.severity = "error";
      mark.title += `\n${diagnostic.message}`;
    }
  }
  return [...marks.values()].sort((a, b) => a.line - b.line);
}

/** Where a 1-based line (and column) of `text` starts, as a caret offset. */
export function offsetOfLine(text: string, line: number, column = 1): number {
  let start = 0;
  for (let current = 1; current < line; current += 1) {
    const next = text.indexOf("\n", start);
    if (next === -1) return text.length;
    start = next + 1;
  }
  let end = text.indexOf("\n", start);
  if (end === -1) end = text.length;
  if (end > start && text[end - 1] === "\r") end -= 1;
  return Math.min(start + Math.max(column, 1) - 1, end);
}
