import CoreGraphics
import Foundation

/// One yank keeps its target and command ownership through AX and clipboard replies.
struct SelectionYankRequest {
  let targetPID: pid_t
  let register: String?
  let commandToken: UInt64
  let input: SelectionYankInputSnapshot

  init(
    targetPID: pid_t, register: String?, commandToken: UInt64,
    input: SelectionYankInputSnapshot = .capture()
  ) {
    self.targetPID = targetPID
    self.register = register
    self.commandToken = commandToken
    self.input = input
  }

  func owns(
    targetPID: pid_t?, commandToken: UInt64,
    currentInput: SelectionYankInputSnapshot = .capture()
  ) -> Bool {
    self.targetPID == targetPID && self.commandToken == commandToken && permitsInput(currentInput)
  }

  func permitsInput(_ current: SelectionYankInputSnapshot = .capture()) -> Bool {
    input == current
  }

  func permitsFrontmost(_ pid: pid_t?, flashPID: pid_t) -> Bool {
    pid == targetPID || pid == flashPID
  }

  static func permitsArrowFallback(
    isTerminal: Bool, selection: TextSelectionIdentity, copiedText: String? = nil,
    discard: Bool = false
  ) -> Bool {
    !isTerminal && (selection.hasSelection || copiedText?.isEmpty == false || discard)
  }

  @discardableResult
  func complete(
    text: String?,
    write: (String, String?) -> Void, clear: () -> Void
  ) -> Bool {
    if register != "_" {
      guard let text, !text.isEmpty else { return false }
      write(text, register)
    }
    clear()
    return true
  }
}

/// The public AX selection attributes that can identify what a yank captured.
struct TextSelectionIdentity: Equatable {
  enum State { case unchanged, collapsed, changed }
  let text: String?
  let range: NSRange?

  var hasSelection: Bool { text?.isEmpty == false || (range?.length ?? 0) > 0 }

  func state(comparedTo current: Self) -> State {
    if self == current { return .unchanged }
    if let range, range.location >= 0, range.length > 0,
      range.location <= Int.max - range.length,
      current.range == NSRange(location: range.location + range.length, length: 0),
      current.text?.isEmpty != false
    {
      return .collapsed
    }
    return .changed
  }
}

/// Counts only selection-changing hardware input, never key values. Releases
/// are excluded so lifting the triggering yank key does not revoke the request.
struct SelectionYankInputSnapshot: Equatable {
  static let eventTypes: [CGEventType] = [
    .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
  ]
  private let counts: [UInt32]

  static func capture(
    readCount: (CGEventType) -> UInt32 = {
      CGEventSource.counterForEventType(.hidSystemState, eventType: $0)
    }
  ) -> Self {
    Self(counts: eventTypes.map(readCount))
  }
}
