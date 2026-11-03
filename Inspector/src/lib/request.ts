// Requests to the resident: what failed, whether trying again can help, and
// a bounded retry with backoff for the failures that can pass on their own.

import { authorize } from "./access.ts";

/** `offline`: Flash did not answer. `http`: it answered with an error status.
 * `timeout`: it took too long. `contract`: the reply was not what the page
 * reads. `aborted`: the page stopped asking. */
export type FailureKind = "offline" | "http" | "timeout" | "contract" | "aborted";

export class RequestError extends Error {
  readonly kind: FailureKind;
  readonly status?: number;

  constructor(kind: FailureKind, message: string, status?: number) {
    super(message);
    this.name = "RequestError";
    this.kind = kind;
    this.status = status;
  }

  /** Trying again can help: Flash may be restarting or busy. A refused
   * request or a reply the page cannot read fails the same way next time. */
  get transient(): boolean {
    if (this.kind === "offline" || this.kind === "timeout") return true;
    return this.kind === "http" && this.status !== undefined && (this.status >= 500 || this.status === 408 || this.status === 429);
  }
}

/** A contract error: the reply parsed but is not the shape the page reads. */
export function contractError(message: string): RequestError {
  return new RequestError("contract", message);
}

/** Any thrown value as a classified failure. */
export function classify(error: unknown): RequestError {
  if (error instanceof RequestError) return error;
  if (error instanceof DOMException && error.name === "AbortError") return new RequestError("aborted", "Request cancelled");
  if (error instanceof DOMException && error.name === "TimeoutError") return new RequestError("timeout", "Flash took too long to answer");
  // fetch rejects with a TypeError when nothing answers on the port.
  if (error instanceof TypeError) return new RequestError("offline", "Flash is not answering");
  if (error instanceof SyntaxError) return new RequestError("contract", `Unreadable reply: ${error.message}`);
  return new RequestError("contract", error instanceof Error ? error.message : String(error));
}

/** One line for an inline error: what went wrong, in the reader's terms. */
export function describeFailure(error: unknown): string {
  const failure = classify(error);
  switch (failure.kind) {
    case "offline": return "Flash is not answering (offline)";
    case "timeout": return "Flash took too long to answer (timeout)";
    case "http":
      if (failure.status === 401) return "Flash refused this page its data (HTTP 401): open the help from Flash, with flash help show, to unlock it";
      return `Flash answered HTTP ${failure.status}${failure.message ? `: ${failure.message}` : ""}`;
    case "contract": return `Unexpected reply (contract error): ${failure.message}`;
    case "aborted": return "Request cancelled";
  }
}

export interface RetryOptions {
  /** Attempts after the first. */
  retries?: number;
  /** Delay before the first retry; each later one doubles, up to `maxDelayMs`. */
  baseDelayMs?: number;
  maxDelayMs?: number;
  signal?: AbortSignal;
  sleep?: (ms: number, signal?: AbortSignal) => Promise<void>;
  /** Told before each wait, with the failure and the attempt that follows. */
  onRetry?: (failure: RequestError, attempt: number, delayMs: number) => void;
}

/** The wait before retry `attempt` (1-based). */
export function backoff(attempt: number, baseDelayMs = 500, maxDelayMs = 8000): number {
  return Math.min(maxDelayMs, baseDelayMs * 2 ** Math.max(0, attempt - 1));
}

export function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new RequestError("aborted", "Request cancelled"));
    const timer = setTimeout(() => { signal?.removeEventListener("abort", stop); resolve(); }, ms);
    const stop = () => { clearTimeout(timer); reject(new RequestError("aborted", "Request cancelled")); };
    signal?.addEventListener("abort", stop, { once: true });
  });
}

/** Runs `attempt` until it succeeds, retrying transient failures with
 * backoff; a lasting failure, the last retry or an abort rethrows it classified. */
export async function withRetry<T>(attempt: (signal?: AbortSignal) => Promise<T>, options: RetryOptions = {}): Promise<T> {
  const { retries = 3, baseDelayMs = 500, maxDelayMs = 8000, signal, sleep: wait = sleep, onRetry } = options;
  for (let tries = 0; ; tries += 1) {
    try {
      if (signal?.aborted) throw new RequestError("aborted", "Request cancelled");
      return await attempt(signal);
    } catch (error) {
      const failure = classify(error);
      if (signal?.aborted || failure.kind === "aborted") throw new RequestError("aborted", "Request cancelled");
      if (!failure.transient || tries >= retries) throw failure;
      const delay = backoff(tries + 1, baseDelayMs, maxDelayMs);
      onRetry?.(failure, tries + 1, delay);
      await wait(delay, signal);
    }
  }
}

/** GETs or sends JSON with a time limit, classifying every failure. */
export async function requestJSON(url: string, init: RequestInit & { timeoutMs?: number } = {}): Promise<unknown> {
  const { timeoutMs = 10_000, signal, ...rest } = init;
  if (signal?.aborted) throw new RequestError("aborted", "Request cancelled");
  // One controller ends the request for the caller's abort or the time limit.
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
  const cancel = () => controller.abort();
  signal?.addEventListener("abort", cancel, { once: true });
  try {
    let response: Response;
    let text: string;
    try {
      response = await fetch(url, { ...rest, headers: authorize(url, rest.headers), signal: controller.signal });
      text = await response.text();
    } catch (error) {
      if (signal?.aborted) throw new RequestError("aborted", "Request cancelled");
      if (timedOut) throw new RequestError("timeout", "Flash took too long to answer");
      throw classify(error);
    }
    let body: unknown = null;
    if (text) {
      try { body = JSON.parse(text); } catch {
        if (response.ok) throw contractError(`${url} did not return JSON`);
      }
    }
    if (!response.ok) {
      const reason = body && typeof body === "object" && "error" in body && typeof body.error === "string" ? body.error : response.statusText;
      throw new RequestError("http", reason, response.status);
    }
    return body;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", cancel);
  }
}
