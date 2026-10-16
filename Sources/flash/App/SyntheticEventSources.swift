import CoreGraphics

/// The `CGEventSource`s Flash synthesizes input with, created once per
/// process. Creating a source is a WindowServer round trip; every synthesized
/// key, click, pointer move and wheel step used to pay for a fresh one.
enum SyntheticEventSources {
  /// The session state: pointer, wheel and ordinary key events.
  static let session: CGEventSource? = CGEventSource(stateID: .combinedSessionState)

  /// The HID state, for keys that must look like the hardware's.
  static let hid: CGEventSource? = CGEventSource(stateID: .hidSystemState)

  /// A private state for keys posted to the focused app: it keeps a held
  /// hyper key out of the event. The keyboard type is copied from the
  /// session source at creation and refreshed by `focusedKeyboardSource()`.
  private static let privateKeyboard: CGEventSource? = {
    let source = CGEventSource(stateID: .privateState)
    source?.localEventsSuppressionInterval = 0
    return source
  }()

  /// The private keyboard source with the session's current keyboard type,
  /// so function-key unicode and F-keys follow the attached keyboard.
  static func focusedKeyboardSource() -> CGEventSource? {
    guard let source = privateKeyboard else { return nil }
    if let session { source.keyboardType = session.keyboardType }
    return source
  }
}
