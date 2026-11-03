import AppKit
import FlashCore
import Foundation

/// The flashlight's clipboard rows: three sources (`clipboard.pinned`,
/// `clipboard.history`, `clipboard.registers`) of the one `clipboard` type,
/// which `@clipboard` and the `!clip` bang list together. Pinned entries rank above the rest of the history, and named
/// registers below it; each group keeps its own order (newest first) for an
/// empty query and among equal matches.
///
/// History rows are rebuilt on this object's queue whenever the store
/// publishes a new listing. A row is prepared once and reused by id until
/// its entry is pinned, unpinned or dropped, so a copy costs one preparation
/// and a query only reads rows from memory. Register rows are built on main
/// when a query pulls them: a few dozen at most, and `RegisterStore` lives
/// on main.
///
/// What a keystroke costs is bounded: every pinned entry and the newest
/// `historyRowLimit` others are listed, each row searches its first line and
/// a short excerpt of what follows, never the whole copy. A cold scan of the
/// bounded rows (the first keystroke, a deletion) stays within a frame; typing
/// on narrows the previous matches.
final class ClipboardFlashlight {
  static let sourceID = "core.clipboard"
  static let pinnedLabel = "clipboard.pinned"
  static let historyLabel = "clipboard.history"
  static let registersLabel = "clipboard.registers"
  static let entryKind = CandidateKind.plugin("clipboard_entry")
  static let registerKind = CandidateKind.plugin("clipboard_register")
  static let bang = CoreBang(
    token: "clip", description: "Paste from clipboard history: !clip <text>",
    scope: .type("clipboard"))
  /// A row's title is the entry's first line, at most this many characters.
  static let titleLimit = 80
  /// Searchable text after the title, at most this many characters.
  static let excerptLimit = 120
  /// Unpinned entries listed, newest first: Maccy's largest history. Older
  /// ones stay on the Clipboard page, whose search reads every entry.
  static let historyRowLimit = 1_000

  /// Called on main after the history rows changed.
  var onChange: () -> Void = {}

  private let queue = DispatchQueue(label: "flash.clipboard.flashlight", qos: .utility)
  private let lock = NSLock()
  /// Guarded by `lock`.
  private var historyRows: [Candidate] = []
  /// Queue only: prepared rows by `rowKey`, reused across listings.
  private var prepared: [String: Candidate] = [:]
  /// Main only.
  private let registers: () -> [RegisterStore.Entry]

  init(registers: @escaping () -> [RegisterStore.Entry]) {
    self.registers = registers
  }

  /// Rebuild the history rows from the store's listing, off main.
  func update(_ listing: [ClipboardListing]) {
    queue.async { [weak self] in
      guard let self else { return }
      let rows = self.build(listing)
      self.lock.lock()
      self.historyRows = rows
      self.lock.unlock()
      DispatchQueue.main.async { [weak self] in self?.onChange() }
    }
  }

  /// The history rows, then the register rows. Main only.
  func rows() -> [Candidate] {
    lock.lock()
    let history = historyRows
    lock.unlock()
    return history + Self.registerRows(registers())
  }

  private func build(_ listing: [ClipboardListing]) -> [Candidate] {
    let listing = Self.listed(listing)
    var rows: [Candidate?] = listing.map { prepared[Self.rowKey($0)] }
    let missing = rows.indices.filter { rows[$0] == nil }
    let fresh = CandidateFinder.prepare(missing.map { Self.candidate(for: listing[$0]) })
    for (index, row) in zip(missing, fresh) { rows[index] = row }
    var next: [String: Candidate] = [:]
    var result: [Candidate] = []
    result.reserveCapacity(listing.count)
    for (index, entry) in listing.enumerated() {
      guard var row = rows[index] else { continue }
      next[Self.rowKey(entry)] = row
      row.sourceOrder = index
      result.append(row)
    }
    prepared = next
    return result
  }

  /// Every pinned entry, and the first `historyRowLimit` others, in order.
  static func listed(_ listing: [ClipboardListing]) -> [ClipboardListing] {
    var room = historyRowLimit
    return listing.filter { entry in
      if entry.pinned { return true }
      guard room > 0 else { return false }
      room -= 1
      return true
    }
  }

  /// What a prepared row depends on: the entry, and whether it is pinned.
  private static func rowKey(_ entry: ClipboardListing) -> String {
    entry.pinned ? "\(entry.id):pinned" : entry.id
  }

  // MARK: Rows

  /// One history row: its title says what was copied, its subtitle carries
  /// more of the text for search, and its payload is the entry id. Return
  /// pastes it (a finisher).
  static func candidate(for entry: ClipboardListing) -> Candidate {
    Candidate(
      kind: entryKind, sourceID: sourceID, source: entry.pinned ? pinnedLabel : historyLabel,
      title: title(for: entry), subtitle: excerpt(for: entry), sourcePayload: entry.id,
      finishesCommand: true)
  }

