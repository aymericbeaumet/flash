import AppKit
import Carbon
import Contacts
import EventKit
import Foundation

/// An Apple app whose items a plugin lists through the host: `host.notes`,
/// `host.reminders` and `host.contacts`, each behind the capability of the
/// same name. Flash holds the grant (Automation of Notes, Reminders,
/// Contacts); the plugin's sandbox gains nothing.
enum HostAppItemKind: String, CaseIterable, Sendable {
  case notes
  case reminders
  case contacts

  /// The RPC a plugin calls for it (`protocol.json` `app_items.methods`).
  var method: String { "host.\(rawValue)" }

  /// The grant as macOS names it, for the log.
  var grant: String {
    switch self {
    case .notes: return "Notes"
    case .reminders: return "Reminders"
    case .contacts: return "Contacts"
    }
  }
}

/// One item as its reader saw it. What a plugin receives of it is
/// `HostAppItems.wire`: an identifier, the one line the app shows it by,
/// and for a reminder what orders it. Nothing else of the item is read.
struct HostAppItem: Equatable {
  /// Selects the item in its app again (`show`).
  var id: String
  /// A note's name, a reminder's title, the name Contacts shows for a card.
  var title: String
  /// A reminder's list: its title, and its position among Reminders' lists
  /// (nil when Reminders no longer names it).
  var list: String?
  var listIndex: Int?
  /// When a reminder was created.
  var created: Date?
}

/// What one listing found.
enum HostAppItemListing: Equatable {
  /// In the app's own order.
  case items([HostAppItem])
  case denied
  case failed(String)
}

/// Reads one app's items. The blocking calls run on `HostAppItems`' queue,
/// never main; nothing here asks macOS for access but `requestAccess`. The
/// resident wires the live readers at launch; nothing is wired inside the
/// test runner, where a test injects its own and no test reads the Mac's
/// notes, reminders or contacts, runs a script or shows a prompt.
protocol AppItemProviding: AnyObject {
  /// Whether Flash may read the app now, as macOS answers without asking.
  func access() -> AppleCatalogAccess
  /// Whether macOS can be asked now. Notes answers an Automation request
  /// only while it runs.
  func canRequestAccess() -> Bool
  /// Ask macOS (its prompt names Flash); `done` gets whether access was
  /// granted, on any queue.
  func requestAccess(_ done: @escaping (Bool) -> Void)
  func list() -> HostAppItemListing
  /// Bring the app forward on the item with `id`; `done` gets nil, or why
  /// it failed, on any queue.
  func show(id: String, done: @escaping (String?) -> Void)
}

/// One app's items for its host RPC: plugins never reach the app or its
/// framework themselves, and the grant stays Flash's. Every read runs on
/// the kind's own serial queue, never main, so a slow Notes script never
/// holds up Reminders.
///
/// Sendable by confinement: every stored property is immutable or touched
/// on `queue` alone.
final class HostAppItems: @unchecked Sendable {
  /// The most items, and the most bytes of them, one reply holds
  /// (`protocol.json` `app_items`).
  static let maxItems = 10_000
  static let maxReplyBytes = 2_097_152
  /// The longest identifier `show` takes.
  static let maxIDBytes = 1_024
  /// A listing this slow is logged as a warning.
  static let slowListMs = 1_000

  /// What a `list` answers.
  enum Listing {
    /// The items as written on the wire, and whether later ones were left
    /// out of the reply.
    case items([[String: Any]], truncated: Bool)
    case noAccess(AppleCatalogAccess)
    case failed(String)
  }

  let kind: HostAppItemKind
  let queue: DispatchQueue
  private let provider: any AppItemProviding
  // Confined to `queue`.
  private var prompt = PendingGrantRequest()

  init(kind: HostAppItemKind, provider: any AppItemProviding, queue: DispatchQueue? = nil) {
    self.kind = kind
    self.provider = provider
    // `.userInitiated`: a plugin's search or command waits on its read.
    self.queue =
      queue ?? DispatchQueue(label: "flash.app-items.\(kind.rawValue)", qos: .userInitiated)
  }

  /// Runs on `queue`.
  func access() -> AppleCatalogAccess { provider.access() }

