import FlashCore
import FlashOTLP
import Foundation
import SwiftProtobuf

/// The OTLP/HTTP exporter (`[telemetry.exporter]`): Flash's own metrics, log
/// records and spans, sent to the endpoint the user configured. Nothing is
/// sent while nothing changed. The first record after a send arms one flush
/// `interval` later on the shared clock (`.low`: background upkeep); a failed
/// send is retried with exponential backoff, also on the clock, while new
/// data keeps queuing up to its bound. Encoding and the request run on the
/// exporter's queue and URLSession's, never on main.
final class TelemetryExporter {
  struct Settings: Equatable {
    var endpoint: URL
    var encoding: OTLPEncoding = .protobuf
    var gzip = false
    /// Explicit values from the configuration; never logged or shown.
    var headers: [String: String] = [:]
    var serviceName = "flash"
    var signals: Set<TelemetrySignal> = [.metrics, .traces]
    var intervalSeconds: TimeInterval = 30
    var version = "development"
  }

  /// What the help page shows about the exporter. Never the headers.
  struct Status: Equatable {
    var sent: [TelemetrySignal: Int] = [:]
    var dropped: [TelemetrySignal: Int] = [:]
    var failures = 0
    var lastError: String?
    var lastSuccessMs: Int64?
    var retrying: Set<TelemetrySignal> = []
  }

  /// Items one request carries at most.
  static let batchSize = 512
  static let requestTimeoutSeconds: TimeInterval = 10

  let settings: Settings
  let recorder: TelemetryRecorder
  private let queue = DispatchQueue(label: "flash.telemetry.export", qos: .utility)
  private let session: URLSession
  private let instanceID = UUID().uuidString.lowercased()
  private lazy var flushDeadline = PollDeadline(
    "core:telemetry_export", priority: .low, on: queue)
  private var retryDeadlines: [TelemetrySignal: PollDeadline] = [:]
  /// Queue-confined: per signal, the request in flight or the body awaiting
  /// a retry, and its attempt count.
  private var inFlight: Set<TelemetrySignal> = []
  private var retrying: [TelemetrySignal: (body: Data, items: Int, attempt: Int)] = [:]
  private var stopped = false
  private var failing = false
  private let lock = NSLock()
  private var status = Status()
  /// Called on the exporter's queue whenever `status` changes.
  var onStatusChange: (() -> Void)?

