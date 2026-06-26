import AppKit
import CoreGraphics

/// A session-level `CGEventTap` for `keyDown` events that lets Flash capture
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

  init(shouldSwallow: @escaping (CGEvent) -> Bool, handle: @escaping (NSEvent) -> Void) {
    self.shouldSwallow = shouldSwallow
    self.handle = handle
  }

  /// Pure swallow decision: given the coarse flash mode and the overlay's input
  /// mode, should the tap consume this `keyDown`? NORMAL is a hermetic capture
  /// surface — every key in `.normal`/`.hints` is swallowed so nothing (not even
  /// ⌘W / ⌘Q / an app's own shortcut) leaks to the focused app. INSERT and the
  /// key-window surfaces (command-line / modal / candidate-finder, which type
  /// into their own fields) are left untouched.
  ///
  /// Extracted as a static, side-effect-free function so the tap's single most
  /// security-sensitive decision is unit-testable without a live `CGEventTap`.
  static func shouldSwallow(flashMode: FlashMode, inputMode: OverlayInputMode) -> Bool {
    guard flashMode == .normal else { return false }
    switch inputMode {
    case .normal, .hints:
      return true
    case .commandLine, .modal, .candidateFinder:
      return false
    }
  }

  /// Create + install the tap. Returns false if the OS refused it (no
  /// Accessibility grant), so the caller can fall back to key-window capture.
  @discardableResult
  func start() -> Bool {
    guard tap == nil else { return true }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
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
    // pass this event through so capture self-heals.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
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
    guard type == .keyDown, me.shouldSwallow(event) else { return passthrough }
    if let ns = NSEvent(cgEvent: event) {
      // The swallow (returning nil) is synchronous, so the key never reaches
      // the app; defer the (possibly heavy) handling so the callback returns
      // fast and the tap doesn't trip its time budget.
      DispatchQueue.main.async { me.handle(ns) }
    }
    return nil
  }
}
