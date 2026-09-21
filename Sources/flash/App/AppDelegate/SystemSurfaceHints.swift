import AppKit
import ApplicationServices
import FlashCore
import FlashProviders

/// Hints beyond the focused app: the Dock (`mouse_dock`) and the menu-bar
/// status items (`mouse_statusbar`). Wooshy-parity coverage without new
/// permissions — the Dock is read through its own AX tree under the existing
/// Accessibility grant, and status items come from WindowServer geometry
/// (`CGWindowListCopyWindowInfo`, layer 25, geometry only — never content).
extension AppDelegate {
  /// Role stamped on status-item targets so the commit path suspends for the
  /// menu the click opens (same rule as right-click context menus).
  static let statusItemHintRole = "FlashStatusItem"

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

  func activateStatusItemHints() {
    guard prepareHintActivation(.statusItems) else { return }
    let token = activationLifecycle.begin()
    let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
    let screenH = ActionDispatcher.primaryScreenHeight()
    applyModeOverlay()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
      let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
      let targets = Self.statusItemTargets(raw, ownPID: ownPID, screenH: screenH)
      DispatchQueue.main.async {
        guard let self, self.activationLifecycle.complete(token: token) else { return }
        self.presentSystemSurfaceHints(targets, pid: nil, surface: "mouse_statusbar")
      }
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
          providerID: "mouse_statusbar"))
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
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    let hints = assignHints(targets)
    activationLifecycle.invalidate()
    hintSession.hints = hints
    applyModeOverlay()
    overlay.display(hints: hints)
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
