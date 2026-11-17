import Foundation

/// One number read from the metrics the OTLP receiver holds, written in a
/// status format as
///
///     #{flash.otel:<metric>}
///     #{flash.otel.<field>:<metric>[<attribute>=<value>][<attribute>!=<value>]…}
///
/// The whole text between `#{` and `}` is an ordinary value name: tmux reads
/// no modifier from it (a modifier list never starts with `f`), so the form
/// expands to nothing under tmux and needs no change to the shared language.
/// It holds no `,`, `#`, `{` or `}`, so it also sits inside a conditional or
/// a comparison unchanged.
struct TelemetryQuery: Hashable {
  /// What the value reports; see `docs/telemetry.md` for each per kind.
  enum Field: Hashable, CustomStringConvertible {
    /// A gauge's or sum's latest point; a histogram's latest mean.
    case latest
    /// Per second over the latest reporting interval; 0 once the series
    /// stopped reporting.
    case rate
    /// A sum's running total.
    case total
    /// A histogram's or summary's observation count.
    case count
    /// A histogram's or summary's sum of observations.
    case sum
    case min
    case max
    case mean
    /// A percentile, strictly between 0 and 100 (`p50`, `p99.9`).
    case percentile(Double)

    init?(_ text: String) {
      switch text {
      case "latest": self = .latest
      case "rate": self = .rate
      case "total": self = .total
      case "count": self = .count
      case "sum": self = .sum
      case "min": self = .min
      case "max": self = .max
      case "mean": self = .mean
      default:
        let digits = text.dropFirst()
        guard text.first == "p", !digits.isEmpty,
          digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
          digits.first != ".", digits.last != ".",
          digits.filter({ $0 == "." }).count <= 1,
          let value = Double(digits), value > 0, value < 100
        else { return nil }
        self = .percentile(value)
      }
    }

    var description: String {
      switch self {
      case .latest: return "latest"
      case .rate: return "rate"
      case .total: return "total"
      case .count: return "count"
      case .sum: return "sum"
      case .min: return "min"
      case .max: return "max"
      case .mean: return "mean"
      case .percentile(let value): return "p" + TelemetryNumber.format(value)
      }
    }
  }

  /// `[key=value]` keeps the series whose attribute `key` matches `value`;
  /// `[key!=value]` the others. `*` in the value matches any run of
  /// characters. An empty value matches a missing or empty attribute.
  struct Filter: Hashable {
    var key: String
    var pattern: String
    var negated: Bool

    func matches(_ attributes: [String: String]) -> Bool {
      Self.glob(pattern, attributes[key] ?? "") != negated
    }

    /// `*` matches any run; every other character matches itself.
    static func glob(_ pattern: String, _ text: String) -> Bool {
      let pattern = Array(pattern.unicodeScalars)
      let text = Array(text.unicodeScalars)
      var p = 0
      var t = 0
      var star: Int?
      var resume = 0
      while t < text.count {
        if p < pattern.count, pattern[p] != "*", pattern[p] == text[t] {
          p += 1
          t += 1
        } else if p < pattern.count, pattern[p] == "*" {
          star = p
          resume = t
          p += 1
        } else if let star {
          p = star + 1
          resume += 1
          t = resume
        } else {
          return false
        }
      }
      while p < pattern.count, pattern[p] == "*" { p += 1 }
      return p == pattern.count
    }
  }

  static let prefix = "flash.otel"

  var field: Field
  var metric: String
  var filters: [Filter]

  init(field: Field = .latest, metric: String, filters: [Filter] = []) {
    self.field = field
    self.metric = metric
    self.filters = filters
  }

  /// Whether a status-format value name is meant as this form; a malformed
  /// one is reported at load and expands to nothing.
  static func isTelemetryKey(_ key: String) -> Bool {
    key.hasPrefix(prefix + ":") || key.hasPrefix(prefix + ".")
  }

  /// Parses a value name; nil when it is not a well-formed telemetry value.
  init?(key: String) {
    guard Self.isTelemetryKey(key), let colon = key.firstIndex(of: ":") else { return nil }
    let head = key[..<colon]
    if head == Substring(Self.prefix) {
      field = .latest
    } else {
      guard let parsed = Field(String(head.dropFirst(Self.prefix.count + 1))) else { return nil }
      field = parsed
    }
    var rest = key[key.index(after: colon)...]
    let nameEnd = rest.firstIndex(of: "[") ?? rest.endIndex
    let name = rest[..<nameEnd]
    guard !name.isEmpty, name.unicodeScalars.allSatisfy(Self.isMetricNameScalar) else { return nil }
    metric = String(name)
    rest = rest[nameEnd...]
    filters = []
    while !rest.isEmpty {
      guard rest.first == "[", let close = rest.firstIndex(of: "]") else { return nil }
      let body = rest[rest.index(after: rest.startIndex)..<close]
      guard !body.contains("["), let equals = body.firstIndex(of: "=") else { return nil }
      var keyPart = body[..<equals]
      let negated = keyPart.last == "!"
      if negated { keyPart = keyPart.dropLast() }
      guard !keyPart.isEmpty,
        keyPart.unicodeScalars.allSatisfy({
          !"!=[]".unicodeScalars.contains($0) && !$0.properties.isWhitespace
        })
      else { return nil }
      filters.append(
        Filter(
          key: String(keyPart), pattern: String(body[body.index(after: equals)...]),
          negated: negated))
      rest = rest[rest.index(after: close)...]
    }
  }

  /// OpenTelemetry instrument names (`[A-Za-z0-9_.\-/]`), plus `:` for
  /// names that come from Prometheus.
  private static func isMetricNameScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar.isASCII
      && (CharacterSet.alphanumerics.contains(scalar) || "_.-/:".unicodeScalars.contains(scalar))
  }

  func matches(_ attributes: [String: String]) -> Bool {
    filters.allSatisfy { $0.matches(attributes) }
  }
}

enum TelemetryNumber {
  /// A value as a status format shows it: whole numbers without a point,
  /// others with at most six decimals and no trailing zeros; empty for a
  /// value that is not finite.
  static func format(_ value: Double) -> String {
    guard value.isFinite else { return "" }
    if value == value.rounded(), abs(value) < 1e15 {
      return value == 0 ? "0" : String(Int64(value))
    }
    var text = String(format: "%.6f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text == "-0" ? "0" : text
  }
}
