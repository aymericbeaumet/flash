import FlashCore
import Foundation

/// One Apple app whose items the flashlight lists: `@notes`,
/// `@reminders` and `@contacts`. Reminders and Contacts are read
/// through their frameworks, Notes, which has none, through its AppleScript
/// dictionary. Each lists only while its app runs, as Notes's script must.
enum AppleCatalog: String, CaseIterable, Hashable {
  case notes
  case reminders
  case contacts

  var bundleID: String {
    switch self {
    case .notes: return "com.apple.Notes"
    case .reminders: return "com.apple.reminders"
    case .contacts: return "com.apple.AddressBook"
    }
  }

  /// The flashlight source name, for routing and ranking; users narrow to its
  /// resource type, the catalog's raw value (`@notes`; see `ResourceTypes`).
  var sourceLabel: String {
    switch self {
    case .notes: return "notes.notes"
    case .reminders: return "reminders.tasks"
    case .contacts: return "contacts.cards"
    }
  }

  /// The registry identifier that routes a selected row back to its source.
  var sourceID: String { "core.\(rawValue)" }

  /// The row kind the flashlight shows.
  var rowKind: String {
    switch self {
    case .notes: return "note"
    case .reminders: return "reminder"
    case .contacts: return "contact"
    }
  }

  /// What the catalog lists, in a sentence.
  var items: String {
    switch self {
    case .notes: return "your notes"
    case .reminders: return "your open reminders"
    case .contacts: return "your contacts"
    }
  }

  var appName: String {
    switch self {
    case .notes: return "Notes"
    case .reminders: return "Reminders"
    case .contacts: return "Contacts"
    }
  }

  static func owning(bundleID: String?) -> AppleCatalog? {
    guard let bundleID else { return nil }
    return allCases.first { $0.bundleID == bundleID }
  }
}

/// `notes open`, `notes refresh` and their reminders and contacts twins.
enum AppleCatalogCommand: Hashable {
  /// Open the app.
  case open(AppleCatalog)
  /// Relist the catalog now, asking macOS for access first if Flash never
  /// asked.
  case refresh(AppleCatalog)

  var name: CommandName {
    switch self {
    case .open(let catalog): return CommandName(catalog.rawValue, "open")
    case .refresh(let catalog): return CommandName(catalog.rawValue, "refresh")
    }
  }

  /// The mapping explanation: what the verb does, as one sentence.
  var explanation: String {
    switch self {
    case .open(let catalog): return "Opens \(catalog.appName)."
    case .refresh(let catalog): return "Relists \(catalog.items) for the flashlight."
    }
  }

  /// The command line's one-line description.
  var summary: String {
    switch self {
    case .open(let catalog): return "Open \(catalog.appName)"
    case .refresh(let catalog): return "Relist \(catalog.items) in @\(catalog.rawValue) now"
    }
  }

  static let all: [AppleCatalogCommand] = AppleCatalog.allCases.flatMap {
    [.open($0), .refresh($0)]
  }
}

/// One accepted listing entry: `id` selects it in its app again.
struct AppleCatalogRow: Equatable {
  var id: String
  var title: String
  var subtitle: String
}

/// The rows each catalog lists, from its app's own words. Pure, so the
/// shaping is tested without the apps.
enum AppleCatalogRows {
  /// `id<TAB>name` per line, as `notesListScript` prints them.
  static func notes(listing: String) -> [AppleCatalogRow] {
    listing.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = String(line).trimmed.split(
        separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard fields.count == 2 else { return nil }
      return AppleCatalogRow(
        id: String(fields[0]).trimmed, title: String(fields[1]).trimmed, subtitle: "Note")
    }
  }

  /// One open reminder: its identifier, list name and title.
  struct Reminder: Equatable {
    var id: String
    var list: String
    var title: String
  }

  static func reminders(_ reminders: [Reminder]) -> [AppleCatalogRow] {
    reminders.map { reminder in
      AppleCatalogRow(
        id: reminder.id.trimmed, title: reminder.title.trimmed,
        subtitle: "Reminder — \(reminder.list.trimmed)")
    }
  }

  /// One contact card: its identifier and display name.
  struct Contact: Equatable {
    var id: String
    var name: String
  }

  /// One row per name: two cards with the same name would read as the same
  /// row, so the first, in Contacts' own order, stands for both.
  static func contacts(_ contacts: [Contact]) -> [AppleCatalogRow] {
    var names = Set<String>()
    return contacts.compactMap { contact in
      let name = contact.name.trimmed
      guard names.insert(name).inserted else { return nil }
      return AppleCatalogRow(id: contact.id.trimmed, title: name, subtitle: "Contact")
    }
  }

  /// The flashlight rows, in listing order: an entry without an id or a
  /// title is dropped, and an id listed twice keeps its first row.
  static func candidates(_ rows: [AppleCatalogRow], of catalog: AppleCatalog) -> [Candidate] {
    var ids = Set<String>()
    return rows.compactMap { row in
      guard !row.id.isEmpty, !row.title.isEmpty, ids.insert(row.id).inserted else { return nil }
      return Candidate(
        kind: .plugin(catalog.rowKind), sourceID: catalog.sourceID, source: catalog.sourceLabel,
        title: row.title, subtitle: row.subtitle, sourcePayload: row.id)
    }
  }
}

