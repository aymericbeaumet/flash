import test from "node:test";
import assert from "node:assert/strict";
import { parseRoute } from "./src/lib/routes.ts";
import {
  fetchDelay, filterMetrics, formatDuration, formatRate, formatValue, isTelemetryData, kindLabel, recentLogs, seriesLabel,
  severityLevel, snippets, sortSeries, sparklinePath, traceGroups,
} from "./src/lib/telemetry.ts";
import type { TelemetryLog, TelemetryMetric, TelemetrySeries, TelemetrySpan } from "./src/lib/types.ts";

const series = (attributes: Record<string, string>, overrides: Partial<TelemetrySeries> = {}): TelemetrySeries => ({
  attributes, resource: { "service.name": "claude-code" }, scope: "", latest: 1, rate: null, total: null, history: [],
  updated_ms: 0, time_ms: null, quiet: false, updates: 1, ...overrides,
});

const metric = (name: string, kind: TelemetryMetric["kind"], members: TelemetrySeries[], overrides: Partial<TelemetryMetric> = {}): TelemetryMetric => ({
  name, kind, unit: "", description: "", temporality: kind === "gauge" ? "unspecified" : "delta", monotonic: kind === "sum", series: members, ...overrides,
});

const span = (id: string, parent: string, start: number, duration: number, overrides: Partial<TelemetrySpan> = {}): TelemetrySpan => ({
  trace_id: "t1", span_id: id, parent_span_id: parent, name: id, kind: "internal", start_ms: start, duration_ms: duration,
  status: "unset", status_message: "", attributes: {}, events: 0, service: "flash", scope: "flash", ...overrides,
});

const log = (overrides: Partial<TelemetryLog> = {}): TelemetryLog => ({
  time_ms: 0, severity: "", severity_number: 9, body: "", attributes: {}, service: "", scope: "", trace_id: "", span_id: "", event: "", ...overrides,
});

test("the telemetry page has its route", () => {
  assert.deepEqual(parseRoute({ pathname: "/telemetry", search: "" }), { page: "telemetry", param: "" });
  assert.deepEqual(parseRoute({ pathname: "/telemetry/x", search: "" }), { page: "not-found", param: "" });
});

test("a reply is read only in the shape the page expects", () => {
  assert.equal(isTelemetryData({ revision: 1, metrics: [], logs: [], spans: [], limits: {} }), true);
  assert.equal(isTelemetryData({ metrics: [] }), false);
  assert.equal(isTelemetryData(null), false);
  assert.equal(isTelemetryData("x"), false);
});

test("fetches stay one interval apart", () => {
  assert.equal(fetchDelay(0, 5000), 0);
  assert.equal(fetchDelay(1000, 1400), 600);
  assert.equal(fetchDelay(1000, 2000), 0);
  assert.equal(fetchDelay(5000, 1000), 1000, "a clock that went back waits one interval at most");
});

test("readings fit a narrow cell", () => {
  assert.deepEqual(
    [null, undefined, Number.NaN, 0, 42, 1234, -3, 0.25, 0.00123, 12.345, 123.456, 150000, 3_200_000, 4_500_000_000].map(formatValue),
    ["—", "—", "—", "0", "42", "1,234", "-3", "0.25", "0.00123", "12.35", "123.5", "150k", "3.2M", "4.5G"],
  );
  assert.equal(formatRate(2.5), "2.5/s");
  assert.equal(formatRate(null), "—");
  assert.deepEqual([0.85, 12.34, 950, 1240].map(formatDuration), ["850 µs", "12.3 ms", "950 ms", "1.24 s"]);
});

test("kinds name their temporality", () => {
  assert.equal(kindLabel({ kind: "gauge", temporality: "unspecified", monotonic: false }), "gauge");
  assert.equal(kindLabel({ kind: "sum", temporality: "delta", monotonic: true }), "sum · delta · monotonic");
  assert.equal(kindLabel({ kind: "exponential_histogram", temporality: "cumulative", monotonic: true }), "exponential histogram · cumulative");
});

test("a sparkline spans the box with the largest value on top", () => {
  assert.equal(sparklinePath([1, 3, 2], 22, 12), "M1 11 L11 1 L21 6");
  assert.equal(sparklinePath([5, 5], 10, 10), "M1 5 L9 5", "a flat series is a level line");
  assert.equal(sparklinePath([4], 10, 10), "");
  assert.equal(sparklinePath([1, Number.NaN, 2], 10, 10), "M1 9 L9 1");
});

test("series read as their sorted attributes and sender, in a stable order", () => {
  const input = series({ type: "output", model: "opus" });
  assert.deepEqual(seriesLabel(input), { attributes: "model=opus · type=output", service: "claude-code" });
  const sorted = sortSeries([series({ type: "output" }), series({ type: "input" }), series({ type: "cacheRead" })]);
  assert.deepEqual(sorted.map((item) => item.attributes.type), ["cacheRead", "input", "output"]);
});

