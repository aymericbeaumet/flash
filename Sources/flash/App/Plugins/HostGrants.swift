import Carbon
import EventKit
import Foundation

/// Whether Flash may read what one of its macOS grants covers (Calendars,
/// Reminders, Contacts, Automation of Notes), as macOS answers without
/// asking.
enum GrantAccess: Equatable {
  case granted
  /// Flash never asked.
  case undetermined
  /// The user refused, or a policy did.
  case denied

  /// The name a host RPC reports the grant by (`protocol.json`
  /// `calendar_events.access`, `app_items.access`).
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

/// macOS's EventKit authorization, as Flash reads it for events and for
/// reminders: only full access lets it read.
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
  static func access(_ status: EKAuthorizationStatus) -> GrantAccess {
    switch status {
    case .fullAccess: return .granted
    case .notDetermined: return .undetermined
    case .writeOnly, .denied, .restricted: return .denied
    @unknown default: return .denied
    }
  }
}

/// Whether Flash may send Apple Events to an app (Automation), without
/// sending one.
enum AutomationConsent {
  /// `ask` shows macOS's prompt when Flash never asked, and then blocks until
  /// the user answers: never on main. An app that is not running answers
  /// nothing, which reads as undetermined.
  static func access(toBundleID bundleID: String, ask: Bool) -> GrantAccess {
    var target = AEAddressDesc()
    let bytes = Array(bundleID.utf8)
    guard AECreateDesc(DescType(typeApplicationBundleID), bytes, bytes.count, &target) == noErr
    else { return .undetermined }
    defer { AEDisposeDesc(&target) }
    let status = AEDeterminePermissionToAutomateTarget(
      &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    return access(status: status)
  }

  static func access(status: OSStatus) -> GrantAccess {
    switch status {
    case noErr: return .granted
    case OSStatus(errAEEventNotPermitted): return .denied
    default: return .undetermined
    }
  }
}
