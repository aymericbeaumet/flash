import AppKit
import ApplicationServices
import FlashCore

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
    if activationInFlight || !currentHints.isEmpty {
      cancelOverlay()
    }
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
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let items = Self.dockItems(pid: pid)
      DispatchQueue.main.async {
        guard let self else { return }
        let screenH = ActionDispatcher.primaryScreenHeight()
        let targets = items.enumerated().map { index, item in
          JumpTarget(
            id: "dock_item_\(index)",
            frame: CGRect(
              x: item.frame.minX, y: screenH - item.frame.maxY,
              width: item.frame.width, height: item.frame.height),
            role: "AXDockItem",
            accessibilityLabel: item.title,
            pid: pid,
            entersInsertMode: false,
            providerID: "mouse_dock")
        }
        self.presentSystemSurfaceHints(targets, pid: pid, surface: "mouse_dock")
      }
    }
  }

  func activateStatusItemHints() {
    if activationInFlight || !currentHints.isEmpty {
      cancelOverlay()
    }
    // Layer 25 (`.statusBar`) windows are the menu-bar extras. Geometry only;
    // Flash's own click windows are excluded by pid.
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
    let screenH = ActionDispatcher.primaryScreenHeight()
    var targets: [JumpTarget] = []
    for window in raw {
      guard
        let layer = window[kCGWindowLayer as String] as? Int,
        layer == NSWindow.Level.statusBar.rawValue,
        let ownerPID = window[kCGWindowOwnerPID as String] as? Int,
        ownerPID != ownPID,
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
        let x = bounds["X"], let y = bounds["Y"],
        let width = bounds["Width"], let height = bounds["Height"],
        width >= 8, width <= 400, height >= 8, height <= 44
      else { continue }
      let ownerName = window[kCGWindowOwnerName as String] as? String
      targets.append(
        JumpTarget(
          id: "status_item_\(targets.count)",
          // CG window bounds are top-left origin; flip to NSScreen.
          frame: CGRect(x: x, y: screenH - y - height, width: width, height: height),
          role: Self.statusItemHintRole,
          accessibilityLabel: ownerName,
          pid: pid_t(ownerPID),
          entersInsertMode: false,
          providerID: "mouse_statusbar"))
    }
    guard !targets.isEmpty else {
      FlashLog.debug("[mouse_statusbar] no_status_items")
      applyModeOverlay()
      return
    }
    presentSystemSurfaceHints(targets, pid: nil, surface: "mouse_statusbar")
  }

  private func presentSystemSurfaceHints(
    _ targets: [JumpTarget], pid: pid_t?, surface: String
  ) {
    guard !targets.isEmpty else {
      FlashLog.debug("[\(surface)] no_targets")
      applyModeOverlay()
      return
    }
    sourceAppPID = pid
    pendingAction = .leftClick
    pendingClickModifiers = []
    pendingHintCommitBehavior = .click
    currentPrefix = ""
    overlay.overlayConfig = config.overlay
    overlay.debugConfig = config.debug
    let hints = assignHints(targets)
    activationLifecycle.invalidate()
    currentHints = hints
    applyModeOverlay()
    overlay.display(hints: hints)
    FlashLog.debug("[\(surface)] displayed targets=\(hints.count)")
  }

  /// Dock items: title + frame (AX top-left coordinates) of every
  /// `AXDockItem` in the Dock's list.
  private static func dockItems(pid: pid_t) -> [(title: String?, frame: CGRect)] {
    let app = AXApp.make(pid: pid)
    var listRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &listRaw)
        == .success,
      let lists = listRaw as? [AXUIElement]
    else { return [] }
    var items: [(String?, CGRect)] = []
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
        var frameRaw: CFTypeRef?
        guard
          AXUIElementCopyAttributeValue(child, "AXFrame" as CFString, &frameRaw) == .success,
          let frameValue = frameRaw,
          CFGetTypeID(frameValue) == AXValueGetTypeID()
        else { continue }
        var frame = CGRect.zero
        guard AXValueGetValue((frameValue as! AXValue), .cgRect, &frame) else { continue }
        var titleRaw: CFTypeRef?
        let title =
          AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRaw)
            == .success
          ? titleRaw as? String : nil
        items.append((title, frame))
      }
    }
    return items
  }
}