  init(settings: Settings, recorder: TelemetryRecorder) {
    self.settings = settings
    self.recorder = recorder
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
    configuration.timeoutIntervalForResource = Self.requestTimeoutSeconds * 2
    configuration.waitsForConnectivity = false
    session = URLSession(
      configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }

  var currentStatus: Status {
    lock.lock()
    defer { lock.unlock() }
    return status
  }

  private func updateStatus(_ change: (inout Status) -> Void) {
    lock.lock()
    change(&status)
    lock.unlock()
    onStatusChange?()
  }

  func start() {
    recorder.setActivityHandler { [weak self] in
      self?.queue.async { self?.armFlush() }
    }
  }

  /// Stop sending. Whatever was queued is dropped with the recorder.
  func stop() {
    recorder.setActivityHandler(nil)
    queue.async { [self] in
      stopped = true
      flushDeadline.cancel()
      for deadline in retryDeadlines.values { deadline.cancel() }
      session.invalidateAndCancel()
    }
  }

  private func armFlush(afterSeconds: TimeInterval? = nil) {
    guard !stopped, !flushDeadline.isArmed else { return }
    flushDeadline.arm(after: afterSeconds ?? settings.intervalSeconds) { [weak self] in
      self?.flush()
    }
  }

  /// Send what the recorder holds: one request per signal with something
  /// new, skipping a signal whose previous request is in flight or retrying.
  func flush() {
    guard !stopped else { return }
    let busy = inFlight.union(retrying.keys)
    let batch = recorder.drain(maxItems: Self.batchSize, skip: busy)
    let resource = resourceAttributes
    if let metrics = batch.metrics, settings.signals.contains(.metrics) {
      let request = TelemetryExportBuilder.metrics(
        metrics, resource: resource, version: settings.version, startNs: recorder.startNs)
      send(request, signal: .metrics, items: metrics.count)
    }
    if !batch.logs.isEmpty, settings.signals.contains(.logs) {
      let request = TelemetryExportBuilder.logs(
        batch.logs, resource: resource, version: settings.version, recorder: recorder)
      send(request, signal: .logs, items: batch.logs.count)
    }
    if !batch.spans.isEmpty, settings.signals.contains(.traces) {
      let request = TelemetryExportBuilder.traces(
        batch.spans, resource: resource, version: settings.version, recorder: recorder)
      send(request, signal: .traces, items: batch.spans.count)
    }
    // More than one batch queued, or interactions still settling: come
    // back soon rather than a whole interval later.
    if batch.remaining { armFlush(afterSeconds: TelemetryRecorder.settleSeconds) }
  }

  private var resourceAttributes: [String: String] {
    [
      "service.name": settings.serviceName,
      "service.version": settings.version,
      "service.instance.id": instanceID,
      "process.pid": String(ProcessInfo.processInfo.processIdentifier),
      "os.type": "darwin",
      "telemetry.sdk.name": "flash",
      "telemetry.sdk.language": "swift",
    ]
  }

  private func send(_ message: some SwiftProtobuf.Message, signal: TelemetrySignal, items: Int) {
    let body: Data
    do {
      let encoded = try OTLPCodec.encode(message, as: settings.encoding)
      body = settings.gzip ? OTLPCodec.gzip(encoded) : encoded
    } catch {
      FlashLog.warn("[telemetry] could not encode \(signal.rawValue): \(error)")
      recorder.noteDropped(signal, count: items, reason: "encoding")
      return
    }
    post(body, signal: signal, items: items, attempt: 0)
  }

  private func post(_ body: Data, signal: TelemetrySignal, items: Int, attempt: Int) {
    guard !stopped else { return }
    inFlight.insert(signal)
    var request = URLRequest(url: TelemetryExportBuilder.url(settings.endpoint, signal: signal))
    request.httpMethod = "POST"
    request.httpBody = body
    for (name, value) in settings.headers { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue(settings.encoding.contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(
      OTLPReceiver.exporterUserAgentPrefix + settings.version, forHTTPHeaderField: "User-Agent")
    if settings.gzip { request.setValue("gzip", forHTTPHeaderField: "Content-Encoding") }
    session.dataTask(with: request) { [weak self] data, response, error in
      let http = response as? HTTPURLResponse
      let outcome = TelemetryExportPolicy.outcome(
        status: http?.statusCode, transportError: error,
        retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
      self?.queue.async {
        self?.complete(
          outcome, signal: signal, body: body, items: items, attempt: attempt,
          response: data ?? Data())
      }
    }.resume()
  }

  private func complete(
    _ outcome: TelemetryExportPolicy.Outcome, signal: TelemetrySignal, body: Data, items: Int,
    attempt: Int, response: Data
  ) {
    inFlight.remove(signal)
    retrying.removeValue(forKey: signal)
    guard !stopped else { return }
    switch outcome {
    case .success:
      let rejected = TelemetryExportBuilder.rejected(
        in: response, signal: signal, encoding: settings.encoding)
      if rejected > 0 {
        FlashLog.debug(
          "[telemetry] export partially rejected signal=\(signal.rawValue) items=\(rejected)")
        recorder.noteDropped(signal, count: rejected, reason: "rejected")
      }
      if failing {
        failing = false
        FlashLog.info("[telemetry] export recovered")
      }
      updateStatus {
        $0.sent[signal, default: 0] += items - rejected
        if rejected > 0 { $0.dropped[signal, default: 0] += rejected }
        $0.lastSuccessMs = Int64(Date().timeIntervalSince1970 * 1000)
        $0.retrying.remove(signal)
      }
      // What queued meanwhile goes out on the next flush.
      armFlush()
    case .retry(let afterMs, let reason):
      let next = attempt + 1
      guard next <= TelemetryExportPolicy.maxAttempts else {
        return give(up: signal, items: items, reason: reason)
      }
      noteFailure(reason)
      retrying[signal] = (body, items, next)
      updateStatus { $0.retrying.insert(signal) }
      let deadline =
        retryDeadlines[signal]
        ?? PollDeadline("core:telemetry_retry:\(signal.rawValue)", priority: .low, on: queue)
      retryDeadlines[signal] = deadline
      deadline.arm(afterMs: TelemetryExportPolicy.backoffMs(attempt: next, retryAfterMs: afterMs)) {
        [weak self] in
        guard let self, let pending = self.retrying.removeValue(forKey: signal) else { return }
        self.post(pending.body, signal: signal, items: pending.items, attempt: pending.attempt)
      }
    case .drop(let reason):
      give(up: signal, items: items, reason: reason)
    }
  }

  private func give(up signal: TelemetrySignal, items: Int, reason: String) {
    noteFailure(reason)
    recorder.noteDropped(signal, count: items, reason: "export_failed")
    updateStatus {
      $0.dropped[signal, default: 0] += items
      $0.retrying.remove(signal)
    }
    armFlush()
  }

  /// One warning per streak of failures; the rest at debug, so an endpoint
  /// that is down does not fill the log (or, with logs exported, its own
  /// queue).
  private func noteFailure(_ reason: String) {
    if !failing {
      failing = true
      FlashLog.warn("[telemetry] export failing: \(reason)")
    } else {
      FlashLog.debug("[telemetry] export failed: \(reason)")
    }
    updateStatus {
      $0.failures += 1
      $0.lastError = reason
    }
  }

  /// Redirects are refused: the configured headers must reach only the
  /// endpoint they were written for.
  private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }
}

/// What to do after a send, as OTLP/HTTP's retry rules say.
enum TelemetryExportPolicy {
  enum Outcome: Equatable {
    case success
    /// Retry; `afterMs` is the server's `Retry-After`, when it sent one.
    case retry(afterMs: Int?, reason: String)
    case drop(reason: String)
  }

  /// Attempts before a batch is dropped.
  static let maxAttempts = 6
  static let maxBackoffMs = 5 * 60 * 1000

  /// 2xx succeeds; 429, 502, 503, 504 and transport errors (refused, timed
  /// out, offline) retry; every other status drops the batch, since sending
  /// it again would fail the same way.
  static func outcome(status: Int?, transportError: Error?, retryAfter: String?) -> Outcome {
    if let transportError {
      if (transportError as? URLError)?.code == .cancelled { return .drop(reason: "cancelled") }
      return .retry(afterMs: nil, reason: transportError.localizedDescription)
    }
    guard let status else { return .retry(afterMs: nil, reason: "no response") }
    switch status {
    case 200...299:
      return .success
    case 429, 502, 503, 504:
      return .retry(afterMs: retryAfterMs(retryAfter), reason: "HTTP \(status)")
    default:
      return .drop(reason: "HTTP \(status)")
    }
  }

  /// `Retry-After` in seconds; an HTTP date is ignored.
  static func retryAfterMs(_ header: String?) -> Int? {
    guard let header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)),
      seconds >= 0
    else { return nil }
    return min(maxBackoffMs, seconds * 1000)
  }

  /// 1 s, 2 s, 4 s … for attempt 1, 2, 3 …, at most five minutes; a longer
  /// `Retry-After` wins.
  static func backoffMs(attempt: Int, retryAfterMs: Int?) -> Int {
    let exponential = min(maxBackoffMs, 1000 << min(20, max(0, attempt - 1)))
    return min(maxBackoffMs, max(exponential, retryAfterMs ?? 0))
  }
}

/// Flash's recorded telemetry as OTLP export requests. Pure.
enum TelemetryExportBuilder {
  static let scopeName = "flash"

