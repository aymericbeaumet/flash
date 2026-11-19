import Darwin
import Foundation

/// One signal of `host.process_signal` (`protocol.json` `process_signals`):
/// what the host sends a process for a plugin holding the `process_signal`
/// capability. The raw value is the name on the wire; the set is closed.
enum HostProcessSignal: String, CaseIterable, Equatable {
  /// SIGTERM: ask the process to quit.
  case term

  var number: Int32 {
    switch self {
    case .term: return SIGTERM
    }
  }
}

/// Sends a signal. The resident wires `LiveProcessSignals` at launch;
/// nothing is wired inside the test runner, where a test injects its own
/// and may only ever signal a child process it spawned itself.
protocol ProcessSignalling {
  /// Signal `pid` and answer nil, or the OS's reason (EPERM: another user's
  /// process; ESRCH: already gone). Called on `HostProcessSignals.queue`.
  func send(_ signal: HostProcessSignal, to pid: pid_t) -> String?
}

enum HostProcessSignals {
  /// One signal at a time, off main and off every plugin's queue.
  static let queue = DispatchQueue(label: "flash.process-signals", qos: .userInitiated)

  /// False inside the test runner: the real mechanism answers a refusal
  /// there, whoever reaches it.
  static let mechanismsAllowed = NSClassFromString("XCTestCase") == nil
  static let inertReason = "process signals are inert inside the test runner"

  /// Why the host never signals `pid`, whatever the plugin or the user
  /// said: nil for a process it may ask the kernel about. Pid 0 is the
  /// caller's process group, a negative one a group or every process, 1 is
  /// launchd, and the resident does not signal itself.
  static func refusal(of pid: pid_t, own: pid_t = getpid()) -> String? {
    if pid <= 1 { return "refusing pid \(pid)" }
    if pid == own { return "refusing to signal Flash itself" }
    return nil
  }
}

/// The resident's mechanism: `kill(2)`.
struct LiveProcessSignals: ProcessSignalling {
  func send(_ signal: HostProcessSignal, to pid: pid_t) -> String? {
    guard HostProcessSignals.mechanismsAllowed else { return HostProcessSignals.inertReason }
    if let refusal = HostProcessSignals.refusal(of: pid) { return refusal }
    return kill(pid, signal.number) == 0 ? nil : String(cString: strerror(errno))
  }
}
