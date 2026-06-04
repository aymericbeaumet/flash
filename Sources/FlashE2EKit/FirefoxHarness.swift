import AppKit
import ApplicationServices
import FlashCore
import FlashProviders
import Foundation

/// Boot + AX-traversal helpers for the Firefox E2E. Shared by the
/// standalone runner and the xctest target so both forms apply the
/// same launch / settle / web-area-frame logic.
public enum FirefoxHarness {

  public enum LaunchError: Error, CustomStringConvertible {
    case notInstalled(String)
    case openFailed(Error)
    case openTimedOut
    case noAXWindow

    public var description: String {
      switch self {
      case .notInstalled(let path): return "Firefox not installed at \(path)"
      case .openFailed(let e): return "NSWorkspace.open failed: \(e)"
      case .openTimedOut: return "NSWorkspace.open did not return within 20s"
      case .noAXWindow: return "Firefox launched but reported no AX windows within 20s"
      }
    }
  }

  /// Launch Firefox with the fixture page and wait until it reports at
  /// least one AX window. Returns the running app.
  public static func launchWithFixture() throws -> NSRunningApplication {
    guard FileManager.default.fileExists(atPath: FirefoxFixture.appPath) else {
      throw LaunchError.notInstalled(FirefoxFixture.appPath)
    }
    let url = FirefoxFixture.dataURL()

    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    config.addsToRecentItems = false

    var launched: NSRunningApplication?
    var launchError: Error?
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.open(
      [url], withApplicationAt: URL(fileURLWithPath: FirefoxFixture.appPath),
      configuration: config
    ) { app, error in
      launched = app
      launchError = error
      sem.signal()
    }
    if sem.wait(timeout: .now() + 20) == .timedOut {
      throw LaunchError.openTimedOut
    }
    if let launchError {
      throw LaunchError.openFailed(launchError)
    }
    guard let app = launched else {
      throw LaunchError.openFailed(
        NSError(domain: "FirefoxHarness", code: 0))
    }
    guard waitForAXWindow(app, timeout: 20) else {
      throw LaunchError.noAXWindow
    }
    return app
  }

  /// Launch a Firefox-family browser with a dedicated profile and a URL.
  /// Uses `Process` (not NSWorkspace) because `NSWorkspace.open` does
  /// not reliably forward `-profile` to the underlying binary, and the
  /// oracle requires a known-good profile with Vimium-FF + the
  /// companion extension pre-installed.
  ///
  /// `-no-remote -new-instance` are essential: without them, a running
  /// Firefox would steal the URL into its own profile and we'd never
  /// get our oracle profile to load.
  ///
  /// Returns the `NSRunningApplication` for the new process. Because
  /// `firefox` on disk is a shim that re-execs `firefox-bin`, we can't
  /// trust the `Process.processIdentifier`; instead we snapshot existing
  /// Firefox PIDs by bundle ID and poll for the new one.
  public static func launchWithProfile(
    appPath: String,
    profilePath: String,
    url: URL,
    extraArgs: [String] = [],
    timeout: TimeInterval = 20
  ) throws -> NSRunningApplication {
    guard FileManager.default.fileExists(atPath: appPath) else {
      throw LaunchError.notInstalled(appPath)
    }
    let binPath = "\(appPath)/Contents/MacOS/firefox"
    guard FileManager.default.fileExists(atPath: binPath) else {
      throw LaunchError.notInstalled(binPath)
    }
    guard let bundleID = bundleIdentifier(forAppPath: appPath) else {
      throw LaunchError.openFailed(
        NSError(
          domain: "FirefoxHarness", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "could not read Info.plist at \(appPath)"]))
    }

