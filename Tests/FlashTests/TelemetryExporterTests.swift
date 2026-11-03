import FlashOTLP
import Foundation
import XCTest

@testable import flash

/// Flash's own telemetry: what the recorder keeps, how it is batched, how
/// it encodes (round-tripped through the receiver's decoder), and when a
/// failed send is retried.
final class TelemetryExporterTests: XCTestCase {
  final class Clock {
    var uptime: TimeInterval = 500
    var wall = Date(timeIntervalSince1970: 1_800_000_000)
  }

  private func recorder(
    _ signals: Set<TelemetrySignal> = [.metrics, .logs, .traces], clock: Clock = Clock(),
    limits: TelemetryRecorder.Limits = .init()
  ) -> TelemetryRecorder {
    TelemetryRecorder(
      signals: signals, limits: limits, traceIDPrefix: 0xABCD,
      wallClock: { clock.wall }, uptime: { clock.uptime })
  }

  // MARK: Recording

  func testMetricsAggregateInPlace() throws {
    let recorder = recorder()
    recorder.record(.pluginRequestDuration, 3, attributes: ["plugin": "tmux", "method": "perform"])
    recorder.record(
      .pluginRequestDuration, 700, attributes: ["plugin": "tmux", "method": "perform"])
    recorder.record(.pluginRestarts, 1, attributes: ["plugin": "tmux"])
    recorder.record(.pluginRestarts, 1, attributes: ["plugin": "tmux"])
    recorder.record(.monitorValue, 40, attributes: ["monitor": "disk"])
    recorder.record(.monitorValue, 93, attributes: ["monitor": "disk"])
    recorder.record(.monitorValue, .nan, attributes: ["monitor": "disk"])
    let metrics = try XCTUnwrap(recorder.drain(maxItems: 10).metrics)
    let histogram = try XCTUnwrap(
      metrics.first { $0.instrument.name == FlashInstrument.pluginRequestDuration.rawValue })
    XCTAssertEqual(histogram.count, 2)
    XCTAssertEqual(histogram.sum, 703)
    XCTAssertEqual(histogram.min, 3)
    XCTAssertEqual(histogram.max, 700)
    // 3 ms in (2, 5], 700 ms in (500, 1000].
    XCTAssertEqual(histogram.buckets, [0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0])
    XCTAssertEqual(
      metrics.first { $0.instrument.name == FlashInstrument.pluginRestarts.rawValue }?.value, 2)
    XCTAssertEqual(
      metrics.first { $0.instrument.name == FlashInstrument.monitorValue.rawValue }?.value, 93)
    XCTAssertNil(recorder.drain(maxItems: 10).metrics, "nothing changed since")
  }

  func testNothingIsRecordedForASignalNotExported() {
    let recorder = recorder([.traces])
    recorder.record(.pluginRestarts, 1, attributes: [:])
    recorder.log(
      FlashLog.Record(
        level: .info, source: "core:x", message: "m", fields: [:], pid: 1, timeUnixMs: 1))
    let batch = recorder.drain(maxItems: 10)
    XCTAssertNil(batch.metrics)
    XCTAssertEqual(batch.logs, [])
  }

  func testPluginStderrIsNeverExported() {
    let recorder = recorder([.logs])
    recorder.log(
      FlashLog.Record(
        level: .warn, source: "plugin:x", message: "[plugin] stderr: token=secret", fields: [:],
        pid: 1, timeUnixMs: 1))
    recorder.log(
      FlashLog.Record(
        level: .warn, source: "plugin:x", message: "[plugin] stderr suppressed",
        fields: ["lines": "3"], pid: 1, timeUnixMs: 1))
    XCTAssertEqual(recorder.drain(maxItems: 10).logs, [])
  }

