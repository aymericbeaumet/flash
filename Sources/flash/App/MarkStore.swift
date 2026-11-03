import FlashCore
import Foundation

/// One of the 36 mark slots: an ASCII letter or digit, lowercased.
struct MarkSlot: Hashable, CustomStringConvertible {
  let letter: Character

  /// Exactly one ASCII letter or digit; `A` is the slot `a`. Anything else
  /// is rejected, so a typo never makes a slot.
  init?(parsing text: String) {
    guard text.utf8.count == 1, let byte = text.utf8.first else { return nil }
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
      letter = Character(UnicodeScalar(byte))
    case UInt8(ascii: "A")...UInt8(ascii: "Z"):
      letter = Character(UnicodeScalar(byte + 32))
    default:
      return nil
    }
  }

  var description: String { String(letter) }
}

/// What a mark saves: the process is the fast activation handle, the bundle
/// identifier the durable fallback once that process is gone.
struct MarkEntry: Codable, Equatable {
  var pid: pid_t
  var bundleID: String

  private enum CodingKeys: String, CodingKey {
    case pid
    case bundleID = "bundle_id"
  }
}

/// `mark set --letter=<x>` saves the focused app under a slot;
/// `mark jump --letter=<x>` brings it back. See `MarkStore`.
enum MarkCommand: Hashable {
  case set(MarkSlot)
  case jump(MarkSlot)

  var slot: MarkSlot {
    switch self {
    case .set(let slot), .jump(let slot): return slot
    }
  }

  var name: CommandName {
    switch self {
    case .set: return CommandName("mark", "set")
    case .jump: return CommandName("mark", "jump")
    }
  }

  var argTokens: [String] { ["--letter=\(slot)"] }

  /// The mapping explanation: what the command does, as one sentence.
  var explanation: String {
    switch self {
    case .set(let slot): return "Saves the focused app as mark \(slot)."
    case .jump(let slot): return "Brings back the app saved as mark \(slot)."
    }
  }

  /// The command line's one-line descriptions.
  static let setSummary = "Save the focused app under one letter or digit"
  static let jumpSummary = "Bring back the app saved under a letter or digit"
}

/// The named app marks, persisted as `marks.json` beside the other core
/// stores. Serial and host-owned: every read and write of the file happens
/// on its queue, never the main loop, and a mark is in memory only once it
/// is on disk.
final class MarkStore {
  /// The file's shape: `{"entries": {"a": {"pid": 17, "bundle_id": "…"}}}`.
  private struct State: Codable {
    var entries: [String: MarkEntry]
  }

  private let queue = DispatchQueue(label: "flash.marks", qos: .utility)
  private let file: URL
  private let legacyFile: URL?
  private var entries: [MarkSlot: MarkEntry] = [:]

  init(file: URL = MarkStore.defaultFile(), legacyFile: URL? = MarkStore.legacyFile()) {
    self.file = file
    self.legacyFile = legacyFile
    queue.async { [self] in
      migrateAndLoad()
    }
  }

  static func defaultFile() -> URL {
    applicationSupportDirectory().appendingPathComponent("marks.json")
  }

  /// Where the retired marks plugin kept them; moved to `defaultFile()` on
  /// first launch.
  static func legacyFile() -> URL {
    applicationSupportDirectory().appendingPathComponent("Plugins/marks/share/marks.json")
  }

  private static func applicationSupportDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Flash", isDirectory: true)
  }

  /// The process a jump activates: the saved one while it is still that
  /// app, else any running instance of the bundle, else nil (a launch). An
  /// app without a bundle identifier has no other instance to fall back to.
  static func target(for entry: MarkEntry, running: [(pid: pid_t, bundleID: String)]) -> pid_t? {
    if running.contains(where: { $0.pid == entry.pid && $0.bundleID == entry.bundleID }) {
      return entry.pid
    }
    guard !entry.bundleID.isEmpty else { return nil }
    return running.first(where: { $0.pid > 0 && $0.bundleID == entry.bundleID })?.pid
  }

  /// Save `entry` under `slot`: written first, kept in memory only once the
  /// write succeeded, so a failed save leaves no mark. `completion` runs on
  /// main with whether it was saved.
  func set(_ slot: MarkSlot, to entry: MarkEntry, completion: @escaping (Bool) -> Void) {
    queue.async { [self] in
      var next = entries
      next[slot] = entry
      let saved = persist(next)
      if saved { entries = next }
      DispatchQueue.main.async { completion(saved) }
    }
  }

  /// The mark under `slot`, on main.
  func entry(for slot: MarkSlot, completion: @escaping (MarkEntry?) -> Void) {
    queue.async { [self] in
      let value = entries[slot]
      DispatchQueue.main.async { completion(value) }
    }
  }

  /// A jump landed on another instance of the mark's bundle: the mark
  /// follows that process, provided the slot still holds `expected`.
  func rewritePID(_ pid: pid_t, for slot: MarkSlot, expecting expected: MarkEntry) {
    queue.async { [self] in
      guard entries[slot] == expected, expected.pid != pid else { return }
      var next = entries
      next[slot] = MarkEntry(pid: pid, bundleID: expected.bundleID)
      if persist(next) { entries = next }
    }
  }

  private func migrateAndLoad() {
    let manager = FileManager.default
    if let legacyFile, !manager.fileExists(atPath: file.path),
      manager.fileExists(atPath: legacyFile.path)
    {
      do {
        try manager.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: legacyFile, to: file)
        // The plugin's `share` directory and its root, when the move
        // emptied them; best effort.
        let share = legacyFile.deletingLastPathComponent()
        removeIfEmpty(share)
        removeIfEmpty(share.deletingLastPathComponent())
      } catch {
        FlashLog.warn("[marks] migration failed: \(error)")
      }
    }
    guard let data = try? Data(contentsOf: file),
      let state = try? JSONDecoder().decode(State.self, from: data)
    else { return }
    var loaded: [MarkSlot: MarkEntry] = [:]
    for (key, entry) in state.entries {
      guard let slot = MarkSlot(parsing: key) else { continue }
      loaded[slot] = entry
    }
    entries = loaded
  }

  private func removeIfEmpty(_ directory: URL) {
    let manager = FileManager.default
    guard let contents = try? manager.contentsOfDirectory(atPath: directory.path),
      contents.isEmpty
    else { return }
    try? manager.removeItem(at: directory)
  }

  private func persist(_ next: [MarkSlot: MarkEntry]) -> Bool {
    let state = State(
      entries: Dictionary(uniqueKeysWithValues: next.map { ($0.key.description, $0.value) }))
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(state)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try PrivateFile.write(data, to: file)
      return true
    } catch {
      FlashLog.error("[marks] could not save \(file.path): \(error)")
      return false
    }
  }
}
