import Foundation

/// Queued host work belongs to the child transport that requested it. Checking
/// only when sending its reply is too late: an old child could already have
/// activated an app, posted input, or overwritten its replacement's storage.
struct PluginHostRequestScope {
  let isCurrent: () -> Bool

  func enqueue(on queue: DispatchQueue, execute: @escaping () -> Void) {
    queue.async {
      guard isCurrent() else { return }
      execute()
    }
  }
}
