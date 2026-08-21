// Shared Flash plugin SDK for TypeScript on Bun — no Flash business
// concepts, mirroring the Rust `flash_plugin` crate's role for TS plugins.
// Plugins import it by bare module name — the host (and the spec runner)
// inject NODE_PATH pointing at this directory at spawn, so the same import
// works from the checkout, the staged release bundle, and third-party roots:
//
//   import { Plugin, ok, unhandled, fail } from "flashplugin";
//
// Speaks the wire contract from docs/plugin-protocol.md (constants pinned by
// Plugins/_flash_plugin_specs/protocol.json): protocol v1, UTF-8 NDJSON over
// stdio, 10 MiB line cap both directions. Frame triage: id+method is a host
// request, id alone resolves a callHost pending, method alone is a
// notification. Registration is camelCase hooks on the constructor:
//
//   new Plugin({ onStart, onEvaluate, onCommand, ... }).serve();
//
// `perform` routes by kind to onResolve/onCommand/onAction/onNavigate; those
// hooks return replies built with ok(fields)/unhandled()/fail(msg) — plain
// object literals. onHints returns either a target array or {targets,
// context_pid} — the SDK wraps both as {ok: true, targets: [...]}. Request
// handlers are fired without awaiting so a hook that awaits callHost never
// stalls the read pump; all writes funnel through the one serialized writer
// (a single FileSink, one synchronous write+flush per frame). Hook errors
// never break the wire: request hooks answer fail("<method> hook failed")
// (evaluate answers empty — evaluators never error), lifecycle hooks log
// and continue. stdin EOF is the shutdown signal: onShutdown runs, serve()
// resolves, the process exits 0. callHost never rejects and never resolves
// undefined — timeouts and host death arrive as {ok: false, error} results.

// ── constants ──────────────────────────────────────────────────────────────

export const PROTOCOL_VERSION = 1;
const MAX_FRAME_BYTES = 10 * 1024 * 1024; // NDJSON line cap, both directions
const HOST_CALL_TIMEOUT_MS = 5000;

const ERR_FRAME_OVERFLOW = "response exceeded outbound frame limit";
const ERR_HOST_CLOSED = "host closed stdin";
const ERR_HOST_TIMEOUT = "host call timed out";

const PERFORM_KINDS = ["resolve", "command", "action", "navigate"] as const;

export type Value =
  | null
  | boolean
  | number
  | string
  | Value[]
  | { [key: string]: Value };

type Msg = { [key: string]: Value };

// Catalog row for publish/search: `source` is first-class and must name a
// manifest sources[].name.
export interface Row {
  source: string;
  title: string;
  url?: string;
  metadata?: { [key: string]: string };
  effect?: Value;
}

export interface Answer {
  title: string;
  subtitle?: string;
  effect: { type: string; text: string };
}

export type Reply = { [key: string]: Value };
export type HintTargets = Value[] | { targets: Value[]; context_pid?: number };

export interface Hooks {
  onStart?: () => void | Promise<void>;
  onShutdown?: () => void | Promise<void>;
  onEvent?: (name: string, payload: Value) => void | Promise<void>;
  onEvaluate?: (params: Msg) => Answer[]; // synchronous, CPU-only
  onSearch?: (params: Msg) => Row[] | Promise<Row[]>;
  onHints?: (params: Msg) => HintTargets | Promise<HintTargets>;
  onResolve?: (params: Msg) => Reply | Promise<Reply>;
  onCommand?: (params: Msg) => Reply | Promise<Reply>;
  onAction?: (params: Msg) => Reply | Promise<Reply>;
  onNavigate?: (params: Msg) => Reply | Promise<Reply>;
}

// ── reply helpers ──────────────────────────────────────────────────────────

export const ok = (fields: Reply = {}): Reply => ({ ok: true, ...fields });

export const unhandled = (): Reply => ({ ok: false, unhandled: true });

export const fail = (error: string): Reply => ({ ok: false, error });

// ── config / env accessors ─────────────────────────────────────────────────

let cachedConfig: { [key: string]: Value } | undefined;

/** The object parsed once from FLASH_PLUGIN_CONFIG ({} when unset/invalid). */
export function config(): { [key: string]: Value } {
  if (cachedConfig === undefined) {
    let parsed: Value = null;
    try {
      parsed = JSON.parse(process.env.FLASH_PLUGIN_CONFIG ?? "");
    } catch {}
    cachedConfig =
      parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
        ? parsed
        : {};
  }
  return cachedConfig;
}

/** The plugin's writable data directory; never defaults (a silent "." would
 * scatter state into whatever cwd the plugin happened to spawn in). */
