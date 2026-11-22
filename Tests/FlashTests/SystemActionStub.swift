import Foundation

@testable import flash

/// The host's system-action mechanisms for the tests: it records what it was
/// asked to carry out, and on which thread, and touches nothing. No test
/// reaches the Mac's lock, power management, screen saver or Apple Events.
final class SystemActionStub: SystemActionPerforming {
  private let lock = NSLock()
  private var performed: [SystemActionExecution] = []
  private var threads: [Bool] = []
  private var reason: String?

  /// The reason every later request fails with, or nil for success.
  var failure: String? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return reason
    }
    set {
      lock.lock()
      reason = newValue
      lock.unlock()
    }
  }

  /// Each execution that reached the mechanisms' place, in order.
  var executions: [SystemActionExecution] {
    lock.lock()
    defer { lock.unlock() }
    return performed
  }

  /// Whether each of them was asked for on the main thread.
  var onMainThread: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return threads
  }

  func perform(_ execution: SystemActionExecution) -> String? {
    lock.lock()
    defer { lock.unlock() }
    performed.append(execution)
    threads.append(Thread.isMainThread)
    return reason
  }
}
