import Foundation

/// Lightweight activation/precompute profiler.
///
/// The app is headless, so diagnostics go through `FlashLog` — that always
/// writes to stderr, and additionally mirrors to
/// `~/Library/Logs/Flash/flash.log` when `debug.dump_logs` is set.
final class FlashProfiler {
  private struct Mark {
    let name: String
    let elapsedMs: Double
    let stepMs: Double
    let detail: String?
  }

  private static var nextIDValue: UInt64 = 0
  private static let nextIDLock = NSLock()

  private static func nextID() -> UInt64 {
    nextIDLock.lock()
    defer { nextIDLock.unlock() }
    nextIDValue &+= 1
    return nextIDValue
  }

  private let id: UInt64
  private let kind: String
  private let logEveryRun: Bool
  private let slowMs: Double?
  private let startNs: UInt64
  private var lastNs: UInt64
  private var marks: [Mark] = []
  private let lock = NSLock()
  /// Millisecond-precision wall-clock timestamp at the moment this
  /// profiler was created. Used as a stable correlation id across
  /// stderr/file logs and the AX dump for the same activation —
  /// every show_hints trigger gets a unique value.
  let triggerMs: UInt64

  init(kind: String, debug: Config.Debug, slowLogsEnabled: Bool = true) {
    self.id = Self.nextID()
    self.kind = kind
    self.logEveryRun = debug.profile
    self.slowMs = slowLogsEnabled && debug.slowMs > 0 ? Double(debug.slowMs) : nil
    self.startNs = DispatchTime.now().uptimeNanoseconds
    self.lastNs = startNs
    self.triggerMs = UInt64(Date().timeIntervalSince1970 * 1000)
  }

  var isRecording: Bool {
    logEveryRun || slowMs != nil
  }

  func intervalStart() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  func mark(_ name: String, detail: String? = nil) {
    guard isRecording else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    let elapsed = Self.ms(now - startNs)
    let step = Self.ms(now - lastNs)
    lastNs = now
    marks.append(
      Mark(
        name: name,
        elapsedMs: elapsed,
        stepMs: step,
        detail: detail.map(Self.clean)
      ))
    lock.unlock()
  }

  func finishInterval(_ name: String, since start: UInt64, detail: String? = nil) {
    guard isRecording else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    let interval = Self.ms(now - start)
    let suffix: String
    if let detail, !detail.isEmpty {
      suffix = "\(Self.clean(detail)) duration_ms=\(Self.format(interval))"
    } else {
      suffix = "duration_ms=\(Self.format(interval))"
    }
    mark(name, detail: suffix)
  }

  func finish(outcome: String, detail: String? = nil) {
    guard isRecording else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    let total = Self.ms(now - startNs)
    let shouldLog = logEveryRun || slowMs.map { total >= $0 } == true
    guard shouldLog else { return }

    lock.lock()
    let snapshot = marks
    lock.unlock()

    var header =
      "flash: profile trigger=\(triggerMs) kind=\(kind) id=\(id) total_ms=\(Self.format(total)) outcome=\(Self.clean(outcome))"
    if let detail, !detail.isEmpty {
      header += " \(Self.clean(detail))"
    }
    header += "\n"
    FlashLog.write(header)

    for mark in snapshot {
      var line =
        "flash: profile trigger=\(triggerMs) kind=\(kind) id=\(id) elapsed_ms=\(Self.format(mark.elapsedMs)) step_ms=\(Self.format(mark.stepMs)) stage=\(Self.clean(mark.name))"
      if let detail = mark.detail, !detail.isEmpty {
        line += " \(detail)"
      }
      line += "\n"
      FlashLog.write(line)
    }
  }

  private static func ms(_ ns: UInt64) -> Double {
    Double(ns) / 1_000_000.0
  }

  private static func format(_ ms: Double) -> String {
    String(format: "%.1f", ms)
  }

  private static func clean(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
  }
}
