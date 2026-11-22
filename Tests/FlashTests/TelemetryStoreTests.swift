import FlashOTLP
import Foundation
import XCTest

@testable import flash

/// The receiver's store: OTLP decoded into bounded, in-memory series, log
/// records and spans, and read back through the status format's values.
///
/// `Tests/TelemetryFixtures/*.json` are opentelemetry-proto v1.11.1's own
/// `examples/`; the `.binpb` files are the same requests encoded by the
/// reference Python protobuf runtime (`opentelemetry-proto` 1.38.0), not by
/// Flash's encoder.
final class TelemetryStoreTests: XCTestCase {
  static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("TelemetryFixtures")

  static func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
  }

  final class Clock {
    var now: TimeInterval = 1_000
  }

  private func store(_ clock: Clock = Clock(), limits: TelemetryStore.Limits = .init())
    -> TelemetryStore
  {
    TelemetryStore(
      limits: limits, clock: { clock.now },
      wallClock: { Date(timeIntervalSince1970: 1_800_000_000) }, scheduler: PollScheduler())
  }

  private func ingest(
    _ store: TelemetryStore, _ name: String, _ signal: TelemetrySignal, _ encoding: OTLPEncoding
  ) throws -> TelemetryStore.IngestResult {
    let export = try OTLPCodec.decode(
      Self.fixture(name), signal: signal, encoding: encoding)
    return store.ingest(export)
  }

  private func value(_ store: TelemetryStore, _ key: String) -> String? {
    store.values(for: [key])[key]
  }

  // MARK: Golden payloads

  func testTheGoldenMetricsDecodeIdenticallyFromJSONAndProtobuf() throws {
    let json = try OTLPCodec.decode(
      Self.fixture("metrics.json"), signal: .metrics, encoding: .json)
    let protobuf = try OTLPCodec.decode(
      Self.fixture("metrics.binpb"), signal: .metrics, encoding: .protobuf)
    guard case .metrics(let fromJSON) = json, case .metrics(let fromProtobuf) = protobuf else {
      return XCTFail("decoded the wrong signal")
    }
    XCTAssertEqual(fromJSON, fromProtobuf)
    XCTAssertEqual(fromJSON.resourceMetrics.first?.scopeMetrics.first?.metrics.count, 4)
  }

  func testTheGoldenMetricsLandInTheStore() throws {
    for (name, encoding) in [("metrics.json", OTLPEncoding.json), ("metrics.binpb", .protobuf)] {
      let store = store()
      let result = try ingest(store, name, .metrics, encoding)
      XCTAssertEqual(result, .init(accepted: 4, rejected: 0, message: ""), name)
      XCTAssertEqual(value(store, "flash.otel:my.counter"), "5", name)
      XCTAssertEqual(value(store, "flash.otel.total:my.counter"), "5", name)
      XCTAssertEqual(value(store, "flash.otel:my.gauge"), "10", name)
      XCTAssertEqual(value(store, "flash.otel.count:my.histogram"), "2", name)
      XCTAssertEqual(value(store, "flash.otel.sum:my.histogram"), "2", name)
      XCTAssertEqual(value(store, "flash.otel.mean:my.histogram"), "1", name)
      XCTAssertEqual(value(store, "flash.otel.max:my.histogram"), "2", name)
      XCTAssertEqual(value(store, "flash.otel.count:my.exponential.histogram"), "3", name)
      XCTAssertEqual(value(store, "flash.otel.sum:my.exponential.histogram"), "10", name)
      // Resource, scope and point attributes all filter.
      XCTAssertEqual(value(store, "flash.otel:my.gauge[service.name=my.service]"), "10", name)
      XCTAssertEqual(
        value(store, "flash.otel:my.gauge[my.scope.attribute=some scope attribute]"), "10")
      XCTAssertEqual(value(store, "flash.otel:my.gauge[my.gauge.attr=some value]"), "10", name)
      XCTAssertNil(value(store, "flash.otel:my.gauge[my.gauge.attr=other]"), name)
      XCTAssertNil(value(store, "flash.otel:no.such.metric"), name)
      XCTAssertNil(value(store, "flash.otel.total:my.gauge"), "a gauge has no total")
      XCTAssertNil(value(store, "flash.otel.p50:my.counter"), "a sum has no percentile")
    }
  }

  func testTheGoldenLogsLandInTheStore() throws {
    for (name, encoding) in [("logs.json", OTLPEncoding.json), ("logs.binpb", .protobuf)] {
      let store = store()
      XCTAssertEqual(try ingest(store, name, .logs, encoding).accepted, 1)
      let logs = try XCTUnwrap(store.snapshotJSON()["logs"] as? [[String: Any]])
      XCTAssertEqual(logs.count, 1)
      let log = logs[0]
      XCTAssertEqual(log["body"] as? String, "Example log record")
      XCTAssertEqual(log["severity"] as? String, "Information")
      XCTAssertEqual(log["severity_number"] as? Int, 10)
      XCTAssertEqual(log["service"] as? String, "my.service")
      XCTAssertEqual(log["scope"] as? String, "my.library")
      XCTAssertEqual(log["trace_id"] as? String, "5b8efff798038103d269b633813fc60c")
      XCTAssertEqual(log["span_id"] as? String, "eee19b7ec3c1b174")
      XCTAssertEqual(log["time_ms"] as? Double, 1_544_712_660_300)
      XCTAssertEqual(
        log["attributes"] as? [String: String],
        [
          "string.attribute": "some string", "boolean.attribute": "true", "int.attribute": "10",
          "double.attribute": "637.704", "array.attribute": "[many,values]",
          "map.attribute": "{some.map.key=some value}",
        ])
    }
  }

  func testTheGoldenSpansLandInTheStore() throws {
    for (name, encoding) in [("trace.json", OTLPEncoding.json), ("trace.binpb", .protobuf)] {
      let store = store()
      XCTAssertEqual(try ingest(store, name, .traces, encoding).accepted, 1)
      let spans = try XCTUnwrap(store.snapshotJSON()["spans"] as? [[String: Any]])
      let span = try XCTUnwrap(spans.first)
      XCTAssertEqual(span["trace_id"] as? String, "5b8efff798038103d269b633813fc60c")
      XCTAssertEqual(span["span_id"] as? String, "eee19b7ec3c1b174")
      XCTAssertEqual(span["parent_span_id"] as? String, "eee19b7ec3c1b173")
      XCTAssertEqual(span["name"] as? String, "I'm a server span")
      XCTAssertEqual(span["kind"] as? String, "server")
      XCTAssertEqual(span["duration_ms"] as? Double, 1000)
      XCTAssertEqual(span["service"] as? String, "my.service")
      XCTAssertEqual(span["attributes"] as? [String: String], ["my.span.attr": "some value"])
    }
  }

  func testJSONIgnoresUnknownFieldsAndAcceptsEnumNames() throws {
    let body = Data(
      """
      {"resourceMetrics":[{"futureField":1,"scopeMetrics":[{"metrics":[{"name":"m",
      "sum":{"aggregationTemporality":"AGGREGATION_TEMPORALITY_DELTA","isMonotonic":true,
      "dataPoints":[{"asInt":"7","timeUnixNano":"2000","startTimeUnixNano":"1000"}]}}]}]}]}
      """.utf8)
    let store = store()
    XCTAssertEqual(
      store.ingest(try OTLPCodec.decode(body, signal: .metrics, encoding: .json)).accepted, 1)
    XCTAssertEqual(value(store, "flash.otel.total:m"), "7")
  }

  func testMalformedBodiesAreRefused() {
    for body in ["", "[]", "{", "{\"resourceMetrics\":5}"] {
      XCTAssertThrowsError(
        try OTLPCodec.decode(Data(body.utf8), signal: .metrics, encoding: .json), body)
    }
    XCTAssertThrowsError(
      try OTLPCodec.decode(Data([0xFF, 0xFF, 0xFF]), signal: .metrics, encoding: .protobuf))
  }

  // MARK: Temporality

  private func sum(
    name: String = "m", value: Double, start: UInt64, time: UInt64,
    temporality: Opentelemetry_Proto_Metrics_V1_AggregationTemporality, monotonic: Bool = true,
    attributes: [String: String] = [:]
  ) -> OTLPExport {
    var point = Opentelemetry_Proto_Metrics_V1_NumberDataPoint()
    point.asDouble = value
    point.startTimeUnixNano = start
    point.timeUnixNano = time
    point.attributes = OTLPValues.keyValues(attributes)
    var sum = Opentelemetry_Proto_Metrics_V1_Sum()
    sum.aggregationTemporality = temporality
    sum.isMonotonic = monotonic
    sum.dataPoints = [point]
    var metric = Opentelemetry_Proto_Metrics_V1_Metric()
    metric.name = name
    metric.sum = sum
    return .metrics(Self.request([metric]))
  }

  static func request(_ metrics: [Opentelemetry_Proto_Metrics_V1_Metric]) -> OTLPMetricsRequest {
    var scope = Opentelemetry_Proto_Metrics_V1_ScopeMetrics()
    scope.metrics = metrics
    var resource = Opentelemetry_Proto_Metrics_V1_ResourceMetrics()
    resource.scopeMetrics = [scope]
    var request = OTLPMetricsRequest()
    request.resourceMetrics = [resource]
    return request
  }

  private static let second: UInt64 = 1_000_000_000

  func testACumulativeSumTotalsAcrossResetsAndRatesItsIncrements() {
    let clock = Clock()
    let store = store(clock)
    let s = Self.second
    _ = store.ingest(sum(value: 10, start: 1 * s, time: 10 * s, temporality: .cumulative))
    XCTAssertEqual(value(store, "flash.otel.total:m"), "10")
    XCTAssertNil(value(store, "flash.otel.rate:m"), "one point has no rate yet")
    clock.now += 10
    _ = store.ingest(sum(value: 40, start: 1 * s, time: 20 * s, temporality: .cumulative))
    XCTAssertEqual(value(store, "flash.otel:m"), "40")
    XCTAssertEqual(value(store, "flash.otel.rate:m"), "3", "30 over 10 s")
    // The sender restarted: a new start time, counting from zero again.
    _ = store.ingest(sum(value: 5, start: 25 * s, time: 30 * s, temporality: .cumulative))
    XCTAssertEqual(value(store, "flash.otel.total:m"), "45")
    XCTAssertEqual(value(store, "flash.otel.rate:m"), "1", "5 since its start 5 s earlier")
    // A monotonic value going down is a reset too, even without a start.
    _ = store.ingest(sum(value: 2, start: 0, time: 40 * s, temporality: .cumulative))
    XCTAssertEqual(value(store, "flash.otel.total:m"), "47")
    // A duplicate or late point changes nothing.
    _ = store.ingest(sum(value: 1000, start: 0, time: 40 * s, temporality: .cumulative))
    XCTAssertEqual(value(store, "flash.otel.total:m"), "47")
  }

  func testADeltaSumKeepsARunningTotalAndARate() {
    let clock = Clock()
    let store = store(clock)
    let s = Self.second
    _ = store.ingest(sum(value: 3, start: 0, time: 60 * s, temporality: .delta))
    XCTAssertEqual(value(store, "flash.otel.total:m"), "3")
    XCTAssertNil(value(store, "flash.otel.rate:m"), "no interval yet")
    _ = store.ingest(sum(value: 6, start: 60 * s, time: 120 * s, temporality: .delta))
    XCTAssertEqual(value(store, "flash.otel.total:m"), "9")
    XCTAssertEqual(value(store, "flash.otel:m"), "6", "latest is the last delta")
    XCTAssertEqual(value(store, "flash.otel.rate:m"), "0.1", "6 over its 60 s interval")
    // A retried export resends the same point: it is not counted twice.
    _ = store.ingest(sum(value: 6, start: 60 * s, time: 120 * s, temporality: .delta))
    XCTAssertEqual(value(store, "flash.otel.total:m"), "9")
  }

  func testARateDropsToZeroOnceTheSeriesGoesQuiet() {
    let clock = Clock()
    let store = store(clock)
    let s = Self.second
    _ = store.ingest(sum(value: 6, start: 0, time: 60 * s, temporality: .delta))
    _ = store.ingest(sum(value: 6, start: 60 * s, time: 120 * s, temporality: .delta))
    clock.now += 149
    XCTAssertEqual(value(store, "flash.otel.rate:m"), "0.1")
    clock.now += 1
    XCTAssertEqual(value(store, "flash.otel.rate:m"), "0", "2.5 intervals without a point")
    XCTAssertEqual(value(store, "flash.otel.total:m"), "12", "the total stays")
  }

  func testSeriesAddUpAcrossMatchingAttributes() {
    let store = store()
    let s = Self.second
    for (session, type, amount) in [("a", "input", 100.0), ("a", "output", 20), ("b", "input", 50)]
    {
      _ = store.ingest(
        sum(
          name: "claude_code.token.usage", value: amount, start: 0, time: 60 * s,
          temporality: .delta, attributes: ["session.id": session, "type": type]))
    }
    XCTAssertEqual(value(store, "flash.otel.total:claude_code.token.usage"), "170")
    XCTAssertEqual(value(store, "flash.otel.total:claude_code.token.usage[type=input]"), "150")
    XCTAssertEqual(
      value(store, "flash.otel.total:claude_code.token.usage[type=input][session.id=b]"), "50")
    XCTAssertEqual(value(store, "flash.otel.total:claude_code.token.usage[type!=input]"), "20")
  }

  func testAGaugeKeepsItsLatestValueAndItsHistory() {
    let store = store()
    for (index, reading) in [3.0, 9, 6].enumerated() {
      var point = Opentelemetry_Proto_Metrics_V1_NumberDataPoint()
      point.asDouble = reading
      point.timeUnixNano = UInt64(index + 1) * Self.second
      var metric = Opentelemetry_Proto_Metrics_V1_Metric()
      metric.name = "g"
      metric.gauge.dataPoints = [point]
      _ = store.ingest(.metrics(Self.request([metric])))
    }
    XCTAssertEqual(value(store, "flash.otel:g"), "6")
    XCTAssertEqual(value(store, "flash.otel.rate:g"), "-3")
    XCTAssertEqual(value(store, "flash.otel.min:g"), "3")
    XCTAssertEqual(value(store, "flash.otel.max:g"), "9")
    XCTAssertEqual(value(store, "flash.otel.mean:g"), "6")
    let metrics = store.snapshotJSON()["metrics"] as? [[String: Any]]
    let series = (metrics?.first?["series"] as? [[String: Any]])?.first
    XCTAssertEqual(series?["history"] as? [Double], [3, 9, 6])
  }

  private func histogram(
    count: UInt64, sum: Double, buckets: [UInt64], bounds: [Double], start: UInt64, time: UInt64,
    temporality: Opentelemetry_Proto_Metrics_V1_AggregationTemporality
  ) -> OTLPExport {
    var point = Opentelemetry_Proto_Metrics_V1_HistogramDataPoint()
    point.count = count
    point.sum = sum
    point.bucketCounts = buckets
    point.explicitBounds = bounds
    point.startTimeUnixNano = start
    point.timeUnixNano = time
    var metric = Opentelemetry_Proto_Metrics_V1_Metric()
    metric.name = "h"
    metric.histogram.aggregationTemporality = temporality
    metric.histogram.dataPoints = [point]
    return .metrics(Self.request([metric]))
  }

  func testACumulativeHistogramReadsItsLatestWindow() {
    let store = store()
    let s = Self.second
    _ = store.ingest(
      histogram(
        count: 10, sum: 100, buckets: [0, 10, 0], bounds: [5, 15], start: s, time: 10 * s,
        temporality: .cumulative))
    XCTAssertEqual(value(store, "flash.otel.p50:h"), "10", "the middle of (5, 15]")
    _ = store.ingest(
      histogram(
        count: 30, sum: 700, buckets: [0, 10, 20], bounds: [5, 15], start: s, time: 20 * s,
        temporality: .cumulative))
    XCTAssertEqual(value(store, "flash.otel.count:h"), "30")
    XCTAssertEqual(value(store, "flash.otel.sum:h"), "700")
    XCTAssertEqual(value(store, "flash.otel.mean:h"), "30", "600 over the window's 20")
    XCTAssertEqual(value(store, "flash.otel.rate:h"), "2", "20 observations in 10 s")
    // Every window observation is in (15, +inf), bounded by the lower edge
    // without a reported max.
    XCTAssertEqual(value(store, "flash.otel.p50:h"), "15")
  }

  func testADeltaHistogramMergesSeriesForPercentiles() {
    let store = store()
    let s = Self.second
    _ = store.ingest(
      histogram(
        count: 4, sum: 20, buckets: [0, 4, 0], bounds: [0, 10], start: 0, time: 10 * s,
        temporality: .delta))
    XCTAssertEqual(value(store, "flash.otel.p50:h"), "5")
    XCTAssertEqual(value(store, "flash.otel.p25:h"), "2.5")
    XCTAssertEqual(value(store, "flash.otel.count:h"), "4")
    _ = store.ingest(
      histogram(
        count: 2, sum: 6, buckets: [0, 2, 0], bounds: [0, 10], start: 10 * s, time: 20 * s,
        temporality: .delta))
    XCTAssertEqual(value(store, "flash.otel.count:h"), "6")
    XCTAssertEqual(value(store, "flash.otel.sum:h"), "26")
    XCTAssertEqual(value(store, "flash.otel.mean:h"), "3", "the latest window")
  }

  func testExponentialHistogramsBecomeBuckets() throws {
    let store = store()
    _ = try ingest(store, "metrics.json", .metrics, .json)
    // Scale 0 is base 2 and bucket i holds (2^i, 2^(i+1)]: offset 1 with
    // counts [0, 2] puts both positive observations in (4, 8], beside one
    // zero. The median interpolates halfway into (4, 8]; the reported max
    // of 5 caps the tail.
    XCTAssertEqual(value(store, "flash.otel.p50:my.exponential.histogram"), "5")
    XCTAssertEqual(value(store, "flash.otel.p25:my.exponential.histogram"), "0")
    XCTAssertEqual(value(store, "flash.otel.p99:my.exponential.histogram"), "5")
    let p40 = try XCTUnwrap(
      store.value(of: TelemetryQuery(field: .percentile(40), metric: "my.exponential.histogram")))
    XCTAssertEqual(p40, 4.4, accuracy: 1e-9, "a tenth of the way into (4, 8]")
  }

  func testInvalidPointsAreRejectedAsAPartialSuccess() {
    var good = Opentelemetry_Proto_Metrics_V1_NumberDataPoint()
    good.asDouble = 1
    good.timeUnixNano = 1
    var noValue = Opentelemetry_Proto_Metrics_V1_NumberDataPoint()
    noValue.timeUnixNano = 1
    var gauge = Opentelemetry_Proto_Metrics_V1_Metric()
    gauge.name = "g"
    gauge.gauge.dataPoints = [good, noValue]
    var mismatched = Opentelemetry_Proto_Metrics_V1_HistogramDataPoint()
    mismatched.bucketCounts = [1, 2, 3]
    mismatched.explicitBounds = [1]
    mismatched.timeUnixNano = 1
    var histogram = Opentelemetry_Proto_Metrics_V1_Metric()
    histogram.name = "h"
    histogram.histogram.dataPoints = [mismatched]
    var unnamed = Opentelemetry_Proto_Metrics_V1_Metric()
    unnamed.gauge.dataPoints = [good]
    var empty = Opentelemetry_Proto_Metrics_V1_Metric()
    empty.name = "empty"
    let result = store().ingest(.metrics(Self.request([gauge, histogram, unnamed, empty])))
    XCTAssertEqual(result.accepted, 1)
    XCTAssertEqual(result.rejected, 4)
    XCTAssertEqual(
      result.message,
      "1 data point rejected: a metric without a valid name; "
        + "1 data point rejected: a metric without data; "
        + "1 data point rejected: a number point without a value; "
        + "1 data point rejected: histogram bucket counts that do not match its bounds")
  }

  func testANoRecordedValuePointIsAcceptedButNotStored() {
    var point = Opentelemetry_Proto_Metrics_V1_NumberDataPoint()
    point.timeUnixNano = 1
    point.flags = 1
    point.asDouble = .nan
    var metric = Opentelemetry_Proto_Metrics_V1_Metric()
    metric.name = "g"
    metric.gauge.dataPoints = [point]
    let store = store()
    XCTAssertEqual(store.ingest(.metrics(Self.request([metric]))).accepted, 1)
    XCTAssertNil(value(store, "flash.otel:g"))
  }

  // MARK: Retention

  func testTheLeastRecentlyUpdatedSeriesIsEvictedFirst() {
    let store = store(limits: .init(maxSeries: 2, maxPoints: 3, maxLogs: 2, maxSpans: 2))
    let s = Self.second
    for (index, name) in ["a", "b", "c"].enumerated() {
      _ = store.ingest(
        sum(name: name, value: 1, start: 0, time: UInt64(index + 1) * s, temporality: .delta))
    }
    XCTAssertNil(value(store, "flash.otel:a"))
    XCTAssertEqual(value(store, "flash.otel:b"), "1")
    XCTAssertEqual(value(store, "flash.otel:c"), "1")
    XCTAssertEqual(store.counterSnapshot().counters.evictedSeries, 1)
    for time in 4...8 {
      _ = store.ingest(
        sum(name: "c", value: Double(time), start: 0, time: UInt64(time) * s, temporality: .delta))
    }
    let metrics = store.snapshotJSON()["metrics"] as? [[String: Any]]
    let c = metrics?.first { $0["name"] as? String == "c" }
    XCTAssertEqual((c?["series"] as? [[String: Any]])?.first?["history"] as? [Double], [6, 7, 8])
  }

  func testLogsAndSpansKeepTheMostRecent() throws {
    let store = store(limits: .init(maxSeries: 10, maxPoints: 10, maxLogs: 2, maxSpans: 1))
    for body in ["one", "two", "three"] {
      var record = Opentelemetry_Proto_Logs_V1_LogRecord()
      record.body.stringValue = body
      record.timeUnixNano = 1
      var scope = Opentelemetry_Proto_Logs_V1_ScopeLogs()
      scope.logRecords = [record]
      var resource = Opentelemetry_Proto_Logs_V1_ResourceLogs()
      resource.scopeLogs = [scope]
      var request = OTLPLogsRequest()
      request.resourceLogs = [resource]
      _ = store.ingest(.logs(request))
    }
    let logs = try XCTUnwrap(store.snapshotJSON()["logs"] as? [[String: Any]])
    XCTAssertEqual(logs.map { $0["body"] as? String }, ["two", "three"])
    _ = try ingest(store, "trace.json", .traces, .json)
    _ = try ingest(store, "trace.binpb", .traces, .protobuf)
    XCTAssertEqual(store.counterSnapshot().spans, 1)
    store.setLimits(.init(maxSeries: 10, maxPoints: 10, maxLogs: 1, maxSpans: 1))
    let trimmed = try XCTUnwrap(store.snapshotJSON()["logs"] as? [[String: Any]])
    XCTAssertEqual(trimmed.map { $0["body"] as? String }, ["three"])
  }

  func testSpansWithInvalidIdsAreRejected() {
    var span = Opentelemetry_Proto_Trace_V1_Span()
    span.traceID = Data(repeating: 1, count: 15)
    span.spanID = Data(repeating: 1, count: 8)
    var zero = Opentelemetry_Proto_Trace_V1_Span()
    zero.traceID = Data(repeating: 0, count: 16)
    zero.spanID = Data(repeating: 1, count: 8)
    var scope = Opentelemetry_Proto_Trace_V1_ScopeSpans()
    scope.spans = [span, zero]
    var resource = Opentelemetry_Proto_Trace_V1_ResourceSpans()
    resource.scopeSpans = [scope]
    var request = OTLPTraceRequest()
    request.resourceSpans = [resource]
    let result = store().ingest(.traces(request))
    XCTAssertEqual(result.rejected, 2)
    XCTAssertEqual(result.message, "2 spans rejected: a trace or span id of the wrong length")
  }

  func testRingsKeepOrderAcrossWraps() {
    var ring = TelemetryRing<Int>(capacity: 3)
    for value in 1...5 { ring.append(value) }
    XCTAssertEqual(ring.elements, [3, 4, 5])
    ring.resize(2)
    XCTAssertEqual(ring.elements, [4, 5])
    ring.append(6)
    XCTAssertEqual(ring.elements, [5, 6])
    ring.resize(4)
    ring.append(7)
    XCTAssertEqual(ring.elements, [5, 6, 7])
    var none = TelemetryRing<Int>(capacity: 0)
    none.append(1)
    XCTAssertEqual(none.elements, [])
  }

  // MARK: Observation

  func testOnlyAnObservedMetricWakesTheStatusSurfaces() {
    let store = store()
    var observed = 0
    var changed = 0
    store.setHandlers(changed: { changed += 1 }, observedChanged: { observed += 1 })
    _ = store.ingest(sum(name: "a", value: 1, start: 0, time: Self.second, temporality: .delta))
    XCTAssertEqual(changed, 1)
    XCTAssertEqual(observed, 0, "nothing reads a")
    store.observe(keys: ["flash.otel.rate:a[x=y]", "flash.otel:not a key", "flash.source.x"])
    _ = store.ingest(sum(name: "a", value: 1, start: 0, time: 2 * Self.second, temporality: .delta))
    XCTAssertEqual(observed, 1)
    _ = store.ingest(sum(name: "b", value: 1, start: 0, time: Self.second, temporality: .delta))
    XCTAssertEqual(observed, 1, "b is not read")
    XCTAssertEqual(changed, 3)
  }

  func testResetForgetsEverything() throws {
    let store = store()
    _ = try ingest(store, "metrics.json", .metrics, .json)
    store.reset()
    XCTAssertNil(value(store, "flash.otel:my.gauge"))
    XCTAssertEqual(store.counterSnapshot().series, 0)
  }
}
