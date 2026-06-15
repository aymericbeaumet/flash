import AppKit
import ApplicationServices

/// Implements the `window_move position=… screen=…` verb against the
/// focused application's focused window via Accessibility. When the
/// persistent Flash status bar is active, every target rect is computed
/// from the screen frame after reserving the top status band, even if
/// macOS temporarily reports a full-height `visibleFrame`.
///
/// Coordinate spaces:
///   - `NSScreen.frame` / `NSScreen.visibleFrame` use the primary
///     screen's bottom-left as `(0, 0)` with Y growing upward.
///   - `kAXPositionAttribute` uses the primary screen's TOP-LEFT as
///     `(0, 0)` with Y growing downward.
/// All math is done in NSScreen space; conversion to AX coordinates
/// happens once at the call to `AXValueCreate`.
enum WindowMover {

  static func move(
    _ params: MoveWindowParams,
    statusBarReservesSpace: Bool,
    targetPID: pid_t
  ) {
    let axApp = AXUIElementCreateApplication(targetPID)

    // Resolve the window to move. Three fallbacks because Flash holds
    // key focus during normal-mode capture, so AX answers vary by app:
    //   1. `kAXFocusedWindow`  — only populated when the target app is
    //                            the focused process (i.e. Cocoa apps
    //                            with retained focus state). Often nil.
    //   2. `kAXMainWindow`     — the app's frontmost window regardless
    //                            of who owns the keyboard. Cocoa apps
    //                            track this; some non-Cocoa apps (e.g.
    //                            Alacritty) leave it unset.
    //   3. `kAXWindows[0]`     — the first entry in the app's window
    //                            list, ordered front-to-back by AX.
    //                            Works for Alacritty et al. that only
    //                            expose the list.
    let window: AXUIElement
    if let focused = copyWindowAttribute(axApp, kAXFocusedWindowAttribute) {
      window = focused
    } else if let main = copyWindowAttribute(axApp, kAXMainWindowAttribute) {
      window = main
    } else if let first = copyFirstWindow(axApp) {
      window = first
    } else {
      FlashLog.warn("[window_move] no AX window for pid \(targetPID)")
      return
    }

    guard let currentFrame = readWindowFrameInNSCoords(window: window) else {
      return
    }
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return }
    let currentIndex = screenIndex(forFrame: currentFrame, screens: screens)
    let count = screens.count
    // Swift's `%` returns negative results for negative LHS, so wrap
    // through `+ count` before the final modulo.
    let targetIndex = ((currentIndex + params.screen) % count + count) % count
    let currentScreen = screens[currentIndex]
    let targetScreen = screens[targetIndex]
    let currentUsableFrame = usableFrame(
      screenFrame: currentScreen.frame,
      visibleFrame: currentScreen.visibleFrame,
      statusBarReservesSpace: statusBarReservesSpace,
      fontSize: OverlayPanel.statusBarFontSize(overlayFontSize: 0))
    let targetUsableFrame = usableFrame(
      screenFrame: targetScreen.frame,
      visibleFrame: targetScreen.visibleFrame,
      statusBarReservesSpace: statusBarReservesSpace,
      fontSize: OverlayPanel.statusBarFontSize(overlayFontSize: 0))

