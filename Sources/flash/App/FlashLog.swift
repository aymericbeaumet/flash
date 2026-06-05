import Foundation

/// Single sink for the app's diagnostics. Every emitted line is one
/// compact JSON object, written to stderr and appended to
/// `~/Library/Logs/Flash/flash.log`.
///
/// File writes are dispatched onto a dedicated background queue so a
/// slow disk never blocks the activation hot path.
enum FlashLog {
  /// Severity ordering. The configured `minLevel` is the floor —
  /// messages below it are dropped before any string interpolation
  /// runs (autoclosure args stay un-evaluated).
  enum Level: Int, Comparable {
    case trace = 0
    case debug = 1
    case info = 2
    case warn = 3
    case error = 4
    case fatal = 5

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var name: String {
      switch self {
      case .trace: return "trace"
      case .debug: return "debug"
      case .info: return "info"
      case .warn: return "warn"
      case .error: return "error"
      case .fatal: return "fatal"
      }
    }

    /// Permissive parser — accepts the canonical lowercase names
    /// plus `warning` (synonym for `warn`) since both spellings
    /// turn up in other tools' configs.
    static func parse(_ s: String) -> Level? {
      switch s.lowercased() {
      case "trace": return .trace
      case "debug": return .debug
      case "info": return .info
      case "warn", "warning": return .warn
      case "error": return .error
      case "fatal": return .fatal
      default: return nil
      }
    }
  }

  private static let lock = NSLock()
  private static var minLevel: Level = .info
  private static var handle: FileHandle?
  private static let writeQueue =
    DispatchQueue(label: "flash.log.write", qos: .utility)

  static func setLevel(_ level: Level) {
    lock.lock()
    minLevel = level
    lock.unlock()
  }

  static func debug(_ message: @autoclosure () -> String) {
    emit(.debug, message)
  }
  static func trace(_ message: @autoclosure () -> String) {
    emit(.trace, message)
  }
  static func info(_ message: @autoclosure () -> String) {
    emit(.info, message)
  }
  static func warn(_ message: @autoclosure () -> String) {
    emit(.warn, message)
  }
  static func error(_ message: @autoclosure () -> String) {
    emit(.error, message)
  }
  static func fatal(_ message: @autoclosure () -> String) {
    emit(.fatal, message)
  }

  private static func emit(
    _ level: Level, _ message: () -> String
  ) {
    lock.lock()
    let pass = level >= minLevel
    if pass, handle == nil {
      handle = openLogFile()
    }
    let h = handle
    lock.unlock()
    guard pass else { return }
    let line = jsonLine(level: level, message: message())
    fputs(line, stderr)
    guard let h, let data = line.data(using: .utf8) else { return }
    writeQueue.async {
      try? h.write(contentsOf: data)
    }
  }

  private static func jsonLine(level: Level, message: String) -> String {
    let object: [String: Any] = [
      "level": level.name,
      "message": message,
      "pid": Int(ProcessInfo.processInfo.processIdentifier),
      "time_unix_ms": Int64((Date().timeIntervalSince1970 * 1000).rounded()),
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      var line = String(data: data, encoding: .utf8)
    else {
      return "{\"level\":\"\(level.name)\",\"message\":\"log serialization failed\"}\n"
    }
    line.append("\n")
    return line
  }

  private static func openLogFile() -> FileHandle? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let url = home.appendingPathComponent("Library/Logs/Flash/flash.log")
    let fm = FileManager.default
    try? fm.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    if !fm.fileExists(atPath: url.path) {
      fm.createFile(atPath: url.path, contents: nil)
    }
    guard let h = try? FileHandle(forWritingTo: url) else { return nil }
    _ = try? h.seekToEnd()
    return h
  }
}
