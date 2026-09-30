import type { InspectorState, LogRecord } from "./types";

const MAX_LOGS = 5000;

class InspectorStore {
  state = $state<InspectorState>({});
  logs = $state<LogRecord[]>([]);
  connected = $state(false);
  private source: EventSource | null = null;
  private requests: AbortController | null = null;

  start() {
    if (this.source) return;
    const requests = new AbortController();
    this.requests = requests;
    let receivedState = false;
    let receivedLogs = false;
    // The initial HTTP snapshots must not overwrite a newer stream event.
    void fetch("/api/state", { signal: requests.signal })
      .then((response) => { if (!response.ok) throw new Error("State unavailable"); return response.json(); })
      .then((state: InspectorState) => { if (!receivedState && !requests.signal.aborted) this.state = state; })
      .catch(() => {});
    void fetch("/api/logs", { signal: requests.signal })
      .then((response) => { if (!response.ok) throw new Error("Logs unavailable"); return response.json(); })
      .then((value: { logs?: LogRecord[] }) => { if (!receivedLogs && !requests.signal.aborted) this.logs = (value.logs ?? []).slice(-MAX_LOGS); })
      .catch(() => {});

    const source = new EventSource("/api/events");
    this.source = source;
    source.onopen = () => { this.connected = true; };
    source.onerror = () => { this.connected = false; };
    source.addEventListener("state", (event) => {
      try {
        const state = JSON.parse((event as MessageEvent).data) as InspectorState;
        if (state && typeof state === "object") { receivedState = true; this.state = state; }
      } catch { /* Keep the last complete snapshot until the next event. */ }
    });
    source.addEventListener("logs", (event) => {
      try {
        const value = JSON.parse((event as MessageEvent).data) as { logs?: LogRecord[] };
        if (Array.isArray(value.logs)) { receivedLogs = true; this.logs = value.logs.slice(-MAX_LOGS); }
      } catch { /* A malformed event must not interrupt the live stream. */ }
    });
    source.addEventListener("log", (event) => {
      try {
        const record = JSON.parse((event as MessageEvent).data) as LogRecord;
        if (!record || typeof record !== "object") return;
        receivedLogs = true;
        this.logs = [...this.logs.slice(-(MAX_LOGS - 1)), record];
      } catch { /* A malformed event must not interrupt the live stream. */ }
    });
  }

  /** Ask Flash for a fresh snapshot. Everything else is pushed as it
   * changes; plugin CPU time and memory have no change to push, so they are
   * resampled with each snapshot and on this request. */
  async refresh() {
    try {
      const response = await fetch("/api/state?refresh=1");
      if (!response.ok) return;
      const state = (await response.json()) as InspectorState;
      // The same snapshot also arrives on the stream; never go back in time.
      if (state && typeof state === "object" && (state.snapshot_at_unix_ms ?? 0) >= (this.state.snapshot_at_unix_ms ?? 0)) this.state = state;
    } catch { /* The stream keeps the page current; a failed resample changes nothing. */ }
  }

  stop() {
    this.requests?.abort();
    this.requests = null;
    this.source?.close();
    this.source = null;
    this.connected = false;
  }
}

export const store = new InspectorStore();