  /// Named registers in `RegisterStore` order, each titled `"<name> <text>`.
  /// The payload is the register name: selection reads its text afresh.
  static func registerRows(_ entries: [RegisterStore.Entry]) -> [Candidate] {
    entries.enumerated().map { index, entry in
      let line = firstLine(entry.text)
      var row = Candidate(
        kind: registerKind, sourceID: sourceID, source: registersLabel,
        title: line.isEmpty ? "\"\(entry.name)" : "\"\(entry.name) \(line)",
        subtitle: excerpt(entry.text), sourcePayload: entry.name, finishesCommand: true)
      row.sourceOrder = index
      return row
    }
  }

  /// `Image 1280×800 PNG`, a file name, or the text's first line.
  static func title(for entry: ClipboardListing) -> String {
    switch entry.kind {
    case "image":
      var words = ["Image"]
      if let width = entry.width, let height = entry.height { words.append("\(width)×\(height)") }
      if let format = entry.mime.flatMap(formatName) { words.append(format) }
      return words.joined(separator: " ")
    case "files":
      let names = entry.files.map { ($0 as NSString).lastPathComponent }
      guard let first = names.first else { return "Files" }
      return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
    default:
      let line = firstLine(entry.text)
      if !line.isEmpty { return line }
      return entry.kind == "html" ? "Formatted text" : "Text"
    }
  }

  /// What a row searches besides its title: a file copy's paths, an image's
  /// text, or the text after a text entry's first line.
  static func excerpt(for entry: ClipboardListing) -> String {
    switch entry.kind {
    case "files": return excerpt(entry.files.joined(separator: " "))
    case "image": return excerpt(entry.text)
    default:
      let line = firstLine(entry.text)
      let shown = line.hasSuffix("…") ? String(line.dropLast()) : line
      let start = entry.text.prefix((titleLimit + excerptLimit) * 4)
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
      guard start.hasPrefix(shown) else { return excerpt(start) }
      return excerpt(String(start.dropFirst(shown.count)))
    }
  }

  static func formatName(_ mime: String) -> String? {
    switch mime {
    case "image/png": return "PNG"
    case "image/jpeg": return "JPEG"
    case "image/gif": return "GIF"
    case "image/webp": return "WebP"
    default: return nil
    }
  }

  /// The first line with any text, its whitespace collapsed, cut to
  /// `titleLimit` characters.
  static func firstLine(_ text: String) -> String {
    for line in text.prefix(titleLimit * 8).split(whereSeparator: \.isNewline) {
      let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      guard !collapsed.isEmpty else { continue }
      return collapsed.count <= titleLimit
        ? collapsed : String(collapsed.prefix(titleLimit - 1)) + "…"
    }
    return ""
  }

  /// The start of `text`, its whitespace collapsed, at most `excerptLimit`
  /// characters.
  static func excerpt(_ text: String) -> String {
    let collapsed = text.prefix(excerptLimit * 4).split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    return String(collapsed.prefix(excerptLimit))
  }
}

/// What a selected clipboard row does: paste it, paste its plain text, or
/// put it on the clipboard without pasting.
enum ClipboardRowDelivery: Equatable {
  case paste
  case pastePlain
  case copy

  /// `<cr>` pastes, `<s-cr>` pastes plain text, `<a-cr>` only copies.
  init(_ variant: CommandLineSubmitVariant?) {
    switch variant {
    case nil: self = .paste
    case .shift: self = .pastePlain
    case .option: self = .copy
    }
  }

  var pastes: Bool { self != .copy }
  var plain: Bool { self == .pastePlain }
}

/// `@clipboard`: the rows of ``ClipboardFlashlight``, served from memory
/// when a query names the source or `!clip`. Selecting a row is handled by
/// the flashlight itself (``ClipboardRowDelivery``), which needs the app the
/// command line covered.
final class ClipboardFlashlightSource: FlashSource {
  private let flashlight: ClipboardFlashlight

  init(flashlight: ClipboardFlashlight) {
    self.flashlight = flashlight
  }

  let identifier = ClipboardFlashlight.sourceID
  let displayName = ClipboardFlashlight.sourceID
  let priority = 40
  var capabilities: FlashSourceCapabilities { [.candidates] }
  var servesLiveCandidates: Bool { true }
  var liveCandidatesDependOnText: Bool { false }
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    [
      CandidateSourceDescriptor(
        name: ClipboardFlashlight.pinnedLabel, type: "clipboard", priority: .high),
      CandidateSourceDescriptor(name: ClipboardFlashlight.historyLabel, type: "clipboard"),
      CandidateSourceDescriptor(
        name: ClipboardFlashlight.registersLabel, type: "clipboard", priority: .low),
    ]
  }

  func supports(_ context: AppContext) -> Bool { false }
  func discover(in context: AppContext) throws -> [JumpTarget] { [] }

  func liveCandidates(
    matching text: String,
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    DispatchQueue.main.async { [flashlight] in completion(flashlight.rows()) }
  }
}
