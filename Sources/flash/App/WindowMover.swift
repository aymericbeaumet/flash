import AppKit
import ApplicationServices
import FlashCore

struct WindowScreenLayout: Equatable {
  let id: CGDirectDisplayID
  let frame: CGRect
  let usableFrame: CGRect
}

/// Owns interactive window moves and the semantic layout attached to each
/// window. AX requests run on a dedicated serial queue: a slow target app must
/// not stall Flash's main run loop (and therefore its keyboard tap) while it
/// answers a window resize request.
final class WindowLayoutManager {
  typealias ScreenLayoutsProvider =
    (Bool, Config.StatusBar.Monitor) -> [WindowScreenLayout]

  private struct WindowKey: Hashable {
    let pid: pid_t
    let element: AnyHashable

    init(pid: pid_t, window: AXUIElement) {
      self.pid = pid
      self.element = AnyHashable(window)
    }
  }

  private struct TrackedLayout {
    let pid: pid_t
    let window: AXUIElement
    var layout: WindowLayout
    var screenID: CGDirectDisplayID
  }

  private let queue = DispatchQueue(label: "flash.window-layout", qos: .userInitiated)
  private var tracked: [WindowKey: TrackedLayout] = [:]
  private var currentScreens: [WindowScreenLayout] = []
  private var screenChangeGeneration: UInt64 = 0
  private var screenChangeKeys: Set<WindowKey> = []
  private var screenChangeActiveUntil = DispatchTime(uptimeNanoseconds: 0)
  private var selfAuthoredChangesUntil: [WindowKey: DispatchTime] = [:]

  private let screenRecoveryDelaysMs: [Int]
  private let screenLayoutsProvider: ScreenLayoutsProvider
  private static let authoredChangeGraceMs = 300

  init(
    screenRecoveryDelaysMs: [Int] = [80, 250, 750],
    screenLayouts: @escaping ScreenLayoutsProvider = { statusBarVisible, monitor in
      WindowMover.screenLayouts(
        statusBarReservesSpace: statusBarVisible,
        statusBarMonitor: monitor)
    }
  ) {
    self.screenRecoveryDelaysMs = screenRecoveryDelaysMs
    self.screenLayoutsProvider = screenLayouts
  }

  func move(
    _ params: MoveWindowParams,
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor,
    targetPID: pid_t
  ) {
    let screens = screenLayoutsProvider(statusBarReservesSpace, statusBarMonitor)
    queue.async { [weak self] in
      guard let self else { return }
      self.currentScreens = screens
      guard
        let result = WindowMover.move(
          params,
          targetPID: targetPID,
          screens: screens,
          existingLayout: { window in
            self.tracked[WindowKey(pid: targetPID, window: window)]?.layout
          })
      else { return }
      let key = WindowKey(pid: targetPID, window: result.window)
      if let layout = result.layout {
        self.tracked[key] = TrackedLayout(
          pid: targetPID,
          window: result.window,
          layout: layout,
          screenID: result.screenID)
        self.selfAuthoredChangesUntil[key] =
          .now() + .milliseconds(Self.authoredChangeGraceMs)
      } else {
        self.tracked.removeValue(forKey: key)
        self.selfAuthoredChangesUntil.removeValue(forKey: key)
      }
    }
  }

  /// Reapply semantic layouts after any display topology or usable-frame
  /// change. Repeated bounded passes cover apps that perform their own delayed
  /// relocation after AppKit's screen notification; a newer notification
  /// cancels the older recovery generation.
  func screenParametersDidChange(
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor,
    forceRecovery: Bool = true,
    afterRecoveryPass: (([WindowScreenLayout]) -> Void)? = nil
  ) {
    let provider = screenLayoutsProvider
    scheduleScreenRecovery(
      initialScreens: provider(statusBarReservesSpace, statusBarMonitor),
      forceRecovery: forceRecovery,
      settledScreens: { provider(statusBarReservesSpace, statusBarMonitor) },
      afterRecoveryPass: afterRecoveryPass)
  }

