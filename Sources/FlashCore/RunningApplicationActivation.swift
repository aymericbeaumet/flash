import AppKit
import ApplicationServices

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
    return app.activate(options: options)
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
