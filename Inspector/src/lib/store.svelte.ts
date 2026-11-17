import { withToken } from "./access";
import { backoff, describeFailure, requestJSON, withRetry } from "./request";
import { applyPatch, isNewer, parsePatch } from "./state-patch";
import type { InspectorState, LogRecord } from "./types";

const MAX_LOGS = 5000;
/** New log lines show at most this often: a tail read by eye needs no more,
 * and a busy log would otherwise refilter and redraw the list every frame. */
const LOG_INTERVAL_MS = 200;

/**
 * The resident's state and logs as the page shows them. Both are immutable
 * values (`$state.raw`): a stream `patch` replaces only the sections it
 * carries, so what reads an unchanged section is not recomputed. What the
 * stream delivers is folded in as it arrives and shown once per frame (log
 * lines at most every `LOG_INTERVAL_MS`), so a burst of changes renders once
 * and a hidden tab, which gets no frames, renders nothing until it is shown
 * again.
 */
class InspectorStore {
  state = $state.raw<InspectorState>({});
  logs = $state.raw<LogRecord[]>([]);
  /** The event stream is open, so what the page shows is current. */
  connected = $state(false);
  /** The stream opened at least once since the page loaded. */
  everConnected = $state(false);
  /** When the page lost the stream, or when it started waiting for it. */
  offlineSince = $state(Date.now());
  /** The last refresh that failed, described; empty once one succeeds. */
  refreshError = $state("");
  private source: EventSource | null = null;
  private requests: AbortController | null = null;
  private reopenTimer: ReturnType<typeof setTimeout> | undefined;
  private reopenAttempts = 0;
  /** The stream's newest state, not shown yet. */
  private pendingState: InspectorState | null = null;
  /** The stream's logs, newest last, when they changed since the last frame. */
  private pendingLogs: LogRecord[] | null = null;
  private frame = 0;
  private logsShownAt = 0;
  private logTimer: ReturnType<typeof setTimeout> | undefined;
  private resyncing: Promise<void> | null = null;

  start() {
    if (this.requests) return;
    const requests = new AbortController();
    this.requests = requests;
    this.offlineSince = Date.now();
    // The first snapshot retries while Flash starts; a pushed event that
    // arrives first wins, since an older reply never replaces a newer one.
    // The logs come with every new stream.
    void withRetry((signal) => requestJSON("/api/state", { signal }), { signal: requests.signal })
      .then((value) => this.apply(value))
      .catch(() => {});
    this.open();
  }

  /** The state the stream builds on: the newest delivered, shown or not. */
  private get current(): InspectorState {
    return this.pendingState ?? this.state;
  }

