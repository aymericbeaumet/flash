import AppKit
import ApplicationServices

/// How activation moves between apps on the running macOS. macOS 14 made it
/// cooperative: the active app hands activation over (`yieldActivation(to:)`,
/// `activate(from:options:)`) and `activateIgnoringOtherApps` has no effect.
/// macOS 13 has no handover; there a request carrying
/// `activateIgnoringOtherApps` moves activation as the handover does, and one
/// without it activates its app only while no other app is active.
public enum ActivationModel: Equatable, Sendable {
  case cooperative
  case forced

  public static let current: ActivationModel = {
    if #available(macOS 14.0, *) { return .cooperative }
    return .forced
  }()

  /// The options an activation request carries under this model.
  public func options(_ options: NSApplication.ActivationOptions)
    -> NSApplication.ActivationOptions
  {
    switch self {
    case .cooperative: return options
    case .forced: return options.union(.activateIgnoringOtherApps)
    }
  }
}

public enum RunningApplicationActivation {
  /// `restoringMinimizedWindows` costs one `kAXWindows` read plus one
  /// `kAXMinimized` read per window — AX IPC into the target app, which never
  /// runs on the main run loop: called from main, the restore follows on a
  /// background queue and a minimized window reappears a moment after the
  /// activation. Pass `false` when the target's window is known to be on
  /// screen (a hint commit, a forwarded click, an INSERT hand-off).
  @discardableResult
  public static func activate(
    _ app: NSRunningApplication,
    options: NSApplication.ActivationOptions = [.activateAllWindows],
    restoringMinimizedWindows: Bool = true
  ) -> Bool {
    if restoringMinimizedWindows {
      let pid = app.processIdentifier
      if Thread.isMainThread {
        restoreQueue.async { restoreMinimizedWindows(processID: pid) }
      } else {
        restoreMinimizedWindows(processID: pid)
      }
    }
    app.unhide()
    return app.activate(options: ActivationModel.current.options(options))
  }

  /// Moves activation from Flash to `app`. From macOS 14 Flash yields to it
  /// (when `yielding`), then activates it from Flash: `NSApp.deactivate()` and
  /// a bare `activate(options:)` are ignored there, and the cooperative
  /// handover is the request that moves activation. macOS 13 moves it with
  /// `activateIgnoringOtherApps` instead.
  @discardableResult
  public static func handOff(to app: NSRunningApplication, yielding: Bool) -> Bool {
    if #available(macOS 14.0, *) {
      if yielding { NSApp.yieldActivation(to: app) }
      return app.activate(from: .current, options: [])
    }
    return app.activate(options: ActivationModel.forced.options([]))
  }

  private static let restoreQueue = DispatchQueue(
    label: "flash.activation.restore_minimized", qos: .userInitiated)

  @discardableResult
  public static func restoreMinimizedWindows(processID pid: pid_t) -> Int {
    let axApp = AXApp.make(pid: pid)
    var rawWindows: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &rawWindows)
        == .success,
      let windows = rawWindows as? [AXUIElement]
    else { return 0 }

    var restored = 0
    for window in windows {
      var rawMinimized: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &rawMinimized)
          == .success,
        (rawMinimized as? Bool) == true
      else { continue }

      if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        == .success
      {
        restored += 1
      }
    }
    return restored
  }
}
