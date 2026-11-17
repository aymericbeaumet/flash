import Darwin
import Foundation

/// The files that keep what you typed, used and configured (command history,
/// ranking data, marks, clipboard history and its images, the macOS settings
/// ledger) are readable by you alone, whatever the folder above them allows.
/// Every such file is written here, the one way: a temporary file created
/// owner-only in the same folder, then renamed over the target, so a crash
/// leaves the old file or the new one and the content is never readable by
/// anyone else, not even for the moment between a write and a chmod.
enum PrivateFile {
  /// `data` at `url`, written atomically, mode 0600.
  static func write(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    do {
      try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
          let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
          if written < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
          offset += written
        }
      }
      guard close(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      close(descriptor)
      unlink(temporary.path)
      throw error
    }
    guard rename(temporary.path, url.path) == 0 else {
      let code = errno
      unlink(temporary.path)
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
  }
}
