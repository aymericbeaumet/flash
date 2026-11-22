import FlashOTLP
import Foundation

/// One metric stream: a metric name with one resource, scope and attribute
/// set. Pure over the points and times it is given, so every temporality
/// rule is testable without a receiver.
///
/// - A gauge keeps its latest value; its rate is the change per second
///   between its last two points.
/// - A cumulative sum's total is its reported value, carried across resets
///   (a new start time, or a monotonic value going down); its increment is
///   the difference between consecutive points.
/// - A delta sum's increment is each point; its total is their running sum
///   from the first point Flash received.
/// - A histogram or summary keeps its latest window — a delta point, or the
///   difference between consecutive cumulative points — for its mean and
///   percentiles, and running totals of its count and sum.
///
/// The rate of every kind is per second over the latest reporting interval,
/// and 0 once the series has been quiet for two and a half intervals (at
/// least 10 s): a delta exporter sends nothing while nothing happens.
struct TelemetrySeries {
  enum Kind: String {
    case gauge
    case sum
    case histogram
    case exponentialHistogram = "exponential_histogram"
    case summary

    var isDistribution: Bool {
      switch self {
      case .gauge, .sum: return false
      case .histogram, .exponentialHistogram, .summary: return true
      }
    }
  }

  enum Temporality: String {
    case cumulative
    case delta
    case unspecified
  }

  /// Observations between `lower` (exclusive) and `upper` (inclusive).
  struct Bucket: Equatable {
    var lower: Double
    var upper: Double
    var count: Double
  }

  /// A histogram's or summary's observations over some span of time.
  struct Distribution: Equatable {
    var count: Double = 0
    var sum: Double?
    var min: Double?
    var max: Double?
    var buckets: [Bucket] = []
    /// A summary's reported quantiles, 0…1 → value.
    var quantiles: [Double: Double] = [:]

    var mean: Double? {
      guard count > 0, let sum else { return nil }
      return sum / count
    }

    /// The observations since `earlier`: bucket by bucket when both have the
    /// same buckets, the count and sum alone otherwise. Nil when a count
    /// went down, which is a reset rather than a window.
    func subtracting(_ earlier: Distribution) -> Distribution? {
      guard count >= earlier.count else { return nil }
      var window = Distribution(
        count: count - earlier.count,
        sum: sum.flatMap { current in earlier.sum.map { current - $0 } },
        min: min, max: max, quantiles: quantiles)
      let sameBuckets =
        buckets.count == earlier.buckets.count
        && zip(buckets, earlier.buckets).allSatisfy { $0.lower == $1.lower && $0.upper == $1.upper }
      if sameBuckets {
        window.buckets = zip(buckets, earlier.buckets).map { current, past in
          Bucket(
            lower: current.lower, upper: current.upper,
            count: Swift.max(0, current.count - past.count))
        }
      }
      return window
    }

    /// Several windows as one: counts and sums add, and buckets with the
    /// same bounds merge.
    static func merged(_ parts: [Distribution]) -> Distribution {
      var result = Distribution()
      var buckets: [String: Bucket] = [:]
      for part in parts {
        result.count += part.count
        if let sum = part.sum { result.sum = (result.sum ?? 0) + sum }
        if let min = part.min { result.min = Swift.min(result.min ?? min, min) }
        if let max = part.max { result.max = Swift.max(result.max ?? max, max) }
        for bucket in part.buckets {
          let key = "\(bucket.lower)/\(bucket.upper)"
          buckets[key, default: Bucket(lower: bucket.lower, upper: bucket.upper, count: 0)].count +=
            bucket.count
        }
      }
      result.buckets = buckets.values.sorted { ($0.upper, $0.lower) < ($1.upper, $1.lower) }
      return result
    }

