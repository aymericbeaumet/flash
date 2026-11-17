import Foundation
import ImageIO

/// One retained copy as the flashlight lists it: what its row shows and
/// searches, and whether it is pinned. Image bytes and the formatted copy
/// stay in the store; ``ClipboardHistoryStore/payload(id:completion:)`` reads
/// them back when the entry is restored.
struct ClipboardListing: Equatable {
  var id: String
  var kind: String
  var text: String
  var mime: String?
  var files: [String]
  /// The stored image's pixel size, when the entry has an image.
  var width: Int?
  var height: Int?
  var pinned: Bool
}

/// Everything one entry puts back on the clipboard.
struct ClipboardEntryPayload: Equatable {
  var id: String
  var kind: String
  var text: String
  var html: String?
  var files: [String]
  var mime: String?
  var image: Data?
}

/// Serial, host-owned clipboard history. All disk access stays off the main loop.
///
/// `entries` is newest first. Display order — the help page, the flashlight —
/// lists pinned entries first, each group newest first. Pinned entries count
/// toward the capacity but are never trimmed: trimming keeps every pinned
/// entry and the newest unpinned ones that fit, at least one.
final class ClipboardHistoryStore {
  private struct StoredEntry: Codable, Equatable {
    var id: String
    var kind: String
    var text: String
    var html: String?
    var mime: String?
    var files: [String]
    var sha256: String?
    /// Pixel size of the stored image, read from its header.
    var width: Int?
    var height: Int?
    /// Written only when true.
    var pinned: Bool

    private enum CodingKeys: String, CodingKey {
      case id, kind, text, html, mime, files, sha256, width, height, pinned
    }