  /// Runs on `queue`.
  func canRequestAccess() -> Bool { provider.canRequestAccess() }

  /// Ask macOS when Flash never asked; `done` gets the access once the user
  /// answered, on `queue`. Runs on `queue`, which stays free while the
  /// prompt is up.
  func requestAccess(_ done: @escaping (AppleCatalogAccess) -> Void) {
    let access = provider.access()
    guard access == .undetermined else { return done(access) }
    guard prompt.join({ done($0 ? .granted : .denied) }) else { return }
    let grant = kind.grant
    FlashLog.info("[apple] asking for \(grant) access")
    provider.requestAccess { [weak self] granted in
      guard let self else { return }
      self.queue.async {
        FlashLog.info("[apple] \(grant) access \(granted ? "granted" : "denied")")
        for waiter in self.prompt.finish() { waiter(granted) }
      }
    }
  }

  /// List the items. Runs on `queue`; never asks.
  func list() -> Listing {
    let access = provider.access()
    guard access == .granted else { return .noAccess(access) }
    switch provider.list() {
    case .items(let items):
      let wire = Self.wire(items)
      return .items(wire.items, truncated: wire.truncated)
    case .denied:
      return .noAccess(.denied)
    case .failed(let reason):
      FlashLog.warn("[apple] \(kind.rawValue) list failed: \(reason)")
      return .failed(reason)
    }
  }

  /// Bring the app forward on the item with `id`; `done` gets nil, or why it
  /// failed, on any queue. Runs on `queue`. Only an app Flash may read is
  /// asked: a Notes script sent without the grant would raise macOS's
  /// prompt.
  func show(id: String, done: @escaping (String?) -> Void) {
    guard provider.access() == .granted else { return done("\(kind.method) show requires access") }
    provider.show(id: id, done: done)
  }

  /// Wait for every queued read: tests only.
  func drain() { queue.sync {} }

  // MARK: - The wire shape

  /// `items` in order as a `list` reply carries them: at most `maxItems`
  /// and `maxReplyBytes` of them, the later ones left out.
  static func wire(_ items: [HostAppItem]) -> (items: [[String: Any]], truncated: Bool) {
    var wire: [[String: Any]] = []
    wire.reserveCapacity(min(items.count, maxItems))
    // The array's two brackets.
    var bytes = 2
    for item in items {
      guard wire.count < maxItems else { return (wire, true) }
      let object = self.wire(item)
      guard
        let encoded = try? JSONSerialization.data(
          withJSONObject: object, options: [.withoutEscapingSlashes]),
        bytes + encoded.count + 1 <= maxReplyBytes
      else { return (wire, true) }
      bytes += encoded.count + 1
      wire.append(object)
    }
    return (wire, false)
  }

  /// One item as `protocol.json` `app_item` shapes it.
  static func wire(_ item: HostAppItem) -> [String: Any] {
    var object: [String: Any] = [
      "id": item.id,
      "title": HostCalendarEvents.cut(item.title, toBytes: PluginProtocol.maxTitleBytes),
    ]
    if let list = item.list {
      object["list"] = HostCalendarEvents.cut(list, toBytes: PluginProtocol.maxTitleBytes)
    }
    if let listIndex = item.listIndex { object["list_index"] = listIndex }
    if let created = item.created { object["created"] = created.timeIntervalSince1970 }
    return object
  }

  /// Whether `id` is one `show` takes: 1 to `maxIDBytes` bytes, none of
  /// them a control character.
  static func isShowableID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= maxIDBytes
      && !id.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }
}

// MARK: - The resident's readers

/// The resident's mechanisms, inert inside the test runner, whoever reaches
/// them: no access, no prompt, no read, no script, no app opened.
enum LiveAppItems {
  /// False inside the test runner.
  static let mechanismsAllowed = NSClassFromString("XCTestCase") == nil
  static let inertReason = "app items are inert inside the test runner"

  static func providers() -> [HostAppItemKind: any AppItemProviding] {
    [.notes: LiveNotesItems(), .reminders: LiveRemindersItems(), .contacts: LiveContactsItems()]
  }