    /// The `p`th percentile (0 < p < 100), interpolated linearly inside the
    /// bucket that holds it, as Prometheus's `histogram_quantile` does. An
    /// open-ended bucket is bounded by the reported min or max. Nil without
    /// buckets or observations.
    func percentile(_ p: Double) -> Double? {
      let ordered = buckets.filter { $0.count > 0 }
        .sorted { ($0.upper, $0.lower) < ($1.upper, $1.lower) }
      let total = ordered.reduce(0) { $0 + $1.count }
      guard total > 0 else { return nil }
      let rank = p / 100 * total
      var below = 0.0
      for bucket in ordered {
        guard below + bucket.count >= rank else {
          below += bucket.count
          continue
        }
        var lower = bucket.lower
        var upper = bucket.upper
        if !lower.isFinite { lower = min.map { Swift.min($0, upper) } ?? upper }
        if !upper.isFinite { upper = max.map { Swift.max($0, lower) } ?? lower }
        var value = lower + (upper - lower) * ((rank - below) / bucket.count)
        if let min { value = Swift.max(value, min) }
        if let max { value = Swift.min(value, max) }
        return value
      }
      return max
    }
  }

  struct Point: Equatable {
    var startNs: UInt64
    var timeNs: UInt64
    /// A number point's value; a distribution's count.
    var value: Double
    var distribution: Distribution?
  }

  let id: String
  let metric: String
  private(set) var kind: Kind
  private(set) var temporality: Temporality
  private(set) var monotonic: Bool
  var unit: String
  var summary: String
  let resource: [String: String]
  let scope: String
  /// The point's own attributes.
  let attributes: [String: String]
  /// What a filter matches: resource attributes, overridden by scope
  /// attributes, overridden by the point's.
  let lookup: [String: String]

  private(set) var latest: Point?
  private(set) var previous: Point?
  /// A sum's running total.
  private(set) var total: Double?
  /// A distribution's running observation count and sum.
  private(set) var countTotal: Double?
  private(set) var sumTotal: Double?
  /// The latest change: a sum's increment, a distribution's window count.
  private(set) var increment: Double?
  /// A distribution's latest window.
  private(set) var window: Distribution?
  /// Seconds the latest point covers: what the rate is per.
  private(set) var intervalSeconds: Double?
  /// Per point, oldest first: a gauge's values, a sum's increments, a
  /// distribution's window counts.
  private(set) var history: [Double] = []
  /// Uptime and wall-clock milliseconds of the latest accepted point.
  private(set) var receivedAt: TimeInterval = 0
  private(set) var receivedWallMs: Int64 = 0
  /// Ingest order across the store: the least recent is evicted first.
  private(set) var sequence: UInt64 = 0
  private(set) var updates = 0
  /// What earlier runs of a cumulative stream counted before it reset.
  private var offsetValue = 0.0
  private var offsetCount = 0.0
  private var offsetSum = 0.0

  init(
    id: String, metric: String, kind: Kind, temporality: Temporality, monotonic: Bool,
    unit: String, summary: String, resource: [String: String], scope: String,
    attributes: [String: String], lookup: [String: String]
  ) {
    self.id = id
    self.metric = metric
    self.kind = kind
    self.temporality = temporality
    self.monotonic = monotonic
    self.unit = unit
    self.summary = summary
    self.resource = resource
    self.scope = scope
    self.attributes = attributes
    self.lookup = lookup
  }

  /// The series a point belongs to: its metric name, resource, scope and
  /// attributes, each in sorted order.
  static func identity(
    metric: String, resource: [String: String], scope: String,
    scopeAttributes: [String: String], attributes: [String: String]
  ) -> String {
    func encode(_ pairs: [String: String]) -> String {
      pairs.keys.sorted().map { "\($0)\u{1}\(pairs[$0] ?? "")" }.joined(separator: "\u{2}")
    }
    return [metric, encode(resource), scope, encode(scopeAttributes), encode(attributes)]
      .joined(separator: "\u{0}")
  }

  private static func seconds(_ nanoseconds: UInt64) -> Double {
    Double(nanoseconds) / 1_000_000_000
  }

  /// A point's own interval when its start time is known.
  private static func ownInterval(_ point: Point) -> Double? {
    point.startNs > 0 && point.startNs < point.timeNs
      ? seconds(point.timeNs - point.startNs) : nil
  }

