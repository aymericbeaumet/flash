import Foundation

/// Runs a closure on the main thread. If already on main it runs
/// synchronously; otherwise dispatches asynchronously.
///
/// The pattern was duplicated 3+ times across `AppMonitor`. Extracting
/// it gives one place to revisit if the policy ever needs to change
/// (e.g. always async to avoid reentrancy, or sync via `DispatchQueue.main.sync`
/// when called from a worker queue).
enum MainThreadHopper {
  static func runOrAsync(_ block: @escaping () -> Void) {
    if Thread.isMainThread {
      block()
    } else {
      DispatchQueue.main.async(execute: block)
    }
  }
}
