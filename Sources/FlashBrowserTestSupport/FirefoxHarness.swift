import AppKit
import ApplicationServices
import FlashCore
import FlashProviders
import Foundation

/// Boot + AX-traversal helpers for the Firefox browser integration
/// runner.
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
  /// Uses `Process` (not `open -a`) because Launch Services routes
  /// Firefox-family apps to an already-running default-profile instance
  /// even when `-profile -no-remote -new-instance` are supplied after
  /// `--args`. Launching the bundle's `Contents/MacOS/firefox` binary
  /// directly reliably starts the isolated test profile.
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
    offscreen: Bool = false,
    marionettePort: UInt16? = nil,
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

    // Reclaim our profile: a previous test run may have left a Firefox
    // process holding the .parentlock, which would manifest as a
    // "Close Firefox" dialog instead of the fixture page. Kill any
    // process whose command-line argv includes this profile path, then
    // remove residual lock files.
    reapStaleProfileHolders(profilePath: profilePath)

    // Snapshot whoever currently owns the foreground so we can put
    // them back once Firefox launches. Firefox internally activates
    // itself during startup, even when launched through its binary.
    let previousFrontmost = NSWorkspace.shared.frontmostApplication

    let preExisting = Set(
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .map { $0.processIdentifier })

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binPath)
    var firefoxArgs: [String] =
      ["-profile", profilePath, "-no-remote", "-new-instance"]
    if marionettePort != nil {
      // Firefox ignores -marionette-port and reads `marionette.port`
      // pref instead (set to 0 in user.js so Firefox picks a free
      // port). The caller is expected to read the actual port from
      // `<profile>/MarionetteActivePort` after launch.
      firefoxArgs.append("--marionette")
    }
    process.arguments = firefoxArgs + extraArgs + [url.absoluteString]
    // Capture stderr to a known path so failure modes (extension load
    // errors, content-script crashes, profile init issues) are
    // diagnosable post-mortem. stdout still goes to /dev/null — it's
    // pure noise from Firefox's startup.
    let stderrPath = "/tmp/flash-browser-test-firefox.stderr.log"
    FileManager.default.createFile(atPath: stderrPath, contents: nil)
    if let stderrHandle = FileHandle(forWritingAtPath: stderrPath) {
      process.standardError = stderrHandle
    }
    process.standardOutput = FileHandle.nullDevice
    do { try process.run() } catch { throw LaunchError.openFailed(error) }

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let current = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      let profilePids = Set(pidsHoldingProfile(profilePath: profilePath))
      let profileOwner = current.first {
        profilePids.contains($0.processIdentifier)
      }
      let newProcess = current.first {
        !preExisting.contains($0.processIdentifier)
      }
      if let app = profileOwner ?? newProcess {
        if waitForAXWindow(app, timeout: max(1, deadline.timeIntervalSinceNow)) {
          // Firefox finishes positioning its window asynchronously
          // after the AX window first reports as present. A too-early
          // AXPosition/Size write gets reverted by Firefox's own
          // placement. Sleep briefly, set, sleep, set again so the
          // change sticks.
          Thread.sleep(forTimeInterval: 0.4)
          if offscreen {
            moveWindowsOffscreen(pid: app.processIdentifier)
            Thread.sleep(forTimeInterval: 0.3)
            moveWindowsOffscreen(pid: app.processIdentifier)
          } else {
            maximizeWindows(pid: app.processIdentifier)
            Thread.sleep(forTimeInterval: 0.3)
            maximizeWindows(pid: app.processIdentifier)
          }
          previousFrontmost?.activate()
          return app
        }
        throw LaunchError.noAXWindow
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    throw LaunchError.openTimedOut
  }

  /// Size every Firefox top-level window to cover the primary
  /// screen. Firefox is launched in the background (`open -g`) so
  /// the window stays behind the user's foreground app — but if
  /// they click Firefox in the Dock they see the fixture page
  /// rendered at full size, which is useful for inspecting what
  /// the oracle saw.
  private static func maximizeWindows(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        == .success,
      let windows = raw as? [AXUIElement]
    else { return }
    let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let menuBarH: CGFloat = 25
    var pos = CGPoint(x: 0, y: menuBarH)
    var size = CGSize(width: screen.width, height: screen.height - menuBarH)
    guard let posValue = AXValueCreate(.cgPoint, &pos),
      let sizeValue = AXValueCreate(.cgSize, &size)
    else { return }
    for w in windows {
      AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, posValue)
      AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sizeValue)
    }
  }

  /// Reposition every Firefox top-level window to an off-screen
  /// coordinate. AXPosition writes are honored by Firefox even though
  /// the window stays renderable, and the AX tree (which is what
  /// Flash's provider walks) is unaffected by position.
  private static func moveWindowsOffscreen(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        == .success,
      let windows = raw as? [AXUIElement]
    else { return }
    // (-9999, -9999) is comfortably outside any reasonable monitor
    // arrangement. macOS clamps absurd values; this is large enough
    // to be invisible but small enough that the AX subsystem doesn't
    // refuse it.
    var off = CGPoint(x: -9999, y: -9999)
    guard let posValue = AXValueCreate(.cgPoint, &off) else { return }
    for w in windows {
      AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, posValue)
    }
  }

  /// Read the actual Marionette port Firefox bound to. Firefox writes
  /// the port into `<profile>/MarionetteActivePort` once the marionette
  /// server is listening. Polls up to `timeout` seconds.
  public static func readMarionettePort(
    profilePath: String, timeout: TimeInterval = 15
  ) -> UInt16? {
    let path = (profilePath as NSString)
      .appendingPathComponent("MarionetteActivePort")
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        let str = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        let port = UInt16(str)
      {
        return port
      }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return nil
  }

  /// Find Firefox processes holding `profilePath`, terminate them, and
  /// remove residual lock files. Safe to call when no such processes
  /// exist (no-op). Matches by argv substring so it only touches
  /// processes that were actually launched against this profile —
  /// the user's daily Firefox running against their default profile
  /// stays untouched.
  private static func reapStaleProfileHolders(profilePath: String) {
    let pids = pidsHoldingProfile(profilePath: profilePath)
      .filter { $0 != getpid() }
    if !pids.isEmpty {
      for p in pids { kill(p, SIGTERM) }
      Thread.sleep(forTimeInterval: 0.5)
      for p in pids { kill(p, SIGKILL) }
      Thread.sleep(forTimeInterval: 0.2)
    }
    // Even if no processes matched, a crashed previous run can leave
    // the lock behind. Always wipe.
    for name in [".parentlock", "lock", "parent.lock"] {
      try? FileManager.default.removeItem(
        atPath: (profilePath as NSString).appendingPathComponent(name))
    }
    // Also remove the crash-detection breadcrumbs so the next launch
    // doesn't show the "Troubleshoot Mode?" dialog. The max-resumed-
    // crashes pref handles repeat crashes, but a single dirty exit
    // can still trip the prompt before the pref takes effect.
    //
    // xulstore.json stores window geometry + maximized/fullscreen
    // state across launches; wiping it forces each run to start with
    // the default (small, windowed, non-fullscreen) layout regardless
    // of what state the previous session left behind.
    for name in [
      "sessionstore-backups", "sessionCheckpoints.json",
      "sessionstore.jsonlz4", "previous.jsonlz4", "recovery.jsonlz4",
      "recovery.baklz4", "xulstore.json",
    ] {
      try? FileManager.default.removeItem(
        atPath: (profilePath as NSString).appendingPathComponent(name))
    }
  }

  private static func pidsHoldingProfile(profilePath: String) -> [pid_t] {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", profilePath]
    let pipe = Pipe()
    pgrep.standardOutput = pipe
    pgrep.standardError = FileHandle.nullDevice
    do { try pgrep.run() } catch { return [] }
    pgrep.waitUntilExit()
    let raw = String(
      decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
      as: UTF8.self)
    return raw.split(whereSeparator: { $0.isWhitespace })
      .compactMap { pid_t($0) }
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
    var queue: [AXUIElement] = []
    var focusedRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRaw)
      == .success,
      let focused = focusedRaw,
      CFGetTypeID(focused) == AXUIElementGetTypeID()
    {
      let element = (focused as! AXUIElement)
      if role(of: element) == "AXWindow" { queue.append(element) }
    }
    var windowsRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRaw)
      == .success,
      let windows = windowsRaw as? [AXUIElement]
    {
      queue.append(contentsOf: windows.filter { role(of: $0) == "AXWindow" })
    }
    if queue.isEmpty { queue.append(app) }
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

  private static func role(of element: AXUIElement) -> String? {
    var roleRaw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRaw)
      == .success
    else { return nil }
    return roleRaw as? String
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
      bundleIdentifier: app.bundleIdentifier ?? FirefoxFixture.bundleID,
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
        (try? provider.discover(in: context)) ?? []
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