  /// Fold one point in. A point no newer than the latest is a duplicate or
  /// arrived out of order, and is ignored. A changed kind, temporality or
  /// monotonicity starts the series over.
  mutating func ingest(
    _ point: Point, kind: Kind, temporality: Temporality, monotonic: Bool, unit: String,
    summary: String, now: TimeInterval, wallMs: Int64, sequence: UInt64, maxPoints: Int
  ) {
    if kind != self.kind || temporality != self.temporality || monotonic != self.monotonic {
      self = TelemetrySeries(
        id: id, metric: metric, kind: kind, temporality: temporality, monotonic: monotonic,
        unit: unit, summary: summary, resource: resource, scope: scope, attributes: attributes,
        lookup: lookup)
    }
    if !unit.isEmpty { self.unit = unit }
    if !summary.isEmpty { self.summary = summary }
    if let latest, point.timeNs <= latest.timeNs { return }
    receivedAt = now
    receivedWallMs = wallMs
    self.sequence = sequence
    updates += 1
    let prior = latest
    switch kind {
    case .gauge:
      increment = nil
      intervalSeconds = prior.map { Self.seconds(point.timeNs - $0.timeNs) }
      appendHistory(point.value, limit: maxPoints)
    case .sum where temporality == .delta:
      increment = point.value
      total = (total ?? 0) + point.value
      intervalSeconds =
        Self.ownInterval(point) ?? prior.map { Self.seconds(point.timeNs - $0.timeNs) }
      appendHistory(point.value, limit: maxPoints)
    case .sum:
      if let prior {
        let reset =
          (point.startNs != 0 && prior.startNs != 0 && point.startNs != prior.startNs)
          || (monotonic && point.value < prior.value)
        if reset {
          offsetValue += prior.value
          increment = point.value
          intervalSeconds = Self.ownInterval(point)
        } else {
          increment = point.value - prior.value
          intervalSeconds = Self.seconds(point.timeNs - prior.timeNs)
        }
        appendHistory(increment ?? 0, limit: maxPoints)
      } else {
        increment = nil
        intervalSeconds = nil
      }
      total = offsetValue + point.value
    case .histogram, .exponentialHistogram, .summary:
      guard let current = point.distribution else { return }
      if temporality == .delta {
        window = current
        countTotal = (countTotal ?? 0) + current.count
        if let sum = current.sum { sumTotal = (sumTotal ?? 0) + sum }
        intervalSeconds =
          Self.ownInterval(point) ?? prior.map { Self.seconds(point.timeNs - $0.timeNs) }
        appendHistory(current.count, limit: maxPoints)
      } else {
        if let prior, let earlier = prior.distribution {
          let restarted = point.startNs != 0 && prior.startNs != 0 && point.startNs != prior.startNs
          if !restarted, let difference = current.subtracting(earlier) {
            window = difference
            intervalSeconds = Self.seconds(point.timeNs - prior.timeNs)
          } else {
            offsetCount += earlier.count
            offsetSum += earlier.sum ?? 0
            window = current
            intervalSeconds = Self.ownInterval(point)
          }
          appendHistory(window?.count ?? 0, limit: maxPoints)
        } else {
          // The first cumulative point: its distribution since its start
          // serves the mean and percentiles; its rate waits for a second.
          window = current
          intervalSeconds = nil
        }
        countTotal = offsetCount + current.count
        sumTotal = current.sum.map { offsetSum + $0 }
      }
      increment = window?.count
    }
    previous = prior
    latest = point
  }

  private mutating func appendHistory(_ value: Double, limit: Int) {
    history.append(value)
    trimHistory(to: limit)
  }

  mutating func trimHistory(to limit: Int) {
    if history.count > limit { history.removeFirst(history.count - max(0, limit)) }
  }

  /// When the series counts as quiet: two and a half reporting intervals
  /// (at least 10 s; a minute's when the interval is unknown) after its
  /// latest point arrived.
  var quietAt: TimeInterval? {
    guard latest != nil else { return nil }
    return receivedAt + max(10, 2.5 * (intervalSeconds ?? 60))
  }