    let rect: CGRect
    if let position = params.position {
      // `position` always wins, even when `screen` is `0` — it picks
      // a fresh slot on the destination screen regardless of where
      // the window started.
      rect = rectFor(position: position, in: targetUsableFrame)
    } else if targetIndex != currentIndex {
      // `screen` alone: translate the window onto the new screen
      // while preserving its proportional shape inside the screen's
      // usable frame (so a left-half on a 4K monitor lands as a
      // left-half on a 1080p monitor, not as a clipped 1920px box).
      rect = remap(
        frame: currentFrame,
        from: currentUsableFrame,
        to: targetUsableFrame)
    } else {
      // Nothing to do — `screen=0` with no `position` is a no-op
      // (callers that pass neither were already rejected at parse
      // time).
      return
    }
    apply(rect: rect, toWindow: window, axApp: axApp)
  }

  /// Proportionally remap `frame` from one visible frame into
  /// another. Both rects are NSScreen Y-up coordinates.
  static func remap(
    frame: CGRect, from src: CGRect, to dst: CGRect
  ) -> CGRect {
    guard src.width > 0, src.height > 0 else { return frame }
    let relX = (frame.minX - src.minX) / src.width
    let relY = (frame.minY - src.minY) / src.height
    let relW = frame.width / src.width
    let relH = frame.height / src.height
    return CGRect(
      x: dst.minX + relX * dst.width,
      y: dst.minY + relY * dst.height,
      width: relW * dst.width,
      height: relH * dst.height)
  }

  /// Index of the screen that owns the frame's centre, or `0` when
  /// no screen claims the centre (e.g. an off-screen window after a
  /// monitor was unplugged).
  private static func screenIndex(
    forFrame frame: CGRect, screens: [NSScreen]
  ) -> Int {
    let centre = CGPoint(x: frame.midX, y: frame.midY)
    for (i, s) in screens.enumerated() where s.frame.contains(centre) {
      return i
    }
    return 0
  }

  static func usableFrame(
    screenFrame: CGRect,
    visibleFrame: CGRect,
    statusBarReservesSpace: Bool,
    fontSize: CGFloat,
    fallbackNativeStatusBarHeight: CGFloat = OverlayPanel.nativeStatusBarFallbackHeight()
  ) -> CGRect {
    guard statusBarReservesSpace else { return visibleFrame }
    let statusBarHeight = OverlayPanel.statusBarHeight(
      screenFrame: screenFrame,
      visibleFrame: visibleFrame,
      fontSize: fontSize,
      fallbackNativeStatusBarHeight: fallbackNativeStatusBarHeight)
    let maxY = screenFrame.maxY - statusBarHeight
    return CGRect(
      x: visibleFrame.minX,
      y: visibleFrame.minY,
      width: visibleFrame.width,
      height: max(0, maxY - visibleFrame.minY))
  }

  /// Wrapper around `AXUIElementCopyAttributeValue` that returns the
  /// `AXUIElement` payload for window-shaped attributes (`kAXFocusedWindow`,
  /// `kAXMainWindow`), or `nil` when the attribute is missing or the
  /// query fails.
  private static func copyWindowAttribute(
    _ axApp: AXUIElement,
    _ attribute: String
  ) -> AXUIElement? {
    var ref: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(axApp, attribute as CFString, &ref)
    guard status == .success, let cf = ref else { return nil }
    return (cf as! AXUIElement)
  }

  /// First entry in the application's `kAXWindowsAttribute` list. AX
  /// orders the list front-to-back, so `[0]` is the topmost window —
  /// the right target when the focused/main attributes are nil (e.g.
  /// Alacritty exposes the windows array but neither shortcut).
  private static func copyFirstWindow(_ axApp: AXUIElement) -> AXUIElement? {
    var ref: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      axApp, kAXWindowsAttribute as CFString, &ref)
    guard status == .success, let array = ref as? [AXUIElement], let first = array.first
    else { return nil }
    return first
  }

  /// Read the AX position + size and convert to NSScreen coordinates
  /// (bottom-left origin, Y-up).
  private static func readWindowFrameInNSCoords(window: AXUIElement) -> CGRect? {
    var posRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        == .success,
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        == .success,
      let posCF = posRef, let sizeCF = sizeRef
    else { return nil }

    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posCF as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sizeCF as! AXValue, .cgSize, &size)

    let primaryHeight = NSScreen.screens.first?.frame.height ?? pos.y + size.height
    // AX y is from primary's top-left, Y-down. Convert to NSScreen
    // y (from primary's bottom-left, Y-up).
    let nsY = primaryHeight - pos.y - size.height
    return CGRect(x: pos.x, y: nsY, width: size.width, height: size.height)
  }

  /// Map a `WindowPosition` onto a slot of the supplied usable frame
  /// (in NSScreen / Y-up coordinates).
  static func rectFor(
    position: WindowPosition, in vf: CGRect
  ) -> CGRect {
    let halfW = vf.width / 2
    let halfH = vf.height / 2
    switch position {
    case .maximized:
      return vf
    case .leftHalf:
      return CGRect(x: vf.minX, y: vf.minY, width: halfW, height: vf.height)
    case .rightHalf:
      return CGRect(x: vf.midX, y: vf.minY, width: halfW, height: vf.height)
    case .topHalf:
      // NSScreen Y is up, so "top" is the upper half (y >= midY).
      return CGRect(x: vf.minX, y: vf.midY, width: vf.width, height: halfH)
    case .bottomHalf:
      return CGRect(x: vf.minX, y: vf.minY, width: vf.width, height: halfH)
    case .topLeft:
      return CGRect(x: vf.minX, y: vf.midY, width: halfW, height: halfH)
    case .topRight:
      return CGRect(x: vf.midX, y: vf.midY, width: halfW, height: halfH)
    case .bottomLeft:
      return CGRect(x: vf.minX, y: vf.minY, width: halfW, height: halfH)
    case .bottomRight:
      return CGRect(x: vf.midX, y: vf.minY, width: halfW, height: halfH)
    case .centered:
      // 70 × 80 of the visible frame, centred. Matches the
      // Hammerspoon `wm.centered()` shape users migrate from.
      let w = vf.width * 0.7
      let h = vf.height * 0.8
      return CGRect(
        x: vf.minX + (vf.width - w) / 2,
        y: vf.minY + (vf.height - h) / 2,
        width: w, height: h)
    }
  }

  /// Push the rect into the AX window. Mirrors Hammerspoon's
  /// `setFrame` (size → position → size) so the move is instant and
  /// survives screen-edge clamping:
  ///
  ///   1. Some apps (notably Cocoa apps with default behaviour)
  ///      animate frame changes by ~250ms whenever
  ///      `AXEnhancedUserInterface` is true. Toggling that attribute
  ///      off before the writes and back on after collapses the
  ///      animation to a single repaint. The toggle is a no-op for
  ///      apps that don't expose the attribute (Electron, native
  ///      browsers).
  ///   2. Setting size first means a *shrink* lands cleanly even if
  ///      the new position would have left the old (larger) window
  ///      hanging off the edge of the previous screen — AX clamps
  ///      position when the window's current size doesn't fit on
  ///      the destination.
  ///   3. Setting size again after position covers the *grow* case
  ///      (e.g. moving a 1280px window from a 1920px monitor to a
  ///      4K one and wanting it to fill the new screen): the first
  ///      size write may be clamped to the source screen, the
  ///      position move frees the constraint, the second size
  ///      write actually applies the target dimensions.
  private static func apply(
    rect nsRect: CGRect, toWindow window: AXUIElement, axApp: AXUIElement
  ) {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? nsRect.maxY
    let axY = primaryHeight - nsRect.maxY
    var axPos = CGPoint(x: nsRect.origin.x, y: axY)
    var axSize = CGSize(width: nsRect.width, height: nsRect.height)

    let previousEnhanced = enhancedUserInterface(of: axApp)
    if previousEnhanced == true {
      setEnhancedUserInterface(false, on: axApp)
    }
    defer {
      if previousEnhanced == true {
        setEnhancedUserInterface(true, on: axApp)
      }
    }

    func setSize() {
      if let v = AXValueCreate(.cgSize, &axSize) {
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
      }
    }
    func setPos() {
      if let v = AXValueCreate(.cgPoint, &axPos) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
      }
    }
    setSize()
    setPos()
    setSize()
  }

  /// Read `AXEnhancedUserInterface`. Returns `nil` for apps that
  /// don't expose the attribute (most non-Cocoa apps). Returns
  /// `true` / `false` for the apps that do.
  private static func enhancedUserInterface(of axApp: AXUIElement) -> Bool? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
      axApp, "AXEnhancedUserInterface" as CFString, &value)
    guard status == .success, let cf = value else { return nil }
    return CFBooleanGetValue((cf as! CFBoolean))
  }

  private static func setEnhancedUserInterface(_ enabled: Bool, on axApp: AXUIElement) {
    AXUIElementSetAttributeValue(
      axApp,
      "AXEnhancedUserInterface" as CFString,
      enabled ? kCFBooleanTrue : kCFBooleanFalse)
  }
}
