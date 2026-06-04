import Foundation

/// Single sink for the app's stderr diagnostics. Every line is
/// formatted as `"[LEVEL] subsystem message\n"` so log scraping is
/// uniform across stderr and the file mirror.
///
/// Always writes to stderr (subject to the configured `minLevel`);
/// also appends to `~/Library/Logs/Flash/flash.log` when
/// `mirrorEnabled` is true. Toggled by `debug.dump_logs` via
/// `AppMonitor.configureLogging`.
///
/// File writes are dispatched onto a dedicated background queue so
/// a slow disk never blocks the activation hot path.
enum FlashLog {
  /// Severity ordering. The configured `minLevel` is the floor —
  /// messages below it are dropped before any string interpolation
  /// runs (autoclosure args stay un-evaluated).
  enum Level: Int, Comparable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    /// Six-character padded tag so columns line up across levels
    /// when scanning the file or stderr.
    var tag: String {
      switch self {
      case .debug: return "[DEBUG]"
      case .info: return "[INFO] "
      case .warn: return "[WARN] "
      case .error: return "[ERROR]"
      }
    }

    /// Permissive parser — accepts the canonical lowercase names
    /// plus `warning` (synonym for `warn`) since both spellings
    /// turn up in other tools' configs.
    static func parse(_ s: String) -> Level? {
      switch s.lowercased() {
      case "debug": return .debug
      case "info": return .info
      case "warn", "warning": return .warn
      case "error": return .error
      default: return nil
      }
    }
  }

  private static let lock = NSLock()
  private static var mirrorEnabled: Bool = false
  private static var minLevel: Level = .info
  private static var handle: FileHandle?
  private static let writeQueue =
    DispatchQueue(label: "flash.log.write", qos: .utility)

  static func setLevel(_ level: Level) {
    lock.lock()
    minLevel = level
    lock.unlock()
  }

  static func setMirrorToFile(_ enabled: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if enabled == mirrorEnabled { return }
    mirrorEnabled = enabled
    if enabled {
      handle = openLogFile()
    } else {
      let stale = handle
      handle = nil
      writeQueue.async { try? stale?.close() }
    }
  }

  static func debug(_ message: @autoclosure () -> String) {
    emit(.debug, message)
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

  private static func emit(
    _ level: Level, _ message: () -> String
  ) {
    lock.lock()
    let pass = level >= minLevel
    let mirror = mirrorEnabled
    let h = handle
    lock.unlock()
    guard pass else { return }
    var line = "\(level.tag) \(message())"
    // Callers used to terminate their own strings inconsistently
    // (some `\n`, some bare). Normalise here so every line in
    // stderr and the file mirror ends with exactly one newline.
    if !line.hasSuffix("\n") { line.append("\n") }
    fputs(line, stderr)
    guard mirror, let h, let data = line.data(using: .utf8) else { return }
    writeQueue.async {
      try? h.write(contentsOf: data)
    }
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
