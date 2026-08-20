// Shared Flash plugin SDK for TypeScript on Bun — no Flash business
// concepts, mirroring the Rust `flash_plugin` crate's role for TS plugins.
// Plugins import it relatively (the directory sits beside every plugin in
// both the checkout and the staged release bundle):
//
//   import { Plugin } from "../_typescript_flash_plugin/flashplugin";
//
// Speaks the wire contract from docs/plugin-protocol.md: protocol v1 —
// newline-delimited JSON over stdio, one object per line, no envelope
// beyond id/method/params/result. Frame shapes: id+method = request,
// id alone = response, method alone = notification. Host and plugin id
// counters are independent and may overlap; replies to plugin-issued
// requests are correlated through the SDK's own pending map. A sources
// plugin must have its warm store populated before initialize is answered.

export type Value =
  | null
  | boolean
  | number
  | string
  | Value[]
  | { [key: string]: Value };

export const PROTOCOL_VERSION = 1;

export interface Candidate {
  title: string;
  url?: string;
  metadata: { [key: string]: string };
  effect?: Value;
}

export interface Answer {
  title: string;
  subtitle?: string;
  effect: { type: string; text: string };
}

type Msg = { [key: string]: Value };

export class Plugin {
  private warm = new Map<string, Candidate[]>();
  private nextId = 1;
  private pending = new Map<number, (result: Value) => void>();
  private cachedConfig?: { [key: string]: Value };
  // Synchronous CPU-only evaluator hook: return the (possibly empty) answer
  // list — additive parsers decline unclaimed input, never error.
  onQuery?: (params: Msg) => Answer[];
  // One writer for the process lifetime, flushed per frame: Bun's FileSink
  // buffers, and a fresh writer per send can lose the final (shutdown)
  // reply when the process exits before the sink drains.
  private writer = Bun.stdout.writer();

  setLocations(sourceId: string, candidates: Candidate[]) {
    this.warm.set(sourceId, candidates);
  }

  private send(obj: Value) {
    this.writer.write(JSON.stringify(obj) + "\n");
    this.writer.flush();
  }

  private respond(id: Value, result: Value) {
    this.send({ id, result });
  }

  log(level: string, message: string) {
    this.send({ method: "flash.log", params: { level, message, fields: {} } });
  }

  // Plugin→host RPC on the SDK's own id counter; resolves with the host's
  // result as-is, including capability NAKs shaped {ok: false, error}.
  callHost(method: string, params: Value): Promise<Value> {
    const id = this.nextId++;
    return new Promise((resolve) => {
      this.pending.set(id, resolve);
      this.send({ id, method, params });
    });
  }

  // The plugin's [plugin.<id>] settings table, parsed once from the
  // FLASH_PLUGIN_CONFIG env var (empty object when unset or invalid).
  config(): { [key: string]: Value } {
    if (this.cachedConfig === undefined) {
      let parsed: Value = null;
      try {
        parsed = JSON.parse(process.env.FLASH_PLUGIN_CONFIG ?? "");
      } catch {}
      this.cachedConfig =
        parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)
          ? parsed
          : {};
    }
    return this.cachedConfig;
  }

  async serve() {
    let buf = "";
    const utf8 = new TextDecoder();
    for await (const chunk of Bun.stdin.stream()) {
      buf += utf8.decode(chunk, { stream: true });
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (!line.trim()) continue;
        let msg: Msg;
        try {
          msg = JSON.parse(line) as Msg;
        } catch {
          continue; // wire noise is dropped, never fatal
        }
        if (!this.dispatch(msg)) return;
      }
    }
  }

  private dispatch(msg: Msg): boolean {
    const method = msg.method as string | undefined;
    const id = msg.id;
    if (method === undefined) {
      // id-only frame: a response to one of OUR requests; anything else
      // (an id we never issued) is ignored.
      const resolve = typeof id === "number" ? this.pending.get(id) : undefined;
      if (resolve) {
        this.pending.delete(id as number);
        resolve(msg.result ?? null);
      }
      return true;
    }
    // method without id: a notification (e.g. "event") — ignore silently.
    if (id === undefined || id === null) return true;
    const params = (msg.params ?? {}) as Msg;
    switch (method) {
      case "initialize":
        if (params.protocol_version !== PROTOCOL_VERSION) {
          this.respond(id, { ok: false, error: "protocol version mismatch" });
          return false;
        }
        // The warm store is already populated (readiness gate).
        this.respond(id, { ok: true, protocol_version: PROTOCOL_VERSION });
        return true;
      case "heartbeat":
        this.respond(id, { ok: true });
        return true;
      case "shutdown":
        this.respond(id, { ok: true });
        return false;
      case "sources.snapshot": {
        const candidates = [...this.warm.entries()]
          .sort(([a], [b]) => a.localeCompare(b))
          .flatMap(([, rows]) => rows);
        this.respond(id, { candidates: candidates as unknown as Value });
        return true;
      }
      case "query.evaluate": {
        if (!this.onQuery) break;
        this.respond(id, {
          answers: this.onQuery(params) as unknown as Value,
        });
        return true;
      }
    }
    this.respond(id, { ok: false, error: `unsupported method ${method}` });
    return true;
  }
}