test("the filter matches names, then attributes", () => {
  const metrics = [
    metric("claude_code.token.usage", "sum", [series({ type: "input" }), series({ type: "output" })]),
    metric("claude_code.cost.usage", "sum", [series({ model: "opus" })]),
  ];
  assert.equal(filterMetrics(metrics, "").length, 2);
  assert.deepEqual(filterMetrics(metrics, "token").map((item) => item.series.length), [2]);
  const byAttribute = filterMetrics(metrics, "type=output");
  assert.deepEqual(byAttribute.map((item) => item.name), ["claude_code.token.usage"]);
  assert.deepEqual(byAttribute[0].series.map((item) => item.attributes.type), ["output"]);
  assert.deepEqual(filterMetrics(metrics, "CLAUDE-CODE usage").map((item) => item.name), ["claude_code.token.usage", "claude_code.cost.usage"], "words match anywhere, the sender included");
  assert.deepEqual(filterMetrics(metrics, "nothing"), []);
});

test("snippets bring a metric to the bar and monitors", () => {
  assert.deepEqual(snippets({ name: "g", kind: "gauge" }), ["#{flash.otel:g}"]);
  assert.deepEqual(snippets({ name: "c", kind: "sum" }), ["#{flash.otel:c}", "#{flash.otel.total:c}", "#{flash.otel.rate:c}"]);
  assert.deepEqual(snippets({ name: "h", kind: "histogram" }), ["#{flash.otel:h}", "#{flash.otel.rate:h}", "#{flash.otel.p95:h}"]);
  assert.deepEqual(snippets({ name: "s", kind: "summary" }), ["#{flash.otel:s}", "#{flash.otel.rate:s}"]);
});

test("severities follow OTLP's ranges, else their text", () => {
  assert.deepEqual([1, 5, 9, 10, 13, 17, 21].map((n) => severityLevel(log({ severity_number: n }))), ["trace", "debug", "info", "info", "warn", "error", "fatal"]);
  assert.equal(severityLevel(log({ severity_number: 0, severity: "Warning" })), "warn");
  assert.equal(severityLevel(log({ severity_number: 0, severity: "" })), "info");
});

test("logs list newest first and filter to one trace", () => {
  const logs = [log({ body: "a", trace_id: "t1" }), log({ body: "b" }), log({ body: "c", trace_id: "t1" })];
  assert.deepEqual(recentLogs(logs).map((item) => item.body), ["c", "b", "a"]);
  assert.deepEqual(recentLogs(logs, "t1").map((item) => item.body), ["c", "a"]);
  assert.equal(logs[0].body, "a", "the input keeps its order");
});

test("a trace is a waterfall: parents first, children indented, bars in proportion", () => {
  const [trace] = traceGroups([
    span("child-b", "root", 150, 50),
    span("root", "", 100, 200, { name: "flash.interaction" }),
    span("child-a", "root", 110, 20, { status: "error", service: "tmux" }),
    span("grandchild", "child-a", 115, 5),
  ]);
  assert.equal(trace.name, "flash.interaction");
  assert.equal(trace.duration, 200);
  assert.equal(trace.error, true);
  assert.deepEqual(trace.services, ["flash", "tmux"]);
  assert.deepEqual(trace.rows.map((row) => [row.span.span_id, row.depth]), [["root", 0], ["child-a", 1], ["grandchild", 2], ["child-b", 1]]);
  assert.deepEqual(trace.rows.map((row) => [row.offset, row.width]), [[0, 100], [5, 10], [7.5, 2.5], [25, 25]]);
});

test("orphans are roots, cycles still show, and traces list newest first up to the cap", () => {
  const groups = traceGroups([
    span("a", "missing", 0, 10, { trace_id: "old" }),
    span("x", "y", 500, 10, { trace_id: "new" }),
    span("y", "x", 505, 1, { trace_id: "new" }),
  ]);
  assert.deepEqual(groups.map((group) => group.traceId), ["new", "old"]);
  assert.deepEqual(groups[1].rows.map((row) => row.depth), [0]);
  assert.deepEqual(groups[0].rows.map((row) => row.span.span_id).sort(), ["x", "y"]);
  const many = Array.from({ length: 60 }, (_, index) => span(`s${index}`, "", index, 1, { trace_id: `t${index}` }));
  const capped = traceGroups(many);
  assert.equal(capped.length, 50);
  assert.equal(capped[0].traceId, "t59");
  assert.deepEqual(traceGroups(many, 50, "t3").map((group) => group.traceId), ["t3"]);
  const instant = traceGroups([span("z", "", 7, 0, { trace_id: "zero" })]);
  assert.deepEqual([instant[0].rows[0].offset, instant[0].rows[0].width], [0, 100]);
});
