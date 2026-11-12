import FlashOTLP
import Foundation

/// What the OTLP receiver keeps: every metric series' latest state with a
/// short history, and the most recent log records and spans. Everything is
/// bounded and in memory; nothing is written to disk, and quitting Flash
/// forgets it.
///
/// The data is guarded by a lock, so the receiver ingests on its queue while
/// the status controller and the help server read on theirs. The one
/// deadline — a reporting series going quiet, which drops its rate to 0 — is
/// armed on the store's own queue, on the shared clock, and only while a
/// status surface or monitor reads that metric.
final class TelemetryStore {
  struct Limits: Equatable {
    /// Series kept; the least recently updated is evicted first.
    var maxSeries = 1000
    /// History points kept per series.
    var maxPoints = 60
    var maxLogs = 1000
    var maxSpans = 1000
  }

  /// Received-data counters, per signal, for the help page.
  struct Counters: Equatable {
    var requests: [TelemetrySignal: Int] = [:]
    var accepted: [TelemetrySignal: Int] = [:]
    var rejected: [TelemetrySignal: Int] = [:]
    var evictedSeries = 0
    var lastReceivedMs: Int64?
  }

  private let lock = NSLock()
  private var limits: Limits
  private var series: [String: TelemetrySeries] = [:]
  private var seriesByMetric: [String: Set<String>] = [:]
  private var logs: TelemetryRing<TelemetryLogEntry>
  private var spans: TelemetryRing<TelemetrySpanEntry>
  private var counters = Counters()
  private var sequence: UInt64 = 0
  private(set) var revision: UInt64 = 0
  /// Metric names a status surface or monitor reads.
  private var observedMetrics: Set<String> = []
  private var changeHandler: (() -> Void)?
  private var observedChangeHandler: (() -> Void)?

  private let clock: () -> TimeInterval
  private let wallClock: () -> Date
  private let queue = DispatchQueue(label: "flash.telemetry.store", qos: .utility)
  /// When the next observed series goes quiet. `.low`: a rate dropping to 0
  /// a second late is invisible. Confined to `queue`.
  private lazy var staleDeadline = PollDeadline(
    "core:telemetry_stale:\(UInt(bitPattern: ObjectIdentifier(self).hashValue))",
    priority: .low, on: queue, scheduler: scheduler)
  private let scheduler: PollScheduler

  init(
    limits: Limits = Limits(),
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    wallClock: @escaping () -> Date = Date.init,
    scheduler: PollScheduler = .shared
  ) {
    self.limits = limits
    self.clock = clock
    self.wallClock = wallClock
    self.scheduler = scheduler
    logs = TelemetryRing(capacity: limits.maxLogs)
    spans = TelemetryRing(capacity: limits.maxSpans)
  }

  /// `changed` runs after every ingest (the help page's revision);
  /// `observedChanged` only when a metric a surface reads changed or one of
  /// its series went quiet. Both run on the ingesting queue or the store's.
  func setHandlers(changed: (() -> Void)?, observedChanged: (() -> Void)?) {
    lock.lock()
    changeHandler = changed
    observedChangeHandler = observedChanged
    lock.unlock()
  }

  /// New retention bounds; what no longer fits is evicted at once.
  func setLimits(_ next: Limits) {
    lock.lock()
    defer { lock.unlock() }
    guard next != limits else { return }
    limits = next
    logs.resize(next.maxLogs)
    spans.resize(next.maxSpans)
    while series.count > limits.maxSeries { evictOldestLocked() }
    for id in Array(series.keys) { series[id]?.trimHistory(to: next.maxPoints) }
    revision &+= 1
  }

  /// Forget everything received; the receiver turning off.
  func reset() {
    lock.lock()
    series.removeAll()
    seriesByMetric.removeAll()
    logs.removeAll()
    spans.removeAll()
    counters = Counters()
    revision &+= 1
    let handler = changeHandler
    let observed = observedChangeHandler
    lock.unlock()
    handler?()
    observed?()
    queue.async { [weak self] in self?.staleDeadline.cancel() }
  }

