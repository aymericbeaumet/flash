import AppKit
import CoreGraphics

/// A session-level keyboard tap that captures plain/shift keys while Flash is in
/// idle NORMAL mode, independent of which window holds key focus. This frees
/// normal mode from the fragile "the overlay panel must be the key window"
/// contract: an app can hold focus without breaking capture (so the badge can
/// never read NORMAL while keys silently go elsewhere), and rapid key sequences
/// never leak to the focused app mid-stream.
///
/// Scope is deliberately narrow:
///  - Only plain / shift keys are swallowed — the interpreter-driven keys
///    (`hjkl`, `gg`, `]t`, `3j`, `i`, `:`, …). Cmd/Ctrl/Option chords pass
///    through to the existing Carbon `[mode.*]` hot-key registry, which is
///    global and never depended on the key window, so system chords (⌘Tab, …)
///    keep their proven handling.
///  - Only in idle NORMAL mode (`shouldCapture`). Hints, command line, modal,
///    and insert all pass through untouched.
///  - Flash's own synthesized keys (tagged
///    `NormalModeDispatcher.syntheticKeyEventTag`) are never swallowed, so
///    `/`→⌘F, undo, tab chords, ⌘V paste, etc. still reach the focused app.
///
/// If the tap can't be created (Accessibility not granted) the caller keeps the
/// panel-based capture + recapture machinery, which remains in place as a
/// fallback.
final class NormalModeKeyTap {
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private let shouldCapture: () -> Bool
  private let handleKeyDown: (NSEvent) -> Void

  init(shouldCapture: @escaping () -> Bool, handleKeyDown: @escaping (NSEvent) -> Void) {
    self.shouldCapture = shouldCapture
    self.handleKeyDown = handleKeyDown
  }

  /// True once the tap is created + enabled (Accessibility granted). When false,
  /// callers fall back to the panel-based key-window recapture.
  var isActive: Bool { tap != nil }

  /// Create + enable the tap on the main run loop. Returns false if the tap
  /// couldn't be created (e.g. Accessibility not granted).
  @discardableResult
  func start() -> Bool {
    guard tap == nil else { return true }
    let mask: CGEventMask =
      (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, refcon in
          guard let refcon else { return Unmanaged.passUnretained(event) }
          return Unmanaged<NormalModeKeyTap>.fromOpaque(refcon)
            .takeUnretainedValue()
            .handle(type: type, event: event)
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else {
      FlashLog.warn("[mode] key_tap_unavailable (accessibility not granted?)")
      return false
    }
    self.tap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    FlashLog.info("[mode] key_tap_started")
    return true
  }

  func stop() {
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
    runLoopSource = nil
    tap = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    // The system disables a tap that runs too long or on certain input; turn it
    // back on and pass the triggering event through.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown || type == .keyUp else {
      return Unmanaged.passUnretained(event)
    }
    // Never swallow Flash's own synthesized keys.
    if event.getIntegerValueField(.eventSourceUserData)
      == NormalModeDispatcher.syntheticKeyEventTag
    {
      return Unmanaged.passUnretained(event)
    }
    // Cmd/Ctrl/Option chords stay on the global Carbon registry.
    let flags = event.flags
    if flags.contains(.maskCommand) || flags.contains(.maskControl)
      || flags.contains(.maskAlternate)
    {
      return Unmanaged.passUnretained(event)
    }
    guard shouldCapture() else { return Unmanaged.passUnretained(event) }
    // Idle normal mode is hermetic: swallow the key. Interpret keyDown on the
    // next runloop turn so the callback returns immediately (a slow callback
    // gets the tap disabled). keyUp is swallowed without interpretation so the
    // focused app never sees a dangling release.
    if type == .keyDown, let nsEvent = NSEvent(cgEvent: event) {
      let handler = handleKeyDown
      DispatchQueue.main.async { handler(nsEvent) }
    }
    return nil
  }
}
