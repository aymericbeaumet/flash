import type { InspectorState, LogRecord } from "./types";

const MAX_LOGS = 5000;

// Central reactive store for the inspector. The Swift DebugServer pushes
// `state`, `log`, and `logs` events over SSE (`/events`); we also seed
// from `/state` and `/logs` on load in case the stream lags.
class InspectorStore {
  state = $state<InspectorState>({});
  logs = $state<LogRecord[]>([]);
  connected = $state(false);

  private source: EventSource | null = null;

  start() {
    void fetch("/state")
      .then((r) => r.json())
      .then((s: InspectorState) => (this.state = s))
      .catch(() => {});
    void fetch("/logs")
      .then((r) => r.json())
      .then((v: { logs?: LogRecord[] }) => (this.logs = v.logs ?? []))
      .catch(() => {});

    const es = new EventSource("/events");
    this.source = es;
    es.onopen = () => (this.connected = true);
    es.onerror = () => (this.connected = false);
    es.addEventListener("state", (e) => {
      this.state = JSON.parse((e as MessageEvent).data) as InspectorState;
    });
    es.addEventListener("logs", (e) => {
      const v = JSON.parse((e as MessageEvent).data) as { logs?: LogRecord[] };
      this.logs = v.logs ?? [];
    });
    es.addEventListener("log", (e) => {
      const record = JSON.parse((e as MessageEvent).data) as LogRecord;
      const next = this.logs.length >= MAX_LOGS ? this.logs.slice(1) : this.logs.slice();
      next.push(record);
      this.logs = next;
    });
  }

  stop() {
    this.source?.close();
    this.source = null;
  }
}

export const store = new InspectorStore();