  // MARK: Observed values

  /// The status-format keys the surfaces read now. Their metrics are what
  /// the observed-change handler and the quiet deadline follow.
  func observe(keys: Set<String>) {
    let metrics = Set(keys.compactMap { TelemetryQuery(key: $0)?.metric })
    lock.lock()
    let changed = metrics != observedMetrics
    observedMetrics = metrics
    lock.unlock()
    if changed { armStaleDeadline() }
  }

  /// The value of each well-formed key that has one now; a key with no
  /// matching series, or a field its kind does not have, is absent.
  func values(for keys: Set<String>) -> [String: String] {
    let now = clock()
    lock.lock()
    defer { lock.unlock() }
    var result: [String: String] = [:]
    for key in keys {
      guard let query = TelemetryQuery(key: key),
        let value = valueLocked(of: query, now: now)
      else { continue }
      let text = TelemetryNumber.format(value)
      if !text.isEmpty { result[key] = text }
    }
    return result
  }

  func value(of query: TelemetryQuery) -> Double? {
    let now = clock()
    lock.lock()
    defer { lock.unlock() }
    return valueLocked(of: query, now: now)
  }

  private func valueLocked(of query: TelemetryQuery, now: TimeInterval) -> Double? {
    let matched = (seriesByMetric[query.metric] ?? []).sorted().compactMap { series[$0] }
      .filter { query.matches($0.lookup) }
    guard let first = matched.first else { return nil }
    // One metric name normally has one kind; a stray series of another
    // kind is left out rather than added to numbers it does not share.
    let distribution = first.kind.isDistribution
    let group = matched.filter { $0.kind.isDistribution == distribution }
    return TelemetrySeries.aggregate(query.field, of: group, now: now)
  }

  // MARK: Ingest

  struct IngestResult: Equatable {
    var accepted = 0
    var rejected = 0
    /// Why the rejected items were refused; empty when none were.
    var message = ""
  }

  func ingest(_ export: OTLPExport) -> IngestResult {
    let now = clock()
    let wallMs = Int64((wallClock().timeIntervalSince1970 * 1000).rounded())
    lock.lock()
    let signal: TelemetrySignal
    var result: IngestResult
    var touched = Set<String>()
    switch export {
    case .metrics(let request):
      signal = .metrics
      result = ingestLocked(request, now: now, wallMs: wallMs, touched: &touched)
    case .logs(let request):
      signal = .logs
      result = ingestLocked(request, wallMs: wallMs)
    case .traces(let request):
      signal = .traces
      result = ingestLocked(request)
    }
    counters.requests[signal, default: 0] += 1
    counters.accepted[signal, default: 0] += result.accepted
    counters.rejected[signal, default: 0] += result.rejected
    counters.lastReceivedMs = wallMs
    revision &+= 1
    let handler = changeHandler
    let observedHandler = touched.isDisjoint(with: observedMetrics) ? nil : observedChangeHandler
    lock.unlock()
    handler?()
    if let observedHandler {
      observedHandler()
      armStaleDeadline()
    }
    return result
  }

