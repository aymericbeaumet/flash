import assert from "node:assert/strict";
import test from "node:test";
import { applyPatch, isNewer, parsePatch } from "./src/lib/state-patch.ts";
import type { InspectorState } from "./src/lib/types.ts";

const base: InspectorState = { snapshot_seq: 4, snapshot_at_unix_ms: 1000, mode: "normal", plugins: [], commands: [] };

test("a patch replaces only the sections it carries, keeping the others' identity", () => {
  const patch = parsePatch({ base: 4, set: { snapshot_seq: 5, snapshot_at_unix_ms: 1100, mode: "insert" }, unset: ["commands"] });
  assert.ok(patch);
  const outcome = applyPatch(base, patch);
  assert.ok(typeof outcome === "object");
  assert.equal(outcome.state.mode, "insert");
  assert.equal(outcome.state.snapshot_seq, 5);
  assert.equal(outcome.state.plugins, base.plugins, "an untouched section is the same value");
  assert.equal("commands" in outcome.state, false);
  assert.equal(base.mode, "normal", "the current state is not changed in place");
});

test("a patch the page has already overtaken is stale, one past a missing snapshot a gap", () => {
  const overtaken = parsePatch({ base: 2, set: { snapshot_seq: 3, snapshot_at_unix_ms: 900 } });
  assert.equal(applyPatch(base, overtaken!), "stale");
  const ahead = parsePatch({ base: 6, set: { snapshot_seq: 7, snapshot_at_unix_ms: 1300 } });
  assert.equal(applyPatch(base, ahead!), "gap");
});

test("malformed patches are refused", () => {
  for (const value of [null, 3, {}, { base: 1 }, { base: 1, set: [] }, { base: 1, set: {} }, { base: 1, set: { snapshot_seq: 2 }, unset: [3] }]) {
    assert.equal(parsePatch(value), null, JSON.stringify(value));
  }
});

test("snapshots order by time, then by number", () => {
  assert.ok(isNewer({ snapshot_at_unix_ms: 2 }, { snapshot_at_unix_ms: 1 }));
  assert.ok(isNewer({ snapshot_at_unix_ms: 1, snapshot_seq: 3 }, { snapshot_at_unix_ms: 1, snapshot_seq: 2 }));
  assert.ok(!isNewer({ snapshot_at_unix_ms: 1, snapshot_seq: 2 }, { snapshot_at_unix_ms: 1, snapshot_seq: 2 }));
});
