import AppKit
import CoreGraphics

/// A session-level `CGEventTap` for `keyDown` / `keyUp` events that lets Flash capture
/// NORMAL / hints keystrokes **without** making the overlay the key window.
///
/// The old model made the overlay key (and activated Flash) to receive normal-
/// mode keys. On current macOS that activation greys the focused app's window
/// controls and opens a race window during the normal→hints handoff where a key
/// can leak to the app. Intercepting at the HID/session level fixes both: the
/// focused app keeps its active appearance, and the swallow is deterministic
/// regardless of which window is key.
///
/// `shouldSwallow` decides per event (on the main thread — the tap source runs
/// in the main run loop). Returning true consumes the event and schedules
/// `handle`; returning false passes it through untouched (modified chords →
/// Carbon, INSERT → the focused app, command-line/modal → the key-window path).
final class KeyboardCaptureTap {
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private let shouldSwallow: (CGEvent) -> Bool
  private let handle: (NSEvent) -> Void
  /// Releases pair with the presses this tap swallowed. Main-thread only: the
  /// tap source runs in the main run loop.
  private var swallowedKeys = SwallowedKeys()

  /// Which key releases must be swallowed: exactly those whose press was.
  ///
  /// A terminal running the Kitty keyboard protocol (any modern TUI editor
  /// turns it on) encodes key RELEASES to the pty, so passing the release of a
  /// key whose press NORMAL consumed leaks an escape sequence into the app.
  /// Pairing on the press rather than the current mode means a mode change
  /// mid-keypress can neither leak a release nor strand one an app is waiting
  /// for. Extracted so the rule is unit-testable without a live `CGEventTap`.
  struct SwallowedKeys {
    private var codes: Set<Int64> = []
    var isEmpty: Bool { codes.isEmpty }

    mutating func press(_ code: Int64, swallowed: Bool) {
      if swallowed { codes.insert(code) }
    }

    mutating func releaseIsSwallowed(_ code: Int64) -> Bool {
      codes.remove(code) != nil
    }
  }

  init(
    shouldSwallow: @escaping (CGEvent) -> Bool,
    handle: @escaping (NSEvent) -> Void
  ) {
    self.shouldSwallow = shouldSwallow
    self.handle = handle
  }

  /// Pure swallow decision. NORMAL and hints capture every key; INSERT and
  /// key-window surfaces are left untouched unless a native surface owns the
  /// keyboard and an explicit mapping claims the key.
  ///
  /// Extracted as a static, side-effect-free function so the tap's single most
  /// security-sensitive decision is unit-testable without a live `CGEventTap`.
  static func shouldSwallow(
    flashMode: FlashMode,
    inputMode: OverlayInputMode,
    hasMapping: Bool = false,
    nativeSurfaceOwnsKeyboard: Bool = false
  ) -> Bool {
    if nativeSurfaceOwnsKeyboard { return hasMapping }
    switch inputMode {
    case .hints:
      // A hint session owns every key whatever the base mode: hints opened
      // from INSERT or with advanced mode off must still get their labels.
      return true
    case .normal:
      return flashMode == .normal
    case .passive, .commandLine:
      return false
    }
  }

  /// Create + install the tap. Returns false if the OS refused it (no
  /// Accessibility grant), so the caller can fall back to key-window capture.
  @discardableResult
  func start() -> Bool {
    guard tap == nil else { return true }
    // Keyboard only. Status-bar link clicks are handled by an ordinary app
    // window (`StatusLinkCatcherPanel`) through normal Cocoa hit-testing — the
    // tap deliberately never inspects or swallows mouse events, so native menus,
    // screenshots, and drags that begin in the bar band are untouched.
    let maskedTypes: [CGEventType] = [.keyDown, .keyUp]
    var mask: CGEventMask = 0
    for t in maskedTypes { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, refcon in
          KeyboardCaptureTap.dispatch(type: type, event: event, refcon: refcon)
        },
        userInfo: refcon)
    else {
      FlashLog.warn("[tap] keyboard capture tap could not be created (no accessibility grant?)")
      return false
    }
    tap = port
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    FlashLog.info("[tap] keyboard capture tap installed")
    return true
  }

  private static func dispatch(
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
  ) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)
    guard let refcon else { return passthrough }
    let me = Unmanaged<KeyboardCaptureTap>.fromOpaque(refcon).takeUnretainedValue()
    // The system disables a tap that runs over its time budget; re-enable and
    // pass this event through so capture self-heals. A timeout disable is
    // direct evidence the main run loop (which hosts the tap source) stalled
    // past the OS budget — i.e. keyboard input went dead system-wide — so it
    // must leave a trace even though the recovery is automatic.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      FlashLog.warn(
        "[tap] re-enabled after "
          + "\(type == .tapDisabledByTimeout ? "timeout" : "user_input") disable")
      if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return passthrough
    }
    // Pass Flash's own synthesized keys straight through. `send_key` output
    // (`/`→⌘F, the ⌘⇧[ / ⌘⇧] tab chords, ⌘V, …) is posted with this tag and can
    // loop back through the session tap; re-capturing it in NORMAL mode would
    // re-trigger the mapping that sent it — an infinite replay. Mirrors the
    // synthetic-mouse-tag skip in the pointer monitors.
    if event.getIntegerValueField(.eventSourceUserData)
      == NormalModeDispatcher.syntheticKeyEventTag
    {
      return passthrough
    }
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .keyUp {
      return me.swallowedKeys.releaseIsSwallowed(keyCode) ? nil : passthrough
    }
    guard type == .keyDown else { return passthrough }
    let swallow = me.shouldSwallow(event)
    me.swallowedKeys.press(keyCode, swallowed: swallow)
    guard swallow else { return passthrough }
    if let ns = NSEvent(cgEvent: event) {
      // The swallow (returning nil) is synchronous, so the key never reaches
      // the app; defer the (possibly heavy) handling so the callback returns
      // fast and the tap doesn't trip its time budget.
      DispatchQueue.main.async { me.handle(ns) }
    }
    return nil
  }
}