  func isQuiet(now: TimeInterval) -> Bool {
    quietAt.map { now >= $0 } ?? false
  }

  /// Per second over the latest interval; 0 once quiet.
  func rate(now: TimeInterval) -> Double? {
    guard let latest else { return nil }
    if isQuiet(now: now) { return 0 }
    guard let intervalSeconds, intervalSeconds > 0 else { return nil }
    switch kind {
    case .gauge:
      return previous.map { (latest.value - $0.value) / intervalSeconds }
    case .sum:
      return increment.map { $0 / intervalSeconds }
    case .histogram, .exponentialHistogram, .summary:
      return window.map { $0.count / intervalSeconds }
    }
  }

  /// A field over the series a query matched, all numeric or all
  /// distributions. Values add across series; minimums, maximums and
  /// percentiles combine. Nil for a field the kind does not have.
  static func aggregate(
    _ field: TelemetryQuery.Field, of group: [TelemetrySeries], now: TimeInterval
  ) -> Double? {
    guard let first = group.first else { return nil }
    func added(_ values: [Double?]) -> Double? {
      let known = values.compactMap { $0 }
      return known.isEmpty ? nil : known.reduce(0, +)
    }
    if first.kind.isDistribution {
      switch field {
      case .latest, .mean:
        return Distribution.merged(group.compactMap(\.window).filter { $0.sum != nil }).mean
      case .rate:
        return added(group.map { $0.rate(now: now) })
      case .total:
        return nil
      case .count:
        return added(group.map(\.countTotal))
      case .sum:
        return added(group.map(\.sumTotal))
      case .min:
        return group.compactMap { $0.window?.min ?? $0.latest?.distribution?.min }.min()
      case .max:
        return group.compactMap { $0.window?.max ?? $0.latest?.distribution?.max }.max()
      case .percentile(let p):
        if first.kind == .summary {
          guard group.count == 1, let quantiles = first.latest?.distribution?.quantiles else {
            return nil
          }
          return quantiles.first { abs($0.key - p / 100) < 1e-9 }?.value
        }
        return Distribution.merged(group.compactMap(\.window)).percentile(p)
      }
    }
    let gauges = group.filter { $0.kind == .gauge }.flatMap(\.history)
    switch field {
    case .latest:
      return added(group.map { $0.latest?.value })
    case .rate:
      return added(group.map { $0.rate(now: now) })
    case .total:
      return added(group.filter { $0.kind == .sum }.map(\.total))
    case .min:
      return gauges.min()
    case .max:
      return gauges.max()
    case .mean:
      return gauges.isEmpty ? nil : gauges.reduce(0, +) / Double(gauges.count)
    case .count, .sum, .percentile:
      return nil
    }
  }

  /// One series on the help page.
  func jsonObject(now: TimeInterval) -> [String: Any] {
    func number(_ value: Double?) -> Any {
      guard let value, value.isFinite else { return NSNull() }
      return value
    }
    var object: [String: Any] = [
      "attributes": attributes,
      "resource": resource,
      "scope": scope,
      "latest": number(Self.aggregate(.latest, of: [self], now: now)),
      "rate": number(rate(now: now)),
      "total": number(total),
      "history": history.filter(\.isFinite),
      "updated_ms": receivedWallMs,
      "time_ms": latest.map { Double($0.timeNs) / 1_000_000 } ?? NSNull(),
      "quiet": isQuiet(now: now),
      "updates": updates,
    ]
    if kind.isDistribution {
      object["count"] = number(countTotal)
      object["sum"] = number(sumTotal)
      object["mean"] = number(window?.mean)
      object["min"] = number(Self.aggregate(.min, of: [self], now: now))
      object["max"] = number(Self.aggregate(.max, of: [self], now: now))
      for p in [50.0, 90.0, 99.0] {
        object["p\(Int(p))"] = number(Self.aggregate(.percentile(p), of: [self], now: now))
      }
    }
    return object
  }
}

/// One received log record as the help page lists it.
struct TelemetryLogEntry {
  /// Longest body kept, in characters.
  static let maxBodyLength = 4096

