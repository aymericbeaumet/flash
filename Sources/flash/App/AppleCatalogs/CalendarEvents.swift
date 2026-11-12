import AppKit
import EventKit
import FlashCore
import Foundation

/// `calendar join` and `calendar next`.
enum CalendarCommand: String, Hashable, CaseIterable {
  case join
  case next

  var name: CommandName { CommandName("calendar", rawValue) }

  /// The command line's one-line description.
  var summary: String {
    switch self {
    case .join: return "Open the meeting link of the next or current calendar event"
    case .next: return "Show the next calendar event"
    }
  }

  /// The mapping explanation, as one sentence.
  var explanation: String {
    switch self {
    case .join: return "Opens the meeting link of the next or current calendar event."
    case .next: return "Shows the next calendar event."
    }
  }
}

/// How a `calendar` command ended.
enum CalendarCommandOutcome: Equatable {
  /// `calendar next`: the alert's title and line.
  case next(title: String, detail: String)
  /// `calendar join` opened `url` for the event titled `title`.
  case joined(title: String, url: URL)
  /// Nothing is next within the look-ahead: for `calendar next`, an answer
  /// rather than a failure, though the CLI still exits 1.
  case noEvent(String)
  /// `message` says why, and may name the event; `log` says it without the
  /// event's title, for the log.
  case failed(message: String, log: String)
}

/// What one read of the calendar found.
enum CalendarEventListing: Equatable {
  case events([CalendarEvent])
  case denied
  case failed(String)
}

/// Reads the calendar. The blocking calls run on `CalendarEvents`' queue,
/// never main; nothing here asks macOS for access but `requestAccess`.
protocol CalendarEventReading: AnyObject {
  /// Whether Flash may read events now, as macOS answers without asking.
  func access() -> AppleCatalogAccess
  /// Ask macOS (its prompt names Flash); `done` gets whether access was
  /// granted, on any queue.
  func requestAccess(_ done: @escaping (Bool) -> Void)
  /// The occurrences overlapping `start..<end` in the calendars titled
  /// `calendars` (every event calendar when empty).
  func events(from start: Date, to end: Date, calendars: [String]) -> CalendarEventListing
  /// Call `onChange`, on any queue, each time the calendar database changes,
  /// until `stopObservingChanges`.
  func observeChanges(_ onChange: @escaping () -> Void)
  func stopObservingChanges()
}

/// Owns the calendar's upcoming events: the `#{flash.calendar.next…}` values
/// and the `calendar` commands. The status controller says when a surface
/// reads a value (`observe`); only then does Flash read events, re-read them
/// when the calendar database changes and once a look-ahead has passed, and
/// publish them for the controller to turn into values at the time it shows
/// them. A command reads afresh. Nothing reads before macOS grants access,
/// and macOS is asked only by the user's own use: a format reading a value,
/// or a command. Every read runs on one serial queue, never main.
final class CalendarEvents {
  static let changeSettleID = "core:calendar_changed"
  static let horizonID = "core:calendar_horizon"
  /// A sync writes many changes at once: they are read as one.
  static let changeSettleMs = 500
  /// A failed read keeps the last events and is tried again this much later.
  static let retryMs = 300_000

  private let queue: DispatchQueue
  private let reader: CalendarEventReading
  private let now: () -> Date
  private let publish: (CalendarAgenda?) -> Void
  private let canOpen: (URL) -> Bool
  private let open: (URL, @escaping (String?) -> Void) -> Void
  private let changeSettle: PollDeadline
  private let horizon: PollDeadline
  // Confined to `queue`.
  private var settings = CalendarSettings()
  private var observed = false
  /// Bumped by every `observe` change: a read begun before it is stale.
  private var generation: UInt64 = 0
  /// What was last published while observed; `.some(nil)`: nothing to show.
  private var published: CalendarAgenda??
  /// Reads waiting while macOS's access prompt is open.
  private var askWaiters: [(Bool) -> Void]?

  init(
    reader: CalendarEventReading = CalendarEventReader(),
    // `.userInitiated`: a command waits on its read.
    queue: DispatchQueue = DispatchQueue(label: "flash.calendar", qos: .userInitiated),
    scheduler: PollScheduler = .shared,
    now: @escaping () -> Date = Date.init,
    canOpen: @escaping (URL) -> Bool = { NSWorkspace.shared.urlForApplication(toOpen: $0) != nil },
    open: @escaping (URL, @escaping (String?) -> Void) -> Void = AppleCatalogReaders.open,
    publish: @escaping (CalendarAgenda?) -> Void
  ) {
    self.reader = reader
    self.queue = queue
    self.now = now
    self.canOpen = canOpen
    self.open = open
    self.publish = publish
    // `.normal`: a changed event reaches a value someone may be looking at.
    changeSettle = PollDeadline(
      Self.changeSettleID, priority: .normal, on: queue, scheduler: scheduler)
    // `.low`: the look-ahead moving on brings in events hours away.
    horizon = PollDeadline(Self.horizonID, priority: .low, on: queue, scheduler: scheduler)
  }