  private schedule() {
    // The first state and logs show at once: there is nothing to coalesce
    // them with, and the page is waiting for them.
    if (this.state.snapshot_seq === undefined && this.pendingState) { this.state = this.pendingState; this.pendingState = null; }
    if (!this.logs.length && this.pendingLogs) this.showLogs();
    if (this.frame) return;
    const logsDue = !!this.pendingLogs && performance.now() - this.logsShownAt >= LOG_INTERVAL_MS;
    if (!this.pendingState && !logsDue) {
      if (this.pendingLogs && this.logTimer === undefined) {
        this.logTimer = setTimeout(() => { this.logTimer = undefined; this.schedule(); }, LOG_INTERVAL_MS - (performance.now() - this.logsShownAt));
      }
      return;
    }
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      if (this.pendingState) { this.state = this.pendingState; this.pendingState = null; }
      if (this.pendingLogs && performance.now() - this.logsShownAt >= LOG_INTERVAL_MS) this.showLogs();
      if (this.pendingLogs) this.schedule();
    });
  }

  private showLogs() {
    if (!this.pendingLogs) return;
    this.logs = this.pendingLogs;
    this.pendingLogs = null;
    this.logsShownAt = performance.now();
  }

  private appendLog(record: LogRecord) {
    const logs = this.pendingLogs ?? [...this.logs];
    logs.push(record);
    if (logs.length > MAX_LOGS) logs.splice(0, logs.length - MAX_LOGS);
    this.pendingLogs = logs;
    this.schedule();
  }

  /** Opens the stream. Flash sends its state and logs to each new stream, so
   * a reconnect re-syncs the page; a snapshot request backs that up. */
  private open() {
    const source = new EventSource(withToken("/api/events"));
    this.source = source;
    source.onopen = () => {
      const recovered = this.everConnected;
      this.connected = true;
      this.everConnected = true;
      this.reopenAttempts = 0;
      if (recovered) void this.resync();
    };
    source.onerror = () => {
      if (this.source !== source) return;
      if (this.connected) this.offlineSince = Date.now();
      this.connected = false;
      // The browser retries a dropped stream itself. One it gave up on (an
      // HTTP error, a reply that was not a stream) is reopened here, with backoff.
      if (source.readyState === EventSource.CLOSED) this.scheduleReopen();
    };
    // A new stream starts with the whole state; the patches that follow
    // build on it.
    source.addEventListener("state", (event) => {
      try {
        const state = JSON.parse((event as MessageEvent).data) as InspectorState;
        if (state && typeof state === "object") { this.pendingState = state; this.schedule(); }
      } catch { /* Keep the last complete snapshot until the next event. */ }
    });
    source.addEventListener("patch", (event) => {
      let patch;
      try { patch = parsePatch(JSON.parse((event as MessageEvent).data)); } catch { patch = null; }
      // A patch the page cannot read or place is replaced by a whole snapshot.
      const outcome = patch ? applyPatch(this.current, patch) : "gap";
      if (outcome === "gap") void this.resync();
      else if (outcome !== "stale") { this.pendingState = outcome.state; this.schedule(); }
    });
    source.addEventListener("logs", (event) => {
      try {
        const value = JSON.parse((event as MessageEvent).data) as { logs?: LogRecord[] };
        if (Array.isArray(value.logs)) { this.pendingLogs = value.logs.slice(-MAX_LOGS); this.schedule(); }
      } catch { /* A malformed event must not interrupt the live stream. */ }
    });
    source.addEventListener("log", (event) => {
      try {
        const record = JSON.parse((event as MessageEvent).data) as LogRecord;
        if (record && typeof record === "object") this.appendLog(record);
      } catch { /* A malformed event must not interrupt the live stream. */ }
    });
  }

  private scheduleReopen() {
    this.source?.close();
    this.source = null;
    clearTimeout(this.reopenTimer);
    this.reopenAttempts += 1;
    this.reopenTimer = setTimeout(() => { if (this.requests) this.open(); }, backoff(this.reopenAttempts, 1000, 30_000));
  }

  /** Reconnect now rather than at the next scheduled attempt. */
  reconnect() {
    if (!this.requests) return;
    clearTimeout(this.reopenTimer);
    const source = this.source;
    this.source = null;
    source?.close();
    this.reopenAttempts = 0;
    this.open();
  }

  /** Shows a snapshot reply at once unless the page already holds a newer one. */
  private apply(value: unknown) {
    if (!value || typeof value !== "object") return;
    const state = value as InspectorState;
    if (isNewer(this.current, state)) return;
    this.pendingState = null;
    this.state = state;
  }

  /** One snapshot request at a time: a patch that cannot be placed meanwhile joins it. */
  private resync(): Promise<void> {
    this.resyncing ??= requestJSON("/api/state", { signal: this.requests?.signal })
      .then((value) => this.apply(value))
      .catch(() => { /* The stream delivers the state anyway. */ })
      .finally(() => { this.resyncing = null; });
    return this.resyncing;
  }

  /** Ask Flash for a fresh snapshot. Everything else is pushed as it
   * changes; plugin CPU time and memory have no change to push, so they are
   * resampled with each snapshot and on this request. */
  async refresh() {
    try {
      this.apply(await requestJSON("/api/state?refresh=1", { signal: this.requests?.signal }));
      this.refreshError = "";
    } catch (error) {
      this.refreshError = `Refresh failed. ${describeFailure(error)}.`;
    }
  }

  stop() {
    clearTimeout(this.reopenTimer);
    if (this.frame) cancelAnimationFrame(this.frame);
    this.frame = 0;
    clearTimeout(this.logTimer);
    this.logTimer = undefined;
    this.requests?.abort();
    this.requests = null;
    this.source?.close();
    this.source = null;
    this.connected = false;
  }
}

export const store = new InspectorStore();