  var timeMs: Double
  var severityNumber: Int
  var severity: String
  var body: String
  var attributes: [String: String]
  var service: String
  var scope: String
  var traceID: String
  var spanID: String
  var event: String

  init(
    _ record: Opentelemetry_Proto_Logs_V1_LogRecord, service: String, scope: String,
    receivedMs: Int64
  ) {
    let time =
      record.timeUnixNano != 0 ? record.timeUnixNano : record.observedTimeUnixNano
    timeMs = time != 0 ? Double(time) / 1_000_000 : Double(receivedMs)
    severityNumber = record.severityNumber.rawValue
    severity =
      record.severityText.isEmpty
      ? Self.severityName(severityNumber) : String(record.severityText.prefix(32))
    body = record.hasBody ? OTLPValues.string(record.body, limit: Self.maxBodyLength) : ""
    attributes = OTLPValues.attributes(record.attributes)
    self.service = service
    self.scope = scope
    traceID = record.traceID.count == 16 ? OTLPCodec.hexString(record.traceID) : ""
    spanID = record.spanID.count == 8 ? OTLPCodec.hexString(record.spanID) : ""
    event = String(record.eventName.prefix(256))
  }

  /// OTLP's severity ranges: 1–4 trace … 21–24 fatal.
  static func severityName(_ number: Int) -> String {
    switch number {
    case 1...4: return "TRACE"
    case 5...8: return "DEBUG"
    case 9...12: return "INFO"
    case 13...16: return "WARN"
    case 17...20: return "ERROR"
    case 21...24: return "FATAL"
    default: return ""
    }
  }

  var jsonObject: [String: Any] {
    [
      "time_ms": timeMs, "severity": severity, "severity_number": severityNumber, "body": body,
      "attributes": attributes, "service": service, "scope": scope, "trace_id": traceID,
      "span_id": spanID, "event": event,
    ]
  }
}

/// One received span as the help page lists it.
struct TelemetrySpanEntry {
  var traceID: String
  var spanID: String
  var parentSpanID: String
  var name: String
  var kind: String
  var startNs: UInt64
  var endNs: UInt64
  var status: String
  var statusMessage: String
  var attributes: [String: String]
  var events: Int
  var service: String
  var scope: String

  /// Nil for a span whose trace or span id is missing or the wrong length:
  /// OTLP rejects it.
  init?(_ span: Opentelemetry_Proto_Trace_V1_Span, service: String, scope: String) {
    guard span.traceID.count == 16, span.spanID.count == 8,
      span.traceID.contains(where: { $0 != 0 }), span.spanID.contains(where: { $0 != 0 })
    else { return nil }
    traceID = OTLPCodec.hexString(span.traceID)
    spanID = OTLPCodec.hexString(span.spanID)
    parentSpanID = span.parentSpanID.count == 8 ? OTLPCodec.hexString(span.parentSpanID) : ""
    name = String(span.name.prefix(256))
    switch span.kind {
    case .internal: kind = "internal"
    case .server: kind = "server"
    case .client: kind = "client"
    case .producer: kind = "producer"
    case .consumer: kind = "consumer"
    default: kind = "unspecified"
    }
    startNs = span.startTimeUnixNano
    endNs = max(span.endTimeUnixNano, span.startTimeUnixNano)
    switch span.status.code {
    case .ok: status = "ok"
    case .error: status = "error"
    default: status = "unset"
    }
    statusMessage = String(span.status.message.prefix(OTLPValues.maxValueLength))
    attributes = OTLPValues.attributes(span.attributes)
    events = span.events.count
    self.service = service
    self.scope = scope
  }

  var jsonObject: [String: Any] {
    [
      "trace_id": traceID, "span_id": spanID, "parent_span_id": parentSpanID, "name": name,
      "kind": kind, "start_ms": Double(startNs) / 1_000_000,
      "duration_ms": Double(endNs - startNs) / 1_000_000, "status": status,
      "status_message": statusMessage, "attributes": attributes, "events": events,
      "service": service, "scope": scope,
    ]
  }
}