  /// `[calendar]`; a change reads again while observed.
  func configure(_ settings: CalendarSettings) {
    queue.async { [weak self] in
      guard let self, self.settings != settings else { return }
      self.settings = settings
      if self.observed { self.refresh() }
    }
  }

  /// Whether a surface or a monitor reads a `#{flash.calendar.next…}` value.
  /// The first one asks macOS for access when Flash never asked: the user
  /// wrote that value.
  func observe(_ observed: Bool) {
    queue.async { [weak self] in
      guard let self, observed != self.observed else { return }
      self.observed = observed
      self.generation &+= 1
      if observed {
        self.reader.observeChanges { [weak self] in
          self?.queue.async { self?.databaseChanged() }
        }
        self.refresh()
      } else {
        self.reader.stopObservingChanges()
        self.changeSettle.cancel()
        self.horizon.cancel()
        self.published = nil
      }
    }
  }

  /// Run `command` on a fresh read. `completion` runs on main.
  func perform(
    _ command: CalendarCommand, completion: @escaping (CalendarCommandOutcome) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      let generation = self.generation
      self.read { read in
        // A command's read is the freshest there is: the values take it too.
        self.adopt(read, generation: generation)
        self.finish(command, read: read) { outcome in
          DispatchQueue.main.async { completion(outcome) }
        }
      }
    }
  }

  /// Wait for every queued read: tests only.
  func drain() { queue.sync {} }

  // MARK: Work (queue)

  private func databaseChanged() {
    guard observed else { return }
    changeSettle.arm(afterMs: Self.changeSettleMs) { [weak self] in self?.refresh() }
  }

  private func refresh() {
    let generation = self.generation
    read { [weak self] read in self?.adopt(read, generation: generation) }
  }

  /// Publish what an observed read found, and plan the next read.
  private func adopt(_ read: CalendarRead, generation: UInt64) {
    guard observed, generation == self.generation else { return }
    switch read {
    case .agenda(let agenda):
      horizon.arm(after: settings.lookahead) { [weak self] in self?.refresh() }
      publishIfChanged(agenda)
    case .denied:
      // Granting access later is seen by the next command or reload.
      horizon.cancel()
      publishIfChanged(nil)
    case .failed(let reason):
      FlashLog.warn("[calendar] read failed: \(reason)")
      horizon.arm(afterMs: Self.retryMs) { [weak self] in self?.refresh() }
    }
  }

  private func publishIfChanged(_ agenda: CalendarAgenda?) {
    if case .some(let last) = published, last == agenda { return }
    published = .some(agenda)
    publish(agenda)
  }

  /// Read the events, asking macOS first when Flash never asked. `done` runs
  /// on the queue.
  private func read(_ done: @escaping (CalendarRead) -> Void) {
    switch reader.access() {
    case .granted:
      done(fetch())
    case .denied:
      done(.denied)
    case .undetermined:
      ask { [weak self] granted in
        guard let self else { return }
        done(granted ? self.fetch() : .denied)
      }
    }
  }

  /// macOS's prompt stays up until the user answers; the queue stays free
  /// meanwhile, and reads that need the answer wait for it.
  private func ask(_ done: @escaping (Bool) -> Void) {
    if askWaiters != nil {
      askWaiters?.append(done)
      return
    }
    askWaiters = [done]
    FlashLog.info("[calendar] asking for Calendars access")
    reader.requestAccess { [weak self] granted in
      self?.queue.async {
        guard let self else { return }
        let waiters = self.askWaiters ?? []
        self.askWaiters = nil
        FlashLog.info("[calendar] Calendars access \(granted ? "granted" : "denied")")
        for waiter in waiters { waiter(granted) }
      }
    }
  }

  /// Twice the look-ahead, so the values stay complete until the next read.
  private func fetch() -> CalendarRead {
    let start = now()
    let listing = reader.events(
      from: start, to: start.addingTimeInterval(2 * settings.lookahead),
      calendars: settings.calendars)
    switch listing {
    case .events(let events):
      return .agenda(
        CalendarAgenda(events: events.filter(settings.admits), lookahead: settings.lookahead))
    case .denied:
      return .denied
    case .failed(let reason):
      return .failed(reason)
    }
  }

  private func finish(
    _ command: CalendarCommand, read: CalendarRead,
    _ done: @escaping (CalendarCommandOutcome) -> Void
  ) {
    let agenda: CalendarAgenda
    switch read {
    case .agenda(let read): agenda = read
    case .denied: return done(.failed(message: Self.deniedMessage, log: "no Calendars access"))
    case .failed(let reason):
      let message = "Could not read your calendars: \(reason)"
      return done(.failed(message: message, log: message))
    }
    let at = now()
    let noEvent = CalendarNext.noEventMessage(lookaheadHours: settings.lookaheadHours)
    switch command {
    case .next:
      guard let summary = CalendarNext.summary(agenda, at: at) else {
        return done(.noEvent(noEvent))
      }
      done(.next(title: summary.title, detail: summary.detail))
    case .join:
      switch CalendarNext.joinTarget(agenda, at: at) {
      case .noEvent:
        done(.failed(message: noEvent, log: "no event"))
      case .noLink(let event):
        done(.failed(message: "\(event.displayTitle) has no meeting link", log: "no meeting link"))
      case .join(let event, let link):
        // The meeting's app when one handles its link, else the link itself.
        let url = link.appURL.flatMap { canOpen($0) ? $0 : nil } ?? link.url
        FlashLog.info("[calendar] join service=\(link.service) scheme=\(url.scheme ?? "")")
        open(url) { failure in
          if let failure {
            done(
              .failed(
                message: "Could not open the meeting link of \(event.displayTitle): \(failure)",
                log: "\(link.service) link did not open: \(failure)"))
          } else {
            done(.joined(title: event.displayTitle, url: url))
          }
        }
      }
    }
  }

  static let deniedMessage =
    "Flash may not read your calendars: allow it in System Settings › Privacy & Security › Calendars"
}