  /// The signal's URL under the configured base: OTLP's
  /// `OTEL_EXPORTER_OTLP_ENDPOINT` rule, `<base>/v1/<signal>`.
  static func url(_ base: URL, signal: TelemetrySignal) -> URL {
    var text = base.absoluteString
    while text.hasSuffix("/") { text.removeLast() }
    return URLParsing.url(text + signal.path) ?? base
  }

  private static func resource(_ attributes: [String: String])
    -> Opentelemetry_Proto_Resource_V1_Resource
  {
    var resource = Opentelemetry_Proto_Resource_V1_Resource()
    resource.attributes = OTLPValues.keyValues(attributes)
    return resource
  }

  private static func scope(version: String) -> Opentelemetry_Proto_Common_V1_InstrumentationScope {
    var scope = Opentelemetry_Proto_Common_V1_InstrumentationScope()
    scope.name = scopeName
    scope.version = version
    return scope
  }

  static func metrics(
    _ states: [TelemetryRecorder.MetricState], resource attributes: [String: String],
    version: String, startNs: UInt64
  ) -> OTLPMetricsRequest {
    var scopeMetrics = Opentelemetry_Proto_Metrics_V1_ScopeMetrics()
    scopeMetrics.scope = scope(version: version)
    // One metric per instrument, Flash's own and recorded ones alike, in name
    // order so batches are stable.
    var byName: [String: [TelemetryRecorder.MetricState]] = [:]
    for state in states { byName[state.instrument.name, default: []].append(state) }
    for name in byName.keys.sorted() {
      guard let streams = byName[name], let instrument = streams.first?.instrument else { continue }
      var metric = Opentelemetry_Proto_Metrics_V1_Metric()
      metric.name = instrument.name
      metric.unit = instrument.unit
      metric.description_p = instrument.summary
      switch instrument.kind {
      case .counter:
        var sum = Opentelemetry_Proto_Metrics_V1_Sum()
        sum.aggregationTemporality = .cumulative
        sum.isMonotonic = true
        sum.dataPoints = streams.map { number($0, startNs: startNs) }
        metric.sum = sum
      case .gauge:
        var gauge = Opentelemetry_Proto_Metrics_V1_Gauge()
        gauge.dataPoints = streams.map { number($0, startNs: 0) }
        metric.gauge = gauge
      case .histogram:
        var histogram = Opentelemetry_Proto_Metrics_V1_Histogram()
        histogram.aggregationTemporality = .cumulative
        histogram.dataPoints = streams.map { state in
          var point = Opentelemetry_Proto_Metrics_V1_HistogramDataPoint()
          point.attributes = OTLPValues.keyValues(state.attributes)
          point.startTimeUnixNano = startNs
          point.timeUnixNano = state.timeNs
          point.count = state.count
          point.sum = state.sum
          if state.count > 0 {
            point.min = state.min
            point.max = state.max
          }
          point.explicitBounds = state.instrument.bounds
          point.bucketCounts = state.buckets
          return point
        }
        metric.histogram = histogram
      }
      scopeMetrics.metrics.append(metric)
    }
    var resourceMetrics = Opentelemetry_Proto_Metrics_V1_ResourceMetrics()
    resourceMetrics.resource = resource(attributes)
    resourceMetrics.scopeMetrics = [scopeMetrics]
    var request = OTLPMetricsRequest()
    request.resourceMetrics = [resourceMetrics]
    return request
  }

