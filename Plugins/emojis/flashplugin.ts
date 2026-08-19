// Minimal Flash plugin protocol shim for TypeScript on Bun.
//
// Speaks the wire contract from docs/plugin-protocol.md: length-prefixed
// MessagePack over stdio (4-byte big-endian length + one value), protocol v3
// lifecycle, and the warm-catalog readiness gate — a sources plugin must
// publish its canonical `plugin:<id>` catalog before initialize succeeds.
// Hand-rolls the MessagePack subset the protocol needs, so a plugin author
// needs nothing beyond the Bun runtime.

export type Value =
  | null
  | boolean
  | number
  | string
  | Value[]
  | { [key: string]: Value };

export function encode(obj: Value): Uint8Array {
  const parts: Uint8Array[] = [];
  encodeInto(obj, parts);
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

function u8(...bytes: number[]): Uint8Array {
  return new Uint8Array(bytes);
}

function be32(n: number): Uint8Array {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, n);
  return out;
}

function encodeInto(obj: Value, parts: Uint8Array[]) {
  if (obj === null) return void parts.push(u8(0xc0));
  if (obj === true) return void parts.push(u8(0xc3));
  if (obj === false) return void parts.push(u8(0xc2));
  if (typeof obj === "number") {
    if (Number.isInteger(obj) && obj >= 0 && obj <= 127)
      return void parts.push(u8(obj));
    if (Number.isInteger(obj) && obj >= -32 && obj < 0)
      return void parts.push(u8(obj & 0xff));
    if (Number.isInteger(obj)) {
      const out = new Uint8Array(9);
      out[0] = 0xd3;
      new DataView(out.buffer).setBigInt64(1, BigInt(obj));
      return void parts.push(out);
    }
    const out = new Uint8Array(9);
    out[0] = 0xcb;
    new DataView(out.buffer).setFloat64(1, obj);
    return void parts.push(out);
  }
  if (typeof obj === "string") {
    const raw = new TextEncoder().encode(obj);
    if (raw.length < 32) parts.push(u8(0xa0 | raw.length));
    else {
      parts.push(u8(0xdb));
      parts.push(be32(raw.length));
    }
    return void parts.push(raw);
  }
  if (Array.isArray(obj)) {
    if (obj.length < 16) parts.push(u8(0x90 | obj.length));
    else {
      parts.push(u8(0xdc, obj.length >> 8, obj.length & 0xff));
    }
    for (const x of obj) encodeInto(x, parts);
    return;
  }
  const keys = Object.keys(obj);
  if (keys.length < 16) parts.push(u8(0x80 | keys.length));
  else parts.push(u8(0xde, keys.length >> 8, keys.length & 0xff));
  for (const k of keys) {
    encodeInto(k, parts);
    encodeInto(obj[k], parts);
  }
}