  private func ingestLocked(
    _ request: OTLPMetricsRequest, now: TimeInterval, wallMs: Int64, touched: inout Set<String>
  ) -> IngestResult {
    var result = IngestResult()
    var reasons: [String: Int] = [:]
    func reject(_ count: Int, _ reason: String) {
      result.rejected += count
      reasons[reason, default: 0] += count
    }
    for resourceMetrics in request.resourceMetrics {
      let resource = OTLPValues.attributes(resourceMetrics.resource.attributes)
      for scopeMetrics in resourceMetrics.scopeMetrics {
        let scope = scopeMetrics.scope
        let scopeAttributes = OTLPValues.attributes(scope.attributes)
        for metric in scopeMetrics.metrics {
          guard let points = TelemetryPointBatch(metric) else {
            reject(1, "a metric without data")
            continue
          }
          guard !metric.name.isEmpty, metric.name.utf8.count <= 255 else {
            reject(points.count, "a metric without a valid name")
            continue
          }
          for raw in points.points {
            guard let point = raw.point else {
              reject(1, raw.problem ?? "an invalid data point")
              continue
            }
            if raw.noRecordedValue {
              result.accepted += 1
              continue
            }
            upsertLocked(
              metric: metric.name, resource: resource, scope: scope.name,
              scopeAttributes: scopeAttributes, attributes: OTLPValues.attributes(raw.attributes),
              point: point, kind: points.kind, temporality: points.temporality,
              monotonic: points.monotonic, unit: metric.unit, summary: metric.description_p,
              now: now, wallMs: wallMs)
            touched.insert(metric.name)
            result.accepted += 1
          }
        }
      }
    }
    result.message = Self.message(reasons, noun: "data point")
    return result
  }

  /// Under `lock`: one point into its series, the series created (evicting
  /// the least recently updated past `maxSeries`) on first sight. Received
  /// points and recorded ones go through here alike.
  private func upsertLocked(
    metric: String, resource: [String: String], scope: String,
    scopeAttributes: [String: String], attributes: [String: String],
    point: TelemetrySeries.Point, kind: TelemetrySeries.Kind,
    temporality: TelemetrySeries.Temporality, monotonic: Bool, unit: String, summary: String,
    now: TimeInterval, wallMs: Int64
  ) {
    let id = TelemetrySeries.identity(
      metric: metric, resource: resource, scope: scope, scopeAttributes: scopeAttributes,
      attributes: attributes)
    if series[id] == nil {
      if series.count >= limits.maxSeries { evictOldestLocked() }
      var lookup = resource
      lookup.merge(scopeAttributes) { _, new in new }
      lookup.merge(attributes) { _, new in new }
      series[id] = TelemetrySeries(
        id: id, metric: metric, kind: kind, temporality: temporality, monotonic: monotonic,
        unit: unit, summary: summary, resource: resource, scope: scope, attributes: attributes,
        lookup: lookup)
      seriesByMetric[metric, default: []].insert(id)
    }
    sequence &+= 1
    series[id]?.ingest(
      point, kind: kind, temporality: temporality, monotonic: monotonic, unit: unit,
      summary: summary, now: now, wallMs: wallMs, sequence: sequence, maxPoints: limits.maxPoints)
  }

  // MARK: Recorded metrics

  /// The resource recorded metrics carry: Flash itself, as its exporter
  /// names it.
  static let recordedResource = ["service.name": "flash"]

  /// One measurement recorded through Flash, `metrics record` or one of
  /// Flash's own instruments, into the same series the receiver fills, so
  /// status formats and monitors read it as they read received metrics. A
  /// gauge keeps its value; a counter is a delta sum, each recording an
  /// increment; a histogram records one observation as a delta window.
  func record(_ record: MetricRecord, scope: String) {
    let now = clock()
    let wall = wallClock()
    let wallMs = Int64((wall.timeIntervalSince1970 * 1000).rounded())
    lock.lock()
    recordLocked(
      record, scope: scope, now: now, wallNs: TelemetryRecorder.nanoseconds(wall), wallMs: wallMs)
    revision &+= 1
    let handler = changeHandler
    let observedHandler = observedMetrics.contains(record.name) ? observedChangeHandler : nil
    lock.unlock()
    handler?()
    if let observedHandler {
      observedHandler()
      armStaleDeadline()
    }
  }

  /// `record`, only when a status surface or monitor reads the metric: what
  /// keeps Flash's own instruments, recorded on hot paths, out of the store
  /// until someone looks at them.
  func recordIfObserved(_ record: MetricRecord, scope: String) {
    lock.lock()
    let observed = observedMetrics.contains(record.name)
    lock.unlock()
    guard observed else { return }
    self.record(record, scope: scope)
  }

