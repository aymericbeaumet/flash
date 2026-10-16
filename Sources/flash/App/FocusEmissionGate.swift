import Foundation

/// Which focus changes plugins hear about. The workspace notification and
/// the key-path reconcile both report the app that came forward, often the
/// same one twice in a row; plugins, the MRU ring and the pointer follow
/// hear each app once, when it differs from the last one reported.
struct FocusEmissionGate: Equatable {
  private(set) var lastEmittedPID: pid_t?

  /// True once per change of focused app, and records it.
  mutating func shouldEmit(pid: pid_t) -> Bool {
    guard lastEmittedPID != pid else { return false }
    lastEmittedPID = pid
    return true
  }
}