export function decode(buf: Uint8Array, pos = 0): [Value, number] {
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const b = buf[pos++];
  if (b === 0xc0) return [null, pos];
  if (b === 0xc2) return [false, pos];
  if (b === 0xc3) return [true, pos];
  if (b <= 0x7f) return [b, pos];
  if (b >= 0xe0) return [b - 256, pos];
  const str = (n: number) => {
    const s = new TextDecoder().decode(buf.subarray(pos, pos + n));
    return [s, pos + n] as [Value, number];
  };
  if (b >= 0xa0 && b <= 0xbf) return str(b & 0x1f);
  if (b === 0xd9) return ((pos += 1), str(buf[pos - 1]));
  if (b === 0xda) return ((pos += 2), str(view.getUint16(pos - 2)));
  if (b === 0xdb) return ((pos += 4), str(view.getUint32(pos - 4)));
  const container = (n: number, isMap: boolean): [Value, number] => {
    if (isMap) {
      const out: { [k: string]: Value } = {};
      for (let i = 0; i < n; i++) {
        const [k, p1] = decode(buf, pos);
        const [v, p2] = decode(buf, p1);
        out[String(k)] = v;
        pos = p2;
      }
      return [out, pos];
    }
    const out: Value[] = [];
    for (let i = 0; i < n; i++) {
      const [v, p] = decode(buf, pos);
      out.push(v);
      pos = p;
    }
    return [out, pos];
  };
  if (b >= 0x80 && b <= 0x8f) return container(b & 0x0f, true);
  if (b >= 0x90 && b <= 0x9f) return container(b & 0x0f, false);
  if (b === 0xde) return ((pos += 2), container(view.getUint16(pos - 2), true));
  if (b === 0xdf) return ((pos += 4), container(view.getUint32(pos - 4), true));
  if (b === 0xdc) return ((pos += 2), container(view.getUint16(pos - 2), false));
  if (b === 0xdd) return ((pos += 4), container(view.getUint32(pos - 4), false));
  if (b === 0xcc || b === 0xd0) return [buf[pos], pos + 1];
  if (b === 0xcd || b === 0xd1) return [view.getUint16(pos), pos + 2];
  if (b === 0xce || b === 0xd2) return [view.getUint32(pos), pos + 4];
  if (b === 0xcf || b === 0xd3)
    return [Number(view.getBigUint64(pos)), pos + 8];
  if (b === 0xca) return [view.getFloat32(pos), pos + 4];
  if (b === 0xcb) return [view.getFloat64(pos), pos + 8];
  throw new Error(`unhandled msgpack byte 0x${b.toString(16)}`);
}

export const PROTOCOL_VERSION = 3;

export interface Candidate {
  title: string;
  url?: string;
  metadata: { [key: string]: string };
}

type Msg = { [key: string]: Value };

export class Plugin {
  private warm = new Map<string, Candidate[]>();
  // One writer for the process lifetime, flushed per frame: Bun's FileSink
  // buffers, and a fresh writer per send can lose the final (shutdown)
  // reply when the process exits before the sink drains.
  private writer = Bun.stdout.writer();

  setLocations(sourceId: string, candidates: Candidate[]) {
    this.warm.set(sourceId, candidates);
  }

  private send(obj: Value) {
    const payload = encode(obj);
    const framed = new Uint8Array(4 + payload.length);
    new DataView(framed.buffer).setUint32(0, payload.length);
    framed.set(payload, 4);
    this.writer.write(framed);
    this.writer.flush();
  }

  private respond(id: Value, result: Value) {
    this.send({ jsonrpc: "2.0", id, result });
  }

  log(level: string, message: string) {
    this.send({
      jsonrpc: "2.0",
      method: "flash.log",
      params: { level, message, fields: {} },
    });
  }

  async serve() {
    let buf = new Uint8Array(0);
    for await (const chunk of Bun.stdin.stream()) {
      const next = new Uint8Array(buf.length + chunk.length);
      next.set(buf);
      next.set(chunk, buf.length);
      buf = next;
      while (buf.length >= 4) {
        const n = new DataView(buf.buffer, buf.byteOffset).getUint32(0);
        if (buf.length < 4 + n) break;
        const [msg] = decode(buf.subarray(4, 4 + n));
        buf = buf.slice(4 + n);
        if (!this.dispatch(msg as Msg)) return;
      }
    }
  }

  private dispatch(msg: Msg): boolean {
    const method = msg.method as string | undefined;
    const id = msg.id as Value;
    switch (method) {
      case "initialize": {
        const params = (msg.params ?? {}) as Msg;
        if (params.protocol_version !== PROTOCOL_VERSION) {
          this.respond(id, {
            ok: false,
            error: `protocol ${params.protocol_version} != ${PROTOCOL_VERSION}`,
          });
          return false;
        }
        this.respond(id, {
          ok: true,
          protocol_version: PROTOCOL_VERSION,
          published_sources: [...this.warm.keys()].sort(),
        });
        return true;
      }
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
      default:
        if (id !== undefined && id !== null) {
          this.respond(id, { ok: false, error: `unsupported method ${method}` });
        }
        return true;
    }
  }
}