  private func recordLocked(
    _ record: MetricRecord, scope: String, now: TimeInterval, wallNs: UInt64, wallMs: Int64
  ) {
    let resource = Self.recordedResource
    let id = TelemetrySeries.identity(
      metric: record.name, resource: resource, scope: scope, scopeAttributes: [:],
      attributes: record.attributes)
    // Points of one series must move forward: two recordings inside the
    // same nanosecond still both count.
    let previous = series[id]?.latest?.timeNs ?? 0
    let timeNs = Swift.max(wallNs, previous + 1)
    let point: TelemetrySeries.Point
    let kind: TelemetrySeries.Kind
    let temporality: TelemetrySeries.Temporality
    switch record.kind {
    case .gauge:
      kind = .gauge
      temporality = .unspecified
      point = TelemetrySeries.Point(startNs: 0, timeNs: timeNs, value: record.value)
    case .counter:
      kind = .sum
      temporality = .delta
      point = TelemetrySeries.Point(
        startNs: previous == 0 ? timeNs : previous, timeNs: timeNs, value: record.value)
    case .histogram:
      kind = .histogram
      temporality = .delta
      point = TelemetrySeries.Point(
        startNs: previous == 0 ? timeNs : previous, timeNs: timeNs, value: 1,
        distribution: Self.observation(record.value, bounds: record.instrument.bounds))
    }
    upsertLocked(
      metric: record.name, resource: resource, scope: scope, scopeAttributes: [:],
      attributes: record.attributes, point: point, kind: kind, temporality: temporality,
      monotonic: record.kind == .counter, unit: record.instrument.unit,
      summary: record.instrument.summary, now: now, wallMs: wallMs)
  }

  /// One observation as a histogram window over `bounds`.
  static func observation(_ value: Double, bounds: [Double]) -> TelemetrySeries.Distribution {
    var buckets: [TelemetrySeries.Bucket] = []
    var lower = -Double.infinity
    for upper in bounds + [Double.infinity] {
      let holds = value > lower && value <= upper
      buckets.append(TelemetrySeries.Bucket(lower: lower, upper: upper, count: holds ? 1 : 0))
      lower = upper
    }
    return TelemetrySeries.Distribution(
      count: 1, sum: value, min: value, max: value, buckets: buckets)
  }

  private func ingestLocked(_ request: OTLPLogsRequest, wallMs: Int64) -> IngestResult {
    var result = IngestResult()
    for resourceLogs in request.resourceLogs {
      let resource = OTLPValues.attributes(resourceLogs.resource.attributes)
      let service = resource["service.name"] ?? ""
      for scopeLogs in resourceLogs.scopeLogs {
        for record in scopeLogs.logRecords {
          logs.append(
            TelemetryLogEntry(
              record, service: service, scope: scopeLogs.scope.name, receivedMs: wallMs))
          result.accepted += 1
        }
      }
    }
    return result
  }

  private func ingestLocked(_ request: OTLPTraceRequest) -> IngestResult {
    var result = IngestResult()
    var invalid = 0
    for resourceSpans in request.resourceSpans {
      let resource = OTLPValues.attributes(resourceSpans.resource.attributes)
      let service = resource["service.name"] ?? ""
      for scopeSpans in resourceSpans.scopeSpans {
        for span in scopeSpans.spans {
          guard let entry = TelemetrySpanEntry(span, service: service, scope: scopeSpans.scope.name)
          else {
            invalid += 1
            continue
          }
          spans.append(entry)
          result.accepted += 1
        }
      }
    }
    result.rejected = invalid
    result.message = Self.message(
      invalid > 0 ? ["a trace or span id of the wrong length": invalid] : [:], noun: "span")
    return result
  }

