import Foundation

/// Main-thread ownership for asynchronous source fallbacks and their key strokes.
/// A successful source may intentionally move focus; only fallback effects validate it.
final class NormalModeCommandDelivery {
  private enum Phase { case pending, settled }
  private var phase: Phase = .pending
  let input: SelectionYankInputSnapshot
  private let stillCurrent: () -> Bool
  private let validate: (@escaping (Bool) -> Void) -> Void
  private let completion: (NormalModeCommandOutcome) -> Void

  init(
    stillCurrent: @escaping () -> Bool,
    validate: @escaping (@escaping (Bool) -> Void) -> Void = { $0(true) },
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    self.input = .capture()
    self.stillCurrent = stillCurrent
    self.validate = validate
    self.completion = completion
  }

  var isPending: Bool { phase == .pending }

  func perform(_ effect: @escaping () -> Void) {
    guard isPending else { return }
    guard stillCurrent() else { return complete(.noTarget) }
    validate { [weak self] valid in
      guard let self, self.isPending else { return }
      guard valid, self.stillCurrent() else { return self.complete(.noTarget) }
      effect()
    }
  }

  func complete(_ outcome: NormalModeCommandOutcome) {
    guard isPending else { return }
    phase = .settled
    completion(outcome)
  }

  static func owns(
    targetPID: pid_t, externalPID: pid_t?, flashPID: pid_t, ownsLocalKeyWindow: Bool
  ) -> Bool {
    targetPID == flashPID ? ownsLocalKeyWindow : externalPID == targetPID
  }
}
