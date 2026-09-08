import Darwin
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
  private static var sinks: [UUID: Sink] = [:]
  static let defaultLogFileURL: URL? = {
    guard NSClassFromString("XCTestCase") == nil else { return nil }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Flash/flash.log")
  }()
  private static let fileWriter = defaultLogFileURL.map { FlashLogFileWriter(url: $0) }

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
    if let data = line.data(using: .utf8) { fileWriter?.append(data) }
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

}

final class FlashLogFileWriter {
  private let url: URL
  private let rotationByteLimit: UInt64
  private let rotationKeep: Int
  private let queue = DispatchQueue(label: "flash.log.write", qos: .utility)
  private var handle: FileHandle?
  private var bytesWritten: UInt64 = 0

  init(url: URL, rotationByteLimit: UInt64 = 10 * 1024 * 1024, rotationKeep: Int = 3) {
    precondition(rotationByteLimit > 0 && rotationKeep > 0)
    self.url = url
    self.rotationByteLimit = rotationByteLimit
    self.rotationKeep = rotationKeep
  }

  func append(_ data: Data) {
    queue.async { [self] in
      openIfNeeded()
      guard let handle else { return }
      do { try handle.write(contentsOf: data) } catch { return }
      bytesWritten &+= UInt64(data.count)
      if bytesWritten >= rotationByteLimit { rotate() }
    }
  }

  func flush() { queue.sync {} }

  private func openIfNeeded() {
    guard handle == nil else { return }
    let fm = FileManager.default
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return }
    handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let attributes = try? fm.attributesOfItem(atPath: url.path)
    bytesWritten = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  private func rotate() {
    let fm = FileManager.default
    let base = url.deletingLastPathComponent()
    let name = url.lastPathComponent
    let oldest = base.appendingPathComponent("\(name).\(rotationKeep)")
    try? fm.removeItem(at: oldest)
    for index in stride(from: rotationKeep - 1, through: 1, by: -1) {
      let from = base.appendingPathComponent("\(name).\(index)")
      let to = base.appendingPathComponent("\(name).\(index + 1)")
      try? fm.moveItem(at: from, to: to)
    }
    do {
      try fm.moveItem(at: url, to: base.appendingPathComponent("\(name).1"))
    } catch {
      bytesWritten = 0
      return
    }
    try? handle?.close()
    handle = nil
    openIfNeeded()
  }
}
