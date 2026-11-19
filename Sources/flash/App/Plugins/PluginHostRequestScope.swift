import Foundation

/// Queued host work belongs to the child transport that requested it. Checking
/// only when sending its reply is too late: an old child could already have
/// activated an app, posted input, or overwritten its replacement's storage.
///
/// A host action that needs the user's consent also asks the scope for it:
/// `claimConfirmedPerform` answers true once per `perform` the user confirmed
/// that is still in flight for this child, and false otherwise.
///
/// A host action that shows one of macOS's privacy prompts asks whether the
/// user is using the plugin: `servesUser` answers true while one of the
/// child's performs is in flight or a status surface shows one of its
/// segments, so a plugin never raises a prompt from the background.
struct PluginHostRequestScope {
  let isCurrent: () -> Bool
  var claimConfirmedPerform: () -> Bool = { false }
  var servesUser: () -> Bool = { false }

  func enqueue(on queue: DispatchQueue, execute: @escaping () -> Void) {
    queue.async {
      guard isCurrent() else { return }
      execute()
    }
  }
}

/// The performs the user confirmed that one child has not answered yet. Each
/// covers one host action that needs the user's consent: `claim` hands one
/// out and never the same twice, and a perform that ends takes its unclaimed
/// consent with it.
struct ConfirmedPerforms {
  private var unclaimed: Set<UInt64> = []
  private var serial: UInt64 = 0

  /// A confirmed perform was written to the child; the token ends it.
  mutating func begin() -> UInt64 {
    serial &+= 1
    unclaimed.insert(serial)
    return serial
  }

  /// The perform was answered, timed out or lost its child.
  mutating func end(_ token: UInt64) {
    unclaimed.remove(token)
  }

  /// Take the oldest unclaimed consent; false when none is in flight.
  mutating func claim() -> Bool {
    guard let oldest = unclaimed.min() else { return false }
    unclaimed.remove(oldest)
    return true
  }
}
