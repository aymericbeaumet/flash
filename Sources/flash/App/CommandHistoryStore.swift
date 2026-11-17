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
        "[history] cannot create directory: \(error)",
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
        "[history] load failed: \(error)", fields: ["path": fileURL.path])
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
        try PrivateFile.write(data, to: self.fileURL)
      } catch {
        FlashLog.error(
          "[history] persist failed: \(error)", fields: ["path": self.fileURL.path])
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

/// The command-line inputs the user ran, most recent last, and the recall in
/// progress. Up steps to older entries, down to newer ones and, past the
/// newest, back to the buffer the recall started from. The recall cursor and
/// that buffer exist only together, while recalling.
struct CommandLineHistory: Equatable {
  static let capacity = 200

  private struct Recall: Equatable {
    var index: Int
    /// The buffer being edited when the recall started.
    var stash: String
  }

  private(set) var entries: [String]
  private var recall: Recall?

  init(entries: [String] = []) {
    self.entries = Array(entries.suffix(Self.capacity))
  }

  var isRecalling: Bool { recall != nil }

  /// A real edit ends the recall: the next step stashes the edited buffer
  /// and starts again from the newest entry.
  mutating func endRecall() {
    recall = nil
  }

  /// Record a submitted input, success or not: trimmed, a consecutive
  /// duplicate dropped, the oldest beyond `capacity` dropped. Ends any
  /// recall. Returns whether `entries` changed, so the caller persists them.
  mutating func record(_ rawInput: String) -> Bool {
    recall = nil
    let entry = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !entry.isEmpty, entries.last != entry else { return false }
    entries.append(entry)
    if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    return true
  }

  /// One step of recall from `buffer`, the text on the line now: `delta < 0`
  /// toward older entries, `delta > 0` toward newer ones. As in Vim, only
  /// the entries that start with what was typed when the recall began
  /// (`:tab` recalls `:tab next`, never `:q`) are stepped through. The text
  /// to show, or nil when the step does nothing (no matching entry, or down
  /// while not recalling). Up past the oldest match stays on it.
  mutating func step(_ delta: Int, buffer: String) -> String? {
    if delta < 0 {
      let stash = recall?.stash ?? buffer
      let before = recall?.index ?? entries.count
      guard let older = entries[..<before].lastIndex(where: { Self.entry($0, startsWith: stash) })
      else {
        return recall.map { entries[$0.index] }
      }
      recall = Recall(index: older, stash: stash)
    } else {
      guard let current = recall else { return nil }
      let after = current.index + 1
      guard
        let newer = entries[after...].firstIndex(where: {
          Self.entry($0, startsWith: current.stash)
        })
      else {
        recall = nil
        return current.stash
      }
      recall?.index = newer
    }
    return recall.map { entries[$0.index] }
  }

  /// Whether a recorded `entry` begins with the `typed` text, the prompt's
  /// colon aside on both.
  private static func entry(_ entry: String, startsWith typed: String) -> Bool {
    func body(_ text: String) -> Substring {
      text.hasPrefix(":") ? text.dropFirst() : Substring(text)
    }
    return body(entry).hasPrefix(body(typed))
  }
}