export function dataDir(): string {
  const dir = process.env.FLASH_PLUGIN_DATA_DIR;
  if (!dir) throw new Error("FLASH_PLUGIN_DATA_DIR is not set");
  return dir;
}

/** Async single-process plugin runtime: one read pump, one serialized
 * writer, request hooks fired without blocking the pump. */
export class Plugin {
  private hooks: Hooks;
  private buf = "";
  private skipping = false; // inside an oversized inbound line
  private nextId = 0;
  private pending = new Map<number, (result: Reply) => void>();
  private initialized = false;
  private done = false; // stdin EOF or stdout death: cleanup, then exit 0
  private terminated = false; // version mismatch: exit 0 without cleanup
  // One writer for the process lifetime, flushed per frame: Bun's FileSink
  // buffers, and a fresh writer per send can lose the final reply when the
  // process exits before the sink drains.
  private writer = Bun.stdout.writer();

  constructor(hooks: Hooks = {}) {
    this.hooks = hooks;
  }

  // ── framing ────────────────────────────────────────────────────────────

  /** The single write path: one JSON object, one line, flushed. Returns
   * false when the encoded frame exceeds the outbound cap. */
  private send(obj: Value): boolean {
    const data = JSON.stringify(obj);
    if (Buffer.byteLength(data) > MAX_FRAME_BYTES) return false;
    try {
      this.writer.write(data + "\n");
      this.writer.flush();
    } catch {
      this.done = true; // host is gone; stdin EOF follows
    }
    return true;
  }

  private respond(id: Value, result: Reply) {
    if (!this.send({ id, result })) {
      this.send({ id, result: fail(ERR_FRAME_OVERFLOW) });
    }
  }

  private notify(method: string, params: Value) {
    this.send({ method, params }); // oversized notifications are dropped
  }

  // ── pending map / callHost ─────────────────────────────────────────────

