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

  struct Record {
    var level: Level
    var source: String
    var message: String
    var fields: [String: String]
    var pid: Int
    var timeUnixMs: Int64

    var jsonObject: [String: Any] {
      var object: [String: Any] = [
        "level": level.name,
        "message": message,
        "pid": pid,
        "source": source,
        "time_unix_ms": timeUnixMs,
      ]
      if !fields.isEmpty {
        object["fields"] = fields
      }
      return object
    }
  }

  typealias Sink = (Record) -> Void

  private static let lock = NSLock()
  private static var minLevel: Level = .info
  private static var handle: FileHandle?
  private static var sinks: [UUID: Sink] = [:]
  private static let writeQueue =
    DispatchQueue(label: "flash.log.write", qos: .utility)

  /// Rotate `flash.log` when it exceeds this size. Trace-level logs (which can
  /// include AX tree dumps) can balloon quickly; without rotation the file
  /// grows unbounded across a long-running resident session.
  private static let rotationByteLimit: UInt64 = 10 * 1024 * 1024
  /// Number of rotated segments kept beside `flash.log` (`flash.log.1` …
  /// `flash.log.N`). Anything older is deleted on rotation.
  private static let rotationKeep = 3
  private static var bytesWrittenSinceRotation: UInt64 = 0

  static func setLevel(_ level: Level) {
    lock.lock()
    minLevel = level
    lock.unlock()
  }

  static func addSink(_ sink: @escaping Sink) -> UUID {
    let id = UUID()
    lock.lock()
    sinks[id] = sink
    lock.unlock()
    return id
  }

  static func removeSink(_ id: UUID) {
    lock.lock()
    sinks.removeValue(forKey: id)
    lock.unlock()
  }

  static func wouldEmit(_ level: Level) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return level >= minLevel || !sinks.isEmpty
  }

  static func coreSource(fileID: String, function: String) -> String {
    let file = fileID.split(separator: "/").last.map(String.init) ?? fileID
    return "core:\(file).\(function)"
  }

  static func debug(
    _ message: @autoclosure () -> String,
    fields: [String: String] = [:],
    source: String = FlashLog.coreSource(fileID: #fileID, function: #function)
  ) {
    emit(.debug, source: source, fields: fields, message)
  }
  static func trace(
    _ message: @autoclosure () -> String,
    fields: [String: String] = [:],
    source: String = FlashLog.coreSource(fileID: #fileID, function: #function)
  ) {
    emit(.trace, source: source, fields: fields, message)
  }
  static func info(
    _ message: @autoclosure () -> String,
    fields: [String: String] = [:],
    source: String = FlashLog.coreSource(fileID: #fileID, function: #function)
  ) {
    emit(.info, source: source, fields: fields, message)
  }
  static func warn(
    _ message: @autoclosure () -> String,
    fields: [String: String] = [:],
    source: String = FlashLog.coreSource(fileID: #fileID, function: #function)
  ) {
    emit(.warn, source: source, fields: fields, message)
  }
  static func error(
    _ message: @autoclosure () -> String,
    fields: [String: String] = [:],
    source: String = FlashLog.coreSource(fileID: #fileID, function: #function)
  ) {
    emit(.error, source: source, fields: fields, message)
  }
  static func fatal(
    _ message: @autoclosure () -> String,
    fields: [String: String] = [:],
    source: String = FlashLog.coreSource(fileID: #fileID, function: #function)
  ) {
    emit(.fatal, source: source, fields: fields, message)
  }

  static func plugin(
    _ level: Level,
    pluginID: String,
    message: @autoclosure () -> String,
    fields: [String: String] = [:]
  ) {
    emit(level, source: "plugin:\(pluginID)", fields: fields, message)
  }

  private static func emit(
    _ level: Level,
    source: String,
    fields: [String: String],
    _ message: () -> String
  ) {
    lock.lock()
    let pass = level >= minLevel
    if pass, handle == nil {
      handle = openLogFile()
    }
    let h = handle
    let sinkSnapshot = Array(sinks.values)
    lock.unlock()
    guard pass || !sinkSnapshot.isEmpty else { return }
    let record = Record(
      level: level,
      source: source,
      message: message(),
      fields: fields,
      pid: Int(ProcessInfo.processInfo.processIdentifier),
      timeUnixMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
    let line = jsonLine(record)
    for sink in sinkSnapshot {
      sink(record)
    }
    guard pass else { return }
    fputs(line, stderr)
    guard let h, let data = line.data(using: .utf8) else { return }
    writeQueue.async {
      try? h.write(contentsOf: data)
      bytesWrittenSinceRotation &+= UInt64(data.count)
      if bytesWrittenSinceRotation >= rotationByteLimit {
        rotateIfNeeded()
      }
    }
  }

  /// Off the write queue: if `flash.log` has grown past `rotationByteLimit`,
  /// shift `flash.log.(N-1) → flash.log.N` through `flash.log → flash.log.1`
  /// and reopen a fresh handle. Failures are best-effort; if rotation can't
  /// happen we keep writing to the existing handle rather than losing entries.
  private static func rotateIfNeeded() {
    guard let url = logFileURL() else {
      bytesWrittenSinceRotation = 0
      return
    }
    let fm = FileManager.default
    let attrs = try? fm.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    guard size >= rotationByteLimit else {
      bytesWrittenSinceRotation = 0
      return
    }
    let base = url.deletingLastPathComponent()
    let name = url.lastPathComponent
    // Drop the oldest, then shift each rotated segment up by one.
    let oldest = base.appendingPathComponent("\(name).\(rotationKeep)")
    try? fm.removeItem(at: oldest)
    for index in stride(from: rotationKeep - 1, through: 1, by: -1) {
      let from = base.appendingPathComponent("\(name).\(index)")
      let to = base.appendingPathComponent("\(name).\(index + 1)")
      _ = try? fm.moveItem(at: from, to: to)
    }
    let firstRotated = base.appendingPathComponent("\(name).1")
    _ = try? fm.moveItem(at: url, to: firstRotated)
    lock.lock()
    try? handle?.close()
    handle = openLogFile()
    lock.unlock()
    bytesWrittenSinceRotation = 0
  }

  private static func logFileURL() -> URL? {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Flash/flash.log")
  }

  static func jsonLine(_ record: Record) -> String {
    let object = record.jsonObject
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      var line = String(data: data, encoding: .utf8)
    else {
      return
        "{\"level\":\"error\",\"message\":\"log serialization failed\",\"source\":\"core:FlashLog\"}\n"
    }
    line.append("\n")
    return line
  }

  private static func openLogFile() -> FileHandle? {
    guard let url = logFileURL() else { return nil }
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