  private static func message(_ reasons: [String: Int], noun: String) -> String {
    reasons.keys.sorted().map { reason in
      let count = reasons[reason] ?? 0
      return "\(count) \(noun)\(count == 1 ? "" : "s") rejected: \(reason)"
    }.joined(separator: "; ")
  }

  /// Under `lock`: drop the least recently updated series.
  private func evictOldestLocked() {
    guard let oldest = series.values.min(by: { $0.sequence < $1.sequence }) else { return }
    series.removeValue(forKey: oldest.id)
    seriesByMetric[oldest.metric]?.remove(oldest.id)
    if seriesByMetric[oldest.metric]?.isEmpty == true {
      seriesByMetric.removeValue(forKey: oldest.metric)
    }
    counters.evictedSeries += 1
  }

  // MARK: Quiet deadline

  /// Arm the deadline at the next moment an observed series that reports a
  /// rate goes quiet; nothing is armed while no surface reads a metric.
  private func armStaleDeadline() {
    queue.async { [weak self] in
      guard let self else { return }
      let now = self.clock()
      self.lock.lock()
      var next: TimeInterval?
      for metric in self.observedMetrics {
        for id in self.seriesByMetric[metric] ?? [] {
          guard let quietAt = self.series[id]?.quietAt, quietAt > now else { continue }
          next = min(next ?? quietAt, quietAt)
        }
      }
      self.lock.unlock()
      guard let next else { return self.staleDeadline.cancel() }
      self.staleDeadline.arm(after: next - now + 0.001) { [weak self] in
        guard let self else { return }
        self.lock.lock()
        let handler = self.observedChangeHandler
        self.lock.unlock()
        handler?()
        self.armStaleDeadline()
      }
    }
  }

  // MARK: Help page

  func counterSnapshot() -> (
    counters: Counters, series: Int, logs: Int, spans: Int, revision: UInt64
  ) {
    lock.lock()
    defer { lock.unlock() }
    return (counters, series.count, logs.count, spans.count, revision)
  }

  /// `/api/telemetry`: every metric with its series, then the retained log
  /// records and spans, oldest first.
  func snapshotJSON() -> [String: Any] {
    let now = clock()
    lock.lock()
    defer { lock.unlock() }
    var metrics: [[String: Any]] = []
    for name in seriesByMetric.keys.sorted() {
      let members = (seriesByMetric[name] ?? []).sorted().compactMap { series[$0] }
      guard let first = members.first else { continue }
      metrics.append([
        "name": name,
        "kind": first.kind.rawValue,
        "unit": first.unit,
        "description": first.summary,
        "temporality": first.temporality.rawValue,
        "monotonic": first.monotonic,
        "series": members.map { $0.jsonObject(now: now) },
      ])
    }
    return [
      "revision": revision,
      "metrics": metrics,
      "logs": logs.elements.map(\.jsonObject),
      "spans": spans.elements.map(\.jsonObject),
      "limits": [
        "max_series": limits.maxSeries, "max_points": limits.maxPoints,
        "max_logs": limits.maxLogs, "max_spans": limits.maxSpans,
      ],
    ]
  }
}

/// A fixed-capacity buffer that drops its oldest element when full.
struct TelemetryRing<Element> {
  private var storage: [Element] = []
  private var head = 0
  private(set) var capacity: Int

  init(capacity: Int) {
    self.capacity = max(0, capacity)
  }

  var count: Int { storage.count }

  /// Oldest first.
  var elements: [Element] {
    Array(storage[head...]) + Array(storage[..<head])
  }

  mutating func append(_ element: Element) {
    guard capacity > 0 else { return }
    if storage.count < capacity {
      storage.append(element)
    } else {
      storage[head] = element
      head = (head + 1) % capacity
    }
  }

  mutating func resize(_ next: Int) {
    let kept = Array(elements.suffix(max(0, next)))
    capacity = max(0, next)
    storage = kept
    head = 0
  }