  /// Value-only entry point so display handoff scheduling can be exercised
  /// without asking AppKit for the host's real screen topology.
  func screenParametersDidChange(
    screens: [WindowScreenLayout],
    afterRecoveryPass: (([WindowScreenLayout]) -> Void)? = nil
  ) {
    scheduleScreenRecovery(
      initialScreens: screens,
      forceRecovery: false,
      settledScreens: { screens },
      afterRecoveryPass: afterRecoveryPass)
  }

  private func scheduleScreenRecovery(
    initialScreens: [WindowScreenLayout],
    forceRecovery: Bool,
    settledScreens: @escaping () -> [WindowScreenLayout],
    afterRecoveryPass: (([WindowScreenLayout]) -> Void)?
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      let previousScreens = self.currentScreens
      if !initialScreens.isEmpty { self.currentScreens = initialScreens }
      guard !previousScreens.isEmpty, !initialScreens.isEmpty,
        forceRecovery || previousScreens != initialScreens
      else { return }

      let now = DispatchTime.now()
      let continuingChange = now < self.screenChangeActiveUntil
      if !continuingChange {
        self.screenChangeKeys = Set(self.tracked.keys)
      } else {
        self.screenChangeKeys.formUnion(self.tracked.keys)
      }
      self.screenChangeActiveUntil =
        now + .milliseconds((self.screenRecoveryDelaysMs.last ?? 0) + Self.authoredChangeGraceMs)
      self.screenChangeGeneration &+= 1
      let generation = self.screenChangeGeneration
      let lastDelayMs = self.screenRecoveryDelaysMs.last

      for delayMs in self.screenRecoveryDelaysMs {
        // AppKit may deliver the notification before NSScreen.main and
        // visibleFrame settle. Re-snapshot on main for every bounded pass
        // instead of replaying the notification's transitional geometry.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
          let screens = settledScreens()
          self?.queue.async { [weak self] in
            guard let self, self.screenChangeGeneration == generation else { return }
            if !screens.isEmpty {
              self.currentScreens = screens
              self.restoreTrackedLayouts(using: screens)
              if let afterRecoveryPass {
                DispatchQueue.main.async {
                  afterRecoveryPass(screens)
                }
              }
            }
            if delayMs == lastDelayMs {
              self.screenChangeKeys.removeAll()
            }
          }
        }
      }
    }
  }

  /// Track native/dragged named-slot changes too, retain an explicitly applied
  /// proportional intent while its frame still matches, and forget Flash-owned
  /// layout as soon as the user moves the window to an arbitrary frame. The AX
  /// observer supplies the exact focused-window element, so multiple windows
  /// belonging to the same process remain independent.
  func observedWindowFrameChange(
    pid: pid_t,
    window: AXUIElement,
    frame: CGRect,
    notification: String,
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor
  ) {
    let screens = screenLayoutsProvider(statusBarReservesSpace, statusBarMonitor)
    queue.async { [weak self] in
      guard let self else { return }
      let key = WindowKey(pid: pid, window: window)
      if notification == kAXUIElementDestroyedNotification as String {
        self.tracked.removeValue(forKey: key)
        self.selfAuthoredChangesUntil.removeValue(forKey: key)
        return
      }
      // AppKit can publish the new NSScreen topology before delivering its
      // screen-parameters notification. Do not mistake macOS's interim window
      // relocation for a user-authored free-form resize and erase the slot we
      // are about to restore.
      if self.currentScreens != screens {
        return
      }
      let now = DispatchTime.now()
      if now < self.screenChangeActiveUntil
        || now < (self.selfAuthoredChangesUntil[key] ?? DispatchTime(uptimeNanoseconds: 0))
      {
        return
      }
      self.selfAuthoredChangesUntil.removeValue(forKey: key)
      self.recordObservedLayout(
        key: key, pid: pid, window: window, frame: frame, screens: screens)
    }
  }

  /// Classify the focused window when Flash first observes it, not only after
  /// it moves. A window that was already tiled/maximized before Flash launched
  /// must still survive the first display handoff.
  func observedFocusedWindow(
    pid: pid_t,
    window: AXUIElement,
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor
  ) {
    let screens = screenLayoutsProvider(statusBarReservesSpace, statusBarMonitor)
    queue.async { [weak self] in
      guard let self, let primaryHeight = WindowMover.primaryHeight(in: screens) else { return }
      if self.currentScreens.isEmpty { self.currentScreens = screens }
      guard self.currentScreens == screens else { return }
      let key = WindowKey(pid: pid, window: window)
      let now = DispatchTime.now()
      guard now >= self.screenChangeActiveUntil,
        now >= (self.selfAuthoredChangesUntil[key] ?? DispatchTime(uptimeNanoseconds: 0)),
        let frame = WindowMover.readWindowFrameInNSCoords(
          window: window, primaryHeight: primaryHeight)
      else { return }
      self.selfAuthoredChangesUntil.removeValue(forKey: key)
      self.recordObservedLayout(
        key: key, pid: pid, window: window, frame: frame, screens: screens)
    }
  }

  private func recordObservedLayout(
    key: WindowKey,
    pid: pid_t,
    window: AXUIElement,
    frame: CGRect,
    screens: [WindowScreenLayout]
  ) {
    guard let screen = WindowMover.screenContaining(frame: frame, screens: screens) else {
      tracked.removeValue(forKey: key)
      return
    }
    let existingLayout = tracked[key]?.layout
    guard
      let layout = WindowMover.semanticLayout(
        matching: frame,
        in: screen.usableFrame,
        existing: existingLayout)
    else {
      tracked.removeValue(forKey: key)
      return
    }
    tracked[key] = TrackedLayout(
      pid: pid,
      window: window,
      layout: layout,
      screenID: screen.id)
  }

  private func restoreTrackedLayouts(using screens: [WindowScreenLayout]) {
    guard !screenChangeKeys.isEmpty,
      let primaryHeight = WindowMover.primaryHeight(in: screens)
    else { return }
    var restored = 0
    for key in screenChangeKeys {
      guard var layout = tracked[key] else { continue }
      guard NSRunningApplication(processIdentifier: layout.pid)?.isTerminated == false else {
        tracked.removeValue(forKey: key)
        selfAuthoredChangesUntil.removeValue(forKey: key)
        continue
      }
      let bundleIdentifier =
        NSRunningApplication(processIdentifier: layout.pid)?.bundleIdentifier
      let axApp = AXApp.make(pid: layout.pid)
      let didRestore = FirefoxAccessibility.withWindowManagement(
        pid: layout.pid,
        bundleIdentifier: bundleIdentifier,
        app: axApp
      ) { axApp, prepareGeometry in
        let current = WindowMover.readWindowFrameInNSCoords(
          window: layout.window,
          primaryHeight: primaryHeight)
        guard
          let plan = WindowMover.recoveryPlan(
            layout: layout.layout,
            screenID: layout.screenID,
            currentFrame: current,
            screens: screens)
        else { return false }
        layout.screenID = plan.screen.id
        guard current.map({ WindowMover.framesApproximatelyEqual($0, plan.frame) }) != true else {
          return false
        }
        let startedAt = DispatchTime.now()
        prepareGeometry()
        WindowMover.apply(
          rect: plan.frame,
          toWindow: layout.window,
          axApp: axApp,
          primaryHeight: primaryHeight,
          bundleIdentifier: bundleIdentifier)
        let elapsedMs = WindowMover.elapsedMs(since: startedAt)
        if elapsedMs >= 100 {
          FlashLog.warn(
            "[window_layout] slow restore pid=\(layout.pid) "
              + "layout=\(WindowMover.description(of: layout.layout)) "
              + "elapsed_ms=\(Int(elapsedMs.rounded()))")
        }
        return true
      }
      if didRestore {
        restored += 1
      }
      tracked[key] = layout
      selfAuthoredChangesUntil[key] =
        .now() + .milliseconds(Self.authoredChangeGraceMs)
    }
    if restored > 0 {
      FlashLog.debug(
        "[window_layout] restored count=\(restored)")
    }
  }

  func appDidTerminate(pid: pid_t) {
    queue.async { [weak self] in
      guard let self else { return }
      let keys = self.tracked.keys.filter { $0.pid == pid }
      for key in keys {
        self.tracked.removeValue(forKey: key)
        self.selfAuthoredChangesUntil.removeValue(forKey: key)
        self.screenChangeKeys.remove(key)
      }
    }
  }
}

