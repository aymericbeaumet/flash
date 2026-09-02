import Foundation

/// Persists the command-line history — the `:` inputs recalled by up/down and
/// ctrl+p/n, most-recent last — as a JSON array at
/// `~/Library/Application Support/Flash/command-history.json`.
///
/// Flash is a resident process that gets relaunched on every dev reinstall (and
/// on logout/restart), so in-memory-only history is wiped constantly and recall
/// feels broken right after a reinstall. Persisting it makes recall survive
/// restarts, matching shell history. Loads once on startup; writes coalesce on a
/// background queue and are written atomically.
final class CommandHistoryStore {
  private let fileURL: URL
  private let queue = DispatchQueue(label: "flash.command-history.io", qos: .utility)

  init?(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let appSupport =
        FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        ?? URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support")
      self.fileURL =
        appSupport
        .appendingPathComponent("Flash")
        .appendingPathComponent("command-history.json")
    }
    do {
      try FileManager.default.createDirectory(
        at: self.fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    } catch {
      FlashLog.warn(
        "[command-history] cannot create directory: \(error)",
        fields: ["path": self.fileURL.deletingLastPathComponent().path])
      return nil
    }
  }

  /// Read the persisted history (most-recent last). Returns an empty array when
  /// the file is missing or unreadable.
  func load() -> [String] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    do {
      let data = try Data(contentsOf: fileURL)
      return try JSONDecoder().decode([String].self, from: data)
    } catch {
      FlashLog.warn(
        "[command-history] load failed: \(error)", fields: ["path": fileURL.path])
      return []
    }
  }

  /// Persist the full history array. The caller already applied the cap and
  /// duplicate-suppression, so this just snapshots the current list.
  func save(_ history: [String]) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        let data = try JSONEncoder().encode(history)
        // Atomic write so a crash mid-write can't leave a half-flushed file.
        let tmp = self.fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        _ = try? FileManager.default.replaceItemAt(self.fileURL, withItemAt: tmp)
      } catch {
        FlashLog.warn(
          "[command-history] persist failed: \(error)", fields: ["path": self.fileURL.path])
      }
    }
  }

  /// Block until any pending write has hit disk. Tests + shutdown.
  func drain() {
    let group = DispatchGroup()
    group.enter()
    queue.async { group.leave() }
    group.wait()
  }
}
