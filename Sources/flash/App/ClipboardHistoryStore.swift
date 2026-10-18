import Foundation

/// Serial, host-owned clipboard history. All disk access stays off the main loop.
final class ClipboardHistoryStore {
  private struct StoredEntry: Codable, Equatable {
    var id: String
    var kind: String
    var text: String
    var html: String?
    var mime: String?
    var files: [String]
    var sha256: String?

    private enum CodingKeys: String, CodingKey {
      case id, kind, text, html, mime, files, sha256
    }

    init(
      id: String, kind: String, text: String, html: String?, mime: String?,
      files: [String], sha256: String?
    ) {
      self.id = id
      self.kind = kind
      self.text = text
      self.html = html
      self.mime = mime
      self.files = files
      self.sha256 = sha256
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      id = try values.decode(String.self, forKey: .id)
      kind = try values.decode(String.self, forKey: .kind)
      text = try values.decode(String.self, forKey: .text)
      html = try values.decodeIfPresent(String.self, forKey: .html)
      mime = try values.decodeIfPresent(String.self, forKey: .mime)
      files = try values.decodeIfPresent([String].self, forKey: .files) ?? []
      sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)
    }

    func samePayload(as other: Self) -> Bool {
      kind == other.kind && text == other.text && html == other.html
        && files == other.files && sha256 == other.sha256
    }

    var display: ClipboardModalEntry {
      ClipboardModalEntry(
        id: id, kind: kind, preview: Self.preview(for: self), value: text,
        html: html, mime: mime, files: files)
    }

