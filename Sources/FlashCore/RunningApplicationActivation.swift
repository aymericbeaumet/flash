import AppKit
import ApplicationServices

public enum RunningApplicationActivation {
  @discardableResult
  public static func activate(
    _ app: NSRunningApplication,
    options: NSApplication.ActivationOptions = [.activateAllWindows]
  ) -> Bool {
    restoreMinimizedWindows(processID: app.processIdentifier)
    app.unhide()
    return app.activate(options: options)
  }

  @discardableResult
  public static func restoreMinimizedWindows(processID pid: pid_t) -> Int {
    let axApp = AXUIElementCreateApplication(pid)
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