    init(
      id: String, kind: String, text: String, html: String?, mime: String?,
      files: [String], sha256: String?, width: Int? = nil, height: Int? = nil,
      pinned: Bool = false
    ) {
      self.id = id
      self.kind = kind
      self.text = text
      self.html = html
      self.mime = mime
      self.files = files
      self.sha256 = sha256
      self.width = width
      self.height = height
      self.pinned = pinned
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
      width = try values.decodeIfPresent(Int.self, forKey: .width)
      height = try values.decodeIfPresent(Int.self, forKey: .height)
      pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    func encode(to encoder: Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(id, forKey: .id)
      try values.encode(kind, forKey: .kind)
      try values.encode(text, forKey: .text)
      try values.encodeIfPresent(html, forKey: .html)
      try values.encodeIfPresent(mime, forKey: .mime)
      try values.encode(files, forKey: .files)
      try values.encodeIfPresent(sha256, forKey: .sha256)
      try values.encodeIfPresent(width, forKey: .width)
      try values.encodeIfPresent(height, forKey: .height)
      if pinned { try values.encode(true, forKey: .pinned) }
    }

    func samePayload(as other: Self) -> Bool {
      kind == other.kind && text == other.text && html == other.html
        && files == other.files && sha256 == other.sha256
    }

    var display: ClipboardModalEntry {
      ClipboardModalEntry(
        id: id, kind: kind, preview: Self.preview(for: self), value: text,
        html: html, mime: mime, files: files, pinned: pinned)
    }

    var listing: ClipboardListing {
      ClipboardListing(
        id: id, kind: kind, text: text, mime: mime, files: files, width: width, height: height,
        pinned: pinned)
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

  /// Why a pin did not change the history.
  enum PinResult: Equatable {
    case changed
    /// The entry was already in that state.
    case unchanged
    case missing
    /// Pinning it would leave no room for a new copy: pins may fill all but
    /// one slot of the capacity.
    case full(capacity: Int)
    case failed
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
  private let didList: ([ClipboardListing]) -> Void

  /// `didChange` runs on main after every change; `didList` runs on the
  /// store's queue with the new listing, in display order, after the
  /// history loads and after every change.
  init(
    directory: URL = ClipboardHistoryStore.defaultDirectory(),
    legacyDirectory: URL? = ClipboardHistoryStore.legacyDirectory(),
    capacity: Int = defaultCapacity,
    didList: @escaping ([ClipboardListing]) -> Void = { _ in },
    didChange: @escaping () -> Void = {}
  ) {
    self.directory = directory
    self.legacyDirectory = legacyDirectory
    self.capacity = min(max(capacity, 1), Self.maxCapacity)
    self.didList = didList
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
      let next = Self.retained(entries, capacity: capacity)
      guard next.count < entries.count else { return }
      commit(next)
    }
  }

  func record(_ item: ClipboardCapture.Item) {
    queue.async { [self] in
      let id = ClipboardCapture.makeID()
      guard let payload = ClipboardImageStore.storedPayload(for: item, dataDir: directory, id: id)
      else { return }
      let size = payload["mime"] == nil ? nil : item.image.flatMap(Self.pixelSize(of:))
      let incoming = StoredEntry(
        id: id, kind: item.kind.rawValue, text: item.text,
        html: item.html, mime: payload["mime"] as? String,
        files: item.files, sha256: payload["sha256"] as? String,
        width: size?.width, height: size?.height)
      let prior = entries.first { $0.samePayload(as: incoming) }
      var next = entries.filter { !$0.samePayload(as: incoming) && $0.id != id }
      next.insert(prior ?? incoming, at: 0)
      next = Self.retained(next, capacity: capacity)
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

  /// Move an entry Flash put back on the clipboard to the front, as a new
  /// copy of it would; it keeps its id, pin and image.
  func touch(id: String) {
    queue.async { [self] in
      guard let index = entries.firstIndex(where: { $0.id == id }), index > 0 else { return }
      var next = entries
      next.insert(next.remove(at: index), at: 0)
      guard persist(next) else { return }
      entries = next
      notifyChange()
    }
  }

  func page(offset: Int, completion: @escaping (ClipboardHistoryPage?) -> Void) {
    queue.async { [self] in
      guard (0...Self.maxCapacity).contains(offset) else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let ordered = Self.displayOrder(entries)
      var shown: [ClipboardModalEntry] = []
      var bytes = 32
      for entry in ordered.dropFirst(min(offset, ordered.count)).prefix(Self.pageLimit) {
        let display = entry.display
        let size = (try? JSONEncoder().encode(display).count) ?? Self.pageBytes + 1
        guard bytes + size <= Self.pageBytes else { break }
        shown.append(display)
        bytes += size
      }
      guard !shown.isEmpty || offset >= ordered.count else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let next = min(offset, ordered.count) + shown.count
      let result = ClipboardHistoryPage(
        entries: shown, total: ordered.count,
        nextOffset: next < ordered.count ? next : nil)
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

  /// Pin or unpin one entry. `completion` runs on main.
  func setPinned(id: String, _ pinned: Bool, completion: @escaping (PinResult) -> Void) {
    queue.async { [self] in
      let result = applyPin(id: id, pinned)
      DispatchQueue.main.async { completion(result) }
    }
  }

  private func applyPin(id: String, _ pinned: Bool) -> PinResult {
    guard ClipboardCapture.isEntryID(id), let index = entries.firstIndex(where: { $0.id == id })
    else { return .missing }
    guard entries[index].pinned != pinned else { return .unchanged }
    if pinned, entries.filter(\.pinned).count + 1 >= capacity {
      return .full(capacity: capacity)
    }
    var next = entries
    next[index].pinned = pinned
    next = Self.retained(next, capacity: capacity)
    guard persist(next) else { return .failed }
    entries = next
    notifyChange()
    return .changed
  }

  /// The entry's representations, its image read back from disk. `completion`
  /// runs on main; nil when no entry has this id.
  func payload(id: String, completion: @escaping (ClipboardEntryPayload?) -> Void) {
    queue.async { [self] in
      guard ClipboardCapture.isEntryID(id), let entry = entries.first(where: { $0.id == id })
      else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      var image: Data?
      if let mime = entry.mime,
        let url = ClipboardImageStore.fileURL(dataDir: directory, id: entry.id, mime: mime)
      {
        image = try? Data(contentsOf: url)
      }
      if entry.kind == "image", image?.isEmpty != false {
        // An image entry is its image: without the file there is nothing to restore.
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let payload = ClipboardEntryPayload(
        id: entry.id, kind: entry.kind, text: entry.text, html: entry.html, files: entry.files,
        mime: image == nil ? nil : entry.mime, image: image)
      DispatchQueue.main.async { completion(payload) }
    }
  }

  /// Every pinned entry, newest first, then every other entry, newest first.
  private static func displayOrder(_ entries: [StoredEntry]) -> [StoredEntry] {
    entries.filter(\.pinned) + entries.filter { !$0.pinned }
  }

  /// What `capacity` keeps of `entries` (newest first): every pinned entry,
  /// and the newest unpinned ones in the room the pins leave, at least one.
  private static func retained(_ entries: [StoredEntry], capacity: Int) -> [StoredEntry] {
    var room = max(1, capacity - entries.filter(\.pinned).count)
    return entries.filter { entry in
      if entry.pinned { return true }
      guard room > 0 else { return false }
      room -= 1
      return true
    }
  }

  /// Replace the history with `next` and drop the images of what it lost.
  private func commit(_ next: [StoredEntry]) {
    guard persist(next) else { return }
    let retained = Set(next.map(\.id))
    let removed = entries.filter { !retained.contains($0.id) }.map(\.id)
    entries = next
    for id in removed { removeImages(for: id) }
    notifyChange()
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
        FlashLog.error("[clipboard] history migration failed: \(error)")
      }
    }
    guard prepareDirectory() else { return }
    guard let data = try? Data(contentsOf: historyFile),
      let decoded = try? JSONDecoder().decode([StoredEntry].self, from: data)
    else { return }
    let valid = decoded.filter(Self.valid)
    // Entries recorded before Flash kept image sizes learn theirs from the
    // image file's header, once.
    let sized = valid.map(sizedFromFile)
    entries = Self.retained(sized, capacity: capacity)
    if entries != decoded, persist(entries) {
      let retained = Set(entries.map(\.id))
      for entry in decoded where !retained.contains(entry.id) { removeImages(for: entry.id) }
    }
    notifyChange()
  }

  /// `entry` with the pixel size of its stored image, read from the file's
  /// header when the entry does not know it yet.
  private func sizedFromFile(_ entry: StoredEntry) -> StoredEntry {
    guard entry.width == nil, let mime = entry.mime,
      let url = ClipboardImageStore.fileURL(dataDir: directory, id: entry.id, mime: mime),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let size = Self.pixelSize(of: source)
    else { return entry }
    var sized = entry
    sized.width = size.width
    sized.height = size.height
    return sized
  }

  /// The pixel size an image shows at, from its header alone; nothing is
  /// decoded.
  static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return pixelSize(of: source)
  }

  private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0, height > 0
    else { return nil }
    // EXIF orientations 5–8 turn the image a quarter.
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    return (5...8).contains(orientation) ? (height, width) : (width, height)
  }

  private static func valid(_ entry: StoredEntry) -> Bool {
    guard ClipboardCapture.isEntryID(entry.id),
      entry.text.utf8.count <= ClipboardCapture.maxTextBytes,
      entry.html.map({ !$0.isEmpty && $0.utf8.count <= ClipboardCapture.maxHTMLBytes }) ?? true,
      entry.files.count <= ClipboardCapture.maxFiles,
      entry.files.allSatisfy({ !$0.isEmpty })
    else { return false }
    switch (entry.width, entry.height) {
    case (nil, nil): break
    case (let width?, let height?):
      guard entry.mime != nil, width > 0, height > 0 else { return false }
    default: return false
    }
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
      FlashLog.error("[clipboard] store unavailable: \(error)")
      return false
    }
  }

  private func persist(_ next: [StoredEntry]) -> Bool {
    guard prepareDirectory(), let data = try? JSONEncoder().encode(next) else { return false }
    let file = directory.appendingPathComponent("history.json")
    do {
      try PrivateFile.write(data, to: file)
      return true
    } catch {
      FlashLog.error("[clipboard] history write failed: \(error)")
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

  /// Publish the listing on this queue, then tell main.
  private func notifyChange() {
    didList(Self.displayOrder(entries).map(\.listing))
    DispatchQueue.main.async { [didChange] in didChange() }
  }
}