/// One read's result, for the values and the commands.
enum CalendarRead: Equatable {
  case agenda(CalendarAgenda)
  /// macOS refused access, or the user did when asked.
  case denied
  case failed(String)
}

/// Calendar events through EventKit. macOS asks once whether Flash may
/// access your calendars.
final class CalendarEventReader: CalendarEventReading {
  /// Made by the first read once access is granted, and kept. Only the
  /// calendar queue touches it.
  private var store: EKEventStore?
  private var onChange: (() -> Void)?
  private var observer: NSObjectProtocol?

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func access() -> AppleCatalogAccess {
    EventKitAccess.access(EKEventStore.authorizationStatus(for: .event))
  }

  func requestAccess(_ done: @escaping (Bool) -> Void) {
    EventKitAccess.request(.event, done)
  }

  func events(from start: Date, to end: Date, calendars: [String]) -> CalendarEventListing {
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
      FlashLog.warn("[calendar] no event calendar has a title [calendar] calendars lists")
      return .events([])
    }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: chosen)
    return .events(store.events(matching: predicate).map(Self.event))
  }

  static func event(_ event: EKEvent) -> CalendarEvent {
    let start: Date = event.startDate
    return CalendarEvent(
      id: "\(event.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))",
      title: event.title ?? "", start: start, end: event.endDate, isAllDay: event.isAllDay,
      calendar: event.calendar?.title ?? "",
      declined: event.attendees?.contains {
        $0.isCurrentUser && $0.participantStatus == .declined
      } ?? false,
      canceled: event.status == .canceled,
      link: MeetingLinks.find(
        url: event.url, location: event.location, notes: event.hasNotes ? event.notes : nil))
  }

  func observeChanges(_ onChange: @escaping () -> Void) {
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

/// macOS's EventKit authorization, as the catalogs read it: only full access
/// lets Flash read.
enum EventKitAccess {
  /// Asks macOS for full access to `entity`. macOS 13 has one level of
  /// access, which `requestAccess(to:)` asks for (its usage descriptions
  /// are `NSCalendarsUsageDescription` and `NSRemindersUsageDescription`);
  /// macOS 14 split it and asks through `requestFullAccessTo…`.
  static func request(_ entity: EKEntityType, _ done: @escaping (Bool) -> Void) {
    let asking = EKEventStore()
    let completion: EKEventStoreRequestAccessCompletionHandler = { granted, _ in
      withExtendedLifetime(asking) { done(granted) }
    }
    if #available(macOS 14.0, *) {
      if entity == .reminder {
        asking.requestFullAccessToReminders(completion: completion)
      } else {
        asking.requestFullAccessToEvents(completion: completion)
      }
    } else {
      asking.requestAccess(to: entity, completion: completion)
    }
  }

  /// macOS 13's `.authorized` is `.fullAccess`'s raw value, so the same
  /// switch reads both.
  static func access(_ status: EKAuthorizationStatus) -> AppleCatalogAccess {
    switch status {
    case .fullAccess: return .granted
    case .notDetermined: return .undetermined
    case .writeOnly, .denied, .restricted: return .denied
    @unknown default: return .denied
    }
  }
}