  func testFullQueuesDropAndCountWhatTheyDrop() throws {
    let recorder = recorder(limits: .init(maxSeries: 1, maxLogs: 2, maxSpans: 8))
    for index in 0..<5 {
      recorder.log(
        FlashLog.Record(
          level: .info, source: "core:x", message: "\(index)", fields: [:], pid: 1,
          timeUnixMs: 1))
    }
    recorder.record(.pluginErrors, 1, attributes: ["plugin": "a"])
    recorder.record(.pluginErrors, 1, attributes: ["plugin": "b"])
    let batch = recorder.drain(maxItems: 10)
    XCTAssertEqual(batch.logs.map(\.message), ["0", "1"])
    XCTAssertEqual(batch.dropped, [.logs: 3, .metrics: 1])
    // The drop counter is itself a series; with `maxSeries` full it is the
    // one stream that cannot be added, so it does not count itself.
    XCTAssertEqual(batch.metrics?.map(\.instrument.name), [FlashInstrument.pluginErrors.rawValue])
  }

  func testInteractionsBecomeSpansOnceSettled() throws {
    let clock = Clock()
    let recorder = recorder(clock: clock)
    let trace: UInt64 = 0x1234
    recorder.span(
      "plugin perform", trace: trace, startUptime: 499.9, endUptime: 500,
      attributes: ["plugin": "tmux"], failed: false, origin: nil)
    recorder.span(
      "hints visible", trace: trace, startUptime: 499.8, endUptime: 500.05,
      attributes: [:], failed: false, origin: .key)
    var batch = recorder.drain(maxItems: 10)
    XCTAssertEqual(batch.spans.map(\.name), ["plugin perform", "hints visible"])
    XCTAssertTrue(batch.spans.allSatisfy { $0.parentID == trace })
    XCTAssertTrue(batch.remaining, "the interaction is still settling")
    clock.uptime += TelemetryRecorder.settleSeconds
    batch = recorder.drain(maxItems: 10)
    let root = try XCTUnwrap(batch.spans.first)
    XCTAssertEqual(root.name, "flash.interaction")
    XCTAssertNil(root.parentID)
    XCTAssertEqual(root.spanID, trace)
    XCTAssertEqual(
      root.attributes, ["flash.trace": String(trace, radix: 36), "flash.origin": "key"])
    // It spans its children: from 499.8 to 500.05 uptime, in wall time.
    let wall = Double(TelemetryRecorder.nanoseconds(clock.wall))
    XCTAssertEqual(Double(root.startNs), wall - 200_000_000, accuracy: 10_000)
    XCTAssertEqual(Double(root.endNs), wall + 50_000_000, accuracy: 10_000)
    XCTAssertFalse(batch.remaining)
  }

  func testALogLineTiesItsInteractionToATrace() {
    let clock = Clock()
    let recorder = recorder(clock: clock)
    recorder.log(
      FlashLog.Record(
        level: .info, source: "core:x", message: "m", fields: [:], pid: 1,
        timeUnixMs: 1_800_000_000_000, trace: "abc"))
    clock.uptime += 2
    let batch = recorder.drain(maxItems: 10)
    XCTAssertEqual(batch.logs.first?.trace, UInt64("abc", radix: 36))
    XCTAssertEqual(batch.spans.map(\.name), ["flash.interaction"])
  }

  func testDrainSkipsASignalStillRetrying() {
    let recorder = recorder()
    recorder.log(
      FlashLog.Record(
        level: .info, source: "core:x", message: "kept", fields: [:], pid: 1, timeUnixMs: 1))
    var batch = recorder.drain(maxItems: 10, skip: [.logs])
    XCTAssertEqual(batch.logs, [])
    batch = recorder.drain(maxItems: 10)
    XCTAssertEqual(batch.logs.map(\.message), ["kept"])
  }

