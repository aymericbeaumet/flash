import AppKit
import CoreGraphics

/// A session-level keyboard tap that backstops normal-mode input capture.
///
/// Normal mode otherwise relies on the overlay `NSPanel` becoming the key
/// window and intercepting keys via `performKeyEquivalent`. That hand-off is
/// asynchronous, so the first keystroke after entering normal mode can land
/// before the panel is key and leak to the focused app (the classic `[t`
/// where the leading `[` reaches tmux/alacritty).
///
/// This tap is installed once at launch and left always-on. It does not start
/// or stop on mode transitions — instead it consults a decision closure for
/// every keyDown, so there is no enable/disable race to lose the first key to.
/// When the closure says "swallow", the event is dropped at the session level
/// and never reaches any application; the NSPanel path then only runs as a
/// fallback if this tap is unavailable.
final class NormalModeEventTap {
  /// Returns `true` to swallow the keyDown (consume it), `false` to let it
  /// pass through to the focused application unchanged.
  private let shouldSwallowKeyDown: (CGEvent) -> Bool
  private var tap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  init(shouldSwallowKeyDown: @escaping (CGEvent) -> Bool) {
    self.shouldSwallowKeyDown = shouldSwallowKeyDown
  }

  /// Creates the tap and wires it to the main run loop. Returns `false` (and
  /// logs) if the OS denies the tap — e.g. when Accessibility / Input
  /// Monitoring permission is missing. The caller degrades gracefully to the
  /// NSPanel responder path in that case.
  @discardableResult
  func install() -> Bool {
    guard tap == nil else { return true }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, refcon in
      guard let refcon else { return Unmanaged.passUnretained(event) }
      let me = Unmanaged<NormalModeEventTap>.fromOpaque(refcon).takeUnretainedValue()
      return me.handle(type: type, event: event)
    }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else {
      FlashLog.warn(
        "[input] normal-mode event tap unavailable — check Accessibility/Input Monitoring")
      return false
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    self.tap = tap
    self.runLoopSource = source
    FlashLog.info("[input] normal-mode event tap installed")
    return true
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    // The system disables a tap that blocks too long or is interrupted; just
    // turn it back on and pass the triggering event through untouched.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return Unmanaged.passUnretained(event)
    }
    if type == .keyDown, shouldSwallowKeyDown(event) {
      return nil
    }
    return Unmanaged.passUnretained(event)
  }

  func uninstall() {
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    runLoopSource = nil
    tap = nil
  }

  deinit { uninstall() }
}
