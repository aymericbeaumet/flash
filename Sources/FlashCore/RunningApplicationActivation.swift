import AppKit
import ApplicationServices

public enum RunningApplicationActivation {
  /// `restoringMinimizedWindows` costs one `kAXWindows` read plus one
  /// `kAXMinimized` read per window — synchronous AX IPC on the calling
  /// thread. Pass `false` when the target's window is known to be on screen
  /// (a hint commit, an INSERT hand-off to the focused app).
  @discardableResult
  public static func activate(
    _ app: NSRunningApplication,
    options: NSApplication.ActivationOptions = [.activateAllWindows],
    restoringMinimizedWindows: Bool = true
  ) -> Bool {
    if restoringMinimizedWindows {
      restoreMinimizedWindows(processID: app.processIdentifier)
    }
    app.unhide()
    return app.activate(options: options)
  }

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