    let preExisting = Set(
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .map { $0.processIdentifier })

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binPath)
    process.arguments =
      ["-profile", profilePath, "-no-remote", "-new-instance"]
      + extraArgs + [url.absoluteString]
    // Detach stdout/stderr — we don't want Firefox's chatter on our pipes.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { throw LaunchError.openFailed(error) }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let current = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      if let app = current.first(where: { !preExisting.contains($0.processIdentifier) }) {
        if waitForAXWindow(app, timeout: max(1, deadline.timeIntervalSinceNow)) {
          return app
        }
        throw LaunchError.noAXWindow
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    throw LaunchError.openTimedOut
  }

  private static func bundleIdentifier(forAppPath path: String) -> String? {
    let plistPath = "\(path)/Contents/Info.plist"
    guard let data = FileManager.default.contents(atPath: plistPath),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return plist["CFBundleIdentifier"] as? String
  }

  /// Wait until Firefox's AX root reports at least one window, or
  /// `timeout` expires.
  public static func waitForAXWindow(_ app: NSRunningApplication, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if app.processIdentifier > 0 {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw) == .success,
          let arr = raw as? [AXUIElement], !arr.isEmpty
        {
          return true
        }
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    return false
  }

  /// BFS-walk the AX tree from the app root, returning the AXWebArea
  /// frame in NSScreen coordinates. Used to filter hint targets to the
  /// page area (excluding Firefox chrome buttons).
  public static func findWebAreaFrame(pid: pid_t) -> CGRect? {
    let app = AXUIElementCreateApplication(pid)
    var queue: [AXUIElement] = [app]
    var visited = 0
    let maxNodes = 2000
    let screenH = primaryScreenHeight()
    while !queue.isEmpty, visited < maxNodes {
      let node = queue.removeFirst()
      visited += 1
      var roleRaw: CFTypeRef?
      _ = AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleRaw)
      let role = roleRaw as? String
      if role == "AXWebArea" {
        var posRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(node, kAXPositionAttribute as CFString, &posRaw)
        _ = AXUIElementCopyAttributeValue(node, kAXSizeAttribute as CFString, &sizeRaw)
        if let posCF = posRaw, let sizeCF = sizeRaw,
          CFGetTypeID(posCF) == AXValueGetTypeID(),
          CFGetTypeID(sizeCF) == AXValueGetTypeID()
        {
          let posV = posCF as! AXValue
          let sizeV = sizeCF as! AXValue
          var pos = CGPoint.zero
          var size = CGSize.zero
          if AXValueGetValue(posV, .cgPoint, &pos),
            AXValueGetValue(sizeV, .cgSize, &size),
            size.width > 0, size.height > 0
          {
            // AX is Y-down from primary top-left → convert to NSScreen Y-up.
            let nsY = screenH - pos.y - size.height
            return CGRect(x: pos.x, y: nsY, width: size.width, height: size.height)
          }
        }
      }
      var childrenRaw: CFTypeRef?
      if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenRaw)
        == .success,
        let children = childrenRaw as? [AXUIElement]
      {
        queue.append(contentsOf: children)
      }
    }
    return nil
  }

  /// Build the `AppContext` Flash would pass to `AccessibilityProvider`
  /// in production. The front-window frame is set to the full primary
  /// screen since the test isn't trying to scope hints to a window
  /// sub-region.
  public static func makeContext(for app: NSRunningApplication) -> AppContext {
    let screen =
      NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
      ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    return AppContext(
      bundleIdentifier: FirefoxFixture.bundleID,
      processID: app.processIdentifier,
      runningApp: app,
      frontWindowFrame: screen,
      allScreensFrame: screen
    )
  }

  /// Repeatedly walk via `provider.discover` until either the AXLink
  /// floor for the fixture is reached, or `timeout` expires. Returns
  /// the last walk's targets + the discovered AXWebArea frame.
  ///
  /// Firefox's a11y service is lazy — until something wakes it, the
  /// web area only exposes chrome buttons. `AccessibilityProvider`
  /// sets `AXEnhancedUserInterface` / `AXManualAccessibility` on every
  /// discover() call, which is enough to wake it, but the wake itself
  /// is asynchronous (Firefox needs to build the in-memory AX tree
  /// for the document). This loop polls until the expected fixture
  /// links surface.
  public static func waitForStableTree(
    provider: AccessibilityProvider,
    context: AppContext,
    timeout: TimeInterval
  ) -> (targets: [JumpTarget], webAreaFrame: CGRect?) {
    let expectedLinks = FirefoxFixture.Counts.expectedLinks
    var lastTargets: [JumpTarget] = []
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      lastTargets =
        (try? provider.discover(in: context, deadline: Date().addingTimeInterval(2))) ?? []
      let linkCount = lastTargets.filter { $0.role == "AXLink" }.count
      if linkCount >= expectedLinks { break }
      Thread.sleep(forTimeInterval: 0.25)
    }
    let web = findWebAreaFrame(pid: context.processID)
    return (lastTargets, web)
  }

  private static func primaryScreenHeight() -> CGFloat {
    NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height ?? 1080
  }
}
