import type { InspectorState } from "./types.ts";

/**
 * The event stream's `patch`: the top-level sections of the state that
 * changed since the snapshot numbered `base`, which the stream sent before
 * it. Every other section keeps its value, and so its identity, so the page
 * recomputes only what reads a changed section. `set` always carries the
 * new `snapshot_seq` and `snapshot_at_unix_ms`.
 */
export interface StatePatch {
  base: number;
  set: InspectorState;
  unset: string[];
}

export type PatchOutcome =
  /** The patch applied: the next state. */
  | { state: InspectorState }
  /** The page already holds this snapshot or a newer one (a reply overtook the stream). */
  | "stale"
  /** The patch builds on a snapshot the page never saw: ask for a whole one. */
  | "gap";

export function parsePatch(value: unknown): StatePatch | null {
  if (!value || typeof value !== "object") return null;
  const patch = value as Partial<StatePatch>;
  if (typeof patch.base !== "number" || !patch.set || typeof patch.set !== "object" || Array.isArray(patch.set)) return null;
  if (typeof patch.set.snapshot_seq !== "number") return null;
  if (patch.unset !== undefined && (!Array.isArray(patch.unset) || patch.unset.some((key) => typeof key !== "string"))) return null;
  return { base: patch.base, set: patch.set, unset: patch.unset ?? [] };
}

/** Whether `next` was taken after `current`: by time, then by number. */
export function isNewer(next: InspectorState, current: InspectorState): boolean {
  const at = next.snapshot_at_unix_ms ?? 0;
  const currentAt = current.snapshot_at_unix_ms ?? 0;
  return at > currentAt || (at === currentAt && (next.snapshot_seq ?? 0) > (current.snapshot_seq ?? 0));
}

/** `patch` on `current`, which keeps every section the patch leaves alone. */
export function applyPatch(current: InspectorState, patch: StatePatch): PatchOutcome {
  if (current.snapshot_seq !== patch.base) return isNewer(patch.set, current) ? "gap" : "stale";
  const next: Record<string, unknown> = { ...current, ...patch.set };
  for (const key of patch.unset) delete next[key];
  return { state: next as InspectorState };
}