  private static func number(_ state: TelemetryRecorder.MetricState, startNs: UInt64)
    -> Opentelemetry_Proto_Metrics_V1_NumberDataPoint
  {
    var point = Opentelemetry_Proto_Metrics_V1_NumberDataPoint()
    point.attributes = OTLPValues.keyValues(state.attributes)
    point.startTimeUnixNano = startNs
    point.timeUnixNano = state.timeNs
    point.asDouble = state.value
    return point
  }

  static func severity(_ level: FlashLog.Level) -> Opentelemetry_Proto_Logs_V1_SeverityNumber {
    switch level {
    case .trace: return .trace
    case .debug: return .debug
    case .info: return .info
    case .warn: return .warn
    case .error: return .error
    case .fatal: return .fatal
    }
  }

  static func logs(
    _ items: [TelemetryRecorder.LogItem], resource attributes: [String: String], version: String,
    recorder: TelemetryRecorder
  ) -> OTLPLogsRequest {
    var scopeLogs = Opentelemetry_Proto_Logs_V1_ScopeLogs()
    scopeLogs.scope = scope(version: version)
    scopeLogs.logRecords = items.map { item in
      var record = Opentelemetry_Proto_Logs_V1_LogRecord()
      record.timeUnixNano = item.timeNs
      record.observedTimeUnixNano = item.timeNs
      record.severityNumber = severity(item.level)
      record.severityText = item.level.name.uppercased()
      record.body.stringValue = item.message
      var fields = item.fields
      fields["flash.source"] = item.source
      record.attributes = OTLPValues.keyValues(fields)
      if let trace = item.trace {
        record.traceID = recorder.traceID(trace)
        record.spanID = TelemetryRecorder.bigEndian(trace)
      }
      return record
    }
    var resourceLogs = Opentelemetry_Proto_Logs_V1_ResourceLogs()
    resourceLogs.resource = resource(attributes)
    resourceLogs.scopeLogs = [scopeLogs]
    var request = OTLPLogsRequest()
    request.resourceLogs = [resourceLogs]
    return request
  }