  func testTheFacadeRecordsNothingWithoutARecorder() {
    FlashTelemetry.install(nil)
    FlashTelemetry.record(.pluginErrors, 1, ["plugin": "x"])
    FlashTelemetry.span("x", trace: "abc", startUptime: 0, endUptime: 1)
    let recorder = recorder()
    FlashTelemetry.install(recorder)
    defer { FlashTelemetry.install(nil) }
    FlashTelemetry.record(.pluginErrors, 1, ["plugin": "x"])
    FlashTelemetry.span("plugin perform", trace: "abc", startUptime: 0, endUptime: 1)
    FlashTelemetry.span("untraced", trace: nil, startUptime: 0, endUptime: 1)
    let batch = recorder.drain(maxItems: 10)
    XCTAssertEqual(batch.metrics?.count, 1)
    XCTAssertEqual(batch.spans.map(\.name), ["plugin perform"])
  }

  // MARK: Encoding

  private let resource = ["service.name": "flash", "service.version": "1.2.0"]

  func testMetricsRoundTripThroughTheReceiversDecoder() throws {
    let recorder = recorder()
    recorder.record(.hintsLatency, 42, attributes: ["origin": "key", "surface": "targets"])
    recorder.record(.pluginRestarts, 2, attributes: ["plugin": "tmux"])
    recorder.record(.monitorLevel, 1, attributes: ["monitor": "disk"])
    let states = try XCTUnwrap(recorder.drain(maxItems: 10).metrics)
    let request = TelemetryExportBuilder.metrics(
      states, resource: resource, version: "1.2.0", startNs: recorder.startNs)
    for encoding in OTLPEncoding.allCases {
      let body = try OTLPCodec.encode(request, as: encoding)
      let store = TelemetryStore(scheduler: PollScheduler())
      let result = store.ingest(try OTLPCodec.decode(body, signal: .metrics, encoding: encoding))
      XCTAssertEqual(result.rejected, 0, encoding.rawValue)
      let values = store.values(for: [
        "flash.otel.count:flash.hints.latency[origin=key]",
        "flash.otel.sum:flash.hints.latency",
        "flash.otel.p50:flash.hints.latency",
        "flash.otel.total:flash.plugin.restarts[plugin=tmux][service.name=flash]",
        "flash.otel:flash.monitor.level[monitor=disk]",
      ])
      XCTAssertEqual(
        values,
        [
          "flash.otel.count:flash.hints.latency[origin=key]": "1",
          "flash.otel.sum:flash.hints.latency": "42",
          "flash.otel.p50:flash.hints.latency": "42",
          "flash.otel.total:flash.plugin.restarts[plugin=tmux][service.name=flash]": "2",
          "flash.otel:flash.monitor.level[monitor=disk]": "1",
        ], encoding.rawValue)
    }
  }