/// Whether Flash may read a catalog, as macOS answers without asking.
enum AppleCatalogAccess: Equatable {
  case granted
  /// Flash never asked.
  case undetermined
  /// The user refused, or a policy did: the catalog stays empty, silently.
  case denied
}

/// Why a catalog is being relisted. Events relist what Flash may already
/// read; only the user's own use of a catalog — a query scoped to it, or its
/// refresh verb — may show macOS's access prompt.
struct AppleCatalogRequest: Equatable {
  /// List again when access is granted.
  var relist: Bool
  /// Ask macOS for access when Flash never asked.
  var mayAsk: Bool

  /// Resident start, the app launching, focus leaving it, a flashlight open.
  static let event = AppleCatalogRequest(relist: true, mayAsk: false)
  /// A flashlight query scoped to the catalog: the user is using it.
  static let query = AppleCatalogRequest(relist: false, mayAsk: true)
  /// `<catalog>_refresh`.
  static let command = AppleCatalogRequest(relist: true, mayAsk: true)

  /// Requests queued together run once, as their union.
  func merged(with other: AppleCatalogRequest) -> AppleCatalogRequest {
    AppleCatalogRequest(relist: relist || other.relist, mayAsk: mayAsk || other.mayAsk)
  }
}

/// What one request does to its catalog.
enum AppleCatalogStep: Equatable {
  case list
  /// Show macOS's access prompt, then list on a grant.
  case ask
  /// The app is not running, or access is refused: the catalog is empty.
  case clear
  /// Leave the rows as they are.
  case keep

  static func of(
    _ request: AppleCatalogRequest, running: Bool, access: AppleCatalogAccess
  ) -> AppleCatalogStep {
    guard running else { return .clear }
    switch access {
    case .granted: return request.relist ? .list : .keep
    case .undetermined: return request.mayAsk ? .ask : .keep
    case .denied: return .clear
    }
  }
}

/// When the catalogs relist, besides their apps launching and the refresh
/// verbs. Nothing polls: a catalog relists when focus leaves its app (the
/// user may have just edited it) and when the flashlight opens — then only if
/// its app is focused or its listing began at least `sessionTTLMs` ago, which
/// bounds how stale a change synced in the background can be. The rows stay
/// the last good listing meanwhile, so a query never waits on an app.
struct AppleCatalogSchedule: Equatable {
  static let sessionTTLMs = 60_000

  private(set) var focusedBundleID: String?
  private(set) var listedAtMs: [AppleCatalog: Int] = [:]

  /// Record focus moving to `bundleID`. Returns the catalog whose app it
  /// left.
  mutating func focus(_ bundleID: String?) -> AppleCatalog? {
    let previous = focusedBundleID
    focusedBundleID = bundleID
    guard previous != bundleID else { return nil }
    return AppleCatalog.owning(bundleID: previous)
  }

  /// The running catalogs a flashlight open relists — the focused one, and
  /// any never listed or listed at least `sessionTTLMs` before `nowMs` —
  /// marked as listed at `nowMs` so a reopen does not queue them again.
  mutating func claimOnOpen(running: Set<AppleCatalog>, nowMs: Int) -> [AppleCatalog] {
    let due = AppleCatalog.allCases.filter { catalog in
      guard running.contains(catalog) else { return false }
      if focusedBundleID == catalog.bundleID { return true }
      guard let listedAt = listedAtMs[catalog] else { return true }
      return nowMs - listedAt >= Self.sessionTTLMs
    }
    for catalog in due { mark(catalog, nowMs: nowMs) }
    return due
  }

  mutating func mark(_ catalog: AppleCatalog, nowMs: Int) {
    listedAtMs[catalog] = nowMs
  }
}

/// The scripts behind the Notes catalog: Notes has no framework API.
enum NotesScripts {
  /// Every note of every account as `id<TAB>name`, one per line; nothing
  /// when Notes is not running, so a listing never launches it.
  ///
  /// The ids and names are read with one `every note` request each per
  /// account, never one request per note: each Apple Event is a round trip
  /// Notes answers on its main thread, so a per-note loop over a few hundred
  /// notes took 10–30 s per listing (and hit the 30 s timeout) while Notes
  /// itself stopped responding. Notes returns both lists in the same element
  /// order, so they pair by index.
  static let list = """
    if application "Notes" is not running then return ""
    tell application "Notes"
      set output to {}
      repeat with acc in accounts
        try
          set ids to id of every note of acc
          set names to name of every note of acc
          repeat with i from 1 to count of ids
            set the end of output to ((item i of ids as text) & tab & (item i of names as text))
          end repeat
        end try
      end repeat
      set AppleScript's text item delimiters to linefeed
      return output as text
    end tell
    """

  /// Bring Notes forward on the note with this id.
  static func show(id: String) -> String {
    """
    tell application "Notes"
      activate
      try
        show note id \(quote(id))
      end try
    end tell
    """
  }

  /// `value` as an AppleScript string literal.
  static func quote(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}
