import Darwin
import Foundation

/// Single sink for the app's diagnostics. Every emitted line is one
/// compact JSON object, written to stderr and appended to
/// `~/Library/Logs/Flash/flash.log`.
///
/// The calling thread only decides whether the record passes and builds the
/// record value; JSON encoding, the stderr write, and the file append all run
/// on one background I/O queue so the input hot path never blocks on a
/// `write(2)`. A suppressed call costs one lock round trip and no allocation:
/// the message autoclosure is not evaluated and the default `source` is
/// derived from `StaticString` literals only for records that pass.
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
  private static let pid = Int(getpid())
  /// Serial queue owning every byte of log output (stderr and file).
  private static let ioQueue = DispatchQueue(label: "flash.log.io", qos: .utility)
  static let defaultLogFileURL: URL? = {
    guard NSClassFromString("XCTestCase") == nil else { return nil }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/Flash/flash.log")
  }()
  private static let fileWriter = defaultLogFileURL.map {
    FlashLogFileWriter(url: $0, queue: ioQueue)
  }

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

  /// Block until every record emitted so far has been written out.
  static func flush() {
    ioQueue.sync {}
  }

  static func coreSource(fileID: StaticString, function: StaticString) -> String {
    let fileID = fileID.description
    let file = fileID.split(separator: "/").last.map(String.init) ?? fileID
    return "core:\(file).\(function)"
  }

  static func debug(
    _ message: @autoclosure () -> String,
    fields: [String: String] = [:],
    source: String? = nil,
    fileID: StaticString = #fileID,
    function: StaticString = #function
  ) {
    emit(.debug, source: source, fileID: fileID, function: function, fields: fields, message)
  }
  static func trace(
    _ message: @autoclosure () -> String,
    fields: [String: String] = [:],
    source: String? = nil,
    fileID: StaticString = #fileID,
    function: StaticString = #function
  ) {
    emit(.trace, source: source, fileID: fileID, function: function, fields: fields, message)
  }
  static func info(
    _ message: @autoclosure () -> String,
    fields: [String: String] = [:],
    source: String? = nil,
    fileID: StaticString = #fileID,
    function: StaticString = #function
  ) {
    emit(.info, source: source, fileID: fileID, function: function, fields: fields, message)
  }
  static func warn(
    _ message: @autoclosure () -> String,
    fields: [String: String] = [:],
    source: String? = nil,
    fileID: StaticString = #fileID,
    function: StaticString = #function
  ) {
    emit(.warn, source: source, fileID: fileID, function: function, fields: fields, message)
  }
  static func plugin(
    _ level: Level,
    pluginID: String,
    message: @autoclosure () -> String,
    fields: [String: String] = [:]
  ) {
    emit(level, source: "plugin:\(pluginID)", fileID: #fileID, function: #function, fields: fields, message)
  }

  private static func emit(
    _ level: Level,
    source: String?,
    fileID: StaticString,
    function: StaticString,
    fields: [String: String],
    _ message: () -> String
  ) {
    lock.lock()
    let pass = level >= minLevel
    let hasSinks = !sinks.isEmpty
    lock.unlock()
    guard pass || hasSinks else { return }
    let record = Record(
      level: level,
      source: source ?? coreSource(fileID: fileID, function: function),
      message: message(),
      fields: fields,
      pid: pid,
      timeUnixMs: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
    if hasSinks {
      lock.lock()
      let sinkSnapshot = Array(sinks.values)
      lock.unlock()
      for sink in sinkSnapshot {
        sink(record)
      }
    }
    guard pass else { return }
    ioQueue.async {
      let line = jsonLineData(record)
      line.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        _ = fwrite(base, 1, bytes.count, stderr)
      }
      fileWriter?.writeOnQueue(line)
    }
  }

  /// One newline-terminated JSON object, encoded exactly once.
  static func jsonLineData(_ record: Record) -> Data {
    let object = record.jsonObject
    guard
      var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else {
      return Data(
        "{\"level\":\"error\",\"message\":\"log serialization failed\",\"source\":\"core:FlashLog\"}\n"
          .utf8)
    }
    data.append(0x0A)
    return data
  }

}

final class FlashLogFileWriter {
  private let url: URL
  private let rotationByteLimit: UInt64
  private let rotationKeep: Int
  private let queue: DispatchQueue
  private var handle: FileHandle?
  private var bytesWritten: UInt64 = 0

  init(
    url: URL,
    rotationByteLimit: UInt64 = 10 * 1024 * 1024,
    rotationKeep: Int = 3,
    queue: DispatchQueue = DispatchQueue(label: "flash.log.write", qos: .utility)
  ) {
    precondition(rotationByteLimit > 0 && rotationKeep > 0)
    self.url = url
    self.rotationByteLimit = rotationByteLimit
    self.rotationKeep = rotationKeep
    self.queue = queue
  }

  func append(_ data: Data) {
    queue.async { [self] in
      writeOnQueue(data)
    }
  }

  /// Append from a block already running on this writer's queue.
  func writeOnQueue(_ data: Data) {
    dispatchPrecondition(condition: .onQueue(queue))
    openIfNeeded()
    guard let handle else { return }
    do { try handle.write(contentsOf: data) } catch { return }
    bytesWritten &+= UInt64(data.count)
    if bytesWritten >= rotationByteLimit { rotate() }
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