  /// An identifier a URL scheme takes whole: letters, digits and the marks
  /// EventKit and Contacts use in theirs, so it adds no path, query or
  /// fragment to the URL built around it.
  static func isURLSafeID(_ id: String) -> Bool {
    !id.isEmpty
      && id.unicodeScalars.allSatisfy { scalar in
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
          || ("0"..."9").contains(scalar) || ":._-".unicodeScalars.contains(scalar)
      }
  }

  /// Open `url` in its app.
  static func open(_ url: URL?, done: @escaping (String?) -> Void) {
    guard mechanismsAllowed else { return done(inertReason) }
    guard let url else { return done("no URL for the item") }
    AppleCatalogReaders.open(url, done: done)
  }
}

/// Notes: fixed AppleScript through the in-process runner, since Notes has
/// no framework API. macOS asks once whether Flash may control Notes
/// (Automation), and answers only while Notes runs.
final class LiveNotesItems: AppItemProviding {
  static let bundleID = "com.apple.Notes"
  static let listTimeout: TimeInterval = 30
  static let showTimeout: TimeInterval = 10

  func access() -> AppleCatalogAccess {
    guard LiveAppItems.mechanismsAllowed else { return .denied }
    return AutomationConsent.access(toBundleID: Self.bundleID, ask: false)
  }

  /// The running-app gate: macOS has nobody to ask about while Notes is not
  /// running, and nothing here launches it.
  func canRequestAccess() -> Bool {
    guard LiveAppItems.mechanismsAllowed else { return false }
    return !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
  }

  /// macOS's Automation prompt blocks its caller until the user answers, so
  /// it waits on a global queue rather than the notes queue.
  func requestAccess(_ done: @escaping (Bool) -> Void) {
    guard LiveAppItems.mechanismsAllowed else { return done(false) }
    // `done` only hands the answer to the notes queue.
    nonisolated(unsafe) let done = done
    DispatchQueue.global(qos: .userInitiated).async {
      done(AutomationConsent.access(toBundleID: Self.bundleID, ask: true) == .granted)
    }
  }

  func list() -> HostAppItemListing {
    guard LiveAppItems.mechanismsAllowed else { return .failed(LiveAppItems.inertReason) }
    return Self.listing(of: AppleScriptRunner.run(NotesScripts.list, timeout: Self.listTimeout))
  }

  /// What the list script's run says: its items, a refused Automation
  /// request, or why it failed.
  static func listing(of output: AppleScriptOutput) -> HostAppItemListing {
    if output.ok { return .items(items(listing: output.stdout)) }
    if output.stderr.hasSuffix("(\(errAEEventNotPermitted))\n") { return .denied }
    return .failed(output.failure ?? "applescript failed")
  }

  /// `id<TAB>name` per line, as `NotesScripts.list` prints them; a line
  /// without both fields is no note.
  static func items(listing: String) -> [HostAppItem] {
    listing.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = String(line).trimmed.split(
        separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      guard fields.count == 2 else { return nil }
      return HostAppItem(id: String(fields[0]), title: String(fields[1]))
    }
  }

  /// The script, which activates Notes, runs on a global queue: a listing
  /// in flight never holds a pick back.
  func show(id: String, done: @escaping (String?) -> Void) {
    guard LiveAppItems.mechanismsAllowed else { return done(LiveAppItems.inertReason) }
    // `done` only replies to the plugin.
    nonisolated(unsafe) let done = done
    DispatchQueue.global(qos: .userInitiated).async {
      done(AppleScriptRunner.run(NotesScripts.show(id: id), timeout: Self.showTimeout).failure)
    }
  }
}

/// Reminders: the open reminders of every list, through EventKit. macOS asks
/// once whether Flash may access Reminders.
final class LiveRemindersItems: AppItemProviding {
  static let listTimeout: TimeInterval = 30
  /// Made by the first listing, once access is granted, and kept. Only the
  /// reminders queue touches it.
  private var store: EKEventStore?

  func access() -> AppleCatalogAccess {
    guard LiveAppItems.mechanismsAllowed else { return .denied }
    return EventKitAccess.access(EKEventStore.authorizationStatus(for: .reminder))
  }

  func canRequestAccess() -> Bool { LiveAppItems.mechanismsAllowed }

