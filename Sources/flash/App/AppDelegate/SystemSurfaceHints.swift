import AppKit
import ApplicationServices
import FlashCore
import FlashProviders

/// Hints beyond the focused app's window: the Dock (`mouse_dock`), the menu
/// bar (`mouse_menubar`) and Notification Center (`mouse_notifications`).
/// Wooshy-parity coverage without new permissions — the Dock, the focused
/// app's menu titles and Notification Center are read through their AX trees
/// under the existing Accessibility grant, and status items come from
/// WindowServer geometry (`CGWindowListCopyWindowInfo`, layer 25, geometry
/// only — never content). Every commit is a click `ActionDispatcher` posts.
extension AppDelegate {
  /// Provider of `mouse_menubar` targets, app menu titles and status items
  /// alike. Committing one opens a menu that owns the keyboard, so the commit
  /// path suspends NORMAL for it (the right-click context-menu rule).
  static let menuBarProviderID = "mouse_menubar"
  static let notificationsProviderID = "mouse_notifications"
  /// Role of a status-item target, which has WindowServer geometry but no AX
  /// element.
  static let statusItemHintRole = "FlashStatusItem"

  static func hintOpensMenuBarMenu(_ target: JumpTarget) -> Bool {
    target.providerID == menuBarProviderID
  }

  /// Where a committed hint aims before its target resolves. Most hints aim
  /// at their chip, which sits on the target; a menu title, status item or
  /// notification control is clicked at its centre instead — a banner's chip
  /// sits on its top-left corner, where the close button appears on hover.
  static func hintCommitPoint(for hint: AssignedHint, fontSize: CGFloat) -> CGPoint {
    let provider = hint.target.providerID
    if provider == menuBarProviderID || provider == notificationsProviderID {
      return CGPoint(x: hint.target.frame.midX, y: hint.target.frame.midY)
    }
    let chip = OverlayPanel.chipFrame(for: hint, fontSize: fontSize)
    return CGPoint(x: chip.midX, y: chip.midY)
  }