  static func traces(
    _ items: [TelemetryRecorder.SpanItem], resource attributes: [String: String],
    version: String, recorder: TelemetryRecorder
  ) -> OTLPTraceRequest {
    var scopeSpans = Opentelemetry_Proto_Trace_V1_ScopeSpans()
    scopeSpans.scope = scope(version: version)
    scopeSpans.spans = items.map { item in
      var span = Opentelemetry_Proto_Trace_V1_Span()
      span.traceID = recorder.traceID(item.trace)
      span.spanID = TelemetryRecorder.bigEndian(item.spanID)
      if let parent = item.parentID { span.parentSpanID = TelemetryRecorder.bigEndian(parent) }
      span.name = item.name
      span.kind =
        item.parentID == nil ? .internal : (item.name.hasPrefix("plugin ") ? .client : .internal)
      span.startTimeUnixNano = item.startNs
      span.endTimeUnixNano = item.endNs
      span.attributes = OTLPValues.keyValues(item.attributes)
      if item.failed { span.status.code = .error }
      return span
    }
    var resourceSpans = Opentelemetry_Proto_Trace_V1_ResourceSpans()
    resourceSpans.resource = resource(attributes)
    resourceSpans.scopeSpans = [scopeSpans]
    var request = OTLPTraceRequest()
    request.resourceSpans = [resourceSpans]
    return request
  }

  /// The items a successful response's partial success rejected.
  static func rejected(in body: Data, signal: TelemetrySignal, encoding: OTLPEncoding) -> Int {
    guard !body.isEmpty else { return 0 }
    var options = JSONDecodingOptions()
    options.ignoreUnknownFields = true
    switch (signal, encoding) {
    case (.metrics, .protobuf):
      return Int(
        (try? OTLPMetricsResponse(serializedBytes: body))?.partialSuccess.rejectedDataPoints ?? 0)
    case (.metrics, .json):
      return Int(
        (try? OTLPMetricsResponse(jsonUTF8Data: body, options: options))?.partialSuccess
          .rejectedDataPoints ?? 0)
    case (.logs, .protobuf):
      return Int(
        (try? OTLPLogsResponse(serializedBytes: body))?.partialSuccess.rejectedLogRecords ?? 0)
    case (.logs, .json):
      return Int(
        (try? OTLPLogsResponse(jsonUTF8Data: body, options: options))?.partialSuccess
          .rejectedLogRecords ?? 0)
    case (.traces, .protobuf):
      return Int((try? OTLPTraceResponse(serializedBytes: body))?.partialSuccess.rejectedSpans ?? 0)
    case (.traces, .json):
      return Int(
        (try? OTLPTraceResponse(jsonUTF8Data: body, options: options))?.partialSuccess.rejectedSpans
          ?? 0)
    }
  }
}
