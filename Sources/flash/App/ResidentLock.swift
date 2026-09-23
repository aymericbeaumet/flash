import Darwin
import Foundation

/// One resident per user (hard constraint 4). The dev and release bundles share
/// a bundle identifier, and the CLI symlink runs the resident binary directly
/// when given no arguments, so Launch Services alone never stopped a second
/// resident — and two of them each draw a status bar and a focus border in
/// whatever mode each is in. The resident holds an advisory `flock` on a file
/// in Application Support for its whole lifetime; the kernel drops it when the
/// process exits or crashes, so a stale lock can never block a relaunch.
final class ResidentLock {
  enum Acquisition {
    case acquired(ResidentLock)
    case heldByAnother(pid: pid_t?)
    /// The lock file could not be opened; the resident runs unguarded rather
    /// than not at all.
    case unavailable(errno: Int32)
  }

  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    close(descriptor)
  }

  static var defaultURL: URL {
    let appSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    return appSupport.appendingPathComponent("Flash").appendingPathComponent("resident.lock")
  }

  static func acquire(at url: URL = defaultURL) -> Acquisition {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return .unavailable(errno: errno) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let holder = readPID(descriptor)
      close(descriptor)
      return .heldByAnother(pid: holder)
    }
    // The pid is informational (the lock is the fact): it names the holder in
    // the duplicate's exit message.
    _ = ftruncate(descriptor, 0)
    let text = "\(getpid())\n"
    _ = text.withCString { pwrite(descriptor, $0, strlen($0), 0) }
    return .acquired(ResidentLock(descriptor: descriptor))
  }

  private static func readPID(_ descriptor: Int32) -> pid_t? {
    var buffer = [UInt8](repeating: 0, count: 32)
    let count = pread(descriptor, &buffer, buffer.count - 1, 0)
    guard count > 0 else { return nil }
    return pid_t(
      String(decoding: buffer[0..<count], as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
