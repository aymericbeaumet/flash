import Foundation

/// How a metric aggregates: the one vocabulary for Flash's own instruments,
/// metrics a script records, and how the store and the exporter treat both.
enum MetricKind: String, CaseIterable, Hashable {
  /// The latest value wins: a temperature, a queue length.
  case gauge
  /// Each value is an increment, never negative: requests, bytes, errors.
  case counter
  /// Each value is one observation of a distribution: a duration, a size.
  case histogram
}

/// What a metric stream is, whoever records it: its name, kind, unit,
/// description and, for a histogram, its bucket bounds.
struct MetricInstrument: Hashable {
  var name: String
  var kind: MetricKind
  var unit: String
  var summary: String
  /// A histogram's explicit bucket upper bounds; empty for other kinds.
  var bounds: [Double]

  init(
    name: String, kind: MetricKind, unit: String = "", summary: String = "", bounds: [Double]? = nil
  ) {
    self.name = name
    self.kind = kind
    self.unit = unit
    self.summary = summary
    self.bounds = kind == .histogram ? (bounds ?? MetricRecord.defaultBounds) : []
  }
}

/// One measurement recorded through Flash rather than received over OTLP:
/// `metrics record` from a script, the command line or a mapping. It lands in
/// the same store the receiver fills, so `#{flash.otel:<name>}` and monitors
/// read it, and the exporter sends it with Flash's own metrics.
struct MetricRecord: Hashable {
  var instrument: MetricInstrument
  var value: Double
  var attributes: [String: String]

  var name: String { instrument.name }
  var kind: MetricKind { instrument.kind }

  /// The scope recorded metrics carry in the store, telling them apart from
  /// what the receiver ingests and from Flash's own instruments.
  static let recordedScope = "flash.metrics.record"
  /// The scope Flash's own instruments carry when a surface reads them.
  static let instrumentScope = "flash"

  /// OpenTelemetry's default explicit bucket bounds, for a recorded
  /// histogram.
  static let defaultBounds: [Double] = [
    0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000,
  ]

  /// Attributes one recording may carry: what keeps a script from turning
  /// one metric into an unbounded number of series.
  static let maxAttributes = 16
  static let maxAttributeValueLength = 256
  static let maxUnitLength = 63

  /// A recording, or why it is refused.
  static func make(
    name: String, value rawValue: String, kind rawKind: String?, unit: String?,
    attributes rawAttributes: String?
  ) -> Result<MetricRecord, MetricRecordError> {
    if let problem = MetricNaming.problem(name: name) { return .failure(.init(problem)) }
    if name.hasPrefix(MetricNaming.reservedPrefix) {
      return .failure(.init("names starting with \(MetricNaming.reservedPrefix) are Flash's own"))
    }
    let kind: MetricKind
    if let rawKind {
      guard let parsed = MetricKind(rawValue: rawKind) else {
        return .failure(.init("kind must be gauge, counter or histogram"))
      }
      kind = parsed
    } else {
      kind = .gauge
    }
    guard let value = Double(rawValue.trimmed), value.isFinite else {
      return .failure(.init("value must be a finite number"))
    }
    if kind == .counter, value < 0 {
      return .failure(.init("a counter only goes up: its value is an increment of 0 or more"))
    }
    let unit = unit?.trimmed ?? ""
    if unit.count > maxUnitLength
      || unit.unicodeScalars.contains(where: { !(32...126).contains($0.value) })
    {
      return .failure(.init("unit must be printable ASCII of at most \(maxUnitLength) characters"))
    }
    let attributes: [String: String]
    switch MetricNaming.attributes(rawAttributes ?? "") {
    case .success(let parsed): attributes = parsed
    case .failure(let error): return .failure(error)
    }
    return .success(
      MetricRecord(
        instrument: MetricInstrument(name: name, kind: kind, unit: unit),
        value: value, attributes: attributes))
  }

  /// The words that record it again, after `metrics record`.
  var argTokens: [String] {
    var tokens = ["--name=\(name)", "--value=\(TelemetryNumber.format(value))"]
    if kind != .gauge { tokens.append("--kind=\(kind.rawValue)") }
    if !instrument.unit.isEmpty { tokens.append("--unit=\(instrument.unit)") }
    if !attributes.isEmpty {
      tokens.append("--attributes=\(MetricNaming.attributeText(attributes))")
    }
    return tokens
  }

  var explanation: String {
    switch kind {
    case .gauge: return "Records \(TelemetryNumber.format(value)) as the \(name) gauge."
    case .counter: return "Adds \(TelemetryNumber.format(value)) to the \(name) counter."
    case .histogram:
      return "Records \(TelemetryNumber.format(value)) as one \(name) observation."
    }
  }
}

struct MetricRecordError: Error, Equatable, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

/// The one naming rule for metrics Flash records and attributes they carry,
/// in the OpenTelemetry semantic-conventions style: lowercase dotted
/// segments (`build.duration`, `disk.free`), each a letter then letters,
/// digits and underscores. `flash.` belongs to Flash's own instruments.
enum MetricNaming {
  static let reservedPrefix = "flash."
  static let maxNameLength = 255
  static let maxAttributeKeyLength = 64

  /// Why `name` is not a metric name, or nil when it is.
  static func problem(name: String) -> String? {
    guard !name.isEmpty, name.count <= maxNameLength else {
      return "name must be 1 to \(maxNameLength) characters"
    }
    guard isDotted(name) else {
      return "name must be lowercase dotted words such as build.duration: "
        + "each a letter then letters, digits or _"
    }
    return nil
  }

  /// `key=value,key=value`: keys are dotted names, values any text without
  /// a comma, at most `MetricRecord.maxAttributes` pairs.
  static func attributes(_ text: String) -> Result<[String: String], MetricRecordError> {
    let trimmed = text.trimmed
    guard !trimmed.isEmpty else { return .success([:]) }
    var result: [String: String] = [:]
    for pair in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
      let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else {
        return .failure(.init("attributes must be key=value pairs separated by commas"))
      }
      let key = String(parts[0]).trimmed
      let value = String(parts[1]).trimmed
      guard key.count <= maxAttributeKeyLength, isDotted(key) else {
        return .failure(.init("attribute \(key) must be a lowercase dotted name such as host.name"))
      }
      guard value.count <= MetricRecord.maxAttributeValueLength,
        !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
      else {
        return .failure(
          .init(
            "attribute \(key)'s value must be at most \(MetricRecord.maxAttributeValueLength) characters"
          ))
      }
      guard result[key] == nil else { return .failure(.init("attribute \(key) is repeated")) }
      result[key] = value
    }
    guard result.count <= MetricRecord.maxAttributes else {
      return .failure(.init("at most \(MetricRecord.maxAttributes) attributes"))
    }
    return .success(result)
  }

  /// `attributes` back as `key=value,…`, keys sorted.
  static func attributeText(_ attributes: [String: String]) -> String {
    attributes.keys.sorted().map { "\($0)=\(attributes[$0] ?? "")" }.joined(separator: ",")
  }

  private static func isDotted(_ text: String) -> Bool {
    let segments = text.split(separator: ".", omittingEmptySubsequences: false)
    return segments.allSatisfy { segment in
      guard let first = segment.unicodeScalars.first, ("a"..."z").contains(first) else {
        return false
      }
      return segment.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
      }
    }
  }
}
