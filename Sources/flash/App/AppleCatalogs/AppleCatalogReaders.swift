import AppKit
import Carbon
import Contacts
import EventKit
import Foundation

/// A catalog listing: the rows, an authoritative "no access", or a failure
/// that keeps the last good rows.
enum AppleCatalogListing: Equatable {
  case rows([AppleCatalogRow])
  case denied
  case failed(String)
}

/// Reads one catalog's app. The blocking calls run on the catalog's own
/// queue, never main; nothing here asks macOS for access but
/// `requestAccess`, which the user's own use of the catalog triggers.
protocol AppleCatalogReading: AnyObject {
  /// Whether Flash may read the app now, as macOS answers without asking.
  func access() -> AppleCatalogAccess
  /// Ask macOS (its prompt names Flash); `done` gets whether access was
  /// granted, on any queue.
  func requestAccess(_ done: @escaping (Bool) -> Void)
  func list() -> AppleCatalogListing
  /// Bring the app forward on the row with `id`; `done` gets nil, or why it
  /// failed, on any queue.
  func show(id: String, done: @escaping (String?) -> Void)
}

enum AppleCatalogReaders {
  static func live() -> [AppleCatalog: AppleCatalogReading] {
    [
      .notes: NotesCatalogReader(),
      .reminders: RemindersCatalogReader(),
      .contacts: ContactsCatalogReader(),
    ]
  }

  /// Open `url` in its app, through NSWorkspace's asynchronous open started
  /// on main, as the flashlight's other opens are.
  static func open(_ url: URL, done: @escaping (String?) -> Void) {
    DispatchQueue.main.async {
      NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        done(error?.localizedDescription)
      }
    }
  }
}

/// Notes: AppleScript through the in-process runner, since Notes has no
/// framework API. macOS asks once whether Flash may control Notes
/// (Automation).
final class NotesCatalogReader: AppleCatalogReading {
  static let listTimeout: TimeInterval = 30
  static let showTimeout: TimeInterval = 10

  func access() -> AppleCatalogAccess {
    AutomationConsent.access(toBundleID: AppleCatalog.notes.bundleID, ask: false)
  }

  /// macOS's Automation prompt blocks its caller until the user answers, so
  /// it waits on a global queue rather than the catalog's.
  func requestAccess(_ done: @escaping (Bool) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      done(AutomationConsent.access(toBundleID: AppleCatalog.notes.bundleID, ask: true) == .granted)
    }
  }

  func list() -> AppleCatalogListing {
    let output = AppleScriptRunner.run(NotesScripts.list, timeout: Self.listTimeout)
    if output.ok { return .rows(AppleCatalogRows.notes(listing: output.stdout)) }
    if output.stderr.hasSuffix("(\(errAEEventNotPermitted))\n") { return .denied }
    return .failed(output.failure ?? "applescript failed")
  }

  func show(id: String, done: @escaping (String?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      done(AppleScriptRunner.run(NotesScripts.show(id: id), timeout: Self.showTimeout).failure)
    }
  }
}

/// Whether Flash may send Apple Events to an app (Automation), without
/// sending one.
enum AutomationConsent {
  /// `ask` shows macOS's prompt when Flash never asked, and then blocks until
  /// the user answers: never on main. An app that is not running answers
  /// nothing, which reads as undetermined.
  static func access(toBundleID bundleID: String, ask: Bool) -> AppleCatalogAccess {
    var target = AEAddressDesc()
    let bytes = Array(bundleID.utf8)
    guard AECreateDesc(DescType(typeApplicationBundleID), bytes, bytes.count, &target) == noErr
    else { return .undetermined }
    defer { AEDisposeDesc(&target) }
    let status = AEDeterminePermissionToAutomateTarget(
      &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    return access(status: status)
  }

  static func access(status: OSStatus) -> AppleCatalogAccess {
    switch status {
    case noErr: return .granted
    case OSStatus(errAEEventNotPermitted): return .denied
    default: return .undetermined
    }
  }
}

/// Reminders: the open reminders of every list, through EventKit. macOS asks
/// once whether Flash may access Reminders.
final class RemindersCatalogReader: AppleCatalogReading {
  static let listTimeout: TimeInterval = 30
  /// Made by the first listing, once access is granted, and kept. Only the
  /// reminders queue touches it.
  private var store: EKEventStore?