  mutating func removeAll() {
    storage.removeAll()
    head = 0
  }
}

/// One metric's points as received, normalized across the five OTLP kinds.
struct TelemetryPointBatch {
  struct RawPoint {
    var point: TelemetrySeries.Point?
    var attributes: [OTLPKeyValue]
    /// OTLP's `FLAG_NO_RECORDED_VALUE`: a staleness marker, not a value.
    var noRecordedValue: Bool
    var problem: String?
  }

  var kind: TelemetrySeries.Kind
  var temporality: TelemetrySeries.Temporality
  var monotonic: Bool
  var points: [RawPoint]
  var count: Int { points.count }

  private static let noRecordedValueFlag: UInt32 = 1

  init?(_ metric: Opentelemetry_Proto_Metrics_V1_Metric) {
    switch metric.data {
    case .gauge(let gauge):
      kind = .gauge
      temporality = .unspecified
      monotonic = false
      points = gauge.dataPoints.map(Self.number)
    case .sum(let sum):
      kind = .sum
      temporality = .init(sum.aggregationTemporality)
      monotonic = sum.isMonotonic
      points = sum.dataPoints.map(Self.number)
    case .histogram(let histogram):
      kind = .histogram
      temporality = .init(histogram.aggregationTemporality)
      monotonic = true
      points = histogram.dataPoints.map(Self.histogram)
    case .exponentialHistogram(let histogram):
      kind = .exponentialHistogram
      temporality = .init(histogram.aggregationTemporality)
      monotonic = true
      points = histogram.dataPoints.map(Self.exponential)
    case .summary(let summary):
      kind = .summary
      temporality = .cumulative
      monotonic = true
      points = summary.dataPoints.map(Self.summary)
    case nil:
      return nil
    }
  }

  private static func number(_ point: Opentelemetry_Proto_Metrics_V1_NumberDataPoint) -> RawPoint {
    let value: Double?
    switch point.value {
    case .asDouble(let double): value = double
    case .asInt(let int): value = Double(int)
    case nil: value = nil
    }
    let noValue = point.flags & noRecordedValueFlag != 0
    guard let value, value.isFinite || noValue else {
      return RawPoint(
        point: nil, attributes: point.attributes, noRecordedValue: false,
        problem: value == nil ? "a number point without a value" : "a value that is not finite")
    }
    guard point.timeUnixNano > 0 else {
      return RawPoint(
        point: nil, attributes: point.attributes, noRecordedValue: false,
        problem: "a point without a time")
    }
    return RawPoint(
      point: .init(
        startNs: point.startTimeUnixNano, timeNs: point.timeUnixNano, value: value,
        distribution: nil),
      attributes: point.attributes, noRecordedValue: noValue)
  }

  private static func histogram(_ point: Opentelemetry_Proto_Metrics_V1_HistogramDataPoint)
    -> RawPoint
  {
    let noValue = point.flags & noRecordedValueFlag != 0
    let bounds = point.explicitBounds
    guard point.bucketCounts.isEmpty || point.bucketCounts.count == bounds.count + 1 else {
      return RawPoint(
        point: nil, attributes: point.attributes, noRecordedValue: false,
        problem: "histogram bucket counts that do not match its bounds")
    }
    guard zip(bounds, bounds.dropFirst()).allSatisfy({ $0 < $1 }), bounds.allSatisfy(\.isFinite)
    else {
      return RawPoint(
        point: nil, attributes: point.attributes, noRecordedValue: false,
        problem: "histogram bounds that are not increasing")
    }
    guard point.timeUnixNano > 0 else {
      return RawPoint(
        point: nil, attributes: point.attributes, noRecordedValue: false,
        problem: "a point without a time")
    }
    var buckets: [TelemetrySeries.Bucket] = []
    if !point.bucketCounts.isEmpty {
      let edges = [-Double.infinity] + bounds + [Double.infinity]
      for (index, count) in point.bucketCounts.enumerated() {
        buckets.append(.init(lower: edges[index], upper: edges[index + 1], count: Double(count)))
      }
    }
    let distribution = TelemetrySeries.Distribution(
      count: Double(point.count), sum: point.hasSum ? point.sum : nil,
      min: point.hasMin ? point.min : nil, max: point.hasMax ? point.max : nil, buckets: buckets)
    return RawPoint(
      point: .init(
        startNs: point.startTimeUnixNano, timeNs: point.timeUnixNano, value: Double(point.count),
        distribution: distribution),
      attributes: point.attributes, noRecordedValue: noValue)
  }

