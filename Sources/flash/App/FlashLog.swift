import Foundation

/// Single sink for the app's stderr diagnostics. Always writes to stderr;
/// also appends to `~/Library/Logs/Flash/flash.log` when `mirrorToFile`
/// is true. Toggled by `debug.dump_logs` via `AppMonitor.configureLogging`.
///
/// Profiler output and one-shot permission warnings both flow through
/// here so the file mirror is complete — there is no other code path
/// that writes to stderr directly.
enum FlashLog {
  private static let lock = NSLock()
  private static var mirrorEnabled: Bool = false
  private static var handle: FileHandle?

  static func setMirrorToFile(_ enabled: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if enabled == mirrorEnabled { return }
    mirrorEnabled = enabled
    if enabled {
      handle = openLogFile()
    } else {
      try? handle?.close()
      handle = nil
    }
  }

  static func write(_ message: String) {
    fputs(message, stderr)
    lock.lock()
    defer { lock.unlock() }
    guard mirrorEnabled, let handle else { return }
    if let data = message.data(using: .utf8) {
      try? handle.write(contentsOf: data)
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
    try? h.seekToEnd()
    return h
  }
}