  func requestAccess(_ done: @escaping (Bool) -> Void) {
    guard LiveAppItems.mechanismsAllowed else { return done(false) }
    EventKitAccess.request(.reminder, done)
  }

  func list() -> HostAppItemListing {
    guard LiveAppItems.mechanismsAllowed else { return .failed(LiveAppItems.inertReason) }
    guard access() == .granted else { return .denied }
    let store = self.store ?? EKEventStore()
    self.store = store
    let lists = store.calendars(for: .reminder).map(\.calendarIdentifier)
    let rank = Dictionary(
      lists.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: nil)
    let fetched = FetchedReminders()
    let request = store.fetchReminders(matching: predicate) { reminders in
      fetched.finish(
        (reminders ?? []).map { reminder in
          FetchedReminders.Entry(
            id: reminder.calendarItemIdentifier,
            listID: reminder.calendar?.calendarIdentifier ?? "",
            list: reminder.calendar?.title ?? "",
            title: reminder.title ?? "",
            created: reminder.creationDate)
        })
    }
    guard let entries = fetched.wait(seconds: Self.listTimeout) else {
      store.cancelFetchRequest(request)
      return .failed("reminders fetch timed out after \(Int(Self.listTimeout))s")
    }
    return .items(
      entries.map { entry in
        HostAppItem(
          id: entry.id, title: entry.title, list: entry.list, listIndex: rank[entry.listID],
          created: entry.created)
      })
  }

  /// Reminders opens its own URL scheme on the reminder.
  func show(id: String, done: @escaping (String?) -> Void) {
    LiveAppItems.open(Self.url(id: id), done: done)
  }

  static func url(id: String) -> URL? {
    guard LiveAppItems.isURLSafeID(id) else { return nil }
    return URL(string: "x-apple-reminderkit://REMCDReminder/\(id)")
  }
}

/// Contacts: every card's name, in Contacts' order, through the Contacts
/// framework: never a phone number, an address or any other field. macOS
/// asks once whether Flash may access Contacts.
final class LiveContactsItems: AppItemProviding {
  func access() -> AppleCatalogAccess {
    guard LiveAppItems.mechanismsAllowed else { return .denied }
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized: return .granted
    case .notDetermined: return .undetermined
    case .denied, .restricted: return .denied
    @unknown default: return .denied
    }
  }

  func canRequestAccess() -> Bool { LiveAppItems.mechanismsAllowed }

  func requestAccess(_ done: @escaping (Bool) -> Void) {
    guard LiveAppItems.mechanismsAllowed else { return done(false) }
    // `done` only hands the answer to the contacts queue.
    nonisolated(unsafe) let done = done
    // Held until macOS answers; nothing else reaches this store.
    nonisolated(unsafe) let asking = CNContactStore()
    asking.requestAccess(for: .contacts) { granted, _ in
      withExtendedLifetime(asking) { done(granted) }
    }
  }

  func list() -> HostAppItemListing {
    guard LiveAppItems.mechanismsAllowed else { return .failed(LiveAppItems.inertReason) }
    guard access() == .granted else { return .denied }
    let request = CNContactFetchRequest(keysToFetch: [
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactTypeKey as CNKeyDescriptor,
    ])
    request.sortOrder = .userDefault
    var contacts: [HostAppItem] = []
    do {
      try CNContactStore().enumerateContacts(with: request) { contact, _ in
        contacts.append(HostAppItem(id: contact.identifier, title: Self.name(of: contact)))
      }
    } catch let error as CNError where error.code == .authorizationDenied {
      return .denied
    } catch {
      return .failed(error.localizedDescription)
    }
    return .items(contacts)
  }

  /// The name Contacts shows: the person's full name, or a company card's
  /// company.
  private static func name(of contact: CNContact) -> String {
    let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
    guard name.trimmed.isEmpty, contact.contactType == .organization else { return name }
    return contact.organizationName
  }

  /// Contacts opens its own URL scheme on the card.
  func show(id: String, done: @escaping (String?) -> Void) {
    LiveAppItems.open(Self.url(id: id), done: done)
  }

  static func url(id: String) -> URL? {
    guard LiveAppItems.isURLSafeID(id) else { return nil }
    return URL(string: "addressbook://\(id)")
  }
}