  func testLogsAndSpansRoundTripWithHexIds() throws {
    let clock = Clock()
    let recorder = recorder(clock: clock)
    recorder.log(
      FlashLog.Record(
        level: .warn, source: "core:Plugin.x", message: "[plugin] slow request",
        fields: ["method": "perform"], pid: 1, timeUnixMs: 1_800_000_000_123, trace: "z"))
    recorder.span(
      "plugin perform", trace: 35, startUptime: 499, endUptime: 500, attributes: [:],
      failed: true, origin: nil)
    clock.uptime += 5
    let batch = recorder.drain(maxItems: 10)
    let logs = TelemetryExportBuilder.logs(
      batch.logs, resource: resource, version: "1.2.0", recorder: recorder)
    let traces = TelemetryExportBuilder.traces(
      batch.spans, resource: resource, version: "1.2.0", recorder: recorder)

    let json = try OTLPCodec.encode(traces, as: .json)
    let text = String(decoding: json, as: UTF8.self)
    // OTLP/JSON writes ids as lowercase hex and enums as integers.
    XCTAssertTrue(text.contains(#""traceId":"000000000000abcd0000000000000023""#), text)
    XCTAssertTrue(text.contains(#""parentSpanId":"0000000000000023""#), text)
    XCTAssertTrue(text.contains(#""kind":3"#), text)
    XCTAssertTrue(text.contains(#""code":2"#), text)

    for encoding in OTLPEncoding.allCases {
      let store = TelemetryStore(scheduler: PollScheduler())
      _ = store.ingest(
        try OTLPCodec.decode(
          try OTLPCodec.encode(logs, as: encoding), signal: .logs, encoding: encoding))
      _ = store.ingest(
        try OTLPCodec.decode(
          try OTLPCodec.encode(traces, as: encoding), signal: .traces, encoding: encoding))
      let snapshot = store.snapshotJSON()
      let log = try XCTUnwrap((snapshot["logs"] as? [[String: Any]])?.first)
      XCTAssertEqual(log["body"] as? String, "[plugin] slow request")
      XCTAssertEqual(log["severity"] as? String, "WARN")
      XCTAssertEqual(log["severity_number"] as? Int, 13)
      XCTAssertEqual(log["service"] as? String, "flash")
      XCTAssertEqual(
        log["attributes"] as? [String: String],
        ["method": "perform", "flash.source": "core:Plugin.x"])
      XCTAssertEqual(log["trace_id"] as? String, "000000000000abcd0000000000000023")
      XCTAssertEqual(log["time_ms"] as? Double, 1_800_000_000_123)
      let spans = try XCTUnwrap(snapshot["spans"] as? [[String: Any]])
      let child = try XCTUnwrap(spans.first { $0["name"] as? String == "plugin perform" })
      XCTAssertEqual(child["status"] as? String, "error")
      XCTAssertEqual(child["kind"] as? String, "client")
      XCTAssertEqual(child["parent_span_id"] as? String, "0000000000000023")
      XCTAssertEqual(child["duration_ms"] as? Double, 1000)
      let root = try XCTUnwrap(spans.first { $0["name"] as? String == "flash.interaction" })
      XCTAssertEqual(root["span_id"] as? String, "0000000000000023")
      XCTAssertEqual(root["parent_span_id"] as? String, "")
    }
  }

  func testIdsConvertBetweenHexAndBase64() {
    XCTAssertEqual(
      OTLPCodec.hexToBase64("5B8EFFF798038103D269B633813FC60C"), "W47/95gDgQPSabYzgT/GDA==")
    XCTAssertEqual(
      OTLPCodec.base64ToHex("W47/95gDgQPSabYzgT/GDA=="), "5b8efff798038103d269b633813fc60c")
    XCTAssertNil(OTLPCodec.hexToBase64("abc"))
    XCTAssertNil(OTLPCodec.hexToBase64("zz"))
    XCTAssertEqual(OTLPCodec.hexToBase64(""), "")
  }

  func testGzipRoundTrips() throws {
    let body = Data((0..<10_000).map { UInt8($0 % 251) })
    let compressed = OTLPCodec.gzip(body)
    XCTAssertEqual(Array(compressed.prefix(2)), [0x1F, 0x8B])
    XCTAssertEqual(try OTLPCodec.gunzip(compressed, limit: body.count), body)
    XCTAssertThrowsError(try OTLPCodec.gunzip(compressed, limit: body.count - 1)) { error in
      XCTAssertEqual(error as? OTLPCodecError, .tooLarge)
    }
    XCTAssertThrowsError(
      try OTLPCodec.gunzip(compressed.prefix(compressed.count - 4), limit: 1 << 20))
    // Two members concatenated read as one body.
    XCTAssertEqual(try OTLPCodec.gunzip(compressed + compressed, limit: 1 << 20), body + body)
  }

  func testSignalsPostUnderTheBaseEndpoint() throws {
    let base = try XCTUnwrap(URL(string: "https://collector.example:4318/otlp/"))
    XCTAssertEqual(
      TelemetryExportBuilder.url(base, signal: .metrics).absoluteString,
      "https://collector.example:4318/otlp/v1/metrics")
    XCTAssertEqual(
      TelemetryExportBuilder.url(
        try XCTUnwrap(URL(string: "http://127.0.0.1:4318")), signal: .traces
      )
      .absoluteString,
      "http://127.0.0.1:4318/v1/traces")
  }

  func testPartialSuccessResponsesAreRead() throws {
    for encoding in OTLPEncoding.allCases {
      let body = OTLPCodec.successBody(
        signal: .logs, rejected: 3, message: "no", encoding: encoding)
      XCTAssertEqual(
        TelemetryExportBuilder.rejected(in: body, signal: .logs, encoding: encoding), 3)
      XCTAssertEqual(
        TelemetryExportBuilder.rejected(in: Data(), signal: .logs, encoding: encoding), 0)
    }
  }

  // MARK: Retry

  func testOTLPsRetryableStatusesRetryAndOthersDrop() {
    let policy = TelemetryExportPolicy.self
    XCTAssertEqual(policy.outcome(status: 200, transportError: nil, retryAfter: nil), .success)
    XCTAssertEqual(policy.outcome(status: 204, transportError: nil, retryAfter: nil), .success)
    for status in [429, 502, 503, 504] {
      XCTAssertEqual(
        policy.outcome(status: status, transportError: nil, retryAfter: "7"),
        .retry(afterMs: 7000, reason: "HTTP \(status)"))
    }
    for status in [400, 401, 403, 404, 413, 500] {
      XCTAssertEqual(
        policy.outcome(status: status, transportError: nil, retryAfter: nil),
        .drop(reason: "HTTP \(status)"))
    }
    if case .retry = policy.outcome(
      status: nil, transportError: URLError(.cannotConnectToHost), retryAfter: nil)
    {
    } else {
      XCTFail("a refused connection retries")
    }
    XCTAssertEqual(
      policy.outcome(status: nil, transportError: URLError(.cancelled), retryAfter: nil),
      .drop(reason: "cancelled"))
    XCTAssertNil(policy.retryAfterMs("Wed, 21 Oct 2015 07:28:00 GMT"))
    XCTAssertNil(policy.retryAfterMs("-1"))
  }

  func testBackoffDoublesUpToFiveMinutesAndHonoursRetryAfter() {
    let backoff = TelemetryExportPolicy.backoffMs
    XCTAssertEqual((1...6).map { backoff($0, nil) }, [1000, 2000, 4000, 8000, 16000, 32000])
    XCTAssertEqual(backoff(30, nil), 300_000)
    XCTAssertEqual(backoff(1, 9000), 9000, "a longer Retry-After wins")
    XCTAssertEqual(backoff(4, 1000), 8000, "a shorter one does not")
    XCTAssertEqual(backoff(1, 10_000_000), 300_000)
    XCTAssertEqual(TelemetryExportPolicy.maxAttempts, 6)
  }

  /// End to end: the exporter posts to a live receiver standing in for a
  /// collector, through the shared clock, and the receiver refuses it as
  /// Flash's own telemetry — the loop guard.
  func testTheExporterSendsAndFlashsReceiverRefusesItsOwnExport() throws {
    let store = TelemetryStore(scheduler: PollScheduler())
    let receiver = OTLPReceiver(port: 0, store: store)
    let listening = expectation(description: "listening")
    var port: UInt16?
    receiver.start()
    receiver.whenListening {
      port = $0
      listening.fulfill()
    }
    wait(for: [listening], timeout: 10)
    defer { receiver.stop() }
    let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(port))"))
    let recorder = TelemetryRecorder(signals: [.metrics])
    let exporter = TelemetryExporter(
      settings: .init(endpoint: endpoint, signals: [.metrics], intervalSeconds: 1),
      recorder: recorder)
    let failed = expectation(description: "refused")
    failed.assertForOverFulfill = false
    exporter.onStatusChange = { [weak exporter] in
      if exporter?.currentStatus.dropped[.metrics] != nil { failed.fulfill() }
    }
    exporter.start()
    defer { exporter.stop() }
    recorder.record(.pluginRestarts, 1, attributes: ["plugin": "x"])
    wait(for: [failed], timeout: 10)
    XCTAssertEqual(exporter.currentStatus.lastError, "HTTP 403")
    XCTAssertEqual(store.counterSnapshot().series, 0)
  }
}