/// Implements the `window_move` named/proportional layout and screen-selection
/// options against the focused application's focused window via Accessibility. When the
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

  struct MoveResult {
    let window: AXUIElement
    let layout: WindowLayout?
    let screenID: CGDirectDisplayID
  }

  struct FramePlan {
    let frame: CGRect
    let layout: WindowLayout?
  }

  struct LayoutRecoveryPlan {
    let screen: WindowScreenLayout
    let frame: CGRect
  }

  /// Snapshot AppKit-owned screen state on the main thread before any AX work
  /// moves to the background queue. `NSScreen` is an AppKit object; the plain
  /// value layouts below are safe to carry onto `WindowLayoutManager.queue`.
  static func screenLayouts(
    statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor
  ) -> [WindowScreenLayout] {
    let fontSize = OverlayPanel.statusBarFontSize(overlayFontSize: 0)
    let screens = NSScreen.screens
    let mainFrame = (NSScreen.main ?? screens.first)?.frame
    return screens.enumerated().map { index, screen in
      let number =
        screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      // NSScreenNumber is present for physical displays. Keep a deterministic
      // fallback for virtual/test screens rather than dropping the layout.
      let screenID = number?.uint32Value ?? CGDirectDisplayID(index + 1)
      return WindowScreenLayout(
        id: screenID,
        frame: screen.frame,
        usableFrame: usableFrame(
          screenFrame: screen.frame,
          visibleFrame: screen.visibleFrame,
          statusBarReservesSpace: shouldReserveStatusBarSpace(
            statusBarVisible: statusBarReservesSpace,
            monitor: statusBarMonitor,
            isMainScreen: screen.frame == mainFrame),
          fontSize: fontSize))
    }
  }

  static func shouldReserveStatusBarSpace(
    statusBarVisible: Bool,
    monitor: Config.StatusBar.Monitor,
    isMainScreen: Bool
  ) -> Bool {
    statusBarVisible && (monitor == .all || isMainScreen)
  }

  static func primaryHeight(in screens: [WindowScreenLayout]) -> CGFloat? {
    screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? screens.first?.frame.height
  }

  static func move(
    _ params: MoveWindowParams,
    targetPID: pid_t,
    screens: [WindowScreenLayout],
    existingLayout: (AXUIElement) -> WindowLayout?
  ) -> MoveResult? {
    let startedAt = DispatchTime.now()
    let axApp = AXApp.make(pid: targetPID)
    let bundleIdentifier =
      NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier
    return FirefoxAccessibility.withWindowManagement(
      pid: targetPID,
      bundleIdentifier: bundleIdentifier,
      app: axApp
    ) { axApp, prepareGeometry in
      move(
        params,
        targetPID: targetPID,
        screens: screens,
        startedAt: startedAt,
        axApp: axApp,
        bundleIdentifier: bundleIdentifier,
        prepareGeometry: prepareGeometry,
        existingLayout: existingLayout)
    }
  }

  private static func move(
    _ params: MoveWindowParams,
    targetPID: pid_t,
    screens: [WindowScreenLayout],
    startedAt: DispatchTime,
    axApp: AXUIElement,
    bundleIdentifier: String?,
    prepareGeometry: () -> Void,
    existingLayout: (AXUIElement) -> WindowLayout?
  ) -> MoveResult? {

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
    let resolveStartedAt = DispatchTime.now()
    guard let resolution = resolveWindow(axApp) else {
      FlashLog.warn(
        "[window_move] no AX window for pid \(targetPID)")
      return nil
    }
    let window = resolution.window
    let resolveMs = elapsedMs(since: resolveStartedAt)

    guard let primaryHeight = primaryHeight(in: screens) else { return nil }
    let frameStartedAt = DispatchTime.now()
    guard
      let currentFrame = readWindowFrameInNSCoords(
        window: window, primaryHeight: primaryHeight)
    else { return nil }
    let frameMs = elapsedMs(since: frameStartedAt)
    let currentIndex = screenIndex(forFrame: currentFrame, screens: screens)
    let count = screens.count
    // Swift's `%` returns negative results for negative LHS, so wrap
    // through `+ count` before the final modulo.
    let targetIndex = ((currentIndex + params.screen) % count + count) % count
    let currentScreen = screens[currentIndex]
    let targetScreen = screens[targetIndex]
    guard
      let plan = framePlan(
        currentFrame: currentFrame,
        from: currentScreen,
        to: targetScreen,
        currentLayout: existingLayout(window),
        requestedLayout: params.layout,
        screenChanged: targetIndex != currentIndex)
    else { return nil }
    let rect = plan.frame
    prepareGeometry()
    let applyStartedAt = DispatchTime.now()
    apply(
      rect: rect,
      toWindow: window,
      axApp: axApp,
      primaryHeight: primaryHeight,
      bundleIdentifier: bundleIdentifier)
    let applyMs = elapsedMs(since: applyStartedAt)
    let totalMs = elapsedMs(since: startedAt)
    if totalMs >= 100 {
      FlashLog.warn(
        "[window_move] slow pid=\(targetPID) source=\(resolution.source) "
          + "layout=\(plan.layout.map { description(of: $0) } ?? "arbitrary") "
          + "resolve_ms=\(Int(resolveMs.rounded())) "
          + "frame_ms=\(Int(frameMs.rounded())) "
          + "apply_ms=\(Int(applyMs.rounded())) "
          + "total_ms=\(Int(totalMs.rounded()))")
    }
    return MoveResult(
      window: window,
      layout: plan.layout,
      screenID: targetScreen.id)
  }

  /// Plan a move entirely in NSScreen coordinates. A requested layout wins;
  /// otherwise a screen-only move carries a still-matching tracked intent or
  /// recognized named slot onto the destination. Truly free-form frames are
  /// remapped proportionally without becoming managed layouts.
  static func framePlan(
    currentFrame: CGRect,
    from source: WindowScreenLayout,
    to destination: WindowScreenLayout,
    currentLayout: WindowLayout?,
    requestedLayout: WindowLayout?,
    screenChanged: Bool
  ) -> FramePlan? {
    if let requestedLayout {
      return FramePlan(
        frame: rectFor(layout: requestedLayout, in: destination.usableFrame),
        layout: requestedLayout)
    }
    guard screenChanged else { return nil }
    if let currentLayout,
      framesApproximatelyEqual(
        currentFrame,
        rectFor(layout: currentLayout, in: source.usableFrame))
    {
      return FramePlan(
        frame: rectFor(layout: currentLayout, in: destination.usableFrame),
        layout: currentLayout)
    }
    let sourcePosition = position(matching: currentFrame, in: source.usableFrame)
    if let sourcePosition {
      return FramePlan(
        frame: rectFor(position: sourcePosition, in: destination.usableFrame),
        layout: .position(sourcePosition))
    }
    return FramePlan(
      frame: remap(
        frame: currentFrame,
        from: source.usableFrame,
        to: destination.usableFrame),
      layout: nil)
  }

  /// Resolve the destination for a tracked intent after any screen-topology or
  /// usable-frame change. A surviving display keeps ownership. If it vanished,
  /// follow macOS's relocated window to its new screen, falling back to the
  /// primary display for a fully orphaned frame.
  static func recoveryPlan(
    layout: WindowLayout,
    screenID: CGDirectDisplayID,
    currentFrame: CGRect?,
    screens: [WindowScreenLayout]
  ) -> LayoutRecoveryPlan? {
    guard let primary = screens.first else { return nil }
    let screen =
      screens.first(where: { $0.id == screenID })
      ?? currentFrame.flatMap { screenContaining(frame: $0, screens: screens) }
      ?? primary
    return LayoutRecoveryPlan(
      screen: screen,
      frame: rectFor(layout: layout, in: screen.usableFrame))
  }

  static func description(of layout: WindowLayout) -> String {
    switch layout {
    case .position(let position):
      return "position=\(position.rawValue)"
    case .proportional(let frame):
      return "x=\(frame.xPercent)% y=\(frame.yPercent)% "
        + "width=\(frame.widthPercent)% height=\(frame.heightPercent)%"
    }
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
  static func screenIndex(
    forFrame frame: CGRect, screens: [WindowScreenLayout]
  ) -> Int {
    let centre = CGPoint(x: frame.midX, y: frame.midY)
    for (i, s) in screens.enumerated() where s.frame.contains(centre) {
      return i
    }
    // A partly off-screen window can have its centre outside every display.
    // Pick the display with the greatest overlap before falling back to the
    // primary for a fully orphaned frame after unplugging a monitor.
    if let best = screens.enumerated().max(by: {
      intersectionArea(frame, $0.element.frame) < intersectionArea(frame, $1.element.frame)
    }), intersectionArea(frame, best.element.frame) > 0 {
      return best.offset
    }
    return 0
  }

  static func screenContaining(
    frame: CGRect, screens: [WindowScreenLayout]
  ) -> WindowScreenLayout? {
    guard !screens.isEmpty else { return nil }
    return screens[screenIndex(forFrame: frame, screens: screens)]
  }

  private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }
    return intersection.width * intersection.height
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

  /// Resolve focused/main/frontmost in one AX IPC. Flash's overlay may own key
  /// focus while a normal-mode mapping fires, so the target application's
  /// focused attribute is legitimately absent; requesting all fallbacks as one
  /// batch avoids serially waiting on three app round trips in that case.
  private static func resolveWindow(
    _ axApp: AXUIElement
  ) -> (window: AXUIElement, source: String)? {
    let names = [
      kAXFocusedWindowAttribute as String,
      kAXMainWindowAttribute as String,
      kAXWindowsAttribute as String,
    ]
    var raw: CFArray?
    let status = AXUIElementCopyMultipleAttributeValues(
      axApp, names as CFArray, AXCopyMultipleAttributeOptions(), &raw)
    if status == .success, let values = raw as? [Any], values.count == names.count {
      if let window = windowElement(values[0]) { return (window, "focused") }
      if let window = windowElement(values[1]) { return (window, "main") }
      if let windows = values[2] as? [AXUIElement], let window = windows.first {
        return (window, "windows")
      }
    }

    // Rare wholesale batch failure: keep the compatibility fallbacks lazy so
    // a successful focused/main lookup stops before the more expensive window
    // list read.
    if let window = copyWindowAttribute(axApp, kAXFocusedWindowAttribute) {
      return (window, "focused_fallback")
    }
    if let window = copyWindowAttribute(axApp, kAXMainWindowAttribute) {
      return (window, "main_fallback")
    }
    var windowsRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(
      axApp, kAXWindowsAttribute as CFString, &windowsRaw) == .success,
      let windows = windowsRaw as? [AXUIElement], let window = windows.first
    {
      return (window, "windows_fallback")
    }
    return nil
  }

  private static func copyWindowAttribute(
    _ axApp: AXUIElement, _ attribute: String
  ) -> AXUIElement? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, attribute as CFString, &raw) == .success,
      let raw
    else { return nil }
    return windowElement(raw)
  }

  private static func windowElement(_ value: Any) -> AXUIElement? {
    guard CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  /// Read the AX position + size and convert to NSScreen coordinates
  /// (bottom-left origin, Y-up).
  static func readWindowFrameInNSCoords(
    window: AXUIElement, primaryHeight: CGFloat
  ) -> CGRect? {
    let names = [kAXPositionAttribute as String, kAXSizeAttribute as String]
    var raw: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(
        window, names as CFArray, AXCopyMultipleAttributeOptions(), &raw) == .success,
      let values = raw as? [Any], values.count == names.count,
      CFGetTypeID(values[0] as CFTypeRef) == AXValueGetTypeID(),
      CFGetTypeID(values[1] as CFTypeRef) == AXValueGetTypeID()
    else { return nil }

    var pos = CGPoint.zero
    var size = CGSize.zero
    let posValue = values[0] as! AXValue
    let sizeValue = values[1] as! AXValue
    guard AXValueGetType(posValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else {
      return nil
    }
    AXValueGetValue(posValue, .cgPoint, &pos)
    AXValueGetValue(sizeValue, .cgSize, &size)

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

  /// Map a semantic layout onto the supplied usable frame. Proportional `x`
  /// and `y` are measured from the user's top-left perspective even though the
  /// returned CGRect uses NSScreen's bottom-left, Y-up coordinate space.
  static func rectFor(layout: WindowLayout, in usableFrame: CGRect) -> CGRect {
    switch layout {
    case .position(let position):
      return rectFor(position: position, in: usableFrame)
    case .proportional(let frame):
      let width = usableFrame.width * CGFloat(frame.widthPercent / 100)
      let height = usableFrame.height * CGFloat(frame.heightPercent / 100)
      return CGRect(
        x: usableFrame.minX + usableFrame.width * CGFloat(frame.xPercent / 100),
        y: usableFrame.maxY
          - usableFrame.height * CGFloat(frame.yPercent / 100)
          - height,
        width: width,
        height: height)
    }
  }

  /// Recover the semantic slot represented by an observed window frame. The
  /// small tolerance absorbs AX/AppKit rounding on odd-sized displays without
  /// treating an intentional free-form resize as a tiled layout.
  static func position(
    matching frame: CGRect,
    in usableFrame: CGRect,
    tolerance: CGFloat = 2
  ) -> WindowPosition? {
    WindowPosition.allCases.first {
      framesApproximatelyEqual(
        frame, rectFor(position: $0, in: usableFrame), tolerance: tolerance)
    }
  }

  static func semanticLayout(
    matching frame: CGRect,
    in usableFrame: CGRect,
    existing: WindowLayout?
  ) -> WindowLayout? {
    if let existing,
      framesApproximatelyEqual(frame, rectFor(layout: existing, in: usableFrame))
    {
      return existing
    }
    return position(matching: frame, in: usableFrame).map(WindowLayout.position)
  }

  static func framesApproximatelyEqual(
    _ lhs: CGRect,
    _ rhs: CGRect,
    tolerance: CGFloat = 2
  ) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
      && abs(lhs.minY - rhs.minY) <= tolerance
      && abs(lhs.width - rhs.width) <= tolerance
      && abs(lhs.height - rhs.height) <= tolerance
  }

  /// The most correction passes `apply` makes after its initial
  /// size → position → size burst. One pass is enough to defeat the async
  /// grow-clamp race described below; the extra margin lets grid-snapping
  /// apps settle without looping.
  private static let applyCorrectionAttempts = 2

  /// Push the rect into the AX window. Mirrors Hammerspoon's
  /// `setFrame` (size → position → size) so the move is instant and
  /// survives screen-edge clamping:
  ///
  ///   1. Some apps (notably Cocoa apps with default behaviour)
  ///      animate frame changes by ~250ms whenever
  ///      `AXEnhancedUserInterface` is true. Toggling that attribute
  ///      off before the writes and back on after collapses the
  ///      animation to a single repaint. Firefox is explicitly excluded from
  ///      this toggle because its shared accessibility scope is restored before
  ///      `apply` enters the per-process window-management critical section.
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
  ///   4. The burst above assumes each AX write lands before the next, but
  ///      many apps apply frame writes asynchronously. When the position move
  ///      to the origin hasn't landed by the time the final size write is
  ///      processed, the app clamps the *grow* against the window's old
  ///      position and it settles narrower than requested — the intermittent
  ///      "maximize only fills ~85% of the width" the result depends on where
  ///      the window happened to start. After the burst, read the frame back
  ///      (a synchronous AX round-trip that flushes the app's pending writes)
  ///      and, if it missed the target, re-issue position → size. Bounded so a
  ///      window that genuinely can't reach the rect (grid-snapping terminals,
  ///      min-size dialogs) stops instead of looping.
  static func apply(
    rect nsRect: CGRect,
    toWindow window: AXUIElement,
    axApp: AXUIElement,
    primaryHeight: CGFloat,
    bundleIdentifier: String?
  ) {
    let axY = primaryHeight - nsRect.maxY
    var axPos = CGPoint(x: nsRect.origin.x, y: axY)
    var axSize = CGSize(width: nsRect.width, height: nsRect.height)

    let previousEnhanced = enhancedUserInterface(of: axApp)
    let enhancedUserInterfaceIsSettable = isEnhancedUserInterfaceSettable(on: axApp)
    let temporarilyDisableEnhancedUserInterface = shouldTemporarilyDisableEnhancedUserInterface(
      currentValue: previousEnhanced,
      isSettable: enhancedUserInterfaceIsSettable,
      bundleIdentifier: bundleIdentifier)
    if temporarilyDisableEnhancedUserInterface {
      setEnhancedUserInterface(false, on: axApp)
    }
    defer {
      if temporarilyDisableEnhancedUserInterface {
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

    // Verify the burst actually reached the target and, if an async grow-clamp
    // left the window short, correct it. The read-back is synchronous, so by
    // the time it returns the earlier position move has landed — the window now
    // sits at the origin and the corrective size write can grow freely.
    for _ in 0..<Self.applyCorrectionAttempts {
      guard
        let actual = readWindowFrameInNSCoords(window: window, primaryHeight: primaryHeight),
        !framesApproximatelyEqual(actual, nsRect)
      else { break }
      setPos()
      setSize()
    }
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

  private static func isEnhancedUserInterfaceSettable(on axApp: AXUIElement) -> Bool {
    var settable = DarwinBoolean(false)
    let status = AXUIElementIsAttributeSettable(
      axApp,
      "AXEnhancedUserInterface" as CFString,
      &settable)
    return status == .success && settable.boolValue
  }

  static func shouldTemporarilyDisableEnhancedUserInterface(
    currentValue: Bool?,
    isSettable: Bool,
    bundleIdentifier: String?
  ) -> Bool {
    return currentValue == true
      && isSettable
      && !enhancedUserInterfaceToggleExcludedBundleIdentifiers.contains(bundleIdentifier ?? "")
  }

  private static let enhancedUserInterfaceToggleExcludedBundleIdentifiers: Set<String> = [
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.nightly",
  ]

  private static func setEnhancedUserInterface(_ enabled: Bool, on axApp: AXUIElement) {
    AXUIElementSetAttributeValue(
      axApp,
      "AXEnhancedUserInterface" as CFString,
      enabled ? kCFBooleanTrue : kCFBooleanFalse)
  }

  static func elapsedMs(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
  }
}