    private static func preview(for entry: Self) -> String {
      if entry.kind == "image", entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        switch entry.mime {
        case "image/png": return "PNG image"
        case "image/jpeg": return "JPEG image"
        case "image/gif": return "GIF image"
        case "image/webp": return "WebP image"
        default: return "Image"
        }
      }
      if entry.kind == "files", entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if entry.files.count == 1 { return Self.shortPreview(entry.files[0]) }
        return "\(entry.files.count) files"
      }
      if entry.kind == "html", entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "Formatted text"
      }
      return shortPreview(entry.text)
    }

    private static func shortPreview(_ value: String) -> String {
      let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
      let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      if collapsed.count <= 80 { return collapsed }
      return String(collapsed.prefix(79)) + "…"
    }
  }

  static let defaultCapacity = 1_000
  static let maxCapacity = 10_000
  static let pageLimit = 100
  static let pageBytes = 3 * 1024 * 1024

  private let queue = DispatchQueue(label: "flash.clipboard.history", qos: .utility)
  private let directory: URL
  private let legacyDirectory: URL?
  private var entries: [StoredEntry] = []
  private var capacity: Int
  private let didChange: () -> Void

  init(
    directory: URL = ClipboardHistoryStore.defaultDirectory(),
    legacyDirectory: URL? = ClipboardHistoryStore.legacyDirectory(),
    capacity: Int = defaultCapacity,
    didChange: @escaping () -> Void = {}
  ) {
    self.directory = directory
    self.legacyDirectory = legacyDirectory
    self.capacity = min(max(capacity, 1), Self.maxCapacity)
    self.didChange = didChange
    queue.async { [self] in
      migrateAndLoad()
    }
  }

  static func defaultDirectory() -> URL {
    applicationSupportDirectory().appendingPathComponent("clipboard", isDirectory: true)
  }

  static func legacyDirectory() -> URL {
    applicationSupportDirectory().appendingPathComponent(
      "Plugins/clipboard/share", isDirectory: true)
  }

  private static func applicationSupportDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Flash", isDirectory: true)
  }

  func setCapacity(_ value: Int) {
    queue.async { [self] in
      capacity = min(max(value, 1), Self.maxCapacity)
      guard entries.count > capacity else { return }
      let removed = Array(entries.dropFirst(capacity))
      let next = Array(entries.prefix(capacity))
      guard persist(next) else { return }
      entries = next
      for entry in removed { removeImages(for: entry.id) }
      notifyChange()
    }
  }

  func record(_ item: ClipboardCapture.Item) {
    queue.async { [self] in
      let id = ClipboardCapture.makeID()
      guard let payload = ClipboardImageStore.storedPayload(for: item, dataDir: directory, id: id)
      else { return }
      let incoming = StoredEntry(
        id: id, kind: item.kind.rawValue, text: item.text,
        html: item.html, mime: payload["mime"] as? String,
        files: item.files, sha256: payload["sha256"] as? String)
      let prior = entries.first { $0.samePayload(as: incoming) }
      var next = entries.filter { !$0.samePayload(as: incoming) && $0.id != id }
      next.insert(prior ?? incoming, at: 0)
      next = Array(next.prefix(capacity))
      guard persist(next) else {
        removeImages(for: id)
        return
      }
      let retained = Set(next.map(\.id))
      let removed = entries.filter { !retained.contains($0.id) }.map(\.id)
      entries = next
      if prior != nil { removeImages(for: id) }
      for id in removed { removeImages(for: id) }
      notifyChange()
    }
  }

  func page(offset: Int, completion: @escaping (ClipboardHistoryPage?) -> Void) {
    queue.async { [self] in
      guard (0...Self.maxCapacity).contains(offset) else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      var shown: [ClipboardModalEntry] = []
      var bytes = 32
      for entry in entries.dropFirst(min(offset, entries.count)).prefix(Self.pageLimit) {
        let display = entry.display
        let size = (try? JSONEncoder().encode(display).count) ?? Self.pageBytes + 1
        guard bytes + size <= Self.pageBytes else { break }
        shown.append(display)
        bytes += size
      }
      guard !shown.isEmpty || offset >= entries.count else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let next = min(offset, entries.count) + shown.count
      let result = ClipboardHistoryPage(
        entries: shown, total: entries.count,
        nextOffset: next < entries.count ? next : nil)
      DispatchQueue.main.async { completion(result) }
    }
  }

  func delete(id: String, completion: @escaping (Bool) -> Void) {
    queue.async { [self] in
      guard ClipboardCapture.isEntryID(id), entries.contains(where: { $0.id == id }) else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      let next = entries.filter { $0.id != id }
      let saved = persist(next)
      if saved {
        entries = next
        removeImages(for: id)
        notifyChange()
      }
      DispatchQueue.main.async { completion(saved) }
    }
  }

  func latestText(completion: @escaping (String?) -> Void) {
    queue.async { [self] in
      let value = entries.first(where: { !$0.text.isEmpty })?.text
      DispatchQueue.main.async { completion(value) }
    }
  }

  private func migrateAndLoad() {
    let manager = FileManager.default
    let historyFile = directory.appendingPathComponent("history.json")
    if let legacyDirectory, !manager.fileExists(atPath: historyFile.path),
      manager.fileExists(atPath: legacyDirectory.appendingPathComponent("history.json").path)
    {
      do {
        try manager.createDirectory(
          at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: directory.path) {
          try manager.moveItem(at: legacyDirectory, to: directory)
        } else {
          let oldImages = legacyDirectory.appendingPathComponent("images")
          let newImages = directory.appendingPathComponent("images")
          if manager.fileExists(atPath: oldImages.path), !manager.fileExists(atPath: newImages.path)
          {
            try manager.copyItem(at: oldImages, to: newImages)
          }
          try manager.copyItem(
            at: legacyDirectory.appendingPathComponent("history.json"), to: historyFile)
        }
      } catch {
        FlashLog.warn("[clipboard] history migration failed: \(error)")
      }
    }
    guard prepareDirectory() else { return }
    guard let data = try? Data(contentsOf: historyFile),
      let decoded = try? JSONDecoder().decode([StoredEntry].self, from: data)
    else { return }
    entries = Array(decoded.filter(Self.valid).prefix(capacity))
    if entries.count < decoded.count {
      let removed = decoded.dropFirst(capacity).map(\.id)
      if persist(entries) {
        for id in removed { removeImages(for: id) }
      }
    }
    notifyChange()
  }

  private static func valid(_ entry: StoredEntry) -> Bool {
    guard ClipboardCapture.isEntryID(entry.id),
      entry.text.utf8.count <= ClipboardCapture.maxTextBytes,
      entry.html.map({ !$0.isEmpty && $0.utf8.count <= ClipboardCapture.maxHTMLBytes }) ?? true,
      entry.files.count <= ClipboardCapture.maxFiles,
      entry.files.allSatisfy({ !$0.isEmpty })
    else { return false }
    if let mime = entry.mime {
      guard ClipboardImageStore.ext(for: mime) != nil,
        entry.sha256.map({
          $0.utf8.count == 64
            && $0.utf8.allSatisfy { byte in
              (48...57).contains(byte) || (97...102).contains(byte)
            }
        }) == true
      else { return false }
    } else if entry.sha256 != nil {
      return false
    }
    switch entry.kind {
    case "text":
      return !entry.text.isEmpty && entry.html == nil && entry.mime == nil && entry.files.isEmpty
    case "image": return entry.mime != nil && entry.html == nil && entry.files.isEmpty
    case "html": return entry.html != nil && entry.mime == nil && entry.files.isEmpty
    case "files": return !entry.files.isEmpty && entry.html == nil
    default: return false
    }
  }

  private func prepareDirectory() -> Bool {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      return true
    } catch {
      FlashLog.warn("[clipboard] store unavailable: \(error)")
      return false
    }
  }

  private func persist(_ next: [StoredEntry]) -> Bool {
    guard prepareDirectory(), let data = try? JSONEncoder().encode(next) else { return false }
    let file = directory.appendingPathComponent("history.json")
    do {
      try data.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      return true
    } catch {
      FlashLog.warn("[clipboard] history write failed: \(error)")
      return false
    }
  }

  private func removeImages(for id: String) {
    guard ClipboardCapture.isEntryID(id) else { return }
    for ext in ["png", "jpg", "gif", "webp"] {
      try? FileManager.default.removeItem(
        at: directory.appendingPathComponent("images/\(id).\(ext)"))
    }
  }

  private func notifyChange() {
    DispatchQueue.main.async { [didChange] in didChange() }
  }
}