  private static func exponential(
    _ point: Opentelemetry_Proto_Metrics_V1_ExponentialHistogramDataPoint
  ) -> RawPoint {
    let noValue = point.flags & noRecordedValueFlag != 0
    guard point.timeUnixNano > 0 else {
      return RawPoint(
        point: nil, attributes: point.attributes, noRecordedValue: false,
        problem: "a point without a time")
    }
    guard (-10...20).contains(point.scale) else {
      return RawPoint(
        point: nil, attributes: point.attributes, noRecordedValue: false,
        problem: "an exponential histogram scale outside -10…20")
    }
    let base = pow(2, pow(2, -Double(point.scale)))
    var buckets: [TelemetrySeries.Bucket] = []
    let negative = point.negative
    for (index, count) in negative.bucketCounts.enumerated().reversed() where count > 0 {
      let exponent = Double(Int(negative.offset) + index)
      buckets.append(
        .init(lower: -pow(base, exponent + 1), upper: -pow(base, exponent), count: Double(count)))
    }
    if point.zeroCount > 0 {
      buckets.append(
        .init(
          lower: -point.zeroThreshold, upper: point.zeroThreshold, count: Double(point.zeroCount)))
    }
    let positive = point.positive
    for (index, count) in positive.bucketCounts.enumerated() where count > 0 {
      let exponent = Double(Int(positive.offset) + index)
      buckets.append(
        .init(lower: pow(base, exponent), upper: pow(base, exponent + 1), count: Double(count)))
    }
    let distribution = TelemetrySeries.Distribution(
      count: Double(point.count), sum: point.hasSum ? point.sum : nil,
      min: point.hasMin ? point.min : nil, max: point.hasMax ? point.max : nil, buckets: buckets)
    return RawPoint(
      point: .init(
        startNs: point.startTimeUnixNano, timeNs: point.timeUnixNano, value: Double(point.count),
        distribution: distribution),
      attributes: point.attributes, noRecordedValue: noValue)
  }

  private static func summary(_ point: Opentelemetry_Proto_Metrics_V1_SummaryDataPoint) -> RawPoint
  {
    let noValue = point.flags & noRecordedValueFlag != 0
    guard point.timeUnixNano > 0 else {
      return RawPoint(
        point: nil, attributes: point.attributes, noRecordedValue: false,
        problem: "a point without a time")
    }
    var quantiles: [Double: Double] = [:]
    for quantile in point.quantileValues where (0...1).contains(quantile.quantile) {
      quantiles[quantile.quantile] = quantile.value
    }
    let distribution = TelemetrySeries.Distribution(
      count: Double(point.count), sum: point.sum, min: quantiles[0], max: quantiles[1],
      quantiles: quantiles)
    return RawPoint(
      point: .init(
        startNs: point.startTimeUnixNano, timeNs: point.timeUnixNano, value: Double(point.count),
        distribution: distribution),
      attributes: point.attributes, noRecordedValue: noValue)
  }
}

extension TelemetrySeries.Temporality {
  init(_ temporality: Opentelemetry_Proto_Metrics_V1_AggregationTemporality) {
    switch temporality {
    case .cumulative: self = .cumulative
    case .delta: self = .delta
    default: self = .unspecified
    }
  }
}
