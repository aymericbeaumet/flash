import EventKit
import Foundation

/// One occurrence of an event, as the calendar reader saw it. What a plugin
/// receives of it is `HostCalendarEvents.wire`: the notes never leave the
/// host.
struct HostCalendarEvent: Equatable {
  /// The event's identifier and this occurrence's start: a repeating
  /// event's occurrences share the identifier.
  var id: String
  var title: String
  var start: Date
  var end: Date
  var isAllDay = false
  /// The title of the calendar it belongs to.
  var calendar = ""
  /// The user is an attendee who declined it.
  var declined = false
  var canceled = false
  /// The event's URL field.
  var url: String?
  var location: String?
  /// Read for the link-shaped runs in them, and dropped.
  var notes: String?
}

/// What one read of the calendar found.
enum HostCalendarListing: Equatable {
  case events([HostCalendarEvent])
  case denied
  case failed(String)
}

/// Reads the calendar. The blocking calls run on `HostCalendarEvents`'
/// queue, never main; nothing here asks macOS for access but
/// `requestAccess`. The resident wires `LiveCalendarEvents` at launch;
/// nothing is wired inside the test runner, where a test injects its own
/// and no test reads the Mac's calendars or shows a prompt.
protocol CalendarEventProviding: AnyObject {
  /// Whether Flash may read events now, as macOS answers without asking.
  func access() -> AppleCatalogAccess
  /// Ask macOS (its prompt names Flash); `done` gets whether access was
  /// granted, on any queue.
  func requestAccess(_ done: @escaping (Bool) -> Void)
  /// The occurrences overlapping `start..<end` in the calendars titled
  /// `calendars` (every event calendar when empty).
  func events(from start: Date, to end: Date, calendars: [String]) -> HostCalendarListing
  /// Call `onChange`, on any queue, each time the calendar database changes,
  /// until `stopObservingChanges`.
  func observeChanges(_ onChange: @escaping @Sendable () -> Void)
  func stopObservingChanges()
}

extension AppleCatalogAccess {
  /// The name a host RPC reports the grant by (`protocol.json`
  /// `calendar_events.access`).
  var wireName: String {
    switch self {
    case .granted: return "granted"
    case .denied: return "denied"
    case .undetermined: return "undetermined"
    }
  }

  /// In contract order.
  static let wireNames = [granted, denied, undetermined].map(\.wireName)
}

/// One macOS prompt for one grant: a request made while the prompt is open
/// joins it and gets its answer. Confined to its owner's queue.
struct PendingGrantRequest {
  private var waiters: [(Bool) -> Void]?

  /// Wait for the answer. True when no prompt is open: the caller asks, and
  /// hands the answer to `finish`.
  mutating func join(_ done: @escaping (Bool) -> Void) -> Bool {
    if waiters != nil {
      waiters?.append(done)
      return false
    }
    waiters = [done]
    return true
  }

  /// The user answered: everyone who waited, in order.
  mutating func finish() -> [(Bool) -> Void] {
    defer { waiters = nil }
    return waiters ?? []
  }
}

/// EventKit for `host.calendar_events`: plugins never reach the calendar
/// themselves, and the Calendars grant stays Flash's. Every read runs on one
/// serial queue, never main. The database is observed only between `observe`
/// calls, which follow whether a plugin holding the capability listens to
/// `core:calendar.changed`; a burst of changes is announced once.
///
/// Sendable by confinement: every stored property is immutable or touched
/// on `queue` alone.
final class HostCalendarEvents: @unchecked Sendable {
  static let changeWindowID = "core:calendar_events_changed"
  /// A sync writes many changes at once: they are announced as one.
  static let changeWindowMs = 500
  /// The longest window one `list` reads (`calendar_events.max_window_seconds`).
  static let maxWindowSeconds = 1_209_600
  /// The most calendar titles one `list` names.
  static let maxCalendars = 64
  /// The most events, and the most bytes of them, one reply holds.
  static let maxEvents = 1_000
  static let maxReplyBytes = 1_048_576
  /// The most link-shaped runs of an event's notes a reply carries.
  static let maxLinks = 32
  /// The latest instant a window names: the end of year 9999.
  static let maxTime = 253_402_300_799

  /// What a `list` answers.
  enum Listing {
    /// The events as written on the wire, and whether later ones were left
    /// out of the reply.
    case events([[String: Any]], truncated: Bool)
    case noAccess(AppleCatalogAccess)
    case failed(String)
  }

  let queue: DispatchQueue
  private let provider: any CalendarEventProviding
  private let changed: () -> Void
  private let changeWindow: PollDeadline
  // Confined to `queue`.
  private var observing = false
  private var prompt = PendingGrantRequest()