  /** Plugin→host RPC. Never rejects and never resolves undefined — timeouts
   * and host death arrive as {ok: false, error} result objects. */
  callHost(
    method: string,
    params: Value = {},
    timeoutMs = HOST_CALL_TIMEOUT_MS,
  ): Promise<Reply> {
    const id = ++this.nextId;
    if (this.done) return Promise.resolve(fail(ERR_HOST_CLOSED));
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id); // late replies are dropped
        resolve(fail(ERR_HOST_TIMEOUT));
      }, timeoutMs);
      this.pending.set(id, (result) => {
        clearTimeout(timer);
        resolve(result);
      });
      if (!this.send({ id, method, params })) {
        clearTimeout(timer);
        this.pending.delete(id);
        resolve(fail(ERR_FRAME_OVERFLOW));
      }
    });
  }

  private handleEof() {
    this.done = true;
    for (const [id, settle] of [...this.pending]) {
      this.pending.delete(id);
      settle(fail(ERR_HOST_CLOSED));
    }
  }

  // ── dispatch ───────────────────────────────────────────────────────────

  private dispatch(line: string) {
    let msg: Msg;
    try {
      msg = JSON.parse(line) as Msg;
    } catch {
      return; // wire noise is dropped, never fatal
    }
    if (msg === null || typeof msg !== "object" || Array.isArray(msg)) return;
    const method = typeof msg.method === "string" ? msg.method : undefined;
    const id = msg.id;
    if (method !== undefined && id !== undefined && id !== null) {
      // Host→plugin request: fired, not awaited — the pump keeps reading so
      // a hook that awaits callHost sees its reply arrive.
      void this.handleRequest(id, method, (msg.params ?? {}) as Msg);
    } else if (id !== undefined && id !== null) {
      // Response to one of our callHost requests; unknown ids are dropped.
      const settle = typeof id === "number" ? this.pending.get(id) : undefined;
      if (settle) {
        this.pending.delete(id as number);
        const result = msg.result;
        settle(
          result !== null && typeof result === "object" && !Array.isArray(result)
            ? (result as Reply)
            : fail("malformed host reply"),
        );
      }
    } else if (method === "event") {
      // Notification; unknown methods are ignored.
      const params = (msg.params ?? {}) as Msg;
      void (async () => this.hooks.onEvent?.(String(params.name ?? ""), params.payload ?? null))()
        .catch(() => this.log("error", "event hook failed"));
    }
  }

  // ── handler registry ───────────────────────────────────────────────────

  private async handleRequest(id: Value, method: string, params: Msg) {
    switch (method) {
      case "initialize":
        return this.handleInitialize(id, params);
      case "ping":
        return this.respond(id, ok());
      case "evaluate": {
        let answers: Answer[] = [];
        try {
          answers = this.hooks.onEvaluate?.(params) ?? [];
        } catch {} // evaluators are additive, never error paths
        return this.respond(id, { ok: true, answers: answers as unknown as Value });
      }
      case "search": {
        try {
          const rows = (await this.hooks.onSearch?.(params)) ?? [];
          return this.respond(id, { ok: true, rows: rows as unknown as Value });
        } catch {
          return this.respond(id, fail("search hook failed"));
        }
      }
      case "hints":
        return this.respond(id, await this.hintsReply(params));
      case "perform":
        return this.respond(id, await this.performReply(params));
      default:
        return this.respond(id, fail(`unknown method: ${method}`));
    }
  }

  private handleInitialize(id: Value, params: Msg) {
    const hostVersion = params.protocol_version;
    if (hostVersion !== PROTOCOL_VERSION) {
      this.respond(id, {
        ok: false,
        protocol_version: PROTOCOL_VERSION,
        error:
          `protocol version mismatch: host v${hostVersion},` +
          ` plugin v${PROTOCOL_VERSION}`,
      });
      this.terminated = true; // terminal: serve() returns, the process exits 0
      return;
    }
    if (this.initialized) {
      return this.respond(id, fail("initialize may only be called once"));
    }
    this.initialized = true;
    this.respond(id, { ok: true, protocol_version: PROTOCOL_VERSION });
    // Fire the async hook AFTER the reply, without blocking the pump.
    void (async () => this.hooks.onStart?.())().catch(() =>
      this.log("error", "start hook failed"),
    );
  }

  private async hintsReply(params: Msg): Promise<Reply> {
    if (!this.hooks.onHints) return { ok: true, targets: [] };
    try {
      const reply = await this.hooks.onHints(params);
      return Array.isArray(reply)
        ? { ok: true, targets: reply }
        : ({ ok: true, ...reply } as Reply); // {targets, context_pid?}
    } catch {
      return fail("hints hook failed");
    }
  }

  private async performReply(params: Msg): Promise<Reply> {
    const kind = params.kind;
    if (!(PERFORM_KINDS as readonly Value[]).includes(kind)) {
      return fail(`unknown perform kind: ${kind}`);
    }
    const hook = {
      resolve: this.hooks.onResolve,
      command: this.hooks.onCommand,
      action: this.hooks.onAction,
      navigate: this.hooks.onNavigate,
    }[kind as (typeof PERFORM_KINDS)[number]];
    if (!hook) return unhandled();
    try {
      return (await hook(params)) ?? ok();
    } catch {
      return fail("perform hook failed"); // mine-but-broke: no fallback
    }
  }

  // ── emitters ───────────────────────────────────────────────────────────

  /** Full-replacement catalog push; each row carries a first-class `source`
   * naming a manifest sources[].name. */
  publish(rows: Row[]) {
    this.notify("publish", { rows: rows as unknown as Value });
  }

  status(segments: { [name: string]: string }) {
    this.notify("status", { segments });
  }

  log(level: string, message: string, fields: { [key: string]: Value } = {}) {
    this.notify("log", { level, message, fields });
  }

  // ── serve loop ─────────────────────────────────────────────────────────

  /** Reads frames until stdin EOF — the shutdown signal: onShutdown runs,
   * serve() resolves, the process exits 0. Oversized lines are discarded
   * (never buffered whole); the stream self-heals at the next newline. */
  async serve() {
    const utf8 = new TextDecoder();
    for await (const chunk of Bun.stdin.stream()) {
      this.buf += utf8.decode(chunk, { stream: true });
      let nl: number;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl);
        this.buf = this.buf.slice(nl + 1);
        if (this.skipping) {
          this.skipping = false; // tail of an oversized line
          continue;
        }
        if (Buffer.byteLength(line) > MAX_FRAME_BYTES) continue;
        this.dispatch(line);
        if (this.terminated) return; // version mismatch: exit without cleanup
      }
      if (this.done) break; // stdout died: wind down through cleanup
      // UTF-16 units under-count UTF-8 bytes, so this only bounds memory;
      // the per-line byte check above is the precise gate.
      if (this.skipping) this.buf = "";
      else if (this.buf.length > MAX_FRAME_BYTES) {
        this.buf = "";
        this.skipping = true;
      }
    }
    if (this.buf.trim() && !this.skipping) this.dispatch(this.buf); // EOF tail
    if (this.terminated) return;
    this.handleEof();
    try {
      await this.hooks.onShutdown?.();
    } catch {} // exiting anyway; stdout may already be gone
  }
}