  func access() -> AppleCatalogAccess {
    EventKitAccess.access(EKEventStore.authorizationStatus(for: .reminder))
  }

  func requestAccess(_ done: @escaping (Bool) -> Void) {
    EventKitAccess.request(.reminder, done)
  }

  func list() -> AppleCatalogListing {
    guard access() == .granted else { return .denied }
    let store = self.store ?? EKEventStore()
    self.store = store
    let lists = store.calendars(for: .reminder).map(\.calendarIdentifier)
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
    return .rows(AppleCatalogRows.reminders(Self.ordered(entries, lists: lists)))
  }

  /// List by list, in Reminders' order, then oldest first.
  static func ordered(
    _ entries: [FetchedReminders.Entry], lists: [String]
  ) -> [AppleCatalogRows.Reminder] {
    let rank = Dictionary(
      lists.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    return entries.enumerated().sorted { lhs, rhs in
      let left = rank[lhs.element.listID] ?? lists.count
      let right = rank[rhs.element.listID] ?? lists.count
      if left != right { return left < right }
      let leftDate = lhs.element.created ?? .distantFuture
      let rightDate = rhs.element.created ?? .distantFuture
      if leftDate != rightDate { return leftDate < rightDate }
      return lhs.offset < rhs.offset
    }.map {
      AppleCatalogRows.Reminder(id: $0.element.id, list: $0.element.list, title: $0.element.title)
    }
  }

  /// Reminders opens its own URL scheme on the reminder.
  func show(id: String, done: @escaping (String?) -> Void) {
    guard let url = Self.url(id: id) else {
      done("no reminder URL for \(id)")
      return
    }
    AppleCatalogReaders.open(url, done: done)
  }

  static func url(id: String) -> URL? {
    URL(string: "x-apple-reminderkit://REMCDReminder/\(id)")
  }
}

/// One EventKit fetch, handed from its callback queue to the waiting reader.
final class FetchedReminders {
  struct Entry: Equatable {
    var id: String
    var listID: String
    var list: String
    var title: String
    var created: Date?
  }

  private let lock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private var entries: [Entry] = []

  func finish(_ entries: [Entry]) {
    lock.lock()
    self.entries = entries
    lock.unlock()
    done.signal()
  }

  func wait(seconds: TimeInterval) -> [Entry]? {
    guard done.wait(timeout: .now() + seconds) == .success else { return nil }
    lock.lock()
    defer { lock.unlock() }
    return entries
  }
}

/// Contacts: every card's name, in Contacts' order, through the Contacts
/// framework. macOS asks once whether Flash may access Contacts.
final class ContactsCatalogReader: AppleCatalogReading {
  func access() -> AppleCatalogAccess {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized: return .granted
    case .notDetermined: return .undetermined
    case .denied, .restricted: return .denied
    @unknown default: return .denied
    }
  }

  func requestAccess(_ done: @escaping (Bool) -> Void) {
    let asking = CNContactStore()
    asking.requestAccess(for: .contacts) { granted, _ in
      withExtendedLifetime(asking) { done(granted) }
    }
  }

  func list() -> AppleCatalogListing {
    guard access() == .granted else { return .denied }
    let request = CNContactFetchRequest(keysToFetch: [
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactTypeKey as CNKeyDescriptor,
    ])
    request.sortOrder = .userDefault
    var contacts: [AppleCatalogRows.Contact] = []
    do {
      try CNContactStore().enumerateContacts(with: request) { contact, _ in
        contacts.append(
          AppleCatalogRows.Contact(id: contact.identifier, name: Self.name(of: contact)))
      }
    } catch let error as CNError where error.code == .authorizationDenied {
      return .denied
    } catch {
      return .failed(error.localizedDescription)
    }
    return .rows(AppleCatalogRows.contacts(contacts))
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
    guard let url = Self.url(id: id) else {
      done("no contact URL for \(id)")
      return
    }
    AppleCatalogReaders.open(url, done: done)
  }

  static func url(id: String) -> URL? {
    URL(string: "addressbook://\(id)")
  }
}
