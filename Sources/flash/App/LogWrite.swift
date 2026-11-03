import FlashCore
import Foundation

/// `logs write` (`:logs write --warn --message=…`): one line from a script, the command line or a mapping into
/// Flash's log, through the same serial writer as Flash's own lines and at
/// the level it names, so `[debug] log_level` filters it like any other. It
/// follows the logging convention (`docs/observability.md`): `[area] text`
/// with values in fields; its source is `user`, which tells it apart from
/// Flash's (`core:…`) and plugins' (`plugin:…`) lines.
struct LogWrite: Hashable {
  var level: FlashLog.Level
  var message: String
  var area: String
  var fields: [String: String]

  static let source = "user"
  static let defaultArea = "user"
  static let maxMessageLength = 4096
  static let maxAreaLength = 32
  /// The levels a script may write, one flag each: `--warn`.
  static let levels: [FlashLog.Level] = [.trace, .debug, .info, .warn, .error]

  /// A line to write, or why it is refused. `levelFlags` are the level
  /// flags the command carried; none is `info`.
  static func make(
    levelFlags: [FlashLog.Level], message: String?, area: String?, fields: String?
  ) -> Result<LogWrite, LogWriteError> {
    guard levelFlags.count <= 1 else {
      return .failure(.init("give one level: --trace, --debug, --info, --warn or --error"))
    }
    let text = (message ?? "").replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").trimmed
    guard !text.isEmpty else { return .failure(.init("logs write needs a --message")) }
    guard text.count <= maxMessageLength else {
      return .failure(.init("a message is at most \(maxMessageLength) characters"))
    }
    let area = area?.trimmed ?? defaultArea
    guard Self.isArea(area) else {
      return .failure(
        .init("--area is a snake_case word such as backup: a letter, then letters, digits or _"))
    }
    let parsed: [String: String]
    switch MetricNaming.attributes(fields ?? "") {
    case .success(let value): parsed = value
    case .failure(let error):
      return .failure(.init(error.description.replacingOccurrences(of: "attribute", with: "field")))
    }
    return .success(
      LogWrite(level: levelFlags.first ?? .info, message: text, area: area, fields: parsed))
  }

  static func isArea(_ area: String) -> Bool {
    guard let first = area.unicodeScalars.first, ("a"..."z").contains(first),
      area.count <= maxAreaLength
    else { return false }
    return area.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
    }
  }

  /// The log message: the area tag, then the text.
  var line: String { "[\(area)] \(message)" }

  var argTokens: [String] {
    var tokens: [String] = []
    if level != .info { tokens.append("--\(level.name)") }
    tokens.append("--message=\(message)")
    if area != Self.defaultArea { tokens.append("--area=\(area)") }
    if !fields.isEmpty { tokens.append("--fields=\(MetricNaming.attributeText(fields))") }
    return tokens
  }

  var explanation: String {
    "Writes “\(message)” to Flash's log at \(level.name)."
  }
}

struct LogWriteError: Error, Equatable, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}