  func activateDockHints() {
    guard prepareHintActivation(.dock) else { return }
    guard
      let dock = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.apple.dock"
      })
    else {
      FlashLog.debug("[mouse_dock] dock_not_running")
      applyModeOverlay()
      return
    }
    let pid = dock.processIdentifier
    let screenH = ActionDispatcher.primaryScreenHeight()
    let token = activationLifecycle.begin()
    applyModeOverlay()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let targets = Self.dockTargets(pid: pid, screenH: screenH)
      DispatchQueue.main.async {
        guard let self, self.activationLifecycle.complete(token: token) else { return }
        self.presentSystemSurfaceHints(targets, pid: pid, surface: "mouse_dock")
      }
    }
  }

  /// `mouse_menubar`: the focused app's menu titles, Apple menu first, then
  /// the status items. Committing a title opens its menu.
  func activateMenuBarHints() {
    guard prepareHintActivation(.menuBar) else { return }
    let token = activationLifecycle.begin()
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let screenH = ActionDispatcher.primaryScreenHeight()
    let screens = NSScreen.screens.map(\.frame)
    // The flashlight or the command bar may hold activation; the menus on
    // screen belong to the app that owns the menu bar.
    let menuOwner =
      NSWorkspace.shared.menuBarOwningApplication
      .flatMap { $0.processIdentifier == ownPID ? nil : $0 }
      ?? currentNonFlashRunningApplication()
    let ownerPID = menuOwner?.processIdentifier
    let ownerBundle = menuOwner?.bundleIdentifier
    applyModeOverlay()
    let raw = WindowSnapshot.windowList() ?? []
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let menus =
        ownerPID.map {
          Self.menuTitleTargets(
            pid: $0, bundleIdentifier: ownerBundle, screenH: screenH, screens: screens)
        } ?? []
      let targets = menus + Self.statusItemTargets(raw, ownPID: Int(ownPID), screenH: screenH)
      DispatchQueue.main.async {
        guard let self, self.activationLifecycle.complete(token: token) else { return }
        self.presentSystemSurfaceHints(targets, pid: nil, surface: "mouse_menubar")
      }
    }
  }

  /// `mouse_notifications`: what Notification Center shows. Silent when it
  /// shows nothing.
  func activateNotificationHints() {
    guard prepareHintActivation(.notifications) else { return }
    guard
      let center = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == NotificationCenterSurface.bundleIdentifier
      })
    else {
      FlashLog.debug("[mouse_notifications] notification_center_not_running")
      applyModeOverlay()
      return
    }
    let pid = center.processIdentifier
    let screenH = ActionDispatcher.primaryScreenHeight()
    let token = activationLifecycle.begin()
    applyModeOverlay()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let targets = Self.notificationTargets(pid: pid, screenH: screenH)
      DispatchQueue.main.async {
        guard let self, self.activationLifecycle.complete(token: token) else { return }
        self.presentSystemSurfaceHints(targets, pid: nil, surface: "mouse_notifications")
      }
    }
  }

  /// The menu owner's `AXMenuBarItem`s on screen, in bar order.
  private static func menuTitleTargets(
    pid: pid_t, bundleIdentifier: String?, screenH: CGFloat, screens: [CGRect]
  ) -> [JumpTarget] {
    let app = AXApp.make(pid: pid)
    return MenuBarSource.menuBarItems(of: app).enumerated().compactMap { index, item in
      guard
        let target = AccessibilityProvider.captureTarget(
          element: item, id: "menu_bar_item_\(pid)_\(index)", pid: pid, screenH: screenH,
          providerID: menuBarProviderID, bundleIdentifier: bundleIdentifier),
        target.role == "AXMenuBarItem",
        screens.contains(where: { $0.intersects(target.frame) })
      else { return nil }
      return target
    }
  }

  /// Notification Center's pressable elements as targets. They carry no pid:
  /// Notification Center never becomes the frontmost app, so the commit must
  /// not wait for it to activate; the notification's own app comes forward
  /// when the click opens it.
  private static func notificationTargets(pid: pid_t, screenH: CGFloat) -> [JumpTarget] {
    let elements = NotificationCenterSurface.pressableElements(
      in: NotificationCenterSurface.readWindows(pid: pid, screenH: screenH))
    return elements.enumerated().compactMap { index, element in
      guard
        let target = AccessibilityProvider.captureTarget(
          element: element, id: "notification_\(index)", pid: pid, screenH: screenH,
          providerID: notificationsProviderID,
          bundleIdentifier: NotificationCenterSurface.bundleIdentifier)
      else { return nil }
      return JumpTarget(
        id: target.id, frame: target.frame, role: target.role,
        accessibilityLabel: target.accessibilityLabel, url: target.url,
        resolveClickPoint: target.resolveClickPoint, entersInsertMode: false,
        providerID: target.providerID)
    }
  }

  static func statusItemTargets(
    _ raw: [[String: Any]], ownPID: Int, screenH: CGFloat
  ) -> [JumpTarget] {
    // Layer 25 (`.statusBar`) windows are the menu-bar extras. Geometry only;
    // Flash's own click windows are excluded by pid.
    var targets: [JumpTarget] = []
    for window in raw {
      guard
        let layer = window[kCGWindowLayer as String] as? Int,
        layer == NSWindow.Level.statusBar.rawValue,
        let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
        ownerPID != ownPID,
        let windowNumber = window[kCGWindowNumber as String] as? CGWindowID,
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
        let x = bounds["X"], let y = bounds["Y"],
        let width = bounds["Width"], let height = bounds["Height"],
        width >= 8, width <= 400, height >= 8, height <= 44
      else { continue }
      let ownerName = window[kCGWindowOwnerName as String] as? String
      let frame = CGRect(x: x, y: screenH - y - height, width: width, height: height)
      targets.append(
        JumpTarget(
          id: "status_item_\(ownerPID)_\(windowNumber)",
          frame: frame,
          role: Self.statusItemHintRole,
          accessibilityLabel: ownerName,
          pid: pid_t(ownerPID),
          resolveClickPoint: { preferred in
            guard
              let current = HintWindowSnapshot.current(
                pid: pid_t(ownerPID), primaryHeight: screenH, windowNumber: windowNumber),
              current.layer == layer
            else { return nil }
            return JumpTarget.relocatedClickPoint(preferred, from: frame, to: current.frame)
          },
          entersInsertMode: false,
          providerID: menuBarProviderID))
    }
    return targets
  }

  private func presentSystemSurfaceHints(
    _ targets: [JumpTarget], pid: pid_t?, surface: String
  ) {
    guard !targets.isEmpty else {
      FlashLog.debug("[\(surface)] no_targets")
      applyModeOverlay()
      return
    }
    hintSession.sourceAppPID = pid
    hintSession.command = .click(.leftClick, modifiers: [])
    hintSession.surface = .targets
    hintSession.prefix = ""
    overlay.debugConfig = config.debug
    let hints = assignHints(targets)
    activationLifecycle.invalidate()
    hintSession.hints = hints
    applyModeOverlay()
    presentHints(hints, prepared: .miss, pid: pid, surface: surface)
    FlashLog.debug("[\(surface)] displayed targets=\(hints.count)")
  }

  private static func dockTargets(pid: pid_t, screenH: CGFloat) -> [JumpTarget] {
    let app = AXApp.make(pid: pid)
    var listRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &listRaw)
        == .success,
      let lists = listRaw as? [AXUIElement]
    else { return [] }
    var targets: [JumpTarget] = []
    for list in lists {
      var childrenRaw: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &childrenRaw)
          == .success,
        let children = childrenRaw as? [AXUIElement]
      else { continue }
      for child in children {
        var roleRaw: CFTypeRef?
        guard
          AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRaw)
            == .success,
          (roleRaw as? String) == "AXDockItem"
        else { continue }
        if let target = AccessibilityProvider.captureTarget(
          element: child, id: "dock_item_\(targets.count)", pid: pid, screenH: screenH,
          providerID: "mouse_dock", bundleIdentifier: "com.apple.dock")
        {
          targets.append(target)
        }
      }
    }
    return targets
  }
}
