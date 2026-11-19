import Darwin
import Foundation

@testable import flash

/// The host's signal mechanism for the tests: it records what it was asked
/// to send and to which pid, and signals nothing.
final class ProcessSignalStub: ProcessSignalling {
  private let lock = NSLock()
  private var recorded: [Sent] = []
  private var reason: String?

  struct Sent: Equatable {
    let signal: HostProcessSignal
    let pid: pid_t
    let onMainThread: Bool
  }

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

  /// Each signal that reached the mechanism's place, in order.
  var sent: [Sent] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func send(_ signal: HostProcessSignal, to pid: pid_t) -> String? {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(Sent(signal: signal, pid: pid, onMainThread: Thread.isMainThread))
    return reason
  }
}

/// A mechanism that really signals, and only the child processes a test
/// spawned and handed it: any other pid is refused and recorded.
final class ChildProcessSignals: ProcessSignalling {
  private let children: Set<pid_t>
  private let lock = NSLock()
  private var strangers: [pid_t] = []

  init(children: [Process]) {
    self.children = Set(children.map(\.processIdentifier))
  }

  convenience init(child: Process) {
    self.init(children: [child])
  }

  /// Pids the mechanism was asked to signal that are no child of the test.
  var refused: [pid_t] {
    lock.lock()
    defer { lock.unlock() }
    return strangers
  }

  func send(_ signal: HostProcessSignal, to pid: pid_t) -> String? {
    guard children.contains(pid), pid > 1, pid != getpid() else {
      lock.lock()
      strangers.append(pid)
      lock.unlock()
      return "not the test's child"
    }
    return kill(pid, signal.number) == 0 ? nil : String(cString: strerror(errno))
  }
}