  /// `changed` runs on `queue` once per burst of database changes, and once
  /// the user answered macOS's prompt.
  init(
    provider: any CalendarEventProviding,
    // `.userInitiated`: a plugin's command waits on its read.
    queue: DispatchQueue = DispatchQueue(label: "flash.calendar", qos: .userInitiated),
    scheduler: PollScheduler = .shared,
    changed: @escaping () -> Void
  ) {
    self.provider = provider
    self.queue = queue
    self.changed = changed
    // `.normal`: a changed event reaches a value someone may be looking at.
    changeWindow = PollDeadline(
      Self.changeWindowID, priority: .normal, on: queue, scheduler: scheduler)
  }

  /// Whether a plugin that may hear `core:calendar.changed` listens to it.
  func observe(_ observed: Bool) {
    queue.async { [weak self] in
      guard let self, observed != self.observing else { return }
      self.observing = observed
      if observed {
        self.provider.observeChanges { [weak self] in
          guard let self else { return }
          self.queue.async { self.databaseChanged() }
        }
      } else {
        self.provider.stopObservingChanges()
        self.changeWindow.cancel()
      }
    }
  }

  /// Runs on `queue`.
  func access() -> AppleCatalogAccess { provider.access() }

  /// Ask macOS when Flash never asked; `done` gets the access once the user
  /// answered, on `queue`. Runs on `queue`, which stays free while the
  /// prompt is up.
  func requestAccess(_ done: @escaping (AppleCatalogAccess) -> Void) {
    let access = provider.access()
    guard access == .undetermined else { return done(access) }
    guard prompt.join({ done($0 ? .granted : .denied) }) else { return }
    FlashLog.info("[calendar] asking for Calendars access")
    provider.requestAccess { [weak self] granted in
      guard let self else { return }
      self.queue.async {
        FlashLog.info("[calendar] Calendars access \(granted ? "granted" : "denied")")
        for waiter in self.prompt.finish() { waiter(granted) }
        // The answer changes what every listener reads.
        self.changed()
      }
    }
  }

  /// Read `start..<end`. Runs on `queue`; never asks.
  func list(from start: Date, to end: Date, calendars: [String]) -> Listing {
    let access = provider.access()
    guard access == .granted else { return .noAccess(access) }
    switch provider.events(from: start, to: end, calendars: calendars) {
    case .events(let events):
      let wire = Self.wire(events)
      return .events(wire.events, truncated: wire.truncated)
    case .denied:
      return .noAccess(.denied)
    case .failed(let reason):
      FlashLog.warn("[calendar] read failed: \(reason)")
      return .failed(reason)
    }
  }

  /// Wait for every queued read: tests only.
  func drain() { queue.sync {} }

  private func databaseChanged() {
    guard observing, !changeWindow.isArmed else { return }
    changeWindow.arm(afterMs: Self.changeWindowMs) { [weak self] in self?.changed() }
  }

  // MARK: - The wire shape

  /// `events` in start order as a `list` reply carries them: at most
  /// `maxEvents` and `maxReplyBytes` of them, the later ones left out.
  static func wire(_ events: [HostCalendarEvent]) -> (events: [[String: Any]], truncated: Bool) {
    let sorted = events.sorted { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
    var wire: [[String: Any]] = []
    // The array's two brackets.
    var bytes = 2
    for event in sorted {
      guard wire.count < maxEvents else { return (wire, true) }
      let object = self.wire(event)
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

  /// One event as `protocol.json` `calendar_event` shapes it. The notes
  /// are reduced to their link-shaped runs.
  static func wire(_ event: HostCalendarEvent) -> [String: Any] {
    var object: [String: Any] = [
      "id": event.id,
      "title": cut(event.title, toBytes: PluginProtocol.maxTitleBytes),
      "start": event.start.timeIntervalSince1970,
      "end": event.end.timeIntervalSince1970,
      "all_day": event.isAllDay,
      "calendar": cut(event.calendar, toBytes: PluginProtocol.maxTitleBytes),
      "declined": event.declined,
      "canceled": event.canceled,
    ]
    // A link is never cut: an over-long field is left out whole.
    for (key, text) in [("url", event.url), ("location", event.location)] {
      if let text, !text.isEmpty, text.utf8.count <= PluginProtocol.maxURLBytes {
        object[key] = text
      }
    }
    let links = event.notes.map(linkRuns(in:)) ?? []
    if !links.isEmpty { object["links"] = links }
    return object
  }

  /// A scheme, `:/` and what a link runs to: never whitespace, a quote or
  /// the brackets that wrap one in text or HTML. Which run is a meeting
  /// link, and of which service, is the plugin's to say.
  // The pattern is a constant; a broken one fails every test that reads notes.
  private static let linkRun = try! NSRegularExpression(
    pattern: #"[a-z][a-z0-9+.-]*:/[^\s<>"'()\[\]{}]+"#, options: [.caseInsensitive])

  /// The link-shaped runs of `text`, in order: at most `maxLinks`, none over
  /// the URL bound.
  static func linkRuns(in text: String) -> [String] {
    var runs: [String] = []
    let range = NSRange(text.startIndex..., in: text)
    linkRun.enumerateMatches(in: text, range: range) { match, _, stop in
      guard let match, let matched = Range(match.range, in: text) else { return }
      let run = String(text[matched])
      guard run.utf8.count <= PluginProtocol.maxURLBytes else { return }
      runs.append(run)
      if runs.count == maxLinks { stop.pointee = true }
    }
    return runs
  }

  /// `text` within `limit` UTF-8 bytes, cut at a character boundary.
  static func cut(_ text: String, toBytes limit: Int) -> String {
    guard text.utf8.count > limit else { return text }
    var cut = ""
    var bytes = 0
    for character in text {
      bytes += character.utf8.count
      guard bytes <= limit else { break }
      cut.append(character)
    }
    return cut
  }
}

/// `core:calendar.changed`'s OS source: the calendar database is observed
/// exactly while a plugin that may hear the event listens to it.
final class CalendarChangeSource: HostEventSource {
  private let events: () -> HostCalendarEvents?

  init(_ events: @escaping () -> HostCalendarEvents?) {
    self.events = events
  }

  func start() { events()?.observe(true) }
  func stop() { events()?.observe(false) }
}

/// The resident's mechanism: calendar events through EventKit. macOS asks
/// once whether Flash may access your calendars. Inert inside the test
/// runner, whoever reaches it: no access, no prompt, no read.
final class LiveCalendarEvents: CalendarEventProviding {
  /// False inside the test runner.
  static let mechanismsAllowed = NSClassFromString("XCTestCase") == nil
  static let inertReason = "calendar events are inert inside the test runner"

  /// Made by the first read once access is granted, and kept. Only the
  /// calendar queue touches it.
  private var store: EKEventStore?
  private var onChange: (@Sendable () -> Void)?
  private var observer: NSObjectProtocol?

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func access() -> AppleCatalogAccess {
    guard Self.mechanismsAllowed else { return .denied }
    return EventKitAccess.access(EKEventStore.authorizationStatus(for: .event))
  }

  func requestAccess(_ done: @escaping (Bool) -> Void) {
    guard Self.mechanismsAllowed else { return done(false) }
    EventKitAccess.request(.event, done)
  }

  func events(from start: Date, to end: Date, calendars: [String]) -> HostCalendarListing {
    guard Self.mechanismsAllowed else { return .failed(Self.inertReason) }
    guard access() == .granted else { return .denied }
    let store = self.store ?? EKEventStore()
    if self.store == nil {
      self.store = store
      attachObserver()
    }
    let all = store.calendars(for: .event)
    let chosen = calendars.isEmpty ? all : all.filter { calendars.contains($0.title) }
    // An empty list would read every calendar.
    guard !chosen.isEmpty else {
      FlashLog.warn("[calendar] no event calendar has one of the titles asked for")
      return .events([])
    }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
    return .events(store.events(matching: predicate).map(Self.event))
  }

  static func event(_ event: EKEvent) -> HostCalendarEvent {
    let start: Date = event.startDate
    return HostCalendarEvent(
      id: "\(event.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))",
      title: event.title ?? "", start: start, end: event.endDate, isAllDay: event.isAllDay,
      calendar: event.calendar?.title ?? "",
      declined: event.attendees?.contains {
        $0.isCurrentUser && $0.participantStatus == .declined
      } ?? false,
      canceled: event.status == .canceled,
      url: event.url?.absoluteString, location: event.location,
      notes: event.hasNotes ? event.notes : nil)
  }

  func observeChanges(_ onChange: @escaping @Sendable () -> Void) {
    self.onChange = onChange
    attachObserver()
  }

  func stopObservingChanges() {
    onChange = nil
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }

  /// The store posts its changes; until the first read made it there is
  /// nothing to observe.
  private func attachObserver() {
    guard observer == nil, let store, let onChange else { return }
    observer = NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged, object: store, queue: nil
    ) { _ in onChange() }
  }
}
